# cc-menubar

macOS and Linux menu bar monitor for running **Claude Code**, **Antigravity CLI (`agy`)**, and **Codex** sessions, locally and on SSH servers.

It reads:
- Claude Code's session registry (`~/.claude/sessions/<pid>.json`)
- Antigravity CLI's active presence locks (`~/.gemini/antigravity-cli/presence/*.lock`), SQLite conversation summaries (`conversation_summaries.db`), and step transcripts (`transcript.jsonl`)

- Codex's live writer locks (`$CODEX_HOME/thread-writer-locks`, default `~/.codex`), thread metadata (`state_*.sqlite`), and rollout logs (`sessions/**/*.jsonl`)

on every configured host.

## Build / install

    ./build.sh            # macOS -> build/CCMenubar.app | Linux -> build/cc-menubar
    ./build.sh --install  # macOS -> ~/Applications/CCMenubar.app | Linux -> ~/.local/bin/cc-menubar + autostart

- **macOS**: Enable **Launch at login** in the menu bar dropdown (or add `~/Applications/CCMenubar.app` under System Settings → General → Login Items).
- **Linux (Ubuntu / GNOME AppIndicator)**: Uses `/usr/bin/python3` with `AyatanaAppIndicator3` + GTK3 (included out of the box on Ubuntu Desktop). `./build.sh --install` installs to `~/.local/share/cc-menubar`, links `~/.local/bin/cc-menubar`, adds `~/.config/autostart/cc-menubar.desktop`, and launches it in the top bar. You can also test from the terminal with `./cc-menubar.py --once`.

## Menu bar

Your 5-hour and weekly usage come first, then one segment per host, in config order, for example:

    Claude 5h 59%  wk 49%  local ■ my-session 4m     AGY local ◆ task-monitor 4m     Codex local ● eval 3m

- **Squares (`■`)** are Claude Code sessions; **diamonds (`◆`)** are Antigravity CLI (`agy`); **circles (`●`)** are Codex.
- macOS colors each shape red, orange, or green. Linux uses colored square/circle emoji; AGY pairs its diamond with a colored status dot because Unicode has no red/green diamond emoji. Codex keeps the ChatGPT knot logo.
- Red: waiting for input. Shows the longest-waiting session's name in red, plus `+N` if more are waiting.
- Orange: working (`busy`, `shell`, …). Each working session is shown separately with its name and how
  long it has been working, longest-running first.
- Green: idle (split by tool when both are running, e.g. `🟢1 🟩2`). `✓2m` is the time since a session on that host last finished; it shows for an hour. When the bar has room, idle sessions are listed by name (`🟢 api  🟢 docs ✓2m`), most recently finished first; otherwise they collapse to a count.
- If everything doesn't fit in `maxWidth` (default 600 points), the title is shortened step by step:
  shorter names, then working sessions without names (`● 19m ● 1m`), then counts only.
  Raise `maxWidth` in the config if you have room; macOS hides a menu bar item that doesn't fit.
- Times are cyan. `host 0` means the host has no sessions; `host ⚠︎` means it couldn't be reached.

Click a session to switch tmux to its pane (locally, or over SSH on the remote's tmux server) and bring
`terminalApp` to the front. A session with no tmux pane copies a `claude --resume` command instead
(wrapped in `ssh -t` for a remote one).
You get a notification when a session goes from working to idle.

Codex sessions copy `codex resume <session-id>` when clicked. A shared Codex daemon can serve
several clients, so its tmux pane cannot reliably identify a session's terminal. Codex activity is
inferred from task-start, completion, and abort events; approval waits are currently shown as
working. Missing activity events show `unknown`. Only sessions with an open writer-lock file are
listed, so saved conversations and stale lock files do not appear as running sessions.
Codex collection needs Python 3 and, on macOS, `lsof` on each host. These local file formats are
internal and may change in future Codex releases.

## Usage limits (5-hour / weekly)

Claude Code passes your subscription usage to status line scripts. `statusline.sh` saves it to
`~/.cache/cc-menubar/usage.json` for the app and prints `5h 59% · wk 49%` as your status line.
Percentages are cyan, orange from 70% and red from 90%; the dropdown shows when each window resets.

The dropdown offers **Enable usage tracking on <host>…** for every host that isn't set up yet, and does
it after you confirm. Or from a shell:

    ./install-statusline.sh              # this Mac
    ./install-statusline.sh <ssh-dest>   # a server (needs jq or python3 there)

This sets `statusLine` in `~/.claude/settings.json` (backup saved as `settings.json.bak-cc-menubar`)
and leaves an existing, different status line alone.

Claude Code only sends usage after a session gets a reply, so each host's file updates when a session
there is used. The app fetches the file from every host and shows the newest one, so work on any server
keeps the numbers current. This assumes all hosts use the same Claude account. Only shown for Claude
subscription accounts.

Codex usage needs no status line hook: the app reads the latest quota snapshot from recent
rollout logs, including 5-hour and weekly usage and reset times. It updates during Codex activity;
the dropdown shows its age and source host. This assumes the same Codex account across hosts.
Unavailable windows show `?`; after a window resets, the dropdown notes that a new reading is pending.

## Config: `~/.config/cc-menubar/config.json`

```json
{
  "interval": 5,
  "notify": true,
  "showClaude": true,
  "showAgy": true,
  "showCodex": true,
  "terminalApp": "Ghostty",
  "maxWidth": 600,
  "hosts": [
    { "name": "local" },
    { "name": "gpu-box", "ssh": "gpu-box" },
    { "name": "lab", "ssh": "user@lab.example.com" }
  ]
}
```

`ssh` is any destination `ssh` accepts (your `~/.ssh/config` aliases work). Key-based auth is required
(BatchMode). The remote only needs `sh`, `sed` and `tr` (no jq). Connections are reused through an SSH
ControlMaster socket (`/tmp/cc-menubar-*`), so polling every few seconds stays cheap.
`showClaude`, `showAgy`, and `showCodex` default to `true`. Set any to `false` to hide that tool's
status, sessions, usage, and notifications. If all three are false, a small CCMenubar entry remains
so you can edit/reload the config. Collection continues so showing a tool again picks up current data.
After editing, use **Reload config** in the menu.

`switchboardDir` (optional, default `~/workspace/switchboard`): if that folder has switchboard's `index.html`,
the dropdown offers **Sessions board…** (⌘B), a window with that page fed by cc-menubar's own session data.
Opening the app again also shows it. If `~/.config/switchboard/room.json` exists, cc-menubar also shows
unread room messages (✉N) and sends a notification when a session gets one.

## License

MIT, see [LICENSE](LICENSE).
