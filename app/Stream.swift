// Stream.swift (v29, 17.11.2026): every background worker is watched live, in a window, at zero credits.
// Marko: "Make a mechanism that every few minutes, it report it's alive, and it says what it is doing ... Or maybe the
// stream of code can be shown from the beginning for no credits at all ... It's not hidden in the background. I want to
// see a stream. But, of course, in the window."
// Everything is read locally from the worker's transcript (JSONL, /private/tmp/claude-*/.../tasks/<id>.output): incremental
// offset, one JSON event per line, a malformed line is skipped, secrets are masked before anything is drawn.
import SwiftUI
import AppKit

// ---------------------------------------------------------------- masking
enum Mask {
    static let re: NSRegularExpression? = try? NSRegularExpression(pattern:
        #"(sk-ant-[A-Za-z0-9_\-]{8,}|sk-[A-Za-z0-9_\-]{20,}|gsk_[A-Za-z0-9]{8,}|ghp_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{12,}|AIza[0-9A-Za-z_\-]{12,}|xox[bap]-[A-Za-z0-9\-]{8,}|AC[0-9a-f]{32}|[A-Fa-f0-9]{48,}|(?=[A-Za-z_+\-]*\d)(?=[0-9_+\-]*[A-Za-z])[A-Za-z0-9+_\-]{40,}={0,2})"#)
    static func clean(_ s: String) -> String {
        guard let re = re else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "[hidden]")
    }
}

// ---------------------------------------------------------------- blocks
struct StreamBlock: Identifiable {
    var id: Int = 0
    let kind: String        // prompt | text | tool | result
    let title: String
    let lines: [String]
    let old: [String]
    let new: [String]
    let total: Int          // real line count before the cap
    let action: String      // plain-words current action for the heartbeat
    var isDiff: Bool { !old.isEmpty || !new.isEmpty }
}

enum StreamParse {
    static func cut(_ s: String, _ n: Int = 300) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
    static func lines(_ s: String, cap: Int) -> ([String], Int) {
        let all = Mask.clean(s).split(separator: "\n", omittingEmptySubsequences: false).map { cut(String($0)) }
        return (Array(all.prefix(cap)), all.count)
    }
    static func shortPath(_ p: String?) -> String { ((p ?? "?") as NSString).lastPathComponent }
    static func lastSentence(_ t: String) -> String {
        let flat = t.split(whereSeparator: { $0 == "\n" || $0 == " " }).joined(separator: " ")
        var parts: [String] = []; var cur = ""
        for ch in flat { cur.append(ch); if ".!?".contains(ch) { parts.append(cur); cur = "" } }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur) }
        return cut((parts.last ?? flat).trimmingCharacters(in: .whitespaces), 140)
    }
    static func words(_ name: String, _ inp: J) -> String {
        switch name {
        case "Edit", "MultiEdit", "NotebookEdit": return "editing " + shortPath((inp["file_path"] ?? inp["notebook_path"]) as? String)
        case "Write": return "writing " + shortPath(inp["file_path"] as? String)
        case "Read": return "reading " + shortPath(inp["file_path"] as? String)
        case "Bash":
            let c = ((inp["command"] as? String) ?? "").split(whereSeparator: { $0 == "\n" || $0 == " " }).joined(separator: " ")
            return Mask.clean("running: " + cut(c, 90))
        case "Grep", "Glob": return "searching: " + cut((inp["pattern"] as? String) ?? "", 60)
        case "SubagentHandback": return "handing in its report"
        default: return "using " + name
        }
    }

    static func resultText(_ c: Any?) -> String {
        if let s = c as? String { return s }
        if let a = c as? [J] { return a.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n") }
        return ""
    }

    /// blocks of one transcript event; `done` is set when the event ends the worker's work
    static func blocks(_ e: J, done: inout Bool) -> [StreamBlock] {
        let type = e["type"] as? String ?? ""
        guard let msg = e["message"] as? J else { return [] }
        var out: [StreamBlock] = []
        if type == "user" {
            if let s = msg["content"] as? String {
                if !s.hasPrefix("<system-reminder>") { let (l, n) = lines(s, cap: 14); out.append(StreamBlock(kind: "prompt", title: "PROMPT", lines: l, old: [], new: [], total: n, action: "")) }
            } else if let arr = msg["content"] as? [J] {
                for it in arr {
                    let t = it["type"] as? String ?? ""
                    if t == "tool_result" {
                        let (l, n) = lines(resultText(it["content"]), cap: 400)
                        let bad = (it["is_error"] as? Bool) ?? false
                        out.append(StreamBlock(kind: "result", title: bad ? "ERROR" : "RESULT", lines: l, old: [], new: [], total: n, action: ""))
                    } else if t == "text", let s = it["text"] as? String, !s.hasPrefix("<system-reminder>") {
                        let (l, n) = lines(s, cap: 14); out.append(StreamBlock(kind: "prompt", title: "PROMPT", lines: l, old: [], new: [], total: n, action: ""))
                    }
                }
            }
        } else if type == "assistant", let arr = msg["content"] as? [J] {
            var hadTool = false
            for it in arr {
                let t = it["type"] as? String ?? ""
                if t == "text", let s = it["text"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let (l, n) = lines(s, cap: 60)
                    out.append(StreamBlock(kind: "text", title: "", lines: l, old: [], new: [], total: n, action: lastSentence(Mask.clean(s))))
                } else if t == "tool_use" {
                    hadTool = true
                    let name = it["name"] as? String ?? "?"
                    let inp = (it["input"] as? J) ?? [:]
                    let act = words(name, inp)
                    done = (name == "SubagentHandback")
                    switch name {
                    case "Bash":
                        let (l, n) = lines((inp["command"] as? String) ?? "", cap: 30)
                        out.append(StreamBlock(kind: "tool", title: "Bash", lines: l, old: [], new: [], total: n, action: act))
                    case "Edit":
                        let (o, on) = lines((inp["old_string"] as? String) ?? "", cap: 20), (nw, nn) = lines((inp["new_string"] as? String) ?? "", cap: 20)
                        out.append(StreamBlock(kind: "tool", title: "Edit  " + shortPath(inp["file_path"] as? String), lines: [], old: o, new: nw, total: max(on, nn), action: act))
                    case "MultiEdit":
                        var o: [String] = [], nw: [String] = []
                        for ed in ((inp["edits"] as? [J]) ?? []).prefix(6) {
                            o += lines((ed["old_string"] as? String) ?? "", cap: 8).0; nw += lines((ed["new_string"] as? String) ?? "", cap: 8).0
                        }
                        out.append(StreamBlock(kind: "tool", title: "MultiEdit  " + shortPath(inp["file_path"] as? String), lines: [], old: o, new: nw, total: max(o.count, nw.count), action: act))
                    case "Write":
                        let (l, n) = lines((inp["content"] as? String) ?? "", cap: 40)
                        out.append(StreamBlock(kind: "tool", title: "Write  " + shortPath(inp["file_path"] as? String), lines: l, old: [], new: [], total: n, action: act))
                    case "Read":
                        out.append(StreamBlock(kind: "tool", title: "Read  " + Mask.clean((inp["file_path"] as? String) ?? "?"), lines: [], old: [], new: [], total: 0, action: act))
                    default:
                        var s = ""
                        if let d = try? JSONSerialization.data(withJSONObject: inp), let x = String(data: d, encoding: .utf8) { s = x }
                        let (l, n) = lines(cut(s, 300), cap: 3)
                        out.append(StreamBlock(kind: "tool", title: name, lines: l, old: [], new: [], total: n, action: act))
                    }
                }
            }
            if !hadTool, !out.isEmpty { done = (msg["stop_reason"] as? String) == "end_turn" }
        }
        return out
    }
}

// ---------------------------------------------------------------- the store: tail the file, incremental
struct ChunkResult { var blocks: [StreamBlock] = []; var newOffset: UInt64 = 0; var reset = false; var more = false; var last: Date? = nil; var done: Bool? = nil }

final class StreamStore: ObservableObject {
    let path: String
    @Published var blocks: [StreamBlock] = []
    @Published var lastEventAt: Date? = nil
    @Published var finished = false
    @Published var currentAction = ""
    @Published var loading = true
    private var offset: UInt64 = 0
    private var nextId = 0
    private var reading = false
    private var timer: Timer?
    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static let maxBlocks = 4000

    init(path: String) { self.path = path }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func poll() {
        if reading { return }
        reading = true
        let from = offset
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let r = StreamStore.readChunk(path: self.path, from: from)
            DispatchQueue.main.async { self.apply(r) }
        }
    }

    /// synchronous load of the whole file (screenshots)
    func loadAllSync() {
        for _ in 0..<400 { let r = StreamStore.readChunk(path: path, from: offset); apply(r); if !r.more { break } }
    }

    private func apply(_ r: ChunkResult) {
        reading = false
        if r.reset { blocks = []; nextId = 0 }
        offset = r.newOffset
        if !r.blocks.isEmpty {
            var add = r.blocks
            for i in add.indices { add[i].id = nextId; nextId += 1 }
            blocks.append(contentsOf: add)
            if blocks.count > StreamStore.maxBlocks { blocks.removeFirst(blocks.count - StreamStore.maxBlocks) }
            if let a = r.blocks.last(where: { !$0.action.isEmpty })?.action { currentAction = a }
        }
        if let l = r.last { lastEventAt = l }
        if let d = r.done { finished = d }
        if r.more { poll() } else { loading = false }
    }

    static func readChunk(path: String, from: UInt64) -> ChunkResult {
        var res = ChunkResult(newOffset: from)
        guard let fh = FileHandle(forReadingAtPath: path) else { return res }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return res }
        var start = from
        if size < from { start = 0; res.reset = true; res.newOffset = 0 }
        if size == start { return res }
        var want = 4_000_000
        var data = Data()
        while true {
            try? fh.seek(toOffset: start)
            data = (try? fh.read(upToCount: want)) ?? Data()
            let atEnd = start + UInt64(data.count) >= size
            if data.contains(10) || atEnd || want >= 128_000_000 { break }
            want *= 2
        }
        guard let lastNL = data.lastIndex(of: 10) else {
            if start + UInt64(data.count) < size { res.newOffset = start + UInt64(data.count) }   // an absurd line: skipped
            return res
        }
        let body = data[data.startIndex..<lastNL]
        res.newOffset = start + UInt64(body.count) + 1
        res.more = res.newOffset < size
        var done = false, seen = false
        for line in body.split(separator: 10, omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? J else { continue }   // malformed: skipped
            let t = obj["type"] as? String ?? ""
            if t != "user" && t != "assistant" { continue }
            if let ts = obj["timestamp"] as? String, let d = iso.date(from: ts) { res.last = d }
            let b = StreamParse.blocks(obj, done: &done)
            if !b.isEmpty { res.blocks += b; if t == "assistant" { seen = true } }
        }
        if seen { res.done = done }
        return res
    }
}

// ---------------------------------------------------------------- heartbeat words and colours (one place, rows and stream header)
func ageWords(_ s: Int) -> String { s < 90 ? "\(s) s" : (s < 5400 ? "\(s / 60) min" : "\(s / 3600) h") }
func heartbeatLine(state: String, age: Int) -> (String, Color) {
    if state == "done" { return ("finished " + ageWords(age) + " ago", Ink.grey) }
    if state == "stale" || age >= 600 { return ("no sign of life for " + ageWords(age), Ink.red) }
    if age >= 180 { return ("quiet for " + ageWords(age) + ", maybe stalled", Ink.orange) }
    return ("alive, last action " + ageWords(age) + " ago", Ink.green)
}

// ---------------------------------------------------------------- workers list (one module: advanced column and simple view)
struct WorkerRow: Identifiable {
    let id: String; let desc: String; let model: String; let session: String
    let state: String       // running | stale | done
    let age: Int; let action: String; let path: String
}

func workerRows(_ d: J, dismissed: Set<String>) -> [WorkerRow] {
    var out: [WorkerRow] = []
    for s in ((d["mac"] as? J)?["sessions"] as? [J]) ?? [] {
        for t in (s["tasks"] as? [J]) ?? [] where (t["kind"] as? String) == "agent" {
            let id = t["id"] as? String ?? ""
            if id.isEmpty || dismissed.contains(id) { continue }
            let age = (t["last_event_age_s"] as? Int) ?? (t["age"] as? Int) ?? 0
            let running = (t["running"] as? Bool) ?? false
            let isDone = (t["state"] as? String) == "done"
            let state = running ? "running" : (isDone ? "done" : "stale")
            if state == "done" && age > 6 * 3600 { continue }
            if state == "stale" && age > 6 * 3600 { continue }
            out.append(WorkerRow(id: id, desc: (t["desc"] as? String) ?? "worker", model: (t["model"] as? String) ?? "", session: (s["base"] as? String) ?? (s["name"] as? String) ?? "",
                                 state: state, age: age, action: (t["current_action"] as? String) ?? "", path: (t["transcript"] as? String) ?? ""))
        }
    }
    let rank = ["running": 0, "stale": 1, "done": 2]
    return out.sorted { (rank[$0.state] ?? 3, $0.age) < (rank[$1.state] ?? 3, $1.age) }
}

struct WorkersBlock: View {
    let data: J
    @AppStorage("dismissedWorkers") private var dismissedRaw = ""
    var body: some View {
        let dismissed = Set(dismissedRaw.split(separator: ",").map(String.init))
        let rows = workerRows(data, dismissed: dismissed)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("WORKERS").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Ink.green).accessibilityIdentifier("workers-title")
                ForEach(rows) { r in
                    let hb = heartbeatLine(state: r.state, age: r.age)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(hb.1).frame(width: 7, height: 7)
                            Text("WORKER").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Ink.dim)
                            Spacer(minLength: 0)
                            if !r.model.isEmpty { Text(r.model).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Ink.orange) }
                            if r.state != "running" {
                                Text("✕").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Ink.dim).padding(.horizontal, 5)
                                    .contentShape(Rectangle()).onTapGesture { dismiss(r.id) }
                                    .axButton("Dismiss worker " + r.desc, id: "worker-dismiss-" + r.id) { dismiss(r.id) }
                            }
                        }
                        Text(r.desc).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
                        Text(hb.0).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(hb.1).fixedSize(horizontal: false, vertical: true)
                        if !r.action.isEmpty { Text(r.action).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Ink.dim).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
                        Text("open the stream").font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.grey)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(hb.1.opacity(0.5), lineWidth: 1))
                    .contentShape(Rectangle()).onTapGesture { StreamWindows.show(id: r.id, title: r.desc, path: r.path) }
                    .axButton("Worker stream " + r.desc, id: "worker-" + r.id) { StreamWindows.show(id: r.id, title: r.desc, path: r.path) }
                }
            }
        }
    }
    func dismiss(_ id: String) {
        var s = Set(dismissedRaw.split(separator: ",").map(String.init)); s.insert(id)
        dismissedRaw = Array(s.suffix(300)).joined(separator: ",")
    }
}

// ---------------------------------------------------------------- the stream window
struct BottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct BlockView: View {
    let b: StreamBlock
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch b.kind {
            case "prompt":
                lab(b.title, Ink.amber)
                txt(b.lines.joined(separator: "\n"), Ink.text)
            case "text":
                txt(b.lines.joined(separator: "\n"), Ink.text)
            case "tool":
                lab("▸ " + b.title, Ink.green)
                if b.isDiff {
                    if !b.old.isEmpty { diff(b.old, "- ", Ink.red) }
                    if !b.new.isEmpty { diff(b.new, "+ ", Ink.green) }
                } else if !b.lines.isEmpty {
                    txt(b.lines.joined(separator: "\n") + (b.total > b.lines.count ? "\n… \(b.total - b.lines.count) more lines" : ""), Ink.dim)
                }
            default:
                let shown = open ? b.lines : Array(b.lines.prefix(6))
                lab(b.title, b.title == "ERROR" ? Ink.red : Ink.grey)
                txt(shown.joined(separator: "\n"), Ink.grey)
                if b.total > 6 {
                    Text(open ? "show less" : "+\(b.total - 6) more lines").font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(Ink.amber)
                        .padding(.horizontal, 4).contentShape(Rectangle()).onTapGesture { open.toggle() }
                        .axButton("Expand result", id: "result-" + String(b.id)) { open.toggle() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    func lab(_ s: String, _ c: Color) -> some View { Text(s).font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(c) }
    func txt(_ s: String, _ c: Color) -> some View { Text(s).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(c).fixedSize(horizontal: false, vertical: true) }
    func diff(_ l: [String], _ p: String, _ c: Color) -> some View {
        Text(l.map { p + $0 }.joined(separator: "\n")).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(c)
            .fixedSize(horizontal: false, vertical: true).padding(4).frame(maxWidth: .infinity, alignment: .leading).background(c.opacity(0.10))
    }
}

struct StreamView: View {
    @ObservedObject var store: StreamStore
    let title: String
    let windowId: String
    @State private var follow = true
    @State private var monitor: Any? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Ink.text).lineLimit(2)
                    Spacer()
                    if !follow {
                        Text("FOLLOW ↓").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Ink.ground)
                            .padding(.horizontal, 10).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 5).fill(Ink.amber))
                            .contentShape(Rectangle()).onTapGesture { follow = true; ping += 1 }
                            .axButton("Follow", id: "stream-follow") { follow = true; ping += 1 }
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let age = Int(max(0, ctx.date.timeIntervalSince(store.lastEventAt ?? ctx.date)))
                    let hb = heartbeatLine(state: store.finished ? "done" : "running", age: age)
                    HStack(spacing: 6) {
                        Circle().fill(hb.1).frame(width: 8, height: 8)
                        Text(store.loading && store.lastEventAt == nil ? "reading…" : hb.0).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(hb.1)
                        Text("· " + store.currentAction).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Ink.dim).lineLimit(1).truncationMode(.tail)
                    }.accessibilityIdentifier("stream-heartbeat")
                }
            }.padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 8)
            Rectangle().fill(Ink.line).frame(height: 1)
            GeometryReader { vp in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(store.blocks) { b in BlockView(b: b) }
                            Color.clear.frame(height: 1).id("bottom")
                                .background(GeometryReader { g in Color.clear.preference(key: BottomKey.self, value: g.frame(in: .named("streamscroll")).maxY) })
                        }.padding(16)
                    }
                    .coordinateSpace(name: "streamscroll")
                    .onPreferenceChange(BottomKey.self) { y in if y <= vp.size.height + 6 { follow = true } }
                    .onChange(of: store.blocks.count) { _, _ in if follow { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } } }
                    .onChange(of: ping) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
        }
        .background(Ink.ground)
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                if e.window?.identifier?.rawValue == windowId, e.scrollingDeltaY > 0 { follow = false }   // he scrolled up: stay where he is
                return e
            }
        }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }
    }
    @State private var ping = 0
}

enum StreamWindows {
    static var windows: [String: NSWindow] = [:]
    static var stores: [String: StreamStore] = [:]

    static func show(id: String, title: String, path: String) {
        guard !path.isEmpty else { return }
        if let w = windows[id] { w.makeKeyAndOrderFront(nil); return }
        let store = StreamStore(path: path)
        let wid = "stream-" + id
        let host = NSHostingView(rootView: StreamView(store: store, title: title, windowId: wid))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = ""; w.identifier = NSUserInterfaceItemIdentifier(wid); w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.titlebarSeparatorStyle = .none
        w.contentView = host; w.minSize = NSSize(width: 420, height: 300); w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("AgentManagerStreamWindow"); w.backgroundColor = NSColor(Ink.ground)
        windows[id] = w; stores[id] = store
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            stores[id]?.stop(); stores[id] = nil; windows[id] = nil
        }
        store.start()
        w.makeKeyAndOrderFront(nil)
    }
}
