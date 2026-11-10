#!/usr/bin/python3
"""
cc-menubar — Linux (AppIndicator / GTK3) & CLI menu bar monitor for running
Antigravity CLI (agy) and Claude Code sessions, locally and over SSH.
"""

import concurrent.futures
import dataclasses
import datetime
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

CONFIG_DIR = Path.home() / ".config" / "cc-menubar"
CONFIG_PATH = CONFIG_DIR / "config.json"
CACHE_DIR = Path.home() / ".cache" / "cc-menubar"
USAGE_PATH = CACHE_DIR / "usage.json"
ICON_DIR = CACHE_DIR / "icons"

SSH_OPTS = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=/tmp/cc-menubar-%C",
    "-o", "ControlPersist=600",
]

# Runs on local or remote host via `/bin/sh -s`.
# Collects both Claude Code (~/.claude/sessions/*.json) and Antigravity CLI (~/.gemini/antigravity-cli).
COLLECT_SCRIPT = r"""
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin"
hname=$(hostname 2>/dev/null || uname -n 2>/dev/null)

# 1. Claude Code sessions (~/.claude/sessions/*.json)
for f in "$HOME"/.claude/sessions/*.json; do
  [ -e "$f" ] || continue
  pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$f")
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
  pane=$(sed -n 's/.*"tmux":"[^"]*\.\(%[0-9]*\)".*/\1/p' "$f")
  title=""
  if [ -n "$pane" ] && command -v tmux >/dev/null 2>&1; then
    title=$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null)
    [ "$title" = "$hname" ] && title=""
  fi
  printf '%s\t%s\n' "$(tr -d '\n\t' < "$f")" "$title"
done

# 2. Antigravity CLI (agy) sessions (~/.gemini/antigravity-cli)
if [ -d "$HOME/.gemini/antigravity-cli/presence" ] && command -v python3 >/dev/null 2>&1; then
  python3 - <<'PYEOF' 2>/dev/null
import datetime, glob, json, os, sqlite3, subprocess

home = os.path.expanduser("~")
agy_dir = os.path.join(home, ".gemini", "antigravity-cli")
presence_dir = os.path.join(agy_dir, "presence")

# Map conversation_id -> pid holding ~/.gemini/antigravity-cli/presence/<cid>.lock
locks = {}
if os.path.isdir("/proc"):
    for fd in glob.glob("/proc/[0-9]*/fd/*"):
        try:
            target = os.readlink(fd)
        except OSError:
            continue
        if target.startswith(presence_dir + "/") and target.endswith(".lock"):
            try:
                pid = int(fd.split("/")[2])
            except ValueError:
                continue
            cid = os.path.basename(target)[:-5]
            comm = ""
            try:
                with open(f"/proc/{pid}/comm", "r", encoding="utf-8", errors="ignore") as cf:
                    comm = cf.read().strip()
            except OSError:
                pass
            # Prefer the main 'agy' process over child processes that inherited the fd
            prev = locks.get(cid)
            if prev is None or (comm == "agy" and prev[1] != "agy") or (comm == prev[1] and pid < prev[0]):
                locks[cid] = (pid, comm)
else:
    # Fallback for macOS / non-procfs hosts using lsof
    try:
        out = subprocess.check_output(["lsof", "-F", "pcn", "--"] + glob.glob(os.path.join(presence_dir, "*.lock")), stderr=subprocess.DEVNULL, text=True)
        cur_pid, cur_comm = None, ""
        for line in out.splitlines():
            if line.startswith("p"):
                cur_pid = int(line[1:])
            elif line.startswith("c"):
                cur_comm = line[1:]
            elif line.startswith("n") and line.endswith(".lock") and cur_pid:
                cid = os.path.basename(line[1:])[:-5]
                prev = locks.get(cid)
                if prev is None or (cur_comm == "agy" and prev[1] != "agy"):
                    locks[cid] = (cur_pid, cur_comm)
    except Exception:
        pass

if not locks:
    raise SystemExit(0)

db_rows = {}
db_path = os.path.join(agy_dir, "conversation_summaries.db")
if os.path.isfile(db_path):
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=1.0)
        q = "SELECT conversation_id, title, status, not_fully_idle, last_modified_time, last_user_input_time, workspace_uris FROM conversation_summaries"
        for row in conn.execute(q):
            db_rows[row[0]] = row[1:]
        conn.close()
    except Exception:
        pass

def parse_iso_ms(s):
    if not s or s.startswith("0001-01-01"):
        return None
    try:
        s = s.strip().replace(" ", "T")
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        # Truncate nanoseconds to microseconds for Python < 3.11 compatibility
        m = __import__("re").match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?([+-]\d{2}:\d{2})?$", s)
        if m:
            base, frac, tz = m.group(1), (m.group(2) or "")[:6].ljust(6, "0"), m.group(3) or "+00:00"
            dt = datetime.datetime.fromisoformat(f"{base}.{frac}{tz}")
            return int(dt.timestamp() * 1000)
    except Exception:
        pass
    return None

for cid, (pid, _) in locks.items():
    cwd = ""
    pane = None
    try:
        cwd = os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        pass
    try:
        with open(f"/proc/{pid}/environ", "rb") as ef:
            for item in ef.read().split(b"\0"):
                if item.startswith(b"TMUX_PANE="):
                    pane = item.split(b"=", 1)[1].decode("utf-8", "ignore")
                    break
    except OSError:
        pass

    title, db_status, not_idle, mod_time, input_time, ws_uris = db_rows.get(
        cid, ("", "CASCADE_RUN_STATUS_IDLE", 0, "", "", "[]")
    )
    if not cwd:
        try:
            uris = json.loads(ws_uris)
            if uris and uris[0].startswith("file://"):
                cwd = uris[0][7:]
        except Exception:
            pass

    status = "idle"
    if db_status in ("CASCADE_RUN_STATUS_RUNNING", "CASCADE_RUN_STATUS_BUSY", "CASCADE_RUN_STATUS_CANCELING") or not_idle:
        status = "busy"

    status_ts = parse_iso_ms(input_time if status == "busy" else mod_time) or parse_iso_ms(mod_time)

    # Check transcript tail for WAITING status or fresher step timestamps
    tpath = os.path.join(agy_dir, "brain", cid, ".system_generated", "logs", "transcript.jsonl")
    if os.path.isfile(tpath):
        try:
            with open(tpath, "rb") as tf:
                tf.seek(0, os.SEEK_END)
                size = tf.tell()
                tf.seek(max(0, size - 32768))
                lines = [ln for ln in tf.read().splitlines() if ln.strip()]
            if lines:
                last_step = json.loads(lines[-1])
                st = last_step.get("status", "")
                if st in ("WAITING", "CORTEX_STEP_STATUS_WAITING"):
                    status = "waiting"
                    status_ts = parse_iso_ms(last_step.get("created_at")) or status_ts
                elif status == "busy":
                    for raw in reversed(lines):
                        step = json.loads(raw)
                        if step.get("type") == "USER_INPUT":
                            status_ts = parse_iso_ms(step.get("created_at")) or status_ts
                            break
                elif status == "idle" and not status_ts:
                    status_ts = parse_iso_ms(last_step.get("created_at"))
        except Exception:
            pass

    if not status_ts:
        try:
            status_ts = int(os.path.getmtime(os.path.join(presence_dir, f"{cid}.lock")) * 1000)
        except OSError:
            status_ts = int(datetime.datetime.now().timestamp() * 1000)

    name = os.path.basename(cwd.rstrip("/")) if cwd and cwd != home else ("~" if cwd == home else cid[:8])
    obj = {
        "pid": pid,
        "sessionId": cid,
        "name": name,
        "status": status,
        "tmux": pane,
        "cwd": cwd,
        "statusUpdatedAt": status_ts,
        "entrypoint": "agy",
    }
    clean_title = (title or "").replace("\n", " ").replace("\t", " ").strip()
    print(f"{json.dumps(obj, separators=(',', ':'))}\t{clean_title}")
PYEOF
fi

# 3. Usage limits saved by statusline.sh (cc-menubar), with the file's mtime.
u="$HOME/.cache/cc-menubar/usage.json"
if [ -f "$u" ]; then printf 'USAGE\t%s\t%s\n' "$(date -r "$u" +%s)" "$(tr -d '\n\t' < "$u")"; fi

# 4. Is the cc-menubar status line hook set up here?
s="$HOME/.claude/settings.json"
if grep -q 'cc-menubar-statusline' "$s" 2>/dev/null; then h=installed
elif grep -q '"statusLine"' "$s" 2>/dev/null; then h=other
elif [ -d "$HOME/.claude" ]; then h=none
else h=no_claude; fi
printf 'HOOK\t%s\n' "$h"
"""


@dataclasses.dataclass
class HostConfig:
    name: str
    ssh: Optional[str] = None


@dataclasses.dataclass
class Config:
    interval: float = 5.0
    notify: bool = True
    terminalApp: str = "Ghostty"
    maxWidth: float = 600.0
    hosts: List[HostConfig] = dataclasses.field(
        default_factory=lambda: [HostConfig(name="local", ssh=None)]
    )


@dataclasses.dataclass
class Session:
    host: str
    ssh: Optional[str]
    sessionId: str
    name: str
    status: str
    pane: Optional[str]
    title: str
    cwd: str
    statusSince: Optional[float]  # epoch seconds
    entrypoint: str

    @property
    def key(self) -> str:
        return f"{self.host}/{self.sessionId}"


@dataclasses.dataclass
class UsageWindow:
    pct: float
    resetsAt: float  # epoch seconds


@dataclasses.dataclass
class HostResult:
    host: HostConfig
    sessions: List[Session] = dataclasses.field(default_factory=list)
    error: Optional[str] = None
    usage: Optional[Tuple[bytes, float]] = None
    hook: Optional[str] = None


def load_config() -> Config:
    if CONFIG_PATH.exists():
        try:
            raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            hosts = [
                HostConfig(name=h["name"], ssh=h.get("ssh"))
                for h in raw.get("hosts", [{"name": "local"}])
                if isinstance(h, dict) and "name" in h
            ]
            return Config(
                interval=float(raw.get("interval", 5)),
                notify=bool(raw.get("notify", True)),
                terminalApp=str(raw.get("terminalApp", "Ghostty")),
                maxWidth=float(raw.get("maxWidth", 600)),
                hosts=hosts or [HostConfig(name="local")],
            )
        except Exception:
            pass
    cfg = Config()
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if not CONFIG_PATH.exists():
        data = {
            "hosts": [{"name": h.name, **({"ssh": h.ssh} if h.ssh else {})} for h in cfg.hosts],
            "interval": int(cfg.interval),
            "maxWidth": int(cfg.maxWidth),
            "notify": cfg.notify,
            "terminalApp": cfg.terminalApp,
        }
        try:
            CONFIG_PATH.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        except Exception:
            pass
    return cfg


def run_cmd(
    exe: str,
    args: List[str],
    stdin: Optional[str] = None,
    timeout: float = 15.0,
    extra_env: Optional[Dict[str, str]] = None,
) -> Tuple[int, str, str]:
    env = os.environ.copy()
    env["PATH"] = f"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:{env.get('PATH', '')}"
    if extra_env:
        env.update(extra_env)
    try:
        proc = subprocess.run(
            [exe] + args,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 15, "", "timed out"
    except Exception as e:
        return -1, "", str(e)


def status_category(status: str) -> str:
    """Returns 'red' (waiting), 'orange' (working), or 'green' (idle)."""
    if status == "idle":
        return "green"
    if status in ("waiting", "needs_input", "awaiting_input", "permission"):
        return "red"
    return "orange"


def status_dot(cat: str, entrypoint: str = "") -> str:
    if entrypoint == "agy":
        return {"red": "🟥", "orange": "🟧", "green": "🟩"}.get(cat, "🟧")
    return {"red": "🔴", "orange": "🟠", "green": "🟢"}.get(cat, "🟠")


def ago(ts: Optional[float]) -> str:
    if ts is None:
        return ""
    s = max(0, int(time.time() - ts))
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h"
    return f"{s // 86400}d"


def until_string(ts: float) -> str:
    s = max(0, int(ts - time.time()))
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h{(s % 3600) // 60:02d}m"
    return f"{s // 86400}d{(s % 86400) // 3600}h"


def short_path(p: str) -> str:
    home = str(Path.home())
    return ("~" + p[len(home):]) if p.startswith(home) else p


def collect(host: HostConfig) -> HostResult:
    res = HostResult(host=host)
    if host.ssh:
        code, out, err = run_cmd("/usr/bin/ssh", SSH_OPTS + [host.ssh, "sh", "-s"], stdin=COLLECT_SCRIPT)
    else:
        code, out, err = run_cmd("/bin/sh", ["-s"], stdin=COLLECT_SCRIPT)

    if code != 0 and not out.strip():
        last_err = [ln for ln in err.splitlines() if ln.strip()]
        res.error = "timed out" if code == 15 else (last_err[-1] if last_err else f"exit {code}")
        return res

    for line in out.splitlines():
        if not line:
            continue
        if line.startswith("HOOK\t"):
            res.hook = line[5:].strip()
            continue
        if line.startswith("USAGE\t"):
            parts = line.split("\t", 2)
            if len(parts) == 3:
                try:
                    res.usage = (parts[2].encode("utf-8"), float(parts[1]))
                except ValueError:
                    pass
            continue
        parts = line.split("\t", 1)
        try:
            j = json.loads(parts[0])
        except Exception:
            continue
        title = parts[1] if len(parts) > 1 else ""
        title = re.sub(r"^[✳✻·*\s]+", "", title)
        raw_tmux = j.get("tmux")
        pane = raw_tmux.split(".")[-1] if isinstance(raw_tmux, str) and raw_tmux else None
        ts = j.get("statusUpdatedAt") or j.get("updatedAt")
        status_since = (float(ts) / 1000.0) if isinstance(ts, (int, float)) else None
        res.sessions.append(
            Session(
                host=host.name,
                ssh=host.ssh,
                sessionId=str(j.get("sessionId", "?")),
                name=str(j.get("name", "-")),
                status=str(j.get("status", "unknown")),
                pane=pane,
                title=title,
                cwd=str(j.get("cwd", "")),
                statusSince=status_since,
                entrypoint=str(j.get("entrypoint", "")),
            )
        )

    # Disambiguate if multiple sessions on the same host share the same derived directory name
    name_counts: Dict[str, int] = {}
    for s in res.sessions:
        name_counts[s.name] = name_counts.get(s.name, 0) + 1
    for s in res.sessions:
        if name_counts.get(s.name, 0) > 1 and s.pane:
            s.name = f"{s.name}:{s.pane.lstrip('%')}"

    res.sessions.sort(key=lambda s: (1 if s.status == "idle" else 0, s.name))
    return res


def read_usage(
    results: List[HostResult],
) -> Tuple[Optional[UsageWindow], Optional[UsageWindow], Optional[float], Optional[str]]:
    candidates: List[Tuple[bytes, float, str]] = []
    for r in results:
        if r.usage:
            candidates.append((r.usage[0], r.usage[1], r.host.name))
    if not candidates and USAGE_PATH.exists():
        try:
            candidates.append((USAGE_PATH.read_bytes(), USAGE_PATH.stat().st_mtime, "local"))
        except Exception:
            pass
    if not candidates:
        return None, None, None, None
    best_json, best_ts, best_src = max(candidates, key=lambda x: x[1])
    try:
        j = json.loads(best_json)
        rl = j.get("rate_limits") or {}
    except Exception:
        return None, None, None, None

    def win(k: str) -> Optional[UsageWindow]:
        w = rl.get(k)
        if not isinstance(w, dict):
            return None
        p = w.get("used_percentage")
        r = w.get("resets_at")
        if not isinstance(p, (int, float)) or not isinstance(r, (int, float)):
            return None
        pct = 0.0 if float(r) < time.time() else float(p)
        return UsageWindow(pct=pct, resetsAt=float(r))

    return win("five_hour"), win("seven_day"), best_ts, best_src


def build_title(
    results: List[HostResult],
    last_finished: Dict[str, float],
    level: int = 0,
) -> str:
    """
    level 0: full
    level 1: shorter names, tighter gaps
    level 2: working sessions as '🟠 time' without names
    level 3: counts only
    """
    parts: List[str] = []
    name_len = 20 if level == 0 else 12
    host_gap = "     " if level == 0 else ("    " if level == 1 else "   ")

    def clip(s: str) -> str:
        return (s[: name_len - 1] + "…") if len(s) > name_len else s

    five_h, weekly, updated, _ = read_usage(results)
    if updated is not None or any(r.hook == "installed" for r in results):
        u_parts = []
        for label, w in (("5h", five_h), ("wk", weekly)):
            pct = int(w.pct) if w else 0
            u_parts.append(f"{label} {pct}%")
        parts.append("cc " + "  ".join(u_parts))
        parts.append(host_gap)

    host_segments: List[str] = []
    now = time.time()
    for h in results:
        seg = f"{h.host.name} "
        if h.error is not None:
            seg += "⚠"
        elif not h.sessions:
            seg += "0"
        else:
            groups_out: List[str] = []
            for cat in ("red", "orange", "green"):
                group = [s for s in h.sessions if status_category(s.status) == cat]
                if not group:
                    continue
                if cat == "orange" and level < 3:
                    sorted_g = sorted(group, key=lambda s: s.statusSince if s.statusSince is not None else float("inf"))
                    items: List[str] = []
                    for s in sorted_g:
                        piece = status_dot(cat, s.entrypoint)
                        if level < 2:
                            piece += f" {clip(s.name)}"
                        since = ago(s.statusSince)
                        if since:
                            piece += f" {since}"
                        items.append(piece)
                    sep = "  " if level < 2 else " "
                    groups_out.append(sep.join(items))
                    continue

                cc_sub = [s for s in group if s.entrypoint != "agy"]
                agy_sub = [s for s in group if s.entrypoint == "agy"]
                counts_tokens: List[str] = []
                if cc_sub:
                    counts_tokens.append(f"{status_dot(cat, '')}{len(cc_sub)}")
                if agy_sub:
                    counts_tokens.append(f"{status_dot(cat, 'agy')}{len(agy_sub)}")
                piece = " ".join(counts_tokens)

                oldest = min(group, key=lambda s: s.statusSince if s.statusSince is not None else float("inf"))
                if level >= 3:
                    pass
                elif cat == "orange":
                    since = ago(oldest.statusSince)
                    if since:
                        piece += f" {since}"
                elif cat == "red":
                    piece += f" {clip(oldest.name)}"
                    if len(group) > 1:
                        piece += f" +{len(group) - 1}"
                elif cat == "green":
                    done = last_finished.get(h.host.name)
                    if done is not None and (now - done) < 3600:
                        piece += f" ✓{ago(done)}"
                groups_out.append(piece)
            seg += "  ".join(groups_out)
        host_segments.append(seg)

    parts.append(host_gap.join(host_segments))
    return "".join(parts)


def render_compact_title(
    results: List[HostResult],
    last_finished: Dict[str, float],
    max_width: float,
) -> str:
    # Approximate 1 character ~ 7.5 points in top bar font
    max_chars = max(24, int(max_width / 7.5))
    t = build_title(results, last_finished, level=0)
    for lvl in (1, 2, 3):
        if len(t) > max_chars:
            t = build_title(results, last_finished, level=lvl)
    return t


def ensure_icons() -> str:
    """Create minimal 1x1 transparent SVG icons so the top bar shows clean text + colored dots."""
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="16" viewBox="0 0 1 16">'
        '<rect width="1" height="16" fill="none"/>'
        "</svg>\n"
    )
    icon_file = ICON_DIR / "cc-menubar-empty.svg"
    if not icon_file.exists():
        icon_file.write_text(svg, encoding="utf-8")
    return str(ICON_DIR)


def escape_dbusmenu_label(text: str) -> str:
    """
    ubuntu-appindicators' dbusMenu.js runs `.replace(/_([^_])/, '$1')` (non-global) on every
    menu item label. Doubling the first underscore preserves all literal underscores.
    """
    return text.replace("_", "__", 1)


def send_notification(title: str, body: str) -> None:
    if shutil.which("notify-send"):
        subprocess.Popen(
            ["notify-send", "-a", "cc-menubar", title, body],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def focus_terminal_app(app_name: Optional[str]) -> None:
    if not app_name:
        return
    # On X11 / XWayland with wmctrl installed, raise existing window without spawning a duplicate
    if shutil.which("wmctrl"):
        subprocess.Popen(
            ["wmctrl", "-xa", app_name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def run_once_cli() -> int:
    cfg = load_config()
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(cfg.hosts))) as pool:
        results = list(pool.map(collect, cfg.hosts))
    title = render_compact_title(results, {}, cfg.maxWidth)
    print(f"Top bar: {title}\n")
    for r in results:
        hdr = f"[{r.host.name}]"
        if r.error:
            print(f"{hdr} ⚠ {r.error}")
            continue
        print(f"{hdr} {len(r.sessions)} session(s):")
        for s in r.sessions:
            dot = status_dot(status_category(s.status), s.entrypoint)
            kind = "agy" if s.entrypoint == "agy" else "claude"
            print(
                f"  {dot} {s.name:<20} {s.status:<8} {ago(s.statusSince):<5} "
                f"[{kind}] pane={s.pane or '-'}  {s.title or '-'}  ({short_path(s.cwd)})"
            )
    return 0


def run_tray_app() -> int:
    import fcntl
    import gi

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    lock_file = open(CACHE_DIR / "instance.lock", "w", encoding="utf-8")
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("cc-menubar is already running.", file=sys.stderr)
        return 0

    gi.require_version("Gtk", "3.0")
    try:
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3 as AppIndicator3
    except ValueError:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3

    from gi.repository import Gdk, GLib, Gtk

    class TrayApp:
        def __init__(self) -> None:
            self.config = load_config()
            self.results: List[HostResult] = []
            self.last_status: Dict[str, str] = {}
            self.last_finished: Dict[str, float] = {}
            self.polling = False
            self.poll_timer_id: Optional[int] = None
            self.tick_timer_id: Optional[int] = None

            icon_theme_path = ensure_icons()
            self.indicator = AppIndicator3.Indicator.new(
                "cc-menubar",
                "cc-menubar-empty",
                AppIndicator3.IndicatorCategory.APPLICATION_STATUS,
            )
            self.indicator.set_icon_theme_path(icon_theme_path)
            self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
            self.indicator.set_label("CC …", "CC …")

            self.menu = Gtk.Menu()
            self.indicator.set_menu(self.menu)

            self.start_timers()
            self.poll()

        def start_timers(self) -> None:
            if self.poll_timer_id is not None:
                GLib.source_remove(self.poll_timer_id)
            interval_ms = int(max(2.0, self.config.interval) * 1000)
            self.poll_timer_id = GLib.timeout_add(interval_ms, self._on_poll_timer)
            if self.tick_timer_id is None:
                self.tick_timer_id = GLib.timeout_add(1000, self._on_tick_timer)

        def _on_poll_timer(self) -> bool:
            self.poll()
            return True

        def _on_tick_timer(self) -> bool:
            now = time.time()
            recent = lambda ts: (ts is not None) and ((now - ts) < 61)
            working = [
                s
                for r in self.results
                for s in r.sessions
                if status_category(s.status) != "green"
            ]
            if any(recent(s.statusSince) for s in working) or any(
                recent(ts) for ts in self.last_finished.values()
            ):
                self.render_title()
            return True

        def poll(self) -> None:
            if self.polling:
                return
            self.polling = True
            hosts = list(self.config.hosts)

            def worker() -> None:
                with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(hosts))) as pool:
                    res = list(pool.map(collect, hosts))
                GLib.idle_add(self._on_poll_complete, res)

            threading.Thread(target=worker, daemon=True).start()

        def _on_poll_complete(self, results: List[HostResult]) -> bool:
            self.polling = False
            self.results = results
            all_sessions = [s for r in results for s in r.sessions]

            for s in all_sessions:
                prev_cat = status_category(self.last_status.get(s.key, "idle"))
                if s.status == "idle" and prev_cat == "orange":
                    self.last_finished[s.host] = s.statusSince or time.time()
                    if self.config.notify:
                        agent_label = "Antigravity" if s.entrypoint == "agy" else "Claude"
                        body = f"{s.host} · {s.title if s.title else short_path(s.cwd)}"
                        send_notification(f"{agent_label} finished: {s.name}", body)

            self.last_status = {s.key: s.status for s in all_sessions}
            self.render_title()
            self.rebuild_menu()
            return False

        def render_title(self) -> None:
            t = render_compact_title(self.results, self.last_finished, self.config.maxWidth)
            self.indicator.set_label(t, t)

        def _make_item(
            self,
            label: str,
            sensitive: bool = True,
            callback=None,
            arg=None,
        ) -> Gtk.MenuItem:
            item = Gtk.MenuItem.new_with_label(escape_dbusmenu_label(label))
            item.set_use_underline(False)
            item.set_sensitive(sensitive)
            if callback is not None:
                if arg is not None:
                    item.connect("activate", callback, arg)
                else:
                    item.connect("activate", callback)
            return item

        def rebuild_menu(self) -> None:
            for child in self.menu.get_children():
                self.menu.remove(child)

            def rank(st: str) -> int:
                c = status_category(st)
                return 0 if c == "red" else (1 if c == "orange" else 2)

            def clip(s: str, n: int) -> str:
                return (s[: n - 1] + "…") if len(s) > n else s

            def add_header(r: HostResult) -> None:
                if self.menu.get_children():
                    self.menu.append(Gtk.SeparatorMenuItem())
                h = r.host.name
                if r.error:
                    h += f"  ⚠ {r.error}"
                else:
                    h += f"  · {len(r.sessions)}"
                self.menu.append(self._make_item(h, sensitive=False))

            all_sorted: List[Session] = []
            for r in self.results:
                s_list = sorted(
                    r.sessions,
                    key=lambda s: (rank(s.status), -(s.statusSince or 0.0)),
                )
                all_sorted.extend(s_list)

            emitted = set()
            last_host: Optional[str] = None

            for s in all_sorted:
                if s.host != last_host:
                    for r in self.results:
                        if r.host.name not in emitted:
                            emitted.add(r.host.name)
                            add_header(r)
                            if r.host.name == s.host:
                                break
                    last_host = s.host

                dot = status_dot(status_category(s.status), s.entrypoint)
                title = "" if s.title in ("", "Claude Code") else clip(s.title, 44)
                age_str = f"{s.status} {ago(s.statusSince)}".strip()
                tag = "agy" if s.entrypoint == "agy" else "cc"
                parts = [f"{dot} {clip(s.name, 28)} [{tag}]", age_str]
                if title:
                    parts.append(title)
                parts.append(short_path(s.cwd))
                row_text = "   ·   ".join(parts)
                self.menu.append(self._make_item(row_text, sensitive=True, callback=self.on_activate_session, arg=s))

            for r in self.results:
                if r.host.name not in emitted:
                    add_header(r)

            # Usage section (shown if usage exists or Claude Code is present on any host)
            five_h, weekly, updated, source = read_usage(self.results)
            has_claude = any(r.hook in ("installed", "other", "none") for r in self.results)
            if updated is not None or has_claude:
                self.menu.append(Gtk.SeparatorMenuItem())
                if updated is not None or any(r.hook == "installed" for r in self.results):
                    for label, w in (("Claude 5-hour", five_h), ("Claude weekly", weekly)):
                        pct = int(w.pct) if w else 0
                        note = f"resets in {until_string(w.resetsAt)}" if w else "no data"
                        self.menu.append(
                            self._make_item(f"{label} usage   {pct}%   ({note})", sensitive=False)
                        )
                    if updated is not None:
                        self.menu.append(
                            self._make_item(
                                f"Usage as of {ago(updated)} ago, from {source or '?'}",
                                sensitive=False,
                            )
                        )

                missing = [r for r in self.results if r.error is None and r.hook == "none"]
                for r in missing:
                    self.menu.append(
                        self._make_item(
                            f"Enable usage tracking on {r.host.name}…",
                            sensitive=True,
                            callback=self.on_enable_usage,
                            arg=[r.host.name],
                        )
                    )
                if len(missing) > 1:
                    self.menu.append(
                        self._make_item(
                            f"Enable usage tracking on all {len(missing)} hosts…",
                            sensitive=True,
                            callback=self.on_enable_usage,
                            arg=[r.host.name for r in missing],
                        )
                    )
                for r in self.results:
                    if r.hook == "other":
                        self.menu.append(
                            self._make_item(
                                f"{r.host.name}: has its own status line, usage not tracked",
                                sensitive=False,
                            )
                        )

            self.menu.append(Gtk.SeparatorMenuItem())
            self.menu.append(self._make_item("Refresh now", callback=lambda _: self.poll()))
            self.menu.append(self._make_item("Edit hosts…", callback=self.on_edit_config))
            self.menu.append(self._make_item("Reload config", callback=self.on_reload_config))
            self.menu.append(self._make_item("Quit", callback=lambda _: Gtk.main_quit()))
            self.menu.show_all()

        def on_activate_session(self, _item: Gtk.MenuItem, s: Session) -> None:
            if not s.pane:
                resume_bin = f"agy --conversation {shlex.quote(s.sessionId)}" if s.entrypoint == "agy" else f"claude --resume {shlex.quote(s.sessionId)}"
                cmd = f"cd {shlex.quote(s.cwd)} && {resume_bin}"
                if s.ssh:
                    cmd = f"ssh -t {shlex.quote(s.ssh)} {shlex.quote(cmd)}"
                clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
                clip.set_text(cmd, -1)
                clip.store()
                send_notification("Copied resume command", cmd)
                return

            tm = (
                f"tmux switch-client -t {shlex.quote(s.pane)} 2>/dev/null; "
                f"tmux select-window -t {shlex.quote(s.pane)}; "
                f"tmux select-pane -t {shlex.quote(s.pane)}"
            )
            term = self.config.terminalApp

            def worker() -> None:
                if s.ssh:
                    run_cmd(
                        "/usr/bin/ssh",
                        SSH_OPTS + [s.ssh, "sh", "-s"],
                        stdin=f'PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"\n{tm}\n',
                    )
                else:
                    run_cmd("/bin/sh", ["-c", tm])
                focus_terminal_app(term)

            threading.Thread(target=worker, daemon=True).start()

        def on_enable_usage(self, _item: Gtk.MenuItem, host_names: List[str]) -> None:
            installer = Path(__file__).resolve().parent / "install-statusline.sh"
            if not installer.exists():
                send_notification("cc-menubar", f"Missing {installer}")
                return
            hosts = [h for h in self.config.hosts if h.name in host_names]
            opts = " ".join(SSH_OPTS)

            def worker() -> None:
                lines = []
                for h in hosts:
                    args = [str(installer)] + ([h.ssh] if h.ssh else [])
                    code, out, err = run_cmd("/bin/sh", args, timeout=30.0, extra_env={"SSH_OPTS": opts})
                    msg = (out + err).strip() or f"exit {code}"
                    lines.append(f"{h.name}: {msg}")
                send_notification("Usage tracking", "\n".join(lines))
                GLib.idle_add(lambda: (self.poll(), False)[1])

            threading.Thread(target=worker, daemon=True).start()

        def on_edit_config(self, _item: Gtk.MenuItem) -> None:
            load_config()
            opener = "xdg-open" if shutil.which("xdg-open") else "open"
            subprocess.Popen([opener, str(CONFIG_PATH)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        def on_reload_config(self, _item: Gtk.MenuItem) -> None:
            self.config = load_config()
            self.start_timers()
            self.poll()

    signal.signal(signal.SIGINT, signal.SIG_DFL)
    TrayApp()
    Gtk.main()
    return 0


def main() -> int:
    if "--once" in sys.argv or "--dump" in sys.argv:
        return run_once_cli()
    return run_tray_app()


if __name__ == "__main__":
    sys.exit(main())
