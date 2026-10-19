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
                let alwaysOn = UserDefaults.standard.bool(forKey: Pref.agentAnimationAlwaysOn)
                // Busy (or preview enabled): animate. Idle: reset, so the next run ignites from scratch.
                if store.busyCount > 0 || alwaysOn {
                    store.fire.step()
                } else if store.fire.steps > 0 {
                    store.fire = Fire()
                }
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
            int("input_tokens") + int("cache_creation_input_tokens") + int("cache_read_input_tokens") / 10,
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

/// Procedural pixel animations for the closed notch: Doom fire, Knight Rider laser scanner,
/// Tesla lightning arcs, liquid plasma wave, Matrix digital rain, rainbow rave, and warp starfield.
struct Fire {
    /// The bottom row is the always-hot source for Doom fire and isn't drawn.
    static let cols = 140, rows = 15, maxHeat = 14
    /// Drawn rows (`0..<drawRows`, where `0` is top and `drawRows - 1` is bottom).
    static let drawRows = rows - 1
    /// New random colour every ~10s of burning (steps tick every 0.07s).
    private static let recolorSteps = 143
    /// Row-major, row 0 = top.
    private(set) var heat = [Int](repeating: 0, count: cols * rows)
    private(set) var scannerTrail = [Double](repeating: 0, count: cols)
    private(set) var scannerHead: Double = Double(cols) / 2
    private(set) var lightningMain = [Int](repeating: 9, count: cols)
    private(set) var lightningFork = [Int](repeating: 10, count: cols)
    private(set) var steps = 0
    /// Heat 0 = no fire (transparent); 1...7 = palette.
    private var palette = Fire.randomPalette()

    private static let cycleStyles: [AgentAnimationStyle] = [
        .fire, .scanner, .lightning, .plasma, .matrix, .rave, .warp
    ]

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

    func resolvedStyle(_ style: AgentAnimationStyle) -> AgentAnimationStyle {
        guard style == .randomBullshit else { return style }
        return Self.cycleStyles[(steps / 115) % Self.cycleStyles.count]
    }

    /// The animation's mid colour, for tinting the notch glow.
    var accent: NSColor {
        let raw = UserDefaults.standard.string(forKey: Pref.agentAnimation) ?? AgentAnimationStyle.fire.rawValue
        let style = AgentAnimationStyle(rawValue: raw) ?? .fire
        return accent(for: style)
    }

    func accent(for style: AgentAnimationStyle) -> NSColor {
        switch resolvedStyle(style) {
        case .fire:
            return palette[4]
        case .scanner:
            let hue = CGFloat((Double(steps) * 0.004).truncatingRemainder(dividingBy: 1.0))
            return NSColor(hue: hue, saturation: 0.85, brightness: 1.0, alpha: 1)
        case .lightning:
            return NSColor(hue: 0.56, saturation: 0.80, brightness: 1.0, alpha: 1)
        case .plasma:
            let hue = CGFloat((0.75 + sin(Double(steps) * 0.05) * 0.22).truncatingRemainder(dividingBy: 1.0))
            return NSColor(hue: (hue + 1).truncatingRemainder(dividingBy: 1.0), saturation: 0.85, brightness: 0.98, alpha: 1)
        case .matrix:
            return NSColor(hue: 0.37, saturation: 0.90, brightness: 0.95, alpha: 1)
        case .rave:
            let hue = CGFloat((Double(steps) * 0.025).truncatingRemainder(dividingBy: 1.0))
            return NSColor(hue: hue, saturation: 0.90, brightness: 1.0, alpha: 1)
        case .warp:
            return NSColor(hue: 0.60, saturation: 0.75, brightness: 1.0, alpha: 1)
        case .randomBullshit:
            return palette[4]
        }
    }

    func color(row: Int, col: Int, style: AgentAnimationStyle) -> NSColor? {
        let dRows = Self.drawRows
        let edgeDist = min(col, Self.cols - 1 - col)
        let cornerMask = edgeDist < 4 ? Double(edgeDist + 1) / 5.0 : 1.0

        switch resolvedStyle(style) {
        case .fire:
            let h = heat[row * Self.cols + col]
            return h == 0 ? nil : palette[min(palette.count - 1, (h - 1) * palette.count / Self.maxHeat)]

        case .scanner:
            let trail = scannerTrail[col] * cornerMask
            guard trail > 0.04 else { return nil }
            let vNorm = Double(row + 1) / Double(dRows) // 0 at top -> 1 at bottom
            let verticalProfile = pow(vNorm, 1.35)
            let headDist = abs(Double(col) - scannerHead)
            let isCore = headDist < 3.2 && row >= dRows - 5
            let intensity = min(1.0, trail * (0.35 + 0.75 * verticalProfile) + (headDist < 4.5 ? (1.0 - headDist / 4.5) * 0.5 : 0))
            guard intensity > 0.08 else { return nil }
            let baseHue = (Double(steps) * 0.004 + (1.0 - trail) * 0.08).truncatingRemainder(dividingBy: 1.0)
            let sat = isCore ? 0.18 : max(0.25, 1.0 - intensity * 0.45)
            let bri = min(1.0, 0.25 + intensity * 0.85)
            return NSColor(hue: CGFloat(baseHue), saturation: CGFloat(sat), brightness: CGFloat(bri), alpha: CGFloat(min(1.0, intensity * 1.15)))

        case .lightning:
            guard cornerMask > 0.2 else { return nil }
            let mainY = lightningMain[col]
            let forkY = lightningFork[col]
            let dMain = abs(row - mainY)
            let dFork = abs(row - forkY)
            let surge = (steps % 14 == 0 || steps % 14 == 1) ? 1.25 : 1.0
            if dMain == 0 {
                return NSColor(hue: 0.54, saturation: 0.18, brightness: 1.0, alpha: 1.0)
            } else if dMain == 1 {
                return NSColor(hue: 0.57, saturation: 0.82, brightness: min(1.0, 0.92 * CGFloat(surge)), alpha: 0.92)
            } else if dFork == 0 && col % 2 == 0 {
                return NSColor(hue: 0.77, saturation: 0.75, brightness: 0.95, alpha: 0.85)
            } else if dMain == 2 || (dFork == 1 && col % 3 == 0) {
                return NSColor(hue: 0.62, saturation: 0.92, brightness: 0.65, alpha: 0.55)
            }
            // Occasional random high-voltage sparks
            let sparkHash = (col * 37 + row * 101 + steps * 29) % 197
            if sparkHash == 0 && row >= 3 {
                return NSColor(hue: 0.55, saturation: 0.3, brightness: 1.0, alpha: 0.9)
            }
            return nil

        case .plasma:
            let t = Double(steps) * 0.13
            let nx = Double(col) / Double(Self.cols) * 6.5
            let ny = Double(row) / Double(dRows) * 3.2
            let w1 = sin(nx + t)
            let w2 = sin(ny * 1.6 - t * 0.85 + sin(nx * 0.75 + t * 0.55))
            let w3 = sin((nx + ny) * 0.85 + t * 1.15)
            let v = (w1 + w2 + w3) / 3.0 // -1...1
            let norm = v * 0.5 + 0.5
            let vEnv = pow(Double(row + 1) / Double(dRows), 0.45) * cornerMask
            guard vEnv > 0.1 else { return nil }
            let hue = (0.52 + norm * 0.42 + Double(steps) * 0.003).truncatingRemainder(dividingBy: 1.0)
            let sat = 0.75 + 0.22 * sin(norm * .pi)
            let bri = (0.38 + 0.62 * norm) * vEnv
            return NSColor(hue: CGFloat(hue), saturation: CGFloat(sat), brightness: CGFloat(bri), alpha: CGFloat(min(1.0, vEnv * 1.1)))

        case .matrix:
            // Glitch slice flash every few frames
            let glitchActive = (steps % 9 < 2)
            let glitchColStart = (steps * 43) % (Self.cols - 24)
            let glitchRow = (steps * 7) % max(1, dRows - 3) + 2
            if glitchActive && ( row == glitchRow || row == glitchRow + 1 ) && col >= glitchColStart && col < glitchColStart + 24 {
                let isCyan = (steps + col) % 2 == 0
                return NSColor(hue: isCyan ? 0.52 : 0.86, saturation: 0.85, brightness: 1.0, alpha: 0.95)
            }

            let speed = 0.48 + Double((col * 73 + 19) % 9) * 0.075
            let phase = Double((col * 131 + 11) % 89)
            let cycle = Double(dRows + 7)
            let head = (Double(steps) * speed + phase).truncatingRemainder(dividingBy: cycle) - 1.0
            let dist = head - Double(row)
            guard dist >= 0 && dist < 7.5 else { return nil }
            if dist < 1.15 {
                return NSColor(hue: 0.36, saturation: 0.22, brightness: 1.0, alpha: CGFloat(cornerMask))
            }
            // Flickering digital glyph trail
            if (row + col + steps / 2) % 5 == 0 { return nil }
            let fade = max(0, 1.0 - dist / 7.5) * cornerMask
            let hue = 0.36 + (col % 4 == 0 ? 0.08 : 0.0)
            return NSColor(hue: CGFloat(hue), saturation: 0.92, brightness: CGFloat(0.28 + 0.68 * fade), alpha: CGFloat(fade))

        case .rave:
            let t = Double(steps) * 0.18
            let wave1 = sin(Double(col) * 0.16 - t * 1.8)
            let wave2 = cos(Double(col) * 0.09 + t * 1.3)
            let wave3 = sin(Double(col) * 0.31 + t * 2.4)
            let heightFrac = 0.38 + 0.56 * ((wave1 * 0.45 + wave2 * 0.35 + wave3 * 0.20) * 0.5 + 0.5)
            let topRow = Int(Double(dRows) * (1.0 - heightFrac))
            guard row >= topRow else {
                // Confetti strobe sparkles above the wave
                let sparkle = (col * 53 + row * 97 + steps * 41) % 173
                if sparkle == 0 {
                    let sHue = CGFloat((Double(col) / Double(Self.cols) + t * 0.1).truncatingRemainder(dividingBy: 1.0))
                    return NSColor(hue: sHue, saturation: 0.35, brightness: 1.0, alpha: 0.95)
                }
                return nil
            }
            let hue = ((Double(col) / Double(Self.cols)) * 1.35 - Double(steps) * 0.032 + Double(row) * 0.02 + 10.0)
                .truncatingRemainder(dividingBy: 1.0)
            let isTip = (row == topRow)
            let vBri = 0.55 + 0.45 * (Double(row - topRow + 1) / Double(max(1, dRows - topRow)))
            return NSColor(
                hue: CGFloat(hue),
                saturation: isTip ? 0.30 : 0.92,
                brightness: isTip ? 1.0 : CGFloat(vBri),
                alpha: CGFloat(cornerMask)
            )

        case .warp:
            let center = Double(Self.cols) / 2.0
            let distFromCenter = abs(Double(col) - center)
            // Subtle central reactor core glow
            if distFromCenter < 3.5 && row >= dRows / 3 {
                let core = (1.0 - distFromCenter / 3.5) * 0.75
                return NSColor(hue: 0.58, saturation: 0.45, brightness: 1.0, alpha: CGFloat(core))
            }
            // Deterministic accelerating star streaks per row & lane
            let dir = col < Self.cols / 2 ? -1 : 1
            for lane in 0..<3 {
                let seed = (row * 31 + lane * 67 + (dir > 0 ? 13 : 29))
                let period = 22.0 + Double(seed % 11)
                let age = (Double(steps) + Double(seed % 29) * 1.7).truncatingRemainder(dividingBy: period) / period
                let starDist = pow(age, 2.0) * (center - 1.0)
                let tailLen = max(1.5, age * 14.0)
                if distFromCenter <= starDist && distFromCenter >= starDist - tailLen {
                    let posInStreak = 1.0 - (starDist - distFromCenter) / tailLen // 1 at head, 0 at tail
                    let hue = (0.54 + Double(seed % 7) * 0.045 - (1.0 - posInStreak) * 0.08).truncatingRemainder(dividingBy: 1.0)
                    let isHead = posInStreak > 0.82
                    return NSColor(
                        hue: CGFloat((hue + 1.0).truncatingRemainder(dividingBy: 1.0)),
                        saturation: isHead ? 0.20 : 0.82,
                        brightness: CGFloat(0.35 + 0.65 * posInStreak),
                        alpha: CGFloat(posInStreak * cornerMask)
                    )
                }
            }
            return nil

        case .randomBullshit:
            return nil
        }
    }

    mutating func step() {
        steps += 1
        if steps % Self.recolorSteps == 0 { palette = Self.randomPalette() }
        let cols = Self.cols, rows = Self.rows
        // 1. Step Doom fire buffer
        for c in 0..<cols {
            let edgeDist = min(c, cols - 1 - c)
            let taper = edgeDist < 5 ? (5 - edgeDist) : 0
            heat[(rows - 1) * cols + c] = max(0, Self.maxHeat - taper)
        }
        for r in 0..<(rows - 1) {
            for c in 0..<cols {
                let rand = Int.random(in: 0...3)
                let to = (c - rand + 1 + cols) % cols
                heat[r * cols + to] = max(heat[(r + 1) * cols + c] - rand, 0)
            }
        }

        // 2. Step Knight Rider laser scanner
        let sweepPhase = Double(steps) * 0.11
        scannerHead = (sin(sweepPhase) * 0.5 + 0.5) * Double(cols - 1)
        for c in 0..<cols {
            scannerTrail[c] *= 0.82
            let d = abs(Double(c) - scannerHead)
            if d < 8.0 {
                scannerTrail[c] = max(scannerTrail[c], 1.0 - d / 8.0)
            }
        }

        // 3. Step Tesla lightning arcs
        let dRows = Self.drawRows
        var yMain = Double(Int.random(in: max(3, dRows / 2 - 2)...min(dRows - 2, dRows / 2 + 3)))
        var yFork = yMain + Double(Int.random(in: -2...2))
        for c in 0..<cols {
            yMain += Double.random(in: -1.6...1.6)
            yMain += (Double(dRows) * 0.62 - yMain) * 0.18
            yMain = min(Double(dRows - 2), max(2.0, yMain))
            lightningMain[c] = Int(yMain.rounded())

            if c % 9 == 0 {
                yFork = yMain + Double(Int.random(in: -2...2))
            } else {
                yFork += Double.random(in: -1.8...1.8)
            }
            yFork = min(Double(dRows - 1), max(1.0, yFork))
            lightningFork[c] = Int(yFork.rounded())
        }
    }
}

extension Fire {
    private static let pixel: CGFloat = 2.0

    /// The selected animation as an image of tiny squares spanning the width and height of the notch.
    func image(style: AgentAnimationStyle = .fire) -> NSImage {
        let rows = Fire.drawRows
        let size = NSSize(width: CGFloat(Fire.cols) * Self.pixel, height: CGFloat(rows) * Self.pixel)
        // Drawn lazily at the screen's scale, so it stays crisp on Retina.
        return NSImage(size: size, flipped: true) { _ in
            for r in 0..<rows {
                for c in 0..<Fire.cols {
                    guard let color = color(row: r, col: c, style: style) else { continue }
                    color.setFill()
                    NSRect(x: CGFloat(c) * Self.pixel, y: CGFloat(r) * Self.pixel, width: Self.pixel, height: Self.pixel).fill()
                }
            }
            return true
        }
    }
}
