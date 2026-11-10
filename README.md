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

One segment per host, in config order, for example:

    local ●1 my-session  ●1 task-monitor 4m  ●3 ✓2m     gpu-box ●2 12m  ●1

- Red: waiting for input. Shows the longest-waiting session's name in red, plus `+N` if more are waiting.
- Orange: working (`busy`, `shell`, …). Shows the session name when only one is working, and how long
  the longest one has been working.
- Green: idle. `✓2m` is the time since a session on that host last finished; it shows for an hour.
- Times are cyan. `host 0` means the host has no sessions; `host ⚠︎` means it couldn't be reached.

Click a session to switch tmux to its pane (locally, or over SSH on the remote's tmux server) and bring
`terminalApp` to the front. A session with no tmux pane copies a `claude --resume` command instead
(wrapped in `ssh -t` for a remote one).
You get a notification when a session goes from working to idle.

## Config: `~/.config/cc-menubar/config.json`

```json
{
  "interval": 5,
  "notify": true,
  "terminalApp": "Ghostty",
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
