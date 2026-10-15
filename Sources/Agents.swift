import SwiftUI

/// Which agentic tool a session runs in.
enum Harness: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case antigravity = "Antigravity"

    var id: String { rawValue }
    var tag: String { self == .claude ? "claude" : "agy" }
    var color: Color { self == .claude ? .orange : .cyan }
}

/// A live agent session: a Claude Code session read from ~/.claude/sessions/<pid>.json,
/// or an Antigravity conversation (see AntigravitySessions).
struct Agent: Identifiable, Decodable {
    var harness: Harness = .claude
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String?
    let status: String?       // busy, idle, waiting
    let startedAt: Double     // ms since epoch
    let statusUpdatedAt: Double?

    private enum CodingKeys: String, CodingKey { case pid, sessionId, cwd, name, status, startedAt, statusUpdatedAt }

    /// Per session, not per pid: one agy process can host several conversations.
    var id: String { "\(harness.tag)-\(sessionId)" }
    var started: Date { Date(timeIntervalSince1970: startedAt / 1000) }
    var statusSince: Date { Date(timeIntervalSince1970: (statusUpdatedAt ?? startedAt) / 1000) }

    private static let busy = ["[o_o]   ", "[o_o].  ", "[o_o].. ", "[o_o]...", "[-_o]...", "[o_o]..."]
    private static let waiting = ["[O_O] ? ", "[O_O]   "]
    private static let idle = ["[-_-] z ", "[-_-] zZ", "[-_-] zZ"]

    /// ASCII face for a status at a given animation frame. Idle/waiting animate slower than busy.
    static func face(_ status: String?, frame: Int) -> String {
        switch status {
        case "busy":    return busy[frame % busy.count]
        case "waiting": return waiting[frame / 3 % waiting.count]
        default:        return idle[frame / 3 % idle.count]
        }
    }

    /// Brings the session forward: its iTerm tab if it runs in iTerm, else its folder in VS Code.
    func reveal() {
        let pid = pid, cwd = cwd
        DispatchQueue.global().async {
            let tty = shell("/bin/ps", ["-o", "tty=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Only talk to iTerm if it's running; `tell application` would otherwise launch it.
            if !tty.isEmpty, !NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").isEmpty {
                let script = """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "/dev/\(tty)" then
                                    select w
                                    select t
                                    select s
                                    activate
                                    return "found"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """
                if shell("/usr/bin/osascript", ["-e", script]).contains("found") { return }
            }
            _ = shell("/usr/bin/open", ["-a", "Visual Studio Code", cwd])
        }
    }
}

/// Runs a command and returns its stdout ("" on failure). Blocking: call off the main thread.
func shell(_ path: String, _ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// A subagent spawned by a session, from <session>/subagents/agent-<id>.meta.json + .jsonl.
struct SubAgent: Identifiable {
    let id: String            // agentId
    let description: String
    let type: String
    let started: Date
    let lastActive: Date
    let finished: Bool
    let tokens: (input: Int, output: Int)
}

/// Polls Claude Code's session files and sums token usage from each session's transcripts.
///
/// ponytail: undocumented Claude Code file layout; if it changes upstream this tab just goes empty.
@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()

    @Published private(set) var agents: [Agent] = []
    @Published private(set) var tokens: [String: (input: Int, output: Int)] = [:]  // sessionId -> usage incl. subagents
    @Published private(set) var subagents: [String: [SubAgent]] = [:]              // sessionId -> visible subagents
    @Published private(set) var fire = Fire()

    var busyCount: Int { agents.filter { $0.status == "busy" }.count }

    private let claude = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private let antigravity = AntigravitySessions()

    /// What we've pulled out of one transcript so far.
    private struct Parsed {
        var offset: UInt64 = 0
        var usage: [String: (Int, Int)] = [:]  // by requestId (lines repeat per content block)
        var finished: Set<String> = []        // subagent ids / tool-use ids this transcript saw complete
        var total: (input: Int, output: Int) { usage.values.reduce((0, 0)) { ($0.0 + $1.0, $0.1 + $1.1) } }
    }
    private var parsed: [URL: Parsed] = [:]

    private init() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AgentStore.shared.refresh() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
            Task { @MainActor in
                let store = AgentStore.shared
                // Busy: burn. Idle: reset, so the next fire ignites from scratch in a new random colour.
                if store.busyCount > 0 { store.fire.step() } else if store.fire.steps > 0 { store.fire = Fire() }
            }
        }
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: claude.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)) ?? []
        let claudeAgents = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Agent.self, from: Data(contentsOf: $0)) }
            .filter { kill($0.pid, 0) == 0 }  // drop sessions whose process has exited
        for agent in claudeAgents {
            // Project dir = cwd with non-alphanumerics → "-".
            let slug = String(agent.cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            let project = claude.appendingPathComponent("projects").appendingPathComponent(slug)
            let main = parse(project.appendingPathComponent(agent.sessionId + ".jsonl"))
            let subs = subagents(in: project.appendingPathComponent(agent.sessionId), finished: main.finished)
            tokens[agent.sessionId] = subs.reduce(main.total) { ($0.0 + $1.tokens.input, $0.1 + $1.tokens.output) }
            subagents[agent.sessionId] = subs
                .filter { !$0.finished || $0.lastActive.timeIntervalSinceNow > -300 }  // running + done in last 5 min
                .sorted { $0.started < $1.started }
        }
        let agyAgents = antigravity.refresh()
        for (agent, usage) in agyAgents { tokens[agent.sessionId] = usage }
        agents = (claudeAgents + agyAgents.map(\.agent)).sorted { $0.startedAt > $1.startedAt }
    }

    /// Every subagent of a session. Done = the parent transcript has its task-notification or final tool result.
    private func subagents(in sessionDir: URL, finished: Set<String>) -> [SubAgent] {
        struct Meta: Decodable { let agentType: String?; let description: String?; let toolUseId: String?; let stoppedByUser: Bool? }
        let dir = sessionDir.appendingPathComponent("subagents")
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.map { url in
            let name = url.deletingPathExtension().lastPathComponent          // agent-<id>
            let id = String(name.dropFirst("agent-".count))
            let meta = (try? Data(contentsOf: dir.appendingPathComponent(name + ".meta.json")))
                .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            let dates = try? url.resourceValues(forKeys: Set(keys))
            let lastActive = dates?.contentModificationDate ?? .distantPast
            // ponytail: also treat 30 min of silence as done, so a crashed subagent doesn't spin forever.
            let done = finished.contains(id) || finished.contains(meta?.toolUseId ?? "-")
                || meta?.stoppedByUser == true || lastActive.timeIntervalSinceNow < -1800
            return SubAgent(id: id, description: meta?.description ?? id, type: meta?.agentType ?? "agent",
                            started: dates?.creationDate ?? lastActive, lastActive: lastActive,
                            finished: done, tokens: parse(url).total)
        }
    }

    /// Reads only the bytes appended to a transcript since the last call.
    private func parse(_ url: URL) -> Parsed {
        var entry = parsed[url] ?? Parsed()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return entry }
        defer { try? handle.close() }
        try? handle.seek(toOffset: entry.offset)
        let data = (try? handle.readToEnd()) ?? Data()
        // Only consume complete lines; a half-written last line is picked up next poll.
        if let end = data.lastIndex(of: UInt8(ascii: "\n")) {
            for line in data[..<end].split(separator: UInt8(ascii: "\n")) {
                read(line, into: &entry)
            }
            entry.offset += UInt64(end - data.startIndex + 1)
        }
        parsed[url] = entry
        return entry
    }

    private func read(_ line: Data.SubSequence, into entry: inout Parsed) {
        let text = String(decoding: line, as: UTF8.self)
        // Background subagent finished: "<task-notification><task-id>ID</task-id>…".
        for chunk in text.components(separatedBy: "<task-id>").dropFirst() {
            if let id = chunk.components(separatedBy: "<").first { entry.finished.insert(id) }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = obj["message"] as? [String: Any] else { return }
        // Foreground subagent finished: its Agent tool call got a real result (not the async "launched" stub).
        for item in message["content"] as? [[String: Any]] ?? [] where item["type"] as? String == "tool_result" {
            if let id = item["tool_use_id"] as? String,
               !String(describing: item["content"] ?? "").contains("Async agent launched") {
                entry.finished.insert(id)
            }
        }
        guard let u = message["usage"] as? [String: Any] else { return }
        let key = obj["requestId"] as? String ?? message["id"] as? String ?? UUID().uuidString
        let int = { (k: String) in u[k] as? Int ?? 0 }
        entry.usage[key] = (
            int("input_tokens") + int("cache_creation_input_tokens") + int("cache_read_input_tokens"),
            int("output_tokens"))
    }
}

struct AgentsView: View {
    @ObservedObject private var store = AgentStore.shared
    @State private var filter: Harness?  // nil = all
    @Namespace private var pill

    private var shown: [Agent] { store.agents.filter { filter == nil || $0.harness == filter } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            filters
            if let harness = filter {
                HStack(alignment: .top, spacing: 8) {
                    harnessRunningList(shown, harness: harness)
                    HarnessLimitsCard(harness: harness)
                        .frame(width: 250)
                }
                .frame(maxHeight: .infinity)
            } else {
                fullRunningList
                    .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            AgentUsageTracker.shared.refresh()
        }
    }

    /// Single-harness running sessions list.
    private func harnessRunningList(_ agents: [Agent], harness: Harness) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Running")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(agents.count)")
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.12), in: Capsule())
            }

            if agents.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                    Text("No \(harness.rawValue) sessions")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 0.3)) { context in
                        let frame = Int(context.date.timeIntervalSinceReferenceDate / 0.3)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(agents) { agent in
                                AgentRow(agent: agent, tokens: store.tokens[agent.sessionId], frame: frame)
                                ForEach(store.subagents[agent.sessionId] ?? []) { sub in
                                    SubAgentRow(sub: sub, frame: frame)
                                        .contentShape(Rectangle())
                                        .onTapGesture { agent.reveal() }
                                }
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }

    /// Full-width list for the "All" tab.
    @ViewBuilder
    private var fullRunningList: some View {
        if store.agents.isEmpty {
            Text("No agent sessions running")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                TimelineView(.periodic(from: .now, by: 0.3)) { context in
                    let frame = Int(context.date.timeIntervalSinceReferenceDate / 0.3)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.agents) { agent in
                            AgentRow(agent: agent, tokens: store.tokens[agent.sessionId], frame: frame)
                            ForEach(store.subagents[agent.sessionId] ?? []) { sub in
                                SubAgentRow(sub: sub, frame: frame)
                                    .contentShape(Rectangle())
                                    .onTapGesture { agent.reveal() }
                            }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    /// All / Claude / Antigravity, each with its session count (and busy count while any are working).
    private var filters: some View {
        HStack(spacing: 4) {
            filterButton(nil, "All", store.agents)
            ForEach(Harness.allCases) { h in
                filterButton(h, h.rawValue, store.agents.filter { $0.harness == h })
            }
            Spacer()
        }
        .font(.caption)
    }

    private func filterButton(_ harness: Harness?, _ label: String, _ agents: [Agent]) -> some View {
        let busy = agents.filter { $0.status == "busy" }.count
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { filter = harness }
        } label: {
            HStack(spacing: 4) {
                if let harness { Circle().fill(harness.color).frame(width: 6, height: 6) }
                Text(label)
                Text(busy > 0 ? "\(busy)/\(agents.count)" : "\(agents.count)")
                    .monospacedDigit()
                    .foregroundStyle(busy > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                if filter == harness {
                    Capsule().fill(.white.opacity(0.16)).matchedGeometryEffect(id: "agentFilter", in: pill)
                }
            }
            .foregroundStyle(filter == harness ? .primary : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(busy > 0 ? "\(busy) working of \(agents.count)" : "\(agents.count) running")
    }
}

private struct AgentRow: View {
    let agent: Agent
    let tokens: (input: Int, output: Int)?
    let frame: Int

    private var face: String { Agent.face(agent.status, frame: frame) }

    private var color: Color {
        switch agent.status {
        case "busy":    return .orange
        case "waiting": return .yellow
        default:        return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(face).foregroundStyle(color)
                Text(agent.harness.tag)
                    .font(.system(.caption2, design: .monospaced).bold())
                    .foregroundStyle(agent.harness.color)
                    .padding(.horizontal, 4)
                    .background(agent.harness.color.opacity(0.15), in: Capsule())
                    .help(agent.harness.rawValue)
                Text(agent.name ?? (agent.cwd as NSString).lastPathComponent).lineLimit(1)
                Spacer()
                Text(agent.status ?? "?").foregroundStyle(color)
                Text(agent.statusSince, style: .timer).monospacedDigit()
            }
            HStack {
                Text((agent.cwd as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("up \(Text(agent.started, style: .timer))")
                if let tokens {
                    Text(tokenLabel(tokens)).help("Input (incl. cache) / output tokens, including subagents")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .font(.system(.body, design: .monospaced))
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onTapGesture { agent.reveal() }
        .help("Click to jump to this session")
    }
}

/// One subagent, indented under its session.
private struct SubAgentRow: View {
    let sub: SubAgent
    let frame: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("└").foregroundStyle(.tertiary)
            Text(sub.finished ? "[^_^] ✓" : Agent.face("busy", frame: frame))
                .foregroundStyle(sub.finished ? .green : .orange)
            Text(sub.description).lineLimit(1).truncationMode(.tail)
                .help("\(sub.type): \(sub.description)")
            Spacer()
            if sub.finished {
                Text(Duration.seconds(sub.lastActive.timeIntervalSince(sub.started))
                    .formatted(.time(pattern: .minuteSecond)))
            } else {
                Text(sub.started, style: .timer).monospacedDigit()
            }
            Text(tokenLabel(sub.tokens))
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(sub.finished ? .secondary : .primary)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.bottom, 4)
    }
}

private func tokenLabel(_ t: (input: Int, output: Int)) -> String {
    let compact = { (n: Int) in n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    return "↑\(compact(t.input)) ↓\(compact(t.output))"
}

/// Doom-style fire: the bottom row is max heat; every step each cell's heat rises one row,
/// cooling by a random amount and blowing sideways, so flames flicker.
struct Fire {
    /// The bottom row is the always-hot source and isn't drawn.
    static let cols = 28, rows = 12, maxHeat = 12
    /// New random colour every ~10s of burning (steps tick every 0.07s).
    private static let recolorSteps = 143
    /// Row-major, row 0 = top.
    private(set) var heat = [Int](repeating: 0, count: cols * rows)
    private(set) var steps = 0
    /// Heat 0 = no fire (transparent); 1...7 = palette.
    private var palette = Fire.randomPalette()

    /// Fire-like ramp around a random hue: dark and saturated when cool, shifting hue and fading
    /// to near white when hot, the way Doom's runs red → yellow → white.
    static func randomPalette() -> [NSColor] {
        let hue = CGFloat.random(in: 0..<1)
        return (0..<7).map { i in
            let t = CGFloat(i) / 6
            return NSColor(hue: (hue + 0.12 * t).truncatingRemainder(dividingBy: 1),
                           saturation: 1 - 0.75 * t * t * t,
                           brightness: 0.35 + 0.6 * t, alpha: 1)
        }
    }

    /// The flame's mid colour, for tinting the notch glow.
    var accent: NSColor { palette[4] }

    func color(row: Int, col: Int) -> NSColor? {
        let h = heat[row * Self.cols + col]
        return h == 0 ? nil : palette[(h - 1) * palette.count / Self.maxHeat]
    }

    mutating func step() {
        steps += 1
        if steps % Self.recolorSteps == 0 { palette = Self.randomPalette() }
        let cols = Self.cols, rows = Self.rows
        for c in 0..<cols { heat[(rows - 1) * cols + c] = Self.maxHeat }
        for r in 0..<(rows - 1) {
            for c in 0..<cols {
                // Doom's trick: one random number sets both the cooling and the sideways drift (wind).
                // ponytail: cooling averages 1.5/row, so flames reach ~8 of 11 rows; tune maxHeat for taller/shorter flames.
                let rand = Int.random(in: 0...3)
                let to = (c - rand + 1 + cols) % cols
                heat[r * cols + to] = max(heat[(r + 1) * cols + c] - rand, 0)
            }
        }
    }
}

extension Fire {
    private static let pixel: CGFloat = 1.5

    /// The fire as an image of tiny squares, for the notch's live activity.
    func image() -> NSImage {
        let rows = Fire.rows - 1  // skip the source row
        let size = NSSize(width: CGFloat(Fire.cols) * Self.pixel, height: CGFloat(rows) * Self.pixel)
        // Drawn lazily at the screen's scale, so it stays crisp on Retina.
        return NSImage(size: size, flipped: true) { _ in
            for r in 0..<rows {
                for c in 0..<Fire.cols {
                    guard let color = color(row: r, col: c) else { continue }
                    color.setFill()
                    NSRect(x: CGFloat(c) * Self.pixel, y: CGFloat(r) * Self.pixel, width: Self.pixel, height: Self.pixel).fill()
                }
            }
            return true
        }
    }
}
