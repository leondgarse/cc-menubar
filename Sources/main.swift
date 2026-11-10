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
    var maxWidth: Double?     // max menu bar title width in points before it gets compacted (default 600)
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
# Usage limits saved by statusline.sh (cc-menubar), with the file's mtime.
u="$HOME/.cache/cc-menubar/usage.json"
if [ -f "$u" ]; then printf 'USAGE\t%s\t%s\n' "$(date -r "$u" +%s)" "$(tr -d '\n\t' < "$u")"; fi
# Is the cc-menubar status line hook set up here? installed / other (a different status line) / none
s="$HOME/.claude/settings.json"
if grep -q 'cc-menubar-statusline' "$s" 2>/dev/null; then h=installed
elif grep -q '"statusLine"' "$s" 2>/dev/null; then h=other; else h=none; fi
printf 'HOOK\t%s\n' "$h"
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
    var usage: (json: Data, time: Date)?   // this host's ~/.cache/cc-menubar/usage.json
    var hook: String?                       // status line hook: installed / other / none
}

let sshOpts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
               "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/cc-menubar-%C",
               "-o", "ControlPersist=600"]

/// Runs a process with optional stdin, killing it after `timeout` seconds.
func run(_ exe: String, _ args: [String], stdin: String? = nil, timeout: Double = 15, env extra: [String: String] = [:]) -> (Int32, String, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env.merge(extra) { _, new in new }
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
        if line.hasPrefix("HOOK\t") { res.hook = String(line.dropFirst(5)); continue }
        if line.hasPrefix("USAGE\t") {
            let u = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if u.count == 3, let ts = Double(u[1]), let d = String(u[2]).data(using: .utf8) {
                res.usage = (d, Date(timeIntervalSince1970: ts))
            }
            continue
        }
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

// MARK: - Usage limits
// Written by statusline.sh from Claude Code's status line input (rate_limits.five_hour / seven_day).

struct UsageWindow { let pct: Double; let resetsAt: Date }

let usageURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/cc-menubar/usage.json")

/// Usage from whichever host (or this Mac's file) saw a Claude response most recently.
/// Assumes all hosts use the same Claude account.
func readUsage(_ results: [HostResult]) -> (fiveHour: UsageWindow?, weekly: UsageWindow?, updated: Date?, source: String?) {
    var candidates = results.compactMap { r in r.usage.map { ($0.json, $0.time, r.host.name) } }
    if candidates.isEmpty, let d = try? Data(contentsOf: usageURL),
       let m = (try? FileManager.default.attributesOfItem(atPath: usageURL.path))?[.modificationDate] as? Date {
        candidates.append((d, m, "this Mac"))
    }
    guard let best = candidates.max(by: { $0.1 < $1.1 }),
          let j = try? JSONSerialization.jsonObject(with: best.0) as? [String: Any],
          let rl = j["rate_limits"] as? [String: Any] else { return (nil, nil, nil, nil) }
    func win(_ k: String) -> UsageWindow? {
        guard let w = rl[k] as? [String: Any], let p = w["used_percentage"] as? Double,
              let r = w["resets_at"] as? Double else { return nil }
        let reset = Date(timeIntervalSince1970: r)
        // Window already reset since the last reading: usage starts over.
        return UsageWindow(pct: reset < Date() ? 0 : p, resetsAt: reset)
    }
    return (win("five_hour"), win("seven_day"), best.1, best.2)
}

func untilString(_ d: Date) -> String {
    let s = max(0, Int(d.timeIntervalSinceNow))
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m" }
    return "\(s / 86400)d\(s % 86400 / 3600)h"
}

func usageColor(_ pct: Double) -> NSColor {
    pct >= 90 ? .systemRed : pct >= 70 ? .systemOrange : .systemCyan
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
    var ticker: Timer?
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
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            ticker?.tolerance = 0.1
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
        // Use the most detailed title that fits in maxWidth; macOS silently pushes a too-wide item off-screen.
        renderTitle()
    }

    func renderTitle() {
        let maxW = CGFloat(config.maxWidth ?? 600)
        var t = buildTitle(results, level: 0)
        for level in 1...3 where t.size().width > maxW { t = buildTitle(results, level: level) }
        item.button?.attributedTitle = t
    }

    /// Between polls, redraw every second while any shown time is still in seconds, so "41s" ticks up.
    func tick() {
        let now = Date()
        let recent = { (d: Date?) in d.map { now.timeIntervalSince($0) < 61 } ?? false }
        let working = results.flatMap { $0.sessions }.filter { color(for: $0.status) != .systemGreen }
        if working.contains(where: { recent($0.statusSince) }) || lastFinished.values.contains(where: { recent($0) }) {
            renderTitle()
        }
    }

    /// level 0: full · 1: shorter names, tighter gaps · 2: working sessions as "● time" without names · 3: counts only.
    func buildTitle(_ r: [HostResult], level: Int) -> NSAttributedString {
        let t = NSMutableAttributedString()
        let nameLen = level == 0 ? 20 : 12
        let hostGap = level == 0 ? "     " : level == 1 ? "    " : "   "
        // Left side: account usage, e.g. "5h 42%  wk 18%" (cyan, orange >= 70%, red >= 90%).
        let usage = readUsage(r)
        let boldFont = NSFont.boldSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize)
        var hasUsage = false
        for (label, w) in [("5h", usage.fiveHour), ("wk", usage.weekly)] {
            guard let w = w else { continue }
            if hasUsage { t.append(NSAttributedString(string: "  ")) }
            t.append(NSAttributedString(string: label + " ", attributes: [.font: boldFont, .foregroundColor: NSColor.labelColor]))
            t.append(NSAttributedString(string: "\(Int(w.pct))%", attributes: [.foregroundColor: usageColor(w.pct)]))
            hasUsage = true
        }
        if hasUsage { t.append(NSAttributedString(string: hostGap)) }
        // Gray is too faint on the menu bar: use label colour for structure, cyan for times
        // (red/orange/green are reserved for session states).
        let dimAttr: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
        let timeAttr: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemCyan]
        func clip(_ s: String) -> String { s.count > nameLen ? String(s.prefix(nameLen - 1)) + "…" : s }
        for (i, h) in r.enumerated() {
            // Bold host name leads each segment; a wide gap (no "|") separates hosts.
            if i > 0 { t.append(NSAttributedString(string: hostGap)) }
            t.append(NSAttributedString(string: h.host.name + " ", attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.boldSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize)]))
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
                    if c == .systemOrange && level < 3 {
                        // Working sessions are listed one by one, longest-running first:
                        // "● name 4m  ● other 1m", or at level 2 without names: "● 4m ● 1m".
                        let sorted = group.sorted { ($0.statusSince ?? .distantFuture) < ($1.statusSince ?? .distantFuture) }
                        for (k, s) in sorted.enumerated() {
                            if k > 0 { t.append(NSAttributedString(string: level < 2 ? "  " : " ")) }
                            t.append(NSAttributedString(string: "●", attributes: [.foregroundColor: c]))
                            if level < 2 { t.append(NSAttributedString(string: " " + clip(s.name))) }
                            let since = ago(s.statusSince)
                            if !since.isEmpty { t.append(NSAttributedString(string: " " + since, attributes: timeAttr)) }
                        }
                        first = false
                        continue
                    }
                    t.append(NSAttributedString(string: "●", attributes: [.foregroundColor: c]))
                    t.append(NSAttributedString(string: "\(group.count)"))
                    // Oldest status change first: the longest-waiting / longest-running session.
                    let oldest = group.min { ($0.statusSince ?? .distantFuture) < ($1.statusSince ?? .distantFuture) }!
                    if level >= 3 {
                        // counts only
                    } else if c == .systemOrange {
                        let since = ago(oldest.statusSince)
                        if !since.isEmpty { t.append(NSAttributedString(string: " " + since, attributes: timeAttr)) }
                    } else if c == .systemRed {
                        var label = " " + clip(oldest.name)
                        if group.count > 1 { label += " +\(group.count - 1)" }
                        t.append(NSAttributedString(string: label, attributes: [.foregroundColor: NSColor.systemRed]))
                    } else if let done = lastFinished[h.host.name], Date().timeIntervalSince(done) < 3600 {
                        t.append(NSAttributedString(string: " ✓" + ago(done), attributes: timeAttr))
                    }
                    first = false
                }
            }
        }
        // Measure with the real menu bar font so the width check matches what's drawn.
        let base = NSFont.menuBarFont(ofSize: 0)
        t.enumerateAttribute(.font, in: NSRange(location: 0, length: t.length)) { v, range, _ in
            if v == nil { t.addAttribute(.font, value: base, range: range) }
        }
        return t
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
        let u = readUsage(results)
        if u.fiveHour != nil || u.weekly != nil {
            for (label, w) in [("5-hour", u.fiveHour), ("Weekly", u.weekly)] {
                guard let w = w else { continue }
                let ui = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                let a = NSMutableAttributedString(string: "\(label) usage  ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
                a.append(NSAttributedString(string: "\(Int(w.pct))%", attributes: [.foregroundColor: usageColor(w.pct), .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]))
                a.append(NSAttributedString(string: "   resets in \(untilString(w.resetsAt))", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
                ui.attributedTitle = a
                menu.addItem(ui)
            }
            if let up = u.updated {
                let ui = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                ui.attributedTitle = NSAttributedString(string: "Usage as of \(ago(up)) ago, from \(u.source ?? "?") (updates when a session gets a reply)",
                                                        attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)])
                menu.addItem(ui)
            }
        } else {
            menu.addItem(NSMenuItem(title: "No usage data yet", action: nil, keyEquivalent: ""))
        }
        // Offer to set up the status line hook (the source of usage data) where it's missing.
        let missing = results.filter { $0.error == nil && $0.hook == "none" }
        for r in missing {
            let mi = NSMenuItem(title: "Enable usage tracking on \(r.host.name)…", action: #selector(enableUsage(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = [r.host.name]
            menu.addItem(mi)
        }
        if missing.count > 1 {
            let mi = NSMenuItem(title: "Enable usage tracking on all \(missing.count) hosts…", action: #selector(enableUsage(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = missing.map { $0.host.name }
            menu.addItem(mi)
        }
        for r in results where r.hook == "other" {
            let mi = NSMenuItem(title: "\(r.host.name): has its own status line, usage not tracked", action: nil, keyEquivalent: "")
            mi.toolTip = "cc-menubar won't replace an existing statusLine in ~/.claude/settings.json."
            menu.addItem(mi)
        }
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

    /// Installs the bundled statusline.sh as Claude Code's status line on the given hosts, after asking.
    @objc func enableUsage(_ sender: NSMenuItem) {
        guard let names = sender.representedObject as? [String],
              let installer = Bundle.main.path(forResource: "install-statusline", ofType: "sh") else { return }
        let hosts = config.hosts.filter { names.contains($0.name) }
        let alert = NSAlert()
        alert.messageText = "Enable usage tracking on \(names.joined(separator: ", "))?"
        alert.informativeText = """
            Claude Code only reports 5-hour and weekly usage to status line scripts. This will:
            • copy a small script to ~/.claude/cc-menubar-statusline.sh
            • set "statusLine" in ~/.claude/settings.json to run it (a backup is saved as settings.json.bak-cc-menubar)

            Sessions will show "5h 59% · wk 49%" as their status line. An existing status line is never replaced.
            """
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let opts = sshOpts.joined(separator: " ")
        DispatchQueue.global().async {
            let lines = hosts.map { h -> String in
                let (code, out, err) = run("/bin/sh", [installer] + (h.ssh.map { [$0] } ?? []),
                                           timeout: 30, env: ["SSH_OPTS": opts])
                let msg = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(h.name): " + (msg.isEmpty ? "exit \(code)" : msg)
            }
            DispatchQueue.main.async {
                let done = NSAlert()
                done.messageText = "Usage tracking"
                done.informativeText = lines.joined(separator: "\n\n")
                    + "\n\nUsage appears after a session on that host next gets a reply."
                NSApp.activate(ignoringOtherApps: true)
                done.runModal()
                self.poll()
            }
        }
    }

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
