// Agent Manager (Mantra): tasks and agents overview of every machine, in one window, read-only first.
// Marko, 8.11.2026: "I need to have tasks overview and agents overview of what's going on right now on all of my
// machines. You need to build a Star app: agent manager and viewer."
// The data comes from helper/collect.py (bundled in Resources), run off the main thread with a timeout, so a dead
// machine never freezes the window. `--json` prints that overview and exits; `--shot <png>` draws the window off screen.
import SwiftUI
import AppKit

let VERSION = 2

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
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, c in
            HStack(spacing: 5) {
                Text(c.label).foregroundStyle(Ink.grey)
                Text(c.value ?? "unknown").foregroundStyle(c.value == nil ? Ink.grey : c.color).lineLimit(1)
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
            Chip(label: "WEEK", value: pct(m["wp"]).map { $0 + ((m["wx"] as? String).map { " · resets " + $0 } ?? "") })]
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
                mono("agent " + (agent.isEmpty ? "unknown" : agent), Ink.dim, 10.5).lineLimit(1)
                Spacer(minLength: 4)
                if st == "running" || st == "paused" {
                    WordButton(word: "PAUSE", id: "pause\(n)") { m.send(slug: slug, agent: agent, task: n, action: "pause") }
                    WordButton(word: "STOP", id: "stop\(n)", color: Ink.red) { m.send(slug: slug, agent: agent, task: n, action: "stop") }
                }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    mono(report.isEmpty ? "no report yet" : report, report.isEmpty ? Ink.grey : Ink.text, 11.5)
                    if !next.isEmpty { mono("next: " + next, Ink.dim, 11) }
                    HStack(spacing: 6) {
                        TextField("message to this agent", text: Binding(get: { m.drafts[key] ?? "" }, set: { m.drafts[key] = $0 }))
                            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.text)
                            .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                            .accessibilityIdentifier("box\(n)")
                        WordButton(word: "SEND", id: "send\(n)", color: Ink.green) {
                            let x = (m.drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines); if !x.isEmpty { m.send(slug: slug, agent: agent, task: n, action: "message", text: x) } }
                        WordButton(word: "REPROMPT", id: "reprompt\(n)", color: Ink.amber) {
                            let x = (m.drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines); if !x.isEmpty { m.send(slug: slug, agent: agent, task: n, action: "reprompt", text: x) } }
                    }
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

struct PlanCard: View {
    @ObservedObject var m: Model
    let p: J
    var body: some View {
        let tasks = (p["tasks"] as? [J]) ?? []
        let slug = p["slug"] as? String ?? ""
        func st(_ t: J) -> String { t["status"] as? String ?? "todo" }
        let done = tasks.filter { st($0) == "done" }.count, run = tasks.filter { st($0) == "running" }.count
        let nowT = tasks.filter { st($0) == "running" || st($0) == "paused" }.map { "\($0["n"] as? Int ?? 0)" }
        let nextT = tasks.filter { st($0) == "todo" }.prefix(3).map { "\($0["n"] as? Int ?? 0)" }
        let doneT = tasks.filter { st($0) == "done" }.map { "\($0["n"] as? Int ?? 0)" }
        Panel(title: p["project"] as? String ?? slug, state: "\(done) of \(tasks.count) done · updated \(ago(p["age"] as? Int ?? 0)) ago", good: done == tasks.count && !tasks.isEmpty ? true : nil) {
            if let goal = p["goal"] as? String, !goal.isEmpty { mono(goal, Ink.dim, 12) }
            Bar(done: done, running: run, total: tasks.count).padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 2) {
                mono("WHERE WE ARE  " + (nowT.isEmpty ? "nothing running" : "working on " + nowT.joined(separator: ", ")), Ink.amber, 11)
                mono("DONE  " + (doneT.isEmpty ? "none yet" : doneT.joined(separator: ", ")), Ink.green, 11)
                mono("NEXT  " + (nextT.isEmpty ? "nothing waiting" : nextT.joined(separator: ", ")), Ink.dim, 11)
            }.padding(.bottom, 4)
            ForEach(Array(tasks.enumerated()), id: \.offset) { i, t in
                TaskRow(m: m, slug: slug, t: t, cmds: (p["commands"] as? [J]) ?? [])
                if i < tasks.count - 1 { Rectangle().fill(Ink.line).frame(height: 1) }
            }
        }
    }
}

struct TotalsStrip: View {
    let plans: [J]; let d: J
    var body: some View {
        let all = plans.flatMap { ($0["tasks"] as? [J]) ?? [] }
        func c(_ s: String) -> Int { all.filter { ($0["status"] as? String) == s }.count }
        let sess = ((d["mac"] as? J)?["sessions"] as? [J])?.count ?? 0
        let vmUp = ((d["vm"] as? J)?["ok"] as? Bool) ?? false
        HStack(spacing: 0) {
            ForEach(Array([("DONE", c("done"), Ink.green), ("RUNNING", c("running"), Ink.amber), ("PAUSED", c("paused"), Ink.dim),
                           ("FAILED", c("failed"), Ink.red), ("TO DO", c("todo"), Ink.grey), ("SESSIONS", sess, Ink.text)].enumerated()), id: \.offset) { _, x in
                VStack(spacing: 2) {
                    Text("\(x.1)").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(x.2)
                    Text(x.0).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(Ink.grey)
                }.frame(maxWidth: .infinity)
            }
            VStack(spacing: 2) {
                Text(vmUp ? "UP" : "DOWN").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(vmUp ? Ink.green : Ink.red)
                Text("VM").font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(Ink.grey)
            }.frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ink.line, lineWidth: 1))
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
            (Text("Agent Manager").fontWeight(.bold) + Text(" (Mantra)").fontWeight(.regular)).font(.system(size: 15)).foregroundStyle(Ink.text)
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
    static func float(_ on: Bool) { for w in NSApp.windows where w.title.hasPrefix("Agent Manager (Mantra)") { w.level = on ? .floating : .normal } }
}

struct Root: View {
    @ObservedObject var m: Model
    let margin: CGFloat = 16
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
                        TotalsStrip(plans: (m.data["plans"] as? [J]) ?? [], d: m.data)
                        ForEach(Array(((m.data["plans"] as? [J]) ?? []).enumerated()), id: \.offset) { _, p in PlanCard(m: m, p: p) }
                        if ((m.data["plans"] as? [J]) ?? []).isEmpty && !m.data.isEmpty {
                            mono("No plan yet. The master session writes ~/.mantra-os/plans/<slug>.json (MANTRA_MANIFEST modules/claude-code-mantra-os.md 8a).", Ink.grey, 11)
                        }
                        HeaderStrip(st: (((m.data["mac"] as? J)?["settings"]) as? J) ?? [:])
                        MacPanel(d: (m.data["mac"] as? J) ?? [:])
                        VMPanel(d: (m.data["vm"] as? J) ?? [:])
                        PhonesPanel(d: (m.data["phones"] as? J) ?? [:])
                        CloudPanel(d: (m.data["cloud"] as? J) ?? [:])
                        mono("Read-only. Actions (stop an agent, open a session) come later. `AgentManager --json` prints this for other sessions.", Ink.grey, 11)
                    }
                    .frame(width: max(0, g.size.width - 2 * margin), alignment: .leading)
                    .padding(margin)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Ink.ground)
        .frame(minWidth: 620, idealWidth: 760, maxWidth: .infinity, minHeight: 480, idealHeight: 820, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

// ---------------------------------------------------------------- app
let sampleJSON = """
{"time":"12:00:00","mac":{"ok":true,"settings":{"model":"opus[1m]","effort_default":"medium","rc_at_startup":true,"router_plugin":true,"usage":{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":2000000000},"seven_day":{"used_percentage":35,"resets_at":2000000000}}}},"plans":[{"slug":"example","project":"Example project","goal":"A plan is divided into tasks, each ticked when checked","age":30,"tasks":[{"n":1,"title":"Collector helper","agent":"a1cc","status":"done","checked":true,"report":"done and checked","next":""},{"n":2,"title":"Swift window with a long title that has to wrap and never be cut","agent":"a2dd","status":"running","checked":false,"report":"Half way: cards and bars drawn.","next":"controls"},{"n":3,"title":"Paused job","agent":"a3ee","status":"paused","checked":false,"report":"","next":""},{"n":4,"title":"Publish","agent":"","status":"todo","checked":false,"report":"","next":""},{"n":5,"title":"A failed one","agent":"a5","status":"failed","checked":false,"report":"","next":""}],"commands":[]}],"sessions":[{"modes":{"model":"Opus 5.5","effort":"medium","permission":"auto","rc":true,"router":"off","ctx":30,"sp":12,"sx":"3h","wp":35,"wx":"5d","mcp":[]},"name":"MAC_SES9_08-NOV (Example)","status":"busy","folder":"~/Developer/claude-code","last":"a prompt, shortened to two lines at most","tasks_running":1,"tasks_total":2,"tasks":[{"id":"a1b2c3","kind":"agent","running":true,"age":12,"desc":"Star app: Agent Manager"},{"id":"bx9","kind":"shell","running":false,"age":3600,"desc":"15:38:10 push started"}]},{"name":"MAC_SES8_08-NOV (GitHub)","status":"idle","folder":"~/Developer/claude-code","last":"","tasks_running":0,"tasks_total":0,"tasks":[]}],"other":[]},
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
        window.title = "Agent Manager (Mantra)"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden; window.titlebarSeparatorStyle = .none
        window.contentView = host; window.minSize = NSSize(width: 620, height: 480); window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AgentManagerWindow"); window.backgroundColor = NSColor(Ink.ground)
        // --shot <png>: drawn off screen at the minimum size (sample data, no network, nothing stored); --shot-live: the real data once
        if let i = args.firstIndex(where: { $0 == "--shot" || $0 == "--shot-live" }), i + 1 < args.count {
            if args[i] == "--shot-live" { model.data = (collect().flatMap { try? JSONSerialization.jsonObject(with: $0) as? J }) ?? [:] }
            else { model.data = try! JSONSerialization.jsonObject(with: Data(sampleJSON.utf8)) as! J }
            model.stamp = (model.data["time"] as? String) ?? "?"
            window.setFrame(NSRect(x: -4000, y: -4000, width: 620, height: 900), display: false)
            host.frame = NSRect(x: 0, y: 0, width: 620, height: 900); host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        if !args.contains("--login") { show() }
        model.start()
    }
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
