"""Read-only Codex session probe, also sent verbatim to SSH hosts by the app.

Writer locks identify live sessions; persisted files alone are never presence.
Rollouts are an internal format. Unknown activity stays unknown, never idle.
"""
import datetime
import glob
import json
import os
import re
import sqlite3
import subprocess
from pathlib import Path


def timestamp(value):
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError, AttributeError):
        return None


def reverse_records(path):
    """Read complete JSONL records newest first, ignoring a partially written tail."""
    with open(path, "rb") as stream:
        stream.seek(0, 2)
        pos = stream.tell()
        pending = b""
        while pos:
            size = min(pos, 65536)
            pos -= size
            stream.seek(pos)
            chunks = (stream.read(size) + pending).split(b"\n")
            pending = chunks[0]
            for raw in reversed(chunks[1:]):
                try:
                    yield json.loads(raw)
                except (ValueError, UnicodeDecodeError):
                    pass
        try:
            yield json.loads(pending)
        except (ValueError, UnicodeDecodeError):
            pass


def live_writers(root):
    locks = list((root / "thread-writer-locks").glob("*.lock"))
    paths = {os.path.realpath(str(p)): p.stem for p in locks if not p.name.startswith(".")}
    found = {}
    if not paths:
        return found
    if os.path.isdir("/proc"):
        for fd in glob.iglob("/proc/[0-9]*/fd/*"):
            try:
                target = os.path.realpath(fd)
                if target in paths:
                    found[paths[target]] = int(fd.split("/")[2])
            except OSError:
                pass
    else:
        try:
            result = subprocess.run(["lsof", "-F", "pn", "--"] + list(paths),
                                    capture_output=True, text=True, timeout=3)
            pid = None
            for line in result.stdout.splitlines():
                if line.startswith("p"):
                    pid = int(line[1:])
                elif line.startswith("n") and pid:
                    cid = paths.get(os.path.realpath(line[1:]))
                    if cid:
                        found[cid] = pid
        except (OSError, ValueError, subprocess.TimeoutExpired):
            pass
    return found


def activity_and_limits(path):
    state, since, limits = "unknown", None, None
    lifecycle = False
    for record in reverse_records(path):
        if not isinstance(record, dict):
            continue
        payload = record.get("payload") or {}
        if not isinstance(payload, dict) or record.get("type") != "event_msg":
            continue
        event = payload.get("type")
        if limits is None and payload.get("rate_limits"):
            ts = timestamp(record.get("timestamp"))
            if ts is not None:
                limits = (payload["rate_limits"], ts)
        if not lifecycle and event in ("task_started", "task_complete", "task_completed", "turn_aborted"):
            state = "busy" if event == "task_started" else "idle"
            since = timestamp(record.get("timestamp"))
            lifecycle = True
        if lifecycle and limits:
            break
    return state, since, limits


def collect():
    root = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser().resolve()
    if not root.is_dir():
        return
    live = live_writers(root)
    rows = {}
    # Select only display metadata, never prompts, credentials, or tool output.
    databases = sorted(root.glob("state_*.sqlite"), key=lambda p: int(re.search(r"(\d+)\.sqlite$", p.name)[1]), reverse=True)
    for database in databases:
        try:
            with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=.5) as db:
                for row in db.execute("SELECT id, rollout_path, cwd, title FROM threads WHERE archived = 0 ORDER BY updated_at DESC LIMIT 1000"):
                    rows[row[0]] = row[1:]
            break
        except (sqlite3.Error, ValueError):
            continue
    # Older installations without the state DB still have rollout metadata.
    if any(cid not in rows for cid in live) or not rows:
        paths = sorted((root / "sessions").glob("**/*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
        for path in paths:
            try:
                with path.open() as stream:
                    meta = json.loads(stream.readline()).get("payload", {})
                cid = meta.get("id")
                if cid:
                    rows.setdefault(cid, (str(path), meta.get("cwd", ""), ""))
            except (OSError, ValueError):
                pass
    # Only read live sessions plus a few recent rollouts for account quota.
    candidates = list(live) + [cid for cid in list(rows)[:8] if cid not in live]
    newest = None
    for cid in candidates:
        if cid not in rows:
            continue
        path, cwd, title = rows[cid]
        try:
            state, since, limits = activity_and_limits(path)
        except (OSError, ValueError, TypeError):
            continue
        if limits and (newest is None or limits[1] > newest[1]):
            newest = limits
        if cid not in live:
            continue
        # A shared daemon can serve several tmux clients. Its environment is not
        # evidence of which pane owns a thread, so copy a resume command instead.
        name = os.path.basename(cwd.rstrip("/")) or cid[:8]
        if cwd == str(Path.home()):
            name = "~"
        obj = dict(pid=live[cid], sessionId=cid, name=name, status=state,
                   tmux=None, cwd=cwd, statusUpdatedAt=since * 1000 if since else None,
                   entrypoint="codex")
        clean_title = (title or "").replace("\n", " ").replace("\t", " ")
        print(json.dumps(obj, separators=(",", ":")) + "\t" + clean_title)
    if newest:
        limits, ts = newest
        windows = {}
        for key in ("primary", "secondary"):
            window = limits.get(key) or {}
            minutes = window.get("window_minutes")
            label = {300: "five_hour", 10080: "seven_day"}.get(minutes)
            pct, reset = window.get("used_percent"), window.get("resets_at")
            if label and isinstance(pct, (int, float)) and isinstance(reset, (int, float)):
                windows[label] = dict(used_percentage=max(0, min(100, pct)), resets_at=reset)
        if windows:
            print("CODEX_USAGE\t" + str(ts) + "\t" + json.dumps({"rate_limits": windows}, separators=(",", ":")))


if __name__ == "__main__":
    collect()
