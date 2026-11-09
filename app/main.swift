// Agent Manager (Mantra): tasks and agents overview of every machine, in one window, read-only first.
// Marko, 8.11.2026: "I need to have tasks overview and agents overview of what's going on right now on all of my
// machines. You need to build a Star app: agent manager and viewer."
// The data comes from helper/collect.py (bundled in Resources), run off the main thread with a timeout, so a dead
// machine never freezes the window. `--json` prints that overview and exits; `--shot <png>` draws the window off screen.
import SwiftUI
import AppKit

let VERSION = 13

// ---------------------------------------------------------------- look (CAMERA family: dark ground, mono words)
enum Ink {
    static let ground = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.125)
    static let line = Color.white.opacity(0.10)
    static let text = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let dim = Color(red: 0.62, green: 0.62, blue: 0.66)
    static let grey = Color(red: 0.52, green: 0.52, blue: 0.56)
    static let green = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let amber = Color(red: 0.91, green: 0.64, blue: 0.24)
    static let red = Color(red: 0.95, green: 0.35, blue: 0.33)
}

extension View {
    func axButton(_ label: String, id: String, value: String? = nil, _ action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityIdentifier(id)
            .accessibilityValue(value ?? "").accessibilityAddTraits(.isButton).accessibilityAction(.default, action)
    }
}

// ---------------------------------------------------------------- data
typealias J = [String: Any]

func helperURL() -> URL? {
    if let u = Bundle.main.url(forResource: "collect", withExtension: "py") { return u }
    let dev = URL(fileURLWithPath: NSString(string: "~/Developer/AGENT_MANAGER/helper/collect.py").expandingTildeInPath)
    return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
}

/// the phone door (helper/server.py, Tailscale address only, port 8847): this app owns it, starts it and ends it with itself
var phoneDoor: Process?
func startPhoneDoor() {
    guard let c = helperURL() else { return }
    let s = c.deletingLastPathComponent().appendingPathComponent("server.py").path
    guard FileManager.default.fileExists(atPath: s) else { return }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-I", s]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); phoneDoor = p } catch {}
}

/// runs the helper; kills it after `limit` seconds so nothing waits for a dead machine
func collect(limit: TimeInterval = 30) -> Data? {
    guard let h = helperURL() else { return nil }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-I", h.path]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: killer)
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); killer.cancel()
    return d
}

final class Model: ObservableObject {
    @Published var data: J = [:]
    @Published var stamp = "never"
    @Published var busy = false
    @Published var note = ""
    @Published var openNote = ""
    /// the solo filter: "" = everything; done|running|paused|failed|todo = only tasks with that status; sessions; vm
    @Published var solo = ""
    @Published var confirmAll = false
    @Published var renameOpen: Set<String> = []
    @Published var renameDraft: [String: String] = [:]
    /// the CEO's label helper (bundled): `set <sid> <text>` = manual label, `auto <sid>` = the CEO's own again
    func labelCmd(_ args: [String]) {
        let h = Bundle.main.url(forResource: "ceo_labels", withExtension: "py")?.path
            ?? NSString(string: "~/Developer/AGENT_MANAGER/helper/ceo_labels.py").expandingTildeInPath
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-I", h] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.async { self.refresh() }
        }
    }
    /// Agent Maker (a Claude Code mod): the switch is the file ~/.mantra-os/agent-maker/enabled, present = on
    func toggleMaker() {
        let d = NSString(string: "~/.mantra-os/agent-maker").expandingTildeInPath
        let fm = FileManager.default
        try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        if fm.fileExists(atPath: d + "/enabled") {
            try? fm.removeItem(atPath: d + "/enabled")
            fm.createFile(atPath: d + "/disabled-by-hand", contents: Data())
        } else {
            try? fm.removeItem(atPath: d + "/disabled-by-hand")
            fm.createFile(atPath: d + "/enabled", contents: "on\n".data(using: .utf8))
        }
        refresh()
    }
    @Published var retireOpen: Set<String> = []
    static func slug(_ n: String) -> String {
        var out = "", dash = false
        for ch in n.lowercased() { if ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII { out.append(ch); dash = false } else if !dash { out.append("-"); dash = true } }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    /// RETIRE never deletes: it queues {action:"retire"} for the Session Manager, which wakes the session, has it check everything and only then retires it
    func retire(_ name: String, device: String, kind: String) {
        let master = ((data["retire"] as? J)?["master_slug"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "master"
        let dir = NSString(string: "~/.mantra-os/commands/\(master)").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ms = Int(Date().timeIntervalSince1970 * 1000) + Int.random(in: 0..<999)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let j: J = ["id": "\(ms)", "agent": "", "task": 0, "action": "retire", "session": name, "device": device, "kind": kind, "text": "", "at": f.string(from: Date()), "state": "sent", "result": ""]
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) { try? d.write(to: URL(fileURLWithPath: "\(dir)/\(ms).json"), options: .atomic) }
        refresh()
    }
    func toggleSolo(_ k: String) { solo = solo == k ? "" : k }
    /// OPEN MANTRA OPERATING SYSTEM: a new iTerm window, Claude Code as the master session with master-prompt.txt as its first prompt
    func openMaster() {
        let fm = FileManager.default
        let prompt = Bundle.main.url(forResource: "master-prompt", withExtension: "txt")?.path
            ?? NSString(string: "~/Developer/AGENT_MANAGER/master-prompt.txt").expandingTildeInPath
        let dir = NSString(string: "~/.mantra-os").expandingTildeInPath
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sh = dir + "/start-master.sh"
        let body = "#!/bin/zsh -l\ncd ~/Developer/claude-code\nexec claude \"$(cat '\(prompt)')\"\n"
        try? body.write(toFile: sh, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh)
        let script = "tell application \"iTerm\"\nactivate\ncreate window with default profile command \"\(sh)\"\nend tell"
        DispatchQueue.global().async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            DispatchQueue.main.async { self.openNote = err == nil ? "master session opened in iTerm" : "iTerm did not open: " + ((err?["NSAppleScriptErrorMessage"] as? String) ?? "no answer") }
        }
    }
    @Published var open: Set<String> = []          // task rows whose report is expanded: "<slug>#<n>"
    @Published var drafts: [String: String] = [:]  // the prompt box of each task
    /// writes one command into the queue the master session reads: ~/.mantra-os/commands/<slug>/<unix-ms>.json
    func send(slug: String, agent: String, task: Int, action: String, text: String = "") {
        let dir = NSString(string: "~/.mantra-os/commands/\(slug)").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let j: J = ["id": "\(ms)", "agent": agent, "task": task, "action": action, "text": text, "at": f.string(from: Date()), "state": "sent", "result": ""]
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: "\(dir)/\(ms).json"), options: .atomic)
        }
        drafts["\(slug)#\(task)"] = ""
        refresh()
    }
    private var timer: Timer?
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        if busy { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let d = collect()
            let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? J }
            DispatchQueue.main.async {
                self.busy = false
                if let j = j { self.data = j; self.stamp = (j["time"] as? String) ?? "?"; self.note = "" }
                else { self.note = "the helper gave no answer (kept the last picture)" }
            }
        }
    }
}

func ago(_ s: Int) -> String {
    if s < 90 { return "\(s)s" }; if s < 5400 { return "\(s / 60)min" }; if s < 172800 { return "\(s / 3600)h" }; return "\(s / 86400)d"
}

// ---------------------------------------------------------------- pieces
struct Panel<C: View>: View {
    let title: String; var state: String = ""; var good: Bool? = nil
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(Ink.text)
                Spacer()
                if !state.isEmpty {
                    Text(state).font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(good == true ? Ink.green : good == false ? Ink.red : Ink.dim)
                }
            }.padding(.horizontal, 14).frame(height: 36)
            Rectangle().fill(Ink.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) { content }.padding(14)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ink.line, lineWidth: 1))
    }
}

struct Dot: View { let on: Bool?; var body: some View {
    Circle().fill(on == true ? Ink.green : on == false ? Ink.red : Ink.grey).frame(width: 8, height: 8) } }

struct Wrap: View {   // plain flow of chips that never cuts one
    let items: [(String, Bool)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 6) { Dot(on: it.1); Text(it.0).lineLimit(1) }
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(it.1 ? Ink.text : Ink.red)
            }
        }
    }
}

func mono(_ s: String, _ c: Color = Ink.text, _ size: CGFloat = 12) -> some View {
    Text(s).font(.system(size: size, design: .monospaced)).foregroundStyle(c).fixedSize(horizontal: false, vertical: true)
}

/// label + value; "unknown" in grey where the value cannot be read from any file
struct Chip { let label: String; let value: String?; var color: Color = Ink.text }
@ViewBuilder func chips(_ items: [Chip]) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, c in
            HStack(spacing: 5) {
                Text(c.label).foregroundStyle(Ink.grey)
                Text(c.value ?? "unknown").foregroundStyle(c.value == nil ? Ink.grey : c.color).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 11, weight: .bold, design: .monospaced))
        }
    }
}
func onoff(_ b: Bool?) -> Chip { Chip(label: "", value: b == nil ? nil : (b! ? "ON" : "OFF"), color: b == true ? Ink.green : Ink.dim) }
func pct(_ v: Any?) -> String? { (v as? Int).map { "\($0)%" } }
func routerText(_ mode: String?, _ pick: String?) -> String? {
    guard let m = mode else { return nil }
    if m == "off" { return "BYPASSED (Opus every prompt)" }
    return m + ((pick ?? "").isEmpty ? "" : " → " + pick!)
}
func modeChips(_ m: J, agents: Int) -> [Chip] {
    let perm = (m["permission"] as? String).map { $0 == "normal" ? "default" : $0 }
    let mcp = (m["mcp"] as? [String]) ?? []
    return [Chip(label: "MODEL", value: m["model"] as? String), Chip(label: "EFFORT", value: m["effort"] as? String),
            Chip(label: "PERMISSION", value: perm, color: perm == "auto" ? Ink.green : Ink.text),
            Chip(label: "RC", value: (m["rc"] as? Bool).map { $0 ? "ON" : "OFF" }, color: (m["rc"] as? Bool) == true ? Ink.green : Ink.dim),
            Chip(label: "ROUTER", value: routerText(m["router"] as? String, m["router_pick"] as? String), color: (m["router"] as? String) == "off" ? Ink.amber : Ink.text),
            Chip(label: "FAST", value: m["fast"] as? String),
            Chip(label: "AGENTS", value: "\(agents) running"),
            Chip(label: "MCP", value: mcp.isEmpty ? "none" : mcp.joined(separator: ",")),
            Chip(label: "CONTEXT", value: pct(m["ctx"])),
            Chip(label: "5H", value: pct(m["sp"]).map { $0 + ((m["sx"] as? String).map { " · resets " + $0 } ?? "") }),
            Chip(label: "WEEK", value: pct(m["wp"]).map { $0 + ((m["wx"] as? String).map { " · resets " + $0 } ?? "") }, color: Color(red: 1.0, green: 0.55, blue: 0.1))]
}

/// the header strip: what is set for every session (settings.json) and the plan usage of the account
struct HeaderStrip: View {
    let st: J
    static func w(_ u: J, _ k: String) -> String? {
        guard let x = u[k] as? J, let p = x["used_percentage"] as? Int else { return nil }
        var t = "\(p)% used"
        if let r = x["resets_at"] as? Double { let h = max(0, Int((r - Date().timeIntervalSince1970) / 3600)); t += " · resets in " + (h >= 48 ? "\(h / 24)d" : "\(h)h") }
        return t
    }
    var body: some View {
        let u = ((st["usage"] as? J)?["rate_limits"] as? J) ?? [:]
        Panel(title: "Every session: modes and usage", state: "from settings.json and the status line") {
            chips([Chip(label: "DEFAULT MODEL", value: st["model"] as? String), Chip(label: "EFFORT", value: st["effort_default"] as? String),
                   Chip(label: "RC AT START", value: (st["rc_at_startup"] as? Bool).map { $0 ? "ON" : "OFF" }, color: Ink.green),
                   Chip(label: "ROUTER PLUGIN", value: (st["router_plugin"] as? Bool).map { $0 ? "enabled" : "disabled" }),
                   Chip(label: "FAST MODE", value: (st["fast_mode"] as? Bool).map { $0 ? "ON" : "OFF" }),
                   Chip(label: "5-HOUR WINDOW", value: HeaderStrip.w(u, "five_hour"), color: Ink.amber),
                   Chip(label: "WEEK", value: HeaderStrip.w(u, "seven_day"), color: Ink.amber)])
        }
    }
}

// ---------------------------------------------------------------- plans: the checklist of each project
func statusGlyph(_ st: String, _ checked: Bool) -> (String, Color) {
    switch st {
    case "done": return (checked ? "✓" : "✓?", Ink.green)     // ✓? = the agent says done, the master has not ticked it yet
    case "running": return ("●", Ink.amber)
    case "paused": return ("❚❚", Ink.dim)
    case "failed": return ("✕", Ink.red)
    default: return ("○", Ink.grey)
    }
}

struct WordButton: View {
    let word: String; let id: String; var color: Color = Ink.grey; let action: () -> Void
    var body: some View {
        Text(word).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle()).onTapGesture(perform: action).axButton(word, id: id, action)
    }
}

struct Bar: View {
    let done: Int, running: Int, total: Int
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, t = CGFloat(max(total, 1))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 3).fill(Ink.amber.opacity(0.55)).frame(width: w * CGFloat(done + running) / t)
                RoundedRectangle(cornerRadius: 3).fill(Ink.green).frame(width: w * CGFloat(done) / t)
            }
        }.frame(height: 6)
    }
}

struct TaskRow: View {
    @ObservedObject var m: Model
    let slug: String; let t: J; let cmds: [J]
    @ViewBuilder func replyRow(n: Int, key: String, agent: String) -> some View {
        HStack(spacing: 6) {
                        TextField("message to this worker", text: Binding(get: { m.drafts[key] ?? "" }, set: { m.drafts[key] = $0 }))
                            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.text)
                            .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                            .accessibilityIdentifier("box\(n)")
                        WordButton(word: "SEND", id: "send\(n)", color: Ink.green) {
                            let x = (m.drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines); if !x.isEmpty { m.send(slug: slug, agent: agent, task: n, action: "message", text: x) } }
                        WordButton(word: "REPROMPT", id: "reprompt\(n)", color: Ink.amber) {
                            let x = (m.drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines); if !x.isEmpty { m.send(slug: slug, agent: agent, task: n, action: "reprompt", text: x) } }
                    }
    }
    var body: some View {
        let n = t["n"] as? Int ?? 0, key = "\(slug)#\(n)"
        let st = t["status"] as? String ?? "todo", checked = (t["checked"] as? Bool) ?? false
        let g = statusGlyph(st, checked)
        let agent = t["agent"] as? String ?? ""
        let report = (t["report"] as? String) ?? "", next = (t["next"] as? String) ?? ""
        let isOpen = m.open.contains(key)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(g.0).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(g.1).frame(width: 26, alignment: .leading)
                Text("\(n)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Ink.grey).frame(width: 16, alignment: .trailing)
                Text(t["title"] as? String ?? "").font(.system(size: 12.5, weight: st == "running" ? .semibold : .regular))
                    .foregroundStyle(st == "todo" ? Ink.dim : Ink.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(isOpen ? "▾" : "▸").foregroundStyle(Ink.grey).font(.system(size: 11))
            }
            .contentShape(Rectangle()).onTapGesture { if isOpen { m.open.remove(key) } else { m.open.insert(key) } }
            .axButton("Task \(n) report", id: "task\(n)") { if isOpen { m.open.remove(key) } else { m.open.insert(key) } }
            HStack(spacing: 8) {
                Spacer().frame(width: 50)
                mono("worker " + (agent.isEmpty ? "unknown" : agent), Ink.dim, 10.5).lineLimit(1)
                Spacer(minLength: 4)
                if st == "running" || st == "paused" {
                    WordButton(word: "PAUSE", id: "pause\(n)") { m.send(slug: slug, agent: agent, task: n, action: "pause") }
                    WordButton(word: "STOP", id: "stop\(n)", color: Ink.red) { m.send(slug: slug, agent: agent, task: n, action: "stop") }
                }
            }
            if st == "paused" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WAITING FOR YOU").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Ink.amber)
                    mono(!next.isEmpty ? next : (!report.isEmpty ? report : "this agent is paused and has not said what it needs"), Ink.text, 12)
                    replyRow(n: n, key: key, agent: agent)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Ink.amber.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ink.amber.opacity(0.6), lineWidth: 1)).padding(.leading, 50)
            }
            if isOpen && st != "paused" {
                VStack(alignment: .leading, spacing: 6) {
                    mono(report.isEmpty ? "no report yet" : report, report.isEmpty ? Ink.grey : Ink.text, 11.5)
                    if !next.isEmpty { mono("next: " + next, Ink.dim, 11) }
                    replyRow(n: n, key: key, agent: agent)
                    ForEach(Array(cmds.filter { ($0["task"] as? Int) == n }.prefix(3).enumerated()), id: \.offset) { _, c in
                        let cs = c["state"] as? String ?? "sent"
                        mono("\((c["action"] as? String) ?? ""): \(cs)" + (((c["result"] as? String) ?? "").isEmpty ? "" : " · " + (c["result"] as? String ?? "")),
                             cs == "done" ? Ink.green : cs == "failed" ? Ink.red : Ink.amber, 10.5)
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04))).padding(.leading, 50)
            }
        }
    }
}

func st(_ t: J) -> String { t["status"] as? String ?? "todo" }
func cnt(_ all: [J], _ s: String) -> Int { all.filter { ($0["status"] as? String) == s }.count }

struct PlanCard: View {
    @ObservedObject var m: Model
    let p: J
    var body: some View {
        let allTasks = (p["tasks"] as? [J]) ?? []
        let tasks = allTasks
        let shown = ["done", "running", "paused", "failed", "todo"].contains(m.solo) ? allTasks.filter { st($0) == m.solo } : allTasks
        let slug = p["slug"] as? String ?? ""
        let done = tasks.filter { st($0) == "done" }.count, run = tasks.filter { st($0) == "running" }.count
        let nowT = tasks.filter { st($0) == "running" || st($0) == "paused" }.map { "\($0["n"] as? Int ?? 0)" }
        let nextT = tasks.filter { st($0) == "todo" }.prefix(3).map { "\($0["n"] as? Int ?? 0)" }
        let doneT = tasks.filter { st($0) == "done" }.map { "\($0["n"] as? Int ?? 0)" }
        Panel(title: "Session Manager · " + (p["session"] as? String ?? p["project"] as? String ?? slug), state: "\(done) of \(tasks.count) done · updated \(ago(p["age"] as? Int ?? 0)) ago", good: done == tasks.count && !tasks.isEmpty ? true : nil) {
            if let pr = p["project"] as? String, !pr.isEmpty { mono(pr, Ink.text, 12.5) }
            if let goal = p["goal"] as? String, !goal.isEmpty { mono(goal, Ink.dim, 12) }
            if let f = tasks.first(where: { ($0["focus"] as? Bool) == true }) {
                mono("DOING NOW  \(f["n"] as? Int ?? 0). " + (f["title"] as? String ?? ""), Ink.amber, 12)
            }
            Bar(done: done, running: run, total: tasks.count).padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 2) {
                mono("WHERE WE ARE  " + (nowT.isEmpty ? "nothing running" : "working on " + nowT.joined(separator: ", ")), Ink.amber, 11)
                mono("DONE  " + (doneT.isEmpty ? "none yet" : doneT.joined(separator: ", ")), Ink.green, 11)
                mono("NEXT  " + (nextT.isEmpty ? "nothing waiting" : nextT.joined(separator: ", ")), Ink.dim, 11)
            }.padding(.bottom, 4)
            let cmds = (p["commands"] as? [J]) ?? []
            let focus = shown.first { ($0["focus"] as? Bool) == true }
            let rest = shown.filter { ($0["focus"] as? Bool) != true }
            if shown.isEmpty { mono("no task with this status", Ink.grey, 11) }
            if let f = focus {
                Text("IN FOCUS").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Ink.amber)
                TaskRow(m: m, slug: slug, t: f, cmds: cmds).padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Ink.amber.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ink.amber.opacity(0.5), lineWidth: 1))
                Text("WORKERS IN THE BACKGROUND").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Ink.grey).padding(.top, 4)
            }
            ForEach(Array(rest.enumerated()), id: \.offset) { i, t in
                TaskRow(m: m, slug: slug, t: t, cmds: cmds)
                if i < rest.count - 1 { Rectangle().fill(Ink.line).frame(height: 1) }
            }
        }
    }
}

struct TotalsStrip: View {
    @ObservedObject var m: Model
    let plans: [J]; let d: J
    var body: some View {
        let all = plans.flatMap { ($0["tasks"] as? [J]) ?? [] }
        let sess = ((d["mac"] as? J)?["sessions"] as? [J])?.count ?? 0
        let vmUp = ((d["vm"] as? J)?["ok"] as? Bool) ?? false
        let tiles: [(String, String, String, Color)] = [
            ("done", "\(cnt(all, "done"))", "DONE", Ink.green), ("running", "\(cnt(all, "running"))", "RUNNING", Ink.amber),
            ("paused", "\(cnt(all, "paused"))", "PAUSED", Ink.dim), ("failed", "\(cnt(all, "failed"))", "FAILED", Ink.red),
            ("todo", "\(cnt(all, "todo"))", "TO DO", Ink.grey), ("sessions", "\(((d["sessions_all"] as? J)?["rows"] as? [J])?.count ?? sess)", "SESSIONS", Ink.text),
            ("vm", vmUp ? "UP" : "DOWN", "VM", vmUp ? Ink.green : Ink.red)]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, x in
                    let on = m.solo == x.0
                    VStack(spacing: 2) {
                        Text(x.1).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(x.3)
                        Text(x.2).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(on ? Ink.text : Ink.grey)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? x.3.opacity(0.18) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? x.3 : Color.clear, lineWidth: 1.5))
                    .contentShape(Rectangle()).onTapGesture { m.toggleSolo(x.0) }
                    .axButton("Solo " + x.2, id: "solo-" + x.0, value: on ? "on" : "off") { m.toggleSolo(x.0) }
                }
            }
            if !m.solo.isEmpty {
                HStack(spacing: 8) {
                    mono("SOLO: only " + (tiles.first { $0.0 == m.solo }?.2 ?? m.solo), Ink.amber, 11)
                    WordButton(word: "SHOW ALL", id: "solo-clear", color: Ink.amber) { m.solo = "" }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 6)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ink.line, lineWidth: 1))
    }
}

// ---------------------------------------------------------------- sessions everywhere
func stateColor(_ st: String) -> Color {
    switch st { case "busy", "running": return Ink.green; case "idle": return Ink.text; case "pending", "waiting": return Ink.amber; case "offline": return Ink.grey; default: return Ink.dim }
}

struct LabelLogView: View {
    let ll: [J]
    static func line(_ e: J) -> String {
        let at = String((e["at"] as? String ?? "").suffix(8))
        let who = e["session"] as? String ?? ""
        let from = (e["from"] as? String) ?? "none"
        let to = e["to"] as? String ?? ""
        let by = e["by"] as? String ?? ""
        return at + "  " + who + ": " + from + " → " + to + "  (" + by + ")"
    }
    var body: some View {
        if !ll.isEmpty {
            Rectangle().fill(Ink.line).frame(height: 1)
            mono("LABEL LOG", Ink.grey, 10.5)
            ForEach(Array(ll.enumerated()), id: \.offset) { _, e in mono(LabelLogView.line(e), Ink.dim, 10.5) }
        }
    }
}

/// "AGENT MAKER on · last: new task 'X' → task 21"
func makerSummary(_ a: J) -> String {
    let on = (a["enabled"] as? Bool) ?? false
    var t = "AGENT MAKER " + (on ? "on" : "off")
    if let l = a["last"] as? J, let k = l["kind"] as? String, k != "chat" {
        let title = (l["title"] as? String) ?? ""
        let n = (l["n"] as? Int).map { "\($0)" } ?? "?"
        t += k == "new" ? " · last: new task '\(title)' → task \(n)" : " · last: continues task \(n) '\(title)'"
    } else if on { t += " · waiting for a digression" }
    return t
}

struct MakerPanel: View {
    static func line(_ e: J) -> String {
        let stamp: String = (e["ts"] as? String) ?? (e["at"] as? String) ?? ""
        let hhmmss: String = String(stamp.suffix(14).prefix(8))
        let k: String = (e["kind"] as? String) ?? ""
        let n: String = (e["n"] as? Int).map { String($0) } ?? "?"
        let title: String = (e["title"] as? String) ?? ""
        let who: String = (e["session"] as? String) ?? ""
        return "\(hhmmss)  \(k) task \(n): \(title)  [\(who)]"
    }
    @ObservedObject var m: Model
    let a: J
    var body: some View {
        let on = (a["enabled"] as? Bool) ?? false
        Panel(title: "Agent Maker (mod)", state: on ? "ON" : "OFF", good: on ? true : nil) {
            HStack(spacing: 10) {
                mono(makerSummary(a), Ink.text, 11)
                Spacer(minLength: 0)
                Text(on ? "TURN OFF" : "TURN ON").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(on ? Ink.amber : Ink.green)
                    .contentShape(Rectangle()).onTapGesture { m.toggleMaker() }
                    .axButton("Agent Maker switch", id: "makerswitch", value: on ? "on" : "off") { m.toggleMaker() }
            }
            let log = (a["log"] as? [J]) ?? []
            if !log.isEmpty {
                Rectangle().fill(Ink.line).frame(height: 1)
                mono("AGENT MAKER LOG", Ink.grey, 10.5)
                ForEach(Array(log.enumerated()), id: \.offset) { _, e in
                    let k = (e["kind"] as? String) ?? ""
                    let n = (e["n"] as? Int).map { "\($0)" } ?? "?"
                    mono(MakerPanel.line(e), Ink.dim, 10.5)
                }
            }
            mono("Mod: ~/.claude/dev-mods/…/agent-maker, script ~/.claude/mantra/agent_maker.py; /agent-maker on|off in a session does the same.", Ink.grey, 10)
        }
    }
}

struct SessionsPanel: View {
    @ObservedObject var m: Model
    let all: J; let net: J
    static func deviceOrder(_ rows: [J]) -> [String] {
        var names = Set<String>()
        for r in rows { if let d = r["device"] as? String { names.insert(d) } }
        func w(_ x: String) -> Int { x == "Mac" ? 0 : (x == "chromium-vm" ? 1 : (x == "cloud" ? 9 : 5)) }
        return names.sorted { (w($0), $0) < (w($1), $1) }
    }
    /// (label, colour) of a session's retire progress: from the master's retire file, else from the queued command
    static func retireState(_ rt: J, _ name: String) -> (String, Color)? {
        let sl = Model.slug(name)
        if let f = (rt["files"] as? J)?[sl] as? J, let st = f["state"] as? String {
            switch st {
            case "retired": return ("RETIRED", Ink.grey)
            case "clean": return ("CLEAN", Ink.green)
            case "blocked": return ("BLOCKED", Ink.red)
            default: return ("CHECKING", Ink.amber)
            }
        }
        if let q = (rt["queued"] as? J)?[sl] as? J {
            let st = q["state"] as? String ?? "sent"
            return st == "failed" ? ("RETIRE FAILED", Ink.red) : (st == "done" ? ("RETIRING", Ink.amber) : ("RETIRING", Ink.amber))
        }
        return nil
    }
    /// name, and for a BUSY session the model running its current task in orange parentheses (tooltip: where that came from)
    @ViewBuilder static func nameText(_ r: J, _ stt: String) -> some View {
        let name = r["name"] as? String ?? "?"
        let md = r["modes"] as? J
        let cur = (stt == "busy" || stt == "running") ? (md?["current_model"] as? String) : nil
        let t = Text(name).font(.system(size: 12.5, weight: .bold)).foregroundColor(stt == "offline" ? Ink.dim : Ink.text)
        if let c = cur {
            (t + Text(" (" + c + ")").font(.system(size: 12.5, weight: .bold)).foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.1)))
                .help("Model of the current task: " + (md?["current_source"] as? String ?? "unknown source"))
        } else { t }
    }
    /// the label is the CEO's: "BASE (Label)", marked CEO-given, with a RENAME field to override by hand
    @ViewBuilder static func labelRow(_ m: Model, _ r: J, _ sid: String) -> some View {
        let lb = r["label"] as? J
        let text = lb?["label"] as? String
        let by = lb?["by"] as? String ?? "ceo"
        let applied = (r["name"] as? String ?? "").contains("(" + (text ?? "\u{0}") + ")")
        HStack(spacing: 8) {
            mono((by == "manual" ? "LABEL by Marko: " : "LABEL by CEO: ") + (text ?? "not computed yet") + (text != nil && !applied ? "  (the title takes it at the next prompt)" : ""),
                 by == "manual" ? Ink.green : Ink.dim, 10.5)
            WordButton(word: "RENAME", id: "rename-" + sid.prefix(8), color: Ink.grey) {
                if m.renameOpen.contains(sid) { m.renameOpen.remove(sid) } else { m.renameOpen.insert(sid); m.renameDraft[sid] = text ?? "" } }
            Spacer(minLength: 0)
        }.padding(.leading, 16)
        if m.renameOpen.contains(sid) {
            HStack(spacing: 6) {
                TextField("label, 1 to 3 words", text: Binding(get: { m.renameDraft[sid] ?? "" }, set: { m.renameDraft[sid] = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.text)
                    .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                    .accessibilityIdentifier("rename-box-" + sid.prefix(8))
                WordButton(word: "SET", id: "rename-set-" + sid.prefix(8), color: Ink.green) {
                    let x = (m.renameDraft[sid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !x.isEmpty { m.labelCmd(["set", sid, x]); m.renameOpen.remove(sid) } }
                WordButton(word: "AUTO", id: "rename-auto-" + sid.prefix(8), color: Ink.amber) { m.labelCmd(["auto", sid]); m.renameOpen.remove(sid) }
            }.padding(.leading, 16)
        }
    }
    static func deviceChips(_ devs: [J]) -> [Chip] {
        var out: [Chip] = []
        for d in devs {
            let on = (d["online"] as? Bool) ?? false
            let name = d["name"] as? String ?? "?"
            let os = d["os"] as? String ?? ""
            let seen = String((d["last_seen"] as? String ?? "").prefix(10))
            var v = os + " online"
            if !on { v = os + " offline" + (seen.isEmpty ? "" : " since " + seen) }
            out.append(Chip(label: (on ? "● " : "○ ") + name, value: v, color: on ? Ink.green : Ink.red))
        }
        return out
    }
    static func totalChips(_ order: [String], _ tot: [String: [String: Int]]) -> [Chip] {
        var out: [Chip] = []
        for dv in order {
            let t = tot[dv] ?? [:]
            var parts: [String] = []
            for k in ["busy", "running", "idle", "pending", "waiting", "offline"] { if let n = t[k] { parts.append("\(n) \(k)") } }
            out.append(Chip(label: dv, value: parts.joined(separator: " · ")))
        }
        return out
    }
    var body: some View {
        let rows = (all["rows"] as? [J]) ?? []
        let devs = (net["devices"] as? [J]) ?? []
        let m0 = m.data
        let tot = (all["totals"] as? [String: [String: Int]]) ?? [:]
        let order = SessionsPanel.deviceOrder(rows)
        let busy = rows.filter { ($0["state"] as? String) == "busy" || ($0["state"] as? String) == "running" }.count
        let off = rows.filter { ($0["state"] as? String) == "offline" }.count
        Panel(title: "Sessions on every machine", state: "\(rows.count) sessions · \(busy) working · \(off) offline", good: nil) {
            // devices on the tailnet
            mono("DEVICES  (Tailscale)", Ink.grey, 10.5)
            chips(SessionsPanel.deviceChips(devs))
            if devs.isEmpty { mono("Tailscale did not answer", Ink.amber, 11) }
            Rectangle().fill(Ink.line).frame(height: 1)
            mono("TOTALS BY DEVICE", Ink.grey, 10.5)
            chips(SessionsPanel.totalChips(order, tot))
            let offRows = rows.filter { ($0["state"] as? String) == "offline" && SessionsPanel.retireState((m0["retire"] as? J) ?? [:], $0["name"] as? String ?? "") == nil }
            HStack(spacing: 8) {
                WordButton(word: "RETIRE ALL OFFLINE (\(offRows.count))", id: "retire-all-offline", color: Ink.amber) { if !offRows.isEmpty { m.confirmAll = true } }
                mono("never deletes: each session is woken, checked, then retired", Ink.grey, 10.5)
            }
            if m.confirmAll {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RETIRE THESE \(offRows.count) SESSIONS?").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Ink.amber)
                    ForEach(Array(offRows.enumerated()), id: \.offset) { _, r in mono("· " + (r["name"] as? String ?? "") + "  (" + (r["device"] as? String ?? "") + ")", Ink.text, 11) }
                    mono("The Session Manager wakes each one, it checks that everything is saved and pushed, and only then it is retired. A device that is off is BLOCKED.", Ink.dim, 10.5)
                    HStack(spacing: 8) {
                        WordButton(word: "CONFIRM", id: "retire-confirm", color: Ink.green) {
                            for r in offRows { m.retire(r["name"] as? String ?? "", device: r["device"] as? String ?? "", kind: r["kind"] as? String ?? "") }
                            m.confirmAll = false }
                        WordButton(word: "CANCEL", id: "retire-cancel") { m.confirmAll = false }
                    }
                }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Ink.amber.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ink.amber.opacity(0.5), lineWidth: 1))
            }
            ForEach(order, id: \.self) { dv in
                Rectangle().fill(Ink.line).frame(height: 1)
                mono(dv.uppercased(), Ink.grey, 10.5)
                ForEach(Array(rows.filter { ($0["device"] as? String) == dv }.enumerated()), id: \.offset) { _, r in
                    let stt = r["state"] as? String ?? "unknown"
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Dot(on: (stt == "busy" || stt == "running") ? true : (stt == "offline" ? false : nil))
                            SessionsPanel.nameText(r, stt)
                            Text(stt.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(stateColor(stt))
                            Spacer(minLength: 4)
                            mono((r["kind"] as? String ?? "") + " · " + (r["source"] as? String ?? "") + " " + (((r["as_of"] as? String) ?? "").suffix(8).prefix(8)), Ink.grey, 10)
                        }
                        let nm = r["name"] as? String ?? ""
                        let rs = SessionsPanel.retireState((m0["retire"] as? J) ?? [:], nm)
                        HStack(spacing: 8) {
                            if let rs = rs {
                                Text(rs.0).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(rs.1)
                                    .onTapGesture { if m.retireOpen.contains(nm) { m.retireOpen.remove(nm) } else { m.retireOpen.insert(nm) } }
                                    .axButton("Retire checks " + nm, id: "retire-checks-" + Model.slug(nm)) { if m.retireOpen.contains(nm) { m.retireOpen.remove(nm) } else { m.retireOpen.insert(nm) } }
                            }
                            if rs == nil || rs?.0 == "BLOCKED" || rs?.0 == "RETIRE FAILED" {
                                WordButton(word: "RETIRE", id: "retire-" + Model.slug(nm), color: Ink.amber) { m.retire(nm, device: dv, kind: r["kind"] as? String ?? "") }
                            }
                        }.padding(.leading, 16)
                        if let f = (((m0["retire"] as? J)?["files"] as? J)?[Model.slug(nm)]) as? J, rs != nil, (m.retireOpen.contains(nm) || rs?.0 == "BLOCKED") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(((f["checks"] as? [J]) ?? []).enumerated()), id: \.offset) { _, c in
                                    let ok = (c["ok"] as? Bool) ?? false
                                    mono((ok ? "✓ " : "✕ ") + (c["name"] as? String ?? "") + ((c["detail"] as? String ?? "").isEmpty ? "" : ": " + (c["detail"] as? String ?? "")), ok ? Ink.green : Ink.red, 10.5)
                                }
                                if ((f["checks"] as? [J]) ?? []).isEmpty { mono("waiting for the Session Manager to wake this session", Ink.grey, 10.5) }
                            }.padding(.leading, 16)
                        }
                        if let sid = r["sid"] as? String, !sid.isEmpty {
                            SessionsPanel.labelRow(m, r, sid)
                        }
                        if let m = r["modes"] as? J {
                            chips([Chip(label: "MODEL", value: m["model"] as? String), Chip(label: "PERMISSION", value: (m["permission"] as? String).map { $0 == "normal" ? "default" : $0 }),
                                   Chip(label: "RC", value: (m["rc"] as? Bool).map { $0 ? "ON" : "OFF" }), Chip(label: "CONTEXT", value: pct(m["ctx"]))]).padding(.leading, 16)
                        }
                        if let l = r["last"] as? String, !l.isEmpty { mono("last: " + l, Ink.dim, 10.5).lineLimit(2).padding(.leading, 16) }
                        if (stt == "busy" || stt == "running"), let ws = r["workers"] as? [J], !ws.isEmpty {
                            mono("workers: " + ws.map { (($0["id"] as? String) ?? "").prefix(7) + " (" + (($0["model"] as? String) ?? "model unknown") + ")" }.joined(separator: " · "), Ink.dim, 10.5).padding(.leading, 16)
                        }
                    }
                }
            }
            LabelLogView(ll: (m0["label_log"] as? [J]) ?? [])
            mono("Master list: " + (all["source"] as? String ?? "none") + (((all["updated"] as? String) ?? "").isEmpty ? "" : " · as of " + (all["updated"] as? String ?? "")), Ink.grey, 10)
        }
    }
}

struct MacPanel: View {
    let d: J
    var body: some View {
        let ss = (d["sessions"] as? [J]) ?? []
        let running = ss.reduce(0) { $0 + (($1["tasks_running"] as? Int) ?? 0) }
        Panel(title: "This Mac", state: "\(ss.count) sessions · \(running) tasks running", good: ss.isEmpty ? nil : true) {
            if ss.isEmpty { mono("no Claude Code session found", Ink.dim) }
            ForEach(Array(ss.enumerated()), id: \.offset) { idx, s in
                let busy = (s["status"] as? String) == "busy"
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Dot(on: busy ? true : nil)
                        Text(s["name"] as? String ?? "?").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.text)
                        Text((s["status"] as? String ?? "").uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(busy ? Ink.green : Ink.grey)
                        Spacer(minLength: 8)
                        mono("\(s["tasks_running"] as? Int ?? 0)/\(s["tasks_total"] as? Int ?? 0) tasks", Ink.dim, 11)
                    }
                    mono(s["folder"] as? String ?? "", Ink.dim, 11).padding(.leading, 16)
                    if let l = s["last"] as? String, !l.isEmpty { mono("last: " + l, Ink.dim, 11).lineLimit(2).padding(.leading, 16) }
                    let agentsRun = ((s["tasks"] as? [J]) ?? []).filter { ($0["kind"] as? String) == "agent" && (($0["running"] as? Bool) ?? false) }.count
                    chips(modeChips((s["modes"] as? J) ?? [:], agents: agentsRun)).padding(.leading, 16).padding(.vertical, 2)
                    ForEach(Array(((s["tasks"] as? [J]) ?? []).prefix(6).enumerated()), id: \.offset) { _, t in
                        let run = (t["running"] as? Bool) ?? false
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Dot(on: run ? true : nil)
                            mono((t["kind"] as? String ?? "") + " " + (t["id"] as? String ?? ""), run ? Ink.text : Ink.dim, 11)
                            mono((t["desc"] as? String) ?? "", Ink.dim, 11).lineLimit(1)
                            Spacer(minLength: 4)
                            mono(ago(t["age"] as? Int ?? 0), Ink.dim, 11)
                        }.padding(.leading, 16)
                    }
                    if (s["tasks_total"] as? Int ?? 0) > 6 { mono("… and \((s["tasks_total"] as? Int ?? 0) - 6) older", Ink.grey, 11).padding(.leading, 16) }
                }
                if idx < ss.count - 1 { Rectangle().fill(Ink.line).frame(height: 1) }
            }
            ForEach(Array(((d["other"] as? [J]) ?? []).enumerated()), id: \.offset) { _, o in
                mono("claude process \(o["pid"] as? Int ?? 0): \(o["cmd"] as? String ?? "")", Ink.dim, 11).lineLimit(1)
            }
        }
    }
}

struct VMPanel: View {
    let d: J
    var body: some View {
        let ok = (d["ok"] as? Bool) ?? false
        let sv = (d["services"] as? [J]) ?? []
        let up = sv.filter { ($0["active"] as? String) == "active" }.count
        Panel(title: "chromium-vm (Oracle)", state: ok ? "\(up)/\(sv.count) services up" : "UNREACHABLE", good: ok ? up == sv.count : false) {
            if !ok { mono((d["note"] as? String) ?? "no answer", Ink.red) }
            else {
                HStack(spacing: 14) {
                    HStack(spacing: 6) { Dot(on: d["claude"] as? Bool); mono("Claude Code (tmux claude)", Ink.text) }
                    HStack(spacing: 6) { Dot(on: d["vm_agent"] as? Bool); mono("vm-agent :8890", Ink.text) }
                }
                let b = (d["bar"] as? J) ?? [:], r = (d["router"] as? J) ?? [:]
                chips(modeChips(["model": b["model"] as Any, "rc": b["rc"] as Any, "router": r["mode"] as Any, "router_pick": r["pick"] as Any,
                                 "ctx": b["ctx"] as Any, "sp": b["sp"] as Any, "sx": b["sx"] as Any, "wp": b["wp"] as Any, "wx": b["wx"] as Any],
                                agents: 0)).padding(.vertical, 2)
                Wrap(items: sv.map { ($0["name"] as? String ?? "?", ($0["active"] as? String) == "active") })
                ForEach(Array(((d["workers"] as? [J]) ?? []).enumerated()), id: \.offset) { _, w in
                    VStack(alignment: .leading, spacing: 2) {
                        mono("worker \(w["name"] as? String ?? "") · log \(ago(w["age"] as? Int ?? 0)) ago", Ink.text, 11)
                        mono(w["last"] as? String ?? "", Ink.dim, 11)
                    }
                }
            }
        }
    }
}

struct PhonesPanel: View {
    let d: J
    var body: some View {
        let ds = (d["devices"] as? [J]) ?? []
        Panel(title: "Phones", state: ds.isEmpty ? "NONE ON ADB" : "\(ds.count) on adb", good: ds.isEmpty ? false : true) {
            if ds.isEmpty { mono((d["note"] as? String) ?? "no phone on adb", Ink.dim) }
            ForEach(Array(ds.enumerated()), id: \.offset) { _, p in
                let cc = (p["claude_code"] as? Bool) ?? false
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Dot(on: cc ? true : nil)
                    Text(p["model"] as? String ?? "?").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.text)
                    mono(p["via"] as? String ?? "", Ink.dim, 11)
                    Spacer(minLength: 8)
                    mono("Claude Code: " + (cc ? "RUNNING" : "not running"), cc ? Ink.green : Ink.dim, 11)
                    mono("app: " + (((p["claude_app"] as? Bool) ?? false) ? "yes" : "no"), Ink.dim, 11)
                }
                if ((p["claude_code"] as? Bool) ?? false) { chips(modeChips([:], agents: 0)).padding(.leading, 16) }
            }
        }
    }
}

struct CloudPanel: View {
    let d: J
    var body: some View {
        let it = (d["items"] as? [J]) ?? []
        Panel(title: "Cloud sessions", state: "\(it.count) in the hub's INBOX") {
            mono((d["note"] as? String) ?? "", Ink.dim, 11)
            ForEach(Array(it.enumerated()), id: \.offset) { _, c in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    mono(c["name"] as? String ?? "", Ink.text, 11).lineLimit(1)
                    mono(c["first"] as? String ?? "", Ink.dim, 11).lineLimit(1)
                    Spacer(minLength: 4)
                    mono(ago(c["age"] as? Int ?? 0), Ink.dim, 11)
                }
            }
        }
    }
}

// ---------------------------------------------------------------- the window
struct TopRow: View {
    @AppStorage("onTop") private var onTop = false
    var body: some View {
        ZStack {
            (Text("Agent Manager").fontWeight(.bold) + Text(" (CEO) (Mantra)").fontWeight(.regular)).font(.system(size: 15)).foregroundStyle(Ink.text)
            HStack(spacing: 10) {
                Spacer().frame(width: 64)
                Text("ON").foregroundStyle(Ink.green)
                Text("OFF").foregroundStyle(Ink.grey).contentShape(Rectangle()).onTapGesture { NSApp.terminate(nil) }
                    .axButton("Off", id: "off") { DispatchQueue.main.async { NSApp.terminate(nil) } }
                Spacer()
                Text("TOP").foregroundStyle(onTop ? Ink.green : Ink.grey).contentShape(Rectangle())
                    .onTapGesture { onTop.toggle(); TopRow.float(onTop) }
                    .axButton("Top", id: "top", value: onTop ? "on" : "off") { onTop.toggle(); TopRow.float(onTop) }
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.grey)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
                    .onTapGesture { NSApp.keyWindow?.performClose(nil) }
                    .axButton("Close window", id: "close") { (NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible })?.performClose(nil) }
            }.font(.system(size: 12, weight: .bold, design: .monospaced))
        }
        .frame(height: 30)
        .onAppear { DispatchQueue.main.async { TopRow.float(onTop) } }
    }
    static func float(_ on: Bool) { for w in NSApp.windows where w.identifier?.rawValue == "agentmanager" { w.level = on ? .floating : .normal } }
}

// ---------------------------------------------------------------- the status bar (iTerm style), pinned to the bottom
struct Seg { let text: String; var color: Color = Ink.text; var suffix: String = "" }

func usageColor(_ p: Int?) -> Color { guard let p = p else { return Ink.grey }; return p >= 85 ? Ink.red : (p >= 60 ? Ink.amber : Ink.green) }
func resetsIn(_ t: Double?) -> String {
    guard let t = t else { return "" }
    let h = max(0, Int((t - Date().timeIntervalSince1970) / 3600))
    return " ↻" + (h >= 48 ? "\(h / 24)d" : "\(h)h")
}
/// one flowing line of segments with thin dividers; wraps to a second line instead of cutting
func strip(_ segs: [Seg]) -> Text {
    var t = Text("")
    for (i, g) in segs.enumerated() {
        if i > 0 { t = t + Text("  │  ").foregroundColor(Ink.line.opacity(2.5)) }
        t = t + Text(g.text).foregroundColor(g.color)
        if !g.suffix.isEmpty { t = t + Text(" (" + g.suffix + ")").foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.1)) }
    }
    return t.font(.system(size: 10.5, weight: .medium, design: .monospaced))
}
func lab(_ l: String, _ v: String?, _ c: Color = Ink.text) -> Seg { Seg(text: l + " " + (v ?? "unknown"), color: v == nil ? Ink.grey : c) }

struct StatusBar: View {
    let data: J
    static var amState: J? = nil
    static func globalSegs(_ st: J) -> [Seg] {
        let rl = ((st["usage"] as? J)?["rate_limits"] as? J) ?? [:]
        let f = rl["five_hour"] as? J, w = rl["seven_day"] as? J
        let fp = f?["used_percentage"] as? Int, wp = w?["used_percentage"] as? Int
        var out: [Seg] = [Seg(text: "ALL SESSIONS", color: Ink.amber)]
        if let am = amState { out.append(Seg(text: makerSummary(am), color: (am["enabled"] as? Bool) == true ? Ink.green : Ink.grey)) }
        out.append(lab("model", st["model"] as? String))
        out.append(lab("effort", st["effort_default"] as? String))
        out.append(lab("RC@start", (st["rc_at_startup"] as? Bool).map { $0 ? "on" : "off" }, Ink.green))
        out.append(lab("router", (st["router_plugin"] as? Bool).map { $0 ? "plugin on" : "plugin off" }))
        out.append(lab("fast", (st["fast_mode"] as? Bool).map { $0 ? "on" : "off" }))
        out.append(Seg(text: "5h " + (fp.map { "\($0)%" } ?? "unknown") + resetsIn(f?["resets_at"] as? Double), color: usageColor(fp)))
        out.append(Seg(text: "week " + (wp.map { "\($0)%" } ?? "unknown") + resetsIn(w?["resets_at"] as? Double), color: Color(red: 1.0, green: 0.55, blue: 0.1)))
        return out
    }
    static func sessionSegs(_ s: J) -> [Seg] {
        let m = (s["modes"] as? J) ?? [:]
        let name = ((s["name"] as? String) ?? "?")
        let perm = (m["permission"] as? String).map { $0 == "normal" ? "default" : $0 }
        let rt = routerText(m["router"] as? String, m["router_pick"] as? String)
        let ctx = m["ctx"] as? Int, sp = m["sp"] as? Int, wp = m["wp"] as? Int
        let mcp = (m["mcp"] as? [String]) ?? []
        let agents = ((s["tasks"] as? [J]) ?? []).filter { ($0["kind"] as? String) == "agent" && (($0["running"] as? Bool) ?? false) }.count
        let busy = (s["status"] as? String) == "busy"
        var out: [Seg] = [Seg(text: name, color: busy ? Ink.green : Ink.text, suffix: busy ? (m["current_model"] as? String ?? "") : "")]
        out.append(lab("model", m["model"] as? String)); out.append(lab("effort", m["effort"] as? String))
        out.append(lab("perm", perm, perm == "auto" ? Ink.green : Ink.text))
        out.append(lab("RC", (m["rc"] as? Bool).map { $0 ? "on" : "off" }, Ink.green))
        out.append(lab("router", rt, (m["router"] as? String) == "off" ? Ink.amber : Ink.text))
        out.append(Seg(text: "ctx " + (ctx.map { "\($0)%" } ?? "unknown"), color: usageColor(ctx)))
        out.append(Seg(text: "5h " + (sp.map { "\($0)%" } ?? "unknown"), color: usageColor(sp)))
        out.append(Seg(text: "week " + (wp.map { "\($0)%" } ?? "unknown"), color: Color(red: 1.0, green: 0.55, blue: 0.1)))
        out.append(Seg(text: "agents \(agents)", color: agents > 0 ? Ink.amber : Ink.grey))
        out.append(lab("mcp", mcp.isEmpty ? "none" : mcp.joined(separator: ",")))
        return out
    }
    var body: some View {
        let mac = (data["mac"] as? J) ?? [:]
        let sessions = (mac["sessions"] as? [J]) ?? []
        let _ = { StatusBar.amState = data["agent_maker"] as? J }()
        VStack(spacing: 0) {
            Rectangle().fill(Ink.line).frame(height: 1)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 5) {
                    strip(StatusBar.globalSegs((mac["settings"] as? J) ?? [:])).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(sessions.enumerated()), id: \.offset) { _, s in
                        strip(StatusBar.sessionSegs(s)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 7)
            }
            .frame(maxHeight: 118)
        }
        .background(Color.black.opacity(0.35)).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("statusbar")
    }
}

struct Root: View {
    @ObservedObject var m: Model
    let margin: CGFloat = 16
    static func showPlan(_ solo: String, _ p: J) -> Bool {
        if solo == "sessions" || solo == "vm" { return false }
        if ["done", "running", "paused", "failed", "todo"].contains(solo) { return (((p["tasks"] as? [J]) ?? []).contains { st($0) == solo }) }
        return true
    }
    var body: some View {
        VStack(spacing: 0) {
            TopRow().padding(.horizontal, 12).padding(.top, 6)
            GeometryReader { g in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            mono(m.stamp == "never" ? "collecting…" : "updated \(m.stamp) · every 5 s" + (m.busy ? " · reading" : ""), Ink.dim, 11)
                            if !m.note.isEmpty { mono(m.note, Ink.amber, 11) }
                            Spacer()
                            Text("REFRESH").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(m.busy ? Ink.green : Ink.grey)
                                .contentShape(Rectangle()).onTapGesture { m.refresh() }.axButton("Refresh", id: "refresh") { m.refresh() }
                        }
                        HStack(spacing: 10) {
                            Text("OPEN MANTRA OPERATING SYSTEM").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Ink.ground)
                                .padding(.horizontal, 14).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 8).fill(Ink.green))
                                .contentShape(Rectangle()).onTapGesture { m.openMaster() }
                                .axButton("Open Mantra Operating System", id: "openos") { m.openMaster() }
                            if !m.openNote.isEmpty { mono(m.openNote, Ink.dim, 11) }
                            Spacer(minLength: 0)
                        }
                        MakerPanel(m: m, a: (m.data["agent_maker"] as? J) ?? [:])
                        TotalsStrip(m: m, plans: (m.data["plans"] as? [J]) ?? [], d: m.data)
                        ForEach(Array(((m.data["plans"] as? [J]) ?? []).enumerated()), id: \.offset) { _, p in
                            if Root.showPlan(m.solo, p) { PlanCard(m: m, p: p) }
                        }
                        if ((m.data["plans"] as? [J]) ?? []).isEmpty && !m.data.isEmpty {
                            mono("No plan yet. The master session writes ~/.mantra-os/plans/<slug>.json (MANTRA_MANIFEST modules/claude-code-mantra-os.md 8a).", Ink.grey, 11)
                        }
                        if m.solo.isEmpty || m.solo == "sessions" { SessionsPanel(m: m, all: (m.data["sessions_all"] as? J) ?? [:], net: (m.data["tailnet"] as? J) ?? [:]) }
                        if m.solo.isEmpty || m.solo == "sessions" { MacPanel(d: (m.data["mac"] as? J) ?? [:]) }
                        if m.solo.isEmpty || m.solo == "vm" { VMPanel(d: (m.data["vm"] as? J) ?? [:]) }
                        if m.solo.isEmpty { PhonesPanel(d: (m.data["phones"] as? J) ?? [:])
                        CloudPanel(d: (m.data["cloud"] as? J) ?? [:]) }
                        mono("Commands go to the Session Manager through ~/.mantra-os/commands. `AgentManager --json` prints this overview for other sessions.", Ink.grey, 11)
                    }
                    .frame(width: max(0, g.size.width - 2 * margin), alignment: .leading)
                    .padding(margin)
                }
            }
            StatusBar(data: m.data)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Ink.ground)
        .frame(minWidth: 620, idealWidth: 760, maxWidth: .infinity, minHeight: 480, idealHeight: 820, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

// ---------------------------------------------------------------- app
let sampleJSON = """
{"time":"12:00:00","agent_maker":{"enabled":true,"last":{"kind":"new","n":21,"title":"Concert dates page","at":"12:00:00"},"log":[{"kind":"new","n":21,"title":"Concert dates page","session":"MAC_SES9_08-NOV","ts":"2026-11-09T12:00:00+0100"},{"kind":"continue","n":3,"title":"Band pictures","session":"MAC_SES9_08-NOV","ts":"2026-11-09T11:40:00+0100"}]},"mac":{"ok":true,"settings":{"model":"opus[1m]","effort_default":"medium","rc_at_startup":true,"router_plugin":true,"usage":{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":2000000000},"seven_day":{"used_percentage":35,"resets_at":2000000000}}}},"plans":[{"slug":"example","project":"Example project","goal":"A plan is divided into tasks, each ticked when checked","age":30,"tasks":[{"n":1,"title":"Collector helper","agent":"a1cc","status":"done","checked":true,"report":"done and checked","next":""},{"n":2,"focus":true,"title":"Swift window with a long title that has to wrap and never be cut","agent":"a2dd","status":"running","checked":false,"report":"Half way: cards and bars drawn.","next":"controls"},{"n":3,"title":"Paused job","agent":"a3ee","status":"paused","checked":false,"report":"","next":""},{"n":4,"title":"Publish","agent":"","status":"todo","checked":false,"report":"","next":""},{"n":5,"title":"A failed one","agent":"a5","status":"failed","checked":false,"report":"","next":""}],"commands":[]}],"sessions":[{"modes":{"model":"Opus 5.5","effort":"medium","permission":"auto","rc":true,"router":"off","ctx":30,"sp":12,"sx":"3h","wp":35,"wx":"5d","mcp":[]},"name":"MAC_SES9_08-NOV (Example)","status":"busy","folder":"~/Developer/claude-code","last":"a prompt, shortened to two lines at most","tasks_running":1,"tasks_total":2,"tasks":[{"id":"a1b2c3","kind":"agent","running":true,"age":12,"desc":"Star app: Agent Manager"},{"id":"bx9","kind":"shell","running":false,"age":3600,"desc":"15:38:10 push started"}]},{"name":"MAC_SES8_08-NOV (GitHub)","status":"idle","folder":"~/Developer/claude-code","last":"","tasks_running":0,"tasks_total":0,"tasks":[]}],"other":[]},
"vm":{"ok":true,"claude":true,"vm_agent":true,"services":[{"name":"agent","active":"active"},{"name":"claude-code","active":"active"},{"name":"worker-gemini","active":"failed"}],"workers":[{"name":"gemini","age":210,"last":"2026-11-08 22:03:43 UTC round done; again in 15 min"}]},
"phones":{"ok":true,"devices":[{"model":"Pixel 7","via":"usb+network","claude_code":false,"claude_app":true}]},
"cloud":{"ok":true,"note":"sample","items":[{"name":"session_01Example","age":300,"first":"a message"}]}}
"""

final class Delegate: NSObject, NSApplicationDelegate {
    let model = Model(); var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        let host = NSHostingView(rootView: Root(m: model))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = ""; window.identifier = NSUserInterfaceItemIdentifier("agentmanager"); window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden; window.titlebarSeparatorStyle = .none
        window.contentView = host; window.minSize = NSSize(width: 620, height: 480); window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AgentManagerWindow"); window.backgroundColor = NSColor(Ink.ground)
        // --shot <png>: drawn off screen at the minimum size (sample data, no network, nothing stored); --shot-live: the real data once
        if let i = args.firstIndex(where: { $0 == "--shot" || $0 == "--shot-live" }), i + 1 < args.count {
            if args[i] == "--shot-live" { model.data = (collect().flatMap { try? JSONSerialization.jsonObject(with: $0) as? J }) ?? [:] }
            else { model.data = try! JSONSerialization.jsonObject(with: Data(sampleJSON.utf8)) as! J }
            if let mac = model.data["mac"] as? J, let pl = mac["plans"] { model.data["plans"] = pl }   // the sample keeps its plan inside "mac"
            model.stamp = (model.data["time"] as? String) ?? "?"
            if let k = args.firstIndex(of: "--solo"), k + 1 < args.count { model.solo = args[k + 1] }
            var width: CGFloat = 620
            if let k = args.firstIndex(of: "--width"), k + 1 < args.count, let w = Double(args[k + 1]) { width = CGFloat(w) }
            window.setFrame(NSRect(x: -4000, y: -4000, width: width, height: 900), display: false)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 900); host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        if !args.contains("--login") { show() }
        model.start()
        startPhoneDoor()
    }
    func applicationWillTerminate(_ n: Notification) { phoneDoor?.terminate() }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ a: NSApplication, hasVisibleWindows f: Bool) -> Bool { show(); return true }
}

// --json: the overview for other sessions, no window
if CommandLine.arguments.contains("--json") {
    if let d = collect() { FileHandle.standardOutput.write(d) }
    exit(0)
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
