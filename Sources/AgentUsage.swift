import Foundation
import SwiftUI

/// Tracks daily and weekly token usage across Claude Code and Antigravity sessions.
struct UsageStats {
    var dailyInput: Int = 0
    var dailyOutput: Int = 0
    var weeklyInput: Int = 0
    var weeklyOutput: Int = 0

    var dailyTotal: Int { dailyInput + dailyOutput }
    var weeklyTotal: Int { weeklyInput + weeklyOutput }
}

struct LimitPreset {
    let title: String
    let daily: Int
    let weekly: Int
}

extension Harness {
    var limitPresets: [LimitPreset] {
        switch self {
        case .claude:
            return [
                LimitPreset(title: "Pro (100M / 500M)", daily: 100_000_000, weekly: 500_000_000),
                LimitPreset(title: "Team (250M / 1.5B)", daily: 250_000_000, weekly: 1_500_000_000),
                LimitPreset(title: "Heavy (500M / 2.5B)", daily: 500_000_000, weekly: 2_500_000_000),
                LimitPreset(title: "Max (1B / 5B)", daily: 1_000_000_000, weekly: 5_000_000_000)
            ]
        case .antigravity:
            return [
                LimitPreset(title: "Standard (10M / 50M)", daily: 10_000_000, weekly: 50_000_000),
                LimitPreset(title: "Pro (25M / 100M)", daily: 25_000_000, weekly: 100_000_000),
                LimitPreset(title: "Heavy (50M / 250M)", daily: 50_000_000, weekly: 250_000_000),
                LimitPreset(title: "Max (100M / 500M)", daily: 100_000_000, weekly: 500_000_000)
            ]
        }
    }
}

@MainActor
final class AgentUsageTracker: ObservableObject {
    static let shared = AgentUsageTracker()

    @Published private(set) var claudeStats = UsageStats()
    @Published private(set) var agyStats = UsageStats()

    private let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private let geminiDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    private var lastComputed = Date.distantPast
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        lastComputed = Date()
        let claude = claudeDir
        let gemini = geminiDir

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cStats = Self.computeClaude(claudeDir: claude)
            let aStats = Self.computeAntigravity(geminiDir: gemini)
            DispatchQueue.main.async {
                self?.claudeStats = cStats
                self?.agyStats = aStats
            }
        }
    }

    nonisolated private static func computeClaude(claudeDir: URL) -> UsageStats {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        let startOfWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? startOfDay
        let iso = ISO8601DateFormatter()
        let isoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        var stats = UsageStats()
        let projectsDir = claudeDir.appendingPathComponent("projects")
        guard let slugs = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else {
            return stats
        }

        for slug in slugs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: slug, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let mdate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mdate >= startOfWeek else { continue }
                guard let data = try? Data(contentsOf: file) else { continue }

                var seenRequests = Set<String>()
                data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    var start = 0
                    for i in 0..<raw.count {
                        if base[i] == UInt8(ascii: "\n") {
                            let lineData = Data(bytes: base + start, count: i - start)
                            start = i + 1
                            parseClaudeLine(lineData, startOfWeek: startOfWeek, startOfDay: startOfDay,
                                            iso: iso, isoFrac: isoFrac, seen: &seenRequests, stats: &stats)
                        }
                    }
                }
            }
        }
        return stats
    }

    nonisolated private static func parseClaudeLine(_ lineData: Data, startOfWeek: Date, startOfDay: Date,
                                        iso: ISO8601DateFormatter, isoFrac: ISO8601DateFormatter,
                                        seen: inout Set<String>, stats: inout UsageStats) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let tsStr = obj["timestamp"] as? String ?? obj["created_at"] as? String,
              let date = iso.date(from: tsStr) ?? isoFrac.date(from: tsStr),
              date >= startOfWeek else { return }

        guard let msg = obj["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any] else { return }

        let reqId = obj["requestId"] as? String ?? msg["id"] as? String ?? ""
        if !reqId.isEmpty {
            if seen.contains(reqId) { return }
            seen.insert(reqId)
        }

        let int = { (k: String) in u[k] as? Int ?? 0 }
        let inp = int("input_tokens") + int("cache_creation_input_tokens") + int("cache_read_input_tokens")
        let out = int("output_tokens")

        stats.weeklyInput += inp
        stats.weeklyOutput += out
        if date >= startOfDay {
            stats.dailyInput += inp
            stats.dailyOutput += out
        }
    }

    nonisolated private static func computeAntigravity(geminiDir: URL) -> UsageStats {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        let startOfWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? startOfDay
        let iso = ISO8601DateFormatter()
        let isoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        var stats = UsageStats()
        let roots = ["antigravity-cli", "antigravity"].map { geminiDir.appendingPathComponent($0) }
        for root in roots {
            let brainDir = root.appendingPathComponent("brain")
            guard let convs = try? FileManager.default.contentsOfDirectory(at: brainDir, includingPropertiesForKeys: nil) else {
                continue
            }
            for conv in convs {
                let file = conv.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                guard let mdate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mdate >= startOfWeek else { continue }
                guard let data = try? Data(contentsOf: file) else { continue }

                var seenSteps = Set<Int>()
                data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    var start = 0
                    for i in 0..<raw.count {
                        if base[i] == UInt8(ascii: "\n") {
                            let lineData = Data(bytes: base + start, count: i - start)
                            start = i + 1
                            parseAgyLine(lineData, startOfWeek: startOfWeek, startOfDay: startOfDay,
                                         iso: iso, isoFrac: isoFrac, seen: &seenSteps, stats: &stats)
                        }
                    }
                }
            }
        }
        return stats
    }

    nonisolated private static func parseAgyLine(_ lineData: Data, startOfWeek: Date, startOfDay: Date,
                                     iso: ISO8601DateFormatter, isoFrac: ISO8601DateFormatter,
                                     seen: inout Set<Int>, stats: inout UsageStats) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              (obj["type"] as? String) == "PLANNER_RESPONSE",
              let tsStr = obj["created_at"] as? String,
              let date = iso.date(from: tsStr) ?? isoFrac.date(from: tsStr),
              date >= startOfWeek else { return }

        if let idx = obj["step_index"] as? Int {
            if seen.contains(idx) { return }
            seen.insert(idx)
        }

        let int = { (k: String) in obj[k] as? Int ?? 0 }
        let inp = int("input_tokens") + int("cache_read_tokens") + int("cache_creation_tokens") + int("cache_write_tokens")
        let out = int("output_tokens")

        stats.weeklyInput += inp
        stats.weeklyOutput += out
        if date >= startOfDay {
            stats.dailyInput += inp
            stats.dailyOutput += out
        }
    }
}

/// A compact card showing daily and weekly usage and limits for a specific harness.
struct HarnessLimitsCard: View {
    let harness: Harness
    @ObservedObject private var tracker = AgentUsageTracker.shared
    @AppStorage(Pref.claudeDailyLimit) private var claudeDaily = 250_000_000
    @AppStorage(Pref.claudeWeeklyLimit) private var claudeWeekly = 1_500_000_000
    @AppStorage(Pref.agyDailyLimit) private var agyDaily = 25_000_000
    @AppStorage(Pref.agyWeeklyLimit) private var agyWeekly = 100_000_000

    private var stats: UsageStats {
        harness == .claude ? tracker.claudeStats : tracker.agyStats
    }

    private var dailyLimit: Int {
        harness == .claude ? claudeDaily : agyDaily
    }

    private var weeklyLimit: Int {
        harness == .claude ? claudeWeekly : agyWeekly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(harness.color).frame(width: 8, height: 8)
                Text("\(harness.rawValue) Usage & Limits")
                    .font(.caption.bold())
                Spacer()
                Menu {
                    ForEach(harness.limitPresets, id: \.title) { preset in
                        Button(preset.title) {
                            if harness == .claude {
                                claudeDaily = preset.daily
                                claudeWeekly = preset.weekly
                            } else {
                                agyDaily = preset.daily
                                agyWeekly = preset.weekly
                            }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .help("Change limit tier preset")
            }

            Divider()

            LimitBlock(title: "Daily", used: stats.dailyTotal, limit: dailyLimit,
                       input: stats.dailyInput, output: stats.dailyOutput, color: harness.color)

            Divider()

            LimitBlock(title: "Weekly", used: stats.weeklyTotal, limit: weeklyLimit,
                       input: stats.weeklyInput, output: stats.weeklyOutput, color: harness.color)

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}

private struct LimitBlock: View {
    let title: String
    let used: Int
    let limit: Int
    let input: Int
    let output: Int
    let color: Color

    private var percent: Double {
        guard limit > 0 else { return 0 }
        return min(1.0, Double(used) / Double(limit))
    }

    private var statusColor: Color {
        if percent >= 0.9 { return .red }
        if percent >= 0.7 { return .yellow }
        return color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.caption2.bold())
                Spacer()
                Text("\(Int(percent * 100))%")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(statusColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(statusColor)
                        .frame(width: max(3, geo.size.width * CGFloat(percent)))
                }
            }
            .frame(height: 5)

            HStack {
                Text("\(formatTokens(used)) / \(formatTokens(limit))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("↑\(formatTokens(input)) ↓\(formatTokens(output))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func formatTokens(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
