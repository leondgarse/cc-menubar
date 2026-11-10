# cc-menubar

macOS menu bar monitor for running Claude Code sessions, on this Mac and on SSH servers.

It reads Claude Code's session registry (`~/.claude/sessions/<pid>.json`, the same files
Claude Code uses to track its own sessions) on every configured host. It's an internal format, so it may need a tweak
after a Claude Code upgrade.

## Build / install

    ./build.sh            # -> build/CCMenubar.app
    ./build.sh --install  # copy to ~/Applications and launch

Launch at login: System Settings → General → Login Items → add `~/Applications/CCMenubar.app`.

## Menu bar

Your 5-hour and weekly usage come first, then one segment per host, in config order, for example:

    5h 59%  wk 49%     local ●1 my-session  ● task-monitor 4m  ●3 ✓2m     gpu-box ● train-run 12m  ● eval 3m  ●1

- Red: waiting for input. Shows the longest-waiting session's name in red, plus `+N` if more are waiting.
- Orange: working (`busy`, `shell`, …). Each working session is shown separately with its name and how
  long it has been working, longest-running first.
- Green: idle. `✓2m` is the time since a session on that host last finished; it shows for an hour.
- If everything doesn't fit in `maxWidth` (default 600 points), the title is shortened step by step:
  shorter names, then working sessions without names (`● 19m ● 1m`), then counts only.
  Raise `maxWidth` in the config if you have room; macOS hides a menu bar item that doesn't fit.
- Times are cyan. `host 0` means the host has no sessions; `host ⚠︎` means it couldn't be reached.

Click a session to switch tmux to its pane (locally, or over SSH on the remote's tmux server) and bring
`terminalApp` to the front. A session with no tmux pane copies a `claude --resume` command instead
(wrapped in `ssh -t` for a remote one).
You get a notification when a session goes from working to idle.

## Usage limits (5-hour / weekly)

Claude Code passes your subscription usage to status line scripts. `statusline.sh` saves it to
`~/.cache/cc-menubar/usage.json` for the app and prints `5h 59% · wk 49%` as your status line.
Percentages are cyan, orange from 70% and red from 90%; the dropdown shows when each window resets.

    cp statusline.sh ~/.claude/cc-menubar-statusline.sh
    # then in ~/.claude/settings.json:
    "statusLine": { "type": "command", "command": "~/.claude/cc-menubar-statusline.sh" }

The numbers update whenever a session's status line refreshes, so they can lag while no session is active.
Only shown for Claude subscription accounts.

## Config: `~/.config/cc-menubar/config.json`

```json
{
  "interval": 5,
  "notify": true,
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
After editing, use **Reload config** in the menu.

## License

MIT, see [LICENSE](LICENSE).
