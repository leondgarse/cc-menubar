// cc-menubar — macOS menu bar monitor for Claude Code sessions, local and over SSH.
// Reads Claude Code's peer registry (~/.claude/sessions/<pid>.json) on each host.
// That registry is an internal format and may change after a Claude Code upgrade.
import Cocoa

// MARK: - Config

struct HostConfig: Codable {
    let name: String
    let ssh: String?          // ssh destination (alias from ~/.ssh/config); nil = local
}

struct Config: Codable {
    var interval: Double?     // seconds between polls (default 5)
    var notify: Bool?         // notify when a session goes busy -> idle (default true)
    var terminalApp: String?  // app to bring forward after selecting a tmux pane
    var hosts: [HostConfig]
}

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/cc-menubar")
let configURL = configDir.appendingPathComponent("config.json")

func loadConfig() -> Config {
    if let data = try? Data(contentsOf: configURL),
       let cfg = try? JSONDecoder().decode(Config.self, from: data) {
        return cfg
    }
    let def = Config(interval: 5, notify: true, terminalApp: "Ghostty",
                     hosts: [HostConfig(name: "local", ssh: nil)])
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if !FileManager.default.fileExists(atPath: configURL.path) {
        try? enc.encode(def).write(to: configURL)
    }
    return def
}

// MARK: - Collection

// POSIX sh, no jq needed, so it runs unchanged on remote Linux servers.
// Emits one line per live session: <session json>\t<tmux pane title>
let collectScript = #"""
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin"
for f in "$HOME"/.claude/sessions/*.json; do
  [ -e "$f" ] || continue
  pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$f")
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
  pane=$(sed -n 's/.*"tmux":"[^"]*\.\(%[0-9]*\)".*/\1/p' "$f")
  title=""
  if [ -n "$pane" ] && command -v tmux >/dev/null 2>&1; then
    title=$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null)
  fi
  printf '%s\t%s\n' "$(tr -d '\n\t' < "$f")" "$title"
done
"""#

struct Session {
    let host: String
    let ssh: String?
    let sessionId: String
    let name: String
    let status: String
    let pane: String?
    let title: String
    let cwd: String
    let statusSince: Date?
    let entrypoint: String
    var key: String { host + "/" + sessionId }
}

struct HostResult {
    let host: HostConfig
    var sessions: [Session] = []
    var error: String?
}

let sshOpts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
               "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/cc-menubar-%C",
               "-o", "ControlPersist=600"]

/// Runs a process with optional stdin, killing it after `timeout` seconds.
func run(_ exe: String, _ args: [String], stdin: String? = nil, timeout: Double = 15) -> (Int32, String, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    p.environment = env
    let out = Pipe(), err = Pipe(), inp = Pipe()
    p.standardOutput = out; p.standardError = err; p.standardInput = inp
    do { try p.run() } catch { return (-1, "", "\(error)") }
    if let s = stdin { inp.fileHandleForWriting.write(s.data(using: .utf8)!) }
    try? inp.fileHandleForWriting.close()
    let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit(); timer.cancel()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
}

func collect(_ host: HostConfig) -> HostResult {
    var res = HostResult(host: host)
    let (code, out, err): (Int32, String, String)
    if let dest = host.ssh {
        (code, out, err) = run("/usr/bin/ssh", sshOpts + [dest, "sh", "-s"], stdin: collectScript)
    } else {
        (code, out, err) = run("/bin/sh", ["-s"], stdin: collectScript)
    }
    if code != 0 && out.isEmpty {
        let msg = err.split(separator: "\n").last.map(String.init) ?? "exit \(code)"
        res.error = code == 15 ? "timed out" : msg
        return res
    }
    for line in out.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard let data = parts.first?.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        var title = parts.count > 1 ? String(parts[1]) : ""
        title = title.replacingOccurrences(of: "^[✳✻·*\\s]+", with: "", options: .regularExpression)
        let pane = (j["tmux"] as? String).flatMap { $0.split(separator: ".").last.map(String.init) }
        let ts = (j["statusUpdatedAt"] as? Double) ?? (j["updatedAt"] as? Double)
        res.sessions.append(Session(
            host: host.name, ssh: host.ssh,
            sessionId: j["sessionId"] as? String ?? "?",
            name: j["name"] as? String ?? "-",
            status: j["status"] as? String ?? "unknown",
            pane: pane, title: title,
            cwd: j["cwd"] as? String ?? "",
            statusSince: ts.map { Date(timeIntervalSince1970: $0 / 1000) },
            entrypoint: j["entrypoint"] as? String ?? ""))
    }
    res.sessions.sort { ($0.status == "idle" ? 1 : 0, $0.name) < ($1.status == "idle" ? 1 : 0, $1.name) }
    return res
}

// MARK: - UI helpers

func color(for status: String) -> NSColor {
    switch status {
    case "idle": return .systemGreen
    case "waiting", "needs_input", "awaiting_input", "permission": return .systemRed
    default: return .systemOrange   // busy, shell, … = working
    }
}

func ago(_ d: Date?) -> String {
    guard let d = d else { return "" }
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

func shortPath(_ p: String) -> String {
    let home = NSHomeDirectory()
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}

func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var config = loadConfig()
    var results: [HostResult] = []
    var lastStatus: [String: String] = [:]
    var lastFinished: [String: Date] = [:]   // host name -> when a session there last went working -> idle
    var timer: Timer?
    var polling = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu(); menu.delegate = self
        item.menu = menu
        item.button?.title = "CC …"
        startTimer()
        poll()
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(2, config.interval ?? 5), repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func poll() {
        if polling { return }
        polling = true
        let hosts = config.hosts
        DispatchQueue.global().async {
            var out = [HostResult?](repeating: nil, count: hosts.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: hosts.count) { i in
                let r = collect(hosts[i])
                lock.lock(); out[i] = r; lock.unlock()
            }
            DispatchQueue.main.async {
                self.polling = false
                self.update(out.compactMap { $0 })
            }
        }
    }

    func update(_ r: [HostResult]) {
        results = r
        let all = r.flatMap { $0.sessions }
        // A working session became idle: remember when (for "✓2m") and notify.
        for s in all where s.status == "idle" && color(for: lastStatus[s.key] ?? "idle") == .systemOrange {
            lastFinished[s.host] = s.statusSince ?? Date()
            if config.notify ?? true {
                notify(title: "Claude finished: \(s.name)", body: "\(s.host) · \(s.title.isEmpty ? shortPath(s.cwd) : s.title)")
            }
        }
        lastStatus = Dictionary(all.map { ($0.key, $0.status) }, uniquingKeysWith: { a, _ in a })

        // Status bar, per host, zero counts omitted:
        //   local ●1 my-session  ●1 task-monitor 4m  ●3 ✓2m     RTX8000 ●2 12m  ●1
        //   red = waiting (name in red), orange = working (name if only one + time working),
        //   green = idle, ✓ = time since a session last finished (shown for an hour).
        let t = NSMutableAttributedString()
        // Gray is too faint on the menu bar: use label colour for structure, cyan for times
        // (red/orange/green are reserved for session states).
        let dimAttr: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
        let timeAttr: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemCyan]
        func clip(_ s: String, _ n: Int = 20) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
        for (i, h) in r.enumerated() {
            // Bold host name leads each segment; a wide gap (no "|") separates hosts.
            if i > 0 { t.append(NSAttributedString(string: "     ")) }
            t.append(NSAttributedString(string: h.host.name + " ", attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold)]))
            if h.error != nil {
                t.append(NSAttributedString(string: "⚠︎", attributes: [.foregroundColor: NSColor.systemYellow]))
            } else if h.sessions.isEmpty {
                t.append(NSAttributedString(string: "0", attributes: dimAttr))
            } else {
                var first = true
                for c in [NSColor.systemRed, .systemOrange, .systemGreen] {
                    let group = h.sessions.filter { color(for: $0.status) == c }
                    if group.isEmpty { continue }
                    if !first { t.append(NSAttributedString(string: "  ")) }
                    t.append(NSAttributedString(string: "●", attributes: [.foregroundColor: c]))
                    t.append(NSAttributedString(string: "\(group.count)"))
                    // Oldest status change first: the longest-waiting / longest-running session.
                    let oldest = group.min { ($0.statusSince ?? .distantFuture) < ($1.statusSince ?? .distantFuture) }!
                    if c == .systemRed {
                        var label = " " + clip(oldest.name)
                        if group.count > 1 { label += " +\(group.count - 1)" }
                        t.append(NSAttributedString(string: label, attributes: [.foregroundColor: NSColor.systemRed]))
                    } else if c == .systemOrange {
                        if group.count == 1 { t.append(NSAttributedString(string: " " + clip(oldest.name))) }
                        let since = ago(oldest.statusSince)
                        if !since.isEmpty { t.append(NSAttributedString(string: " " + since, attributes: timeAttr)) }
                    } else if let done = lastFinished[h.host.name], Date().timeIntervalSince(done) < 3600 {
                        t.append(NSAttributedString(string: " ✓" + ago(done), attributes: timeAttr))
                    }
                    first = false
                }
            }
        }
        item.button?.attributedTitle = t
    }

    func notify(title: String, body: String) {
        let script = "display notification \(appleQuote(body)) with title \(appleQuote(title))"
        DispatchQueue.global().async { _ = run("/usr/bin/osascript", ["-e", script]) }
    }

    func appleQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // Build the dropdown lazily so it always reflects the latest poll.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // One flat list across all hosts: waiting first, then working, then idle; newest status change first.
        func rank(_ st: String) -> Int {
            let c = color(for: st)
            return c == .systemRed ? 0 : c == .systemOrange ? 1 : 2
        }
        // Grouped by host (config order); within a host: waiting, working, idle; newest change first.
        let all = results.flatMap { r in r.sessions.sorted {
            (rank($0.status), -($0.statusSince?.timeIntervalSince1970 ?? 0)) <
            (rank($1.status), -($1.statusSince?.timeIntervalSince1970 ?? 0))
        } }
        func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

        let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let small = NSFont.systemFont(ofSize: 12)
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let dim = NSColor.secondaryLabelColor
        // Columns: ● name | status age | title | cwd
        let rows: [[(String, NSFont, NSColor)]] = all.map { s in
            let title = (s.title.isEmpty || s.title == "Claude Code") ? "" : s.title
            return [("● ", nameFont, color(for: s.status)),
                    (clip(s.name, 36), nameFont, .labelColor),
                    ("\(s.status) \(ago(s.statusSince))", small, dim),
                    (clip(title, 48), small, .labelColor),
                    (shortPath(s.cwd), mono, dim)]
        }
        // Tab stops sized to the widest cell in each column.
        var stops: [NSTextTab] = []
        var x: CGFloat = 0
        if let first = rows.first {
            for col in 0..<(first.count - 1) {
                let w = rows.map { r in (r[col].0 as NSString).size(withAttributes: [.font: r[col].1]).width }.max() ?? 0
                x += w + (col == 0 ? 0 : 18)
                stops.append(NSTextTab(textAlignment: .left, location: x))
            }
        }
        let para = NSMutableParagraphStyle(); para.tabStops = stops
        var lastHost: String? = nil
        func addHeader(_ r: HostResult) {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            var h = r.host.name
            if let e = r.error { h += "  ⚠︎ \(e)" } else { h += "  · \(r.sessions.count)" }
            let hi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            hi.attributedTitle = NSAttributedString(string: h, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: r.error != nil ? NSColor.systemYellow : NSColor.systemBlue])
            menu.addItem(hi)
        }
        // Hosts with no sessions (or errors) still get a header, in config order.
        var emitted = Set<String>()
        for (s, row) in zip(all, rows) {
            if s.host != lastHost {
                for r in results where !emitted.contains(r.host.name) {
                    emitted.insert(r.host.name)
                    addHeader(r)
                    if r.host.name == s.host { break }
                }
                lastHost = s.host
            }
            let a = NSMutableAttributedString()
            for (i, cell) in row.enumerated() {
                if i > 0 { a.append(NSAttributedString(string: "\t")) }
                a.append(NSAttributedString(string: cell.0, attributes: [.font: cell.1, .foregroundColor: cell.2]))
            }
            a.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: a.length))
            let mi = NSMenuItem(title: "", action: #selector(activate(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = s
            mi.attributedTitle = a
            mi.toolTip = "Click: focus tmux pane \(s.pane ?? "-") (or copy resume command)\nSession: \(s.sessionId)"
            menu.addItem(mi)
        }
        for r in results where !emitted.contains(r.host.name) { addHeader(r) }
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        let edit = NSMenuItem(title: "Edit hosts…", action: #selector(editConfig), keyEquivalent: ",")
        let reload = NSMenuItem(title: "Reload config", action: #selector(reloadConfig), keyEquivalent: "l")
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        for i in [refresh, edit, reload] { i.target = self; menu.addItem(i) }
        menu.addItem(quit)
    }

    @objc func activate(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Session else { return }
        guard let pane = s.pane else {
            // No tmux pane (e.g. desktop app session): copy a resume command instead.
            var cmd = "cd \(shQuote(s.cwd)) && claude --resume \(s.sessionId)"
            if let dest = s.ssh { cmd = "ssh -t \(dest) \(shQuote(cmd))" }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            if s.entrypoint == "claude-desktop" && s.ssh == nil {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
            }
            return
        }
        let tm = "tmux switch-client -t \(pane) 2>/dev/null; tmux select-window -t \(pane); tmux select-pane -t \(pane)"
        let term = config.terminalApp
        DispatchQueue.global().async {
            if let dest = s.ssh {
                _ = run("/usr/bin/ssh", sshOpts + [dest, "sh", "-s"], stdin: "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin\"\n" + tm)
            } else {
                _ = run("/bin/sh", ["-c", tm])
            }
            if let app = term { _ = run("/usr/bin/open", ["-a", app]) }
        }
    }

    @objc func refreshNow() { poll() }

    @objc func editConfig() {
        _ = loadConfig() // ensures the file exists
        NSWorkspace.shared.open(configURL)
    }

    @objc func reloadConfig() {
        config = loadConfig()
        startTimer()
        poll()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
