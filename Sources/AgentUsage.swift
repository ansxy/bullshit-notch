import Foundation
import SwiftUI

/// Tracks 5-hour session, daily, and 7-day weekly token usage across Claude Code and Antigravity,
/// plus optional live OAuth `/usage` percentages for Claude Code.
struct UsageStats {
    // 5-hour rolling session window (matches Claude Code `/usage` 5h window)
    var sessionInput: Int = 0
    var sessionOutput: Int = 0
    var sessionCacheWrite: Int = 0
    var sessionCacheRead: Int = 0
    var sessionOldestInWindow: Date? = nil

    // Today (since local midnight)
    var dailyInput: Int = 0
    var dailyOutput: Int = 0
    var dailyCacheWrite: Int = 0
    var dailyCacheRead: Int = 0

    // 7-day rolling weekly window (matches Claude Code `/usage` 7d window)
    var weeklyInput: Int = 0
    var weeklyOutput: Int = 0
    var weeklyCacheWrite: Int = 0
    var weeklyCacheRead: Int = 0
    var weeklyOldestInWindow: Date? = nil

    // Live OAuth `/usage` percentages from Anthropic (0...100), if available
    var liveFiveHourPercent: Double? = nil
    var liveFiveHourResetsAt: Date? = nil
    var liveSevenDayPercent: Double? = nil
    var liveSevenDayResetsAt: Date? = nil

    /// Effective tokens weighting cached reads at 10% (0.1x) so prompt cache hits don't inflate usage 20-50x.
    var sessionEffective: Int {
        sessionInput + sessionCacheWrite + (sessionCacheRead / 10) + sessionOutput
    }
    var dailyEffective: Int {
        dailyInput + dailyCacheWrite + (dailyCacheRead / 10) + dailyOutput
    }
    var weeklyEffective: Int {
        weeklyInput + weeklyCacheWrite + (weeklyCacheRead / 10) + weeklyOutput
    }

    var sessionResetsAt: Date? {
        if let live = liveFiveHourResetsAt { return live }
        return sessionOldestInWindow?.addingTimeInterval(5 * 3600)
    }

    var weeklyResetsAt: Date? {
        if let live = liveSevenDayResetsAt { return live }
        return weeklyOldestInWindow?.addingTimeInterval(7 * 24 * 3600)
    }
}

struct LimitPreset {
    let title: String
    let sessionOrDaily: Int
    let weekly: Int
}

extension Harness {
    /// Realistic effective-token presets (where cache reads are weighted at 0.1x).
    var limitPresets: [LimitPreset] {
        switch self {
        case .claude:
            return [
                LimitPreset(title: "Pro (2.5M 5h / 18M wk)", sessionOrDaily: 2_500_000, weekly: 18_000_000),
                LimitPreset(title: "Max 5x (12.5M 5h / 90M wk)", sessionOrDaily: 12_500_000, weekly: 90_000_000),
                LimitPreset(title: "Max 20x (50M 5h / 360M wk)", sessionOrDaily: 50_000_000, weekly: 360_000_000),
                LimitPreset(title: "Team / API (100M / 500M)", sessionOrDaily: 100_000_000, weekly: 500_000_000)
            ]
        case .antigravity:
            return [
                LimitPreset(title: "Standard (3M 5h / 20M wk)", sessionOrDaily: 3_000_000, weekly: 20_000_000),
                LimitPreset(title: "Pro (8M 5h / 50M wk)", sessionOrDaily: 8_000_000, weekly: 50_000_000),
                LimitPreset(title: "Heavy (20M 5h / 120M wk)", sessionOrDaily: 20_000_000, weekly: 120_000_000),
                LimitPreset(title: "Max (50M 5h / 300M wk)", sessionOrDaily: 50_000_000, weekly: 300_000_000)
            ]
        }
    }
}

struct UsageEntry {
    let date: Date
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int
}

private actor UsageFileCache {
    static let shared = UsageFileCache()

    struct CachedFile {
        var modDate: Date
        var size: UInt64
        var entries: [UsageEntry]
    }

    private var claudeFiles: [URL: CachedFile] = [:]
    private var agyFiles: [URL: CachedFile] = [:]

    func claudeEntries(for file: URL, modDate: Date, size: UInt64, builder: () -> [UsageEntry]) -> [UsageEntry] {
        if let cached = claudeFiles[file], cached.modDate == modDate, cached.size == size {
            return cached.entries
        }
        let entries = builder()
        claudeFiles[file] = CachedFile(modDate: modDate, size: size, entries: entries)
        return entries
    }

    func agyEntries(for file: URL, modDate: Date, size: UInt64, builder: () -> [UsageEntry]) -> [UsageEntry] {
        if let cached = agyFiles[file], cached.modDate == modDate, cached.size == size {
            return cached.entries
        }
        let entries = builder()
        agyFiles[file] = CachedFile(modDate: modDate, size: size, entries: entries)
        return entries
    }

    func prune(activeClaude: Set<URL>, activeAgy: Set<URL>) {
        claudeFiles = claudeFiles.filter { activeClaude.contains($0.key) }
        agyFiles = agyFiles.filter { activeAgy.contains($0.key) }
    }
}

@MainActor
final class AgentUsageTracker: ObservableObject {
    static let shared = AgentUsageTracker()

    @Published private(set) var claudeStats = UsageStats()
    @Published private(set) var agyStats = UsageStats()
    @Published private(set) var isRefreshing = false
    @Published private(set) var claudeOAuthConnected = false

    private let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private let geminiDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    private var cachedKeychainToken: String? = nil
    private var timer: Timer?
    private var isDemo = false
    private var lastRefreshDate: Date = .distantPast

    init() {
        migrateLegacyLimitsIfNeeded()
        if CommandLine.arguments.contains("--demo") {
            loadDemoData()
            return
        }
    }

    func startPolling() {
        if isDemo { return }
        if Date().timeIntervalSince(lastRefreshDate) > 15 {
            refresh()
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func loadDemoData() {
        isDemo = true
        claudeOAuthConnected = true
        claudeStats = UsageStats(
            sessionInput: 418_000,
            sessionOutput: 142_000,
            sessionCacheWrite: 1_240_000,
            sessionCacheRead: 3_800_000,
            sessionOldestInWindow: .now.addingTimeInterval(-3.2 * 3600),
            dailyInput: 1_120_000,
            dailyOutput: 390_000,
            dailyCacheWrite: 2_900_000,
            dailyCacheRead: 8_400_000,
            weeklyInput: 3_400_000,
            weeklyOutput: 1_180_000,
            weeklyCacheWrite: 9_800_000,
            weeklyCacheRead: 26_500_000,
            weeklyOldestInWindow: .now.addingTimeInterval(-4.5 * 86400),
            liveFiveHourPercent: 62.0,
            liveFiveHourResetsAt: .now.addingTimeInterval(1.8 * 3600),
            liveSevenDayPercent: 48.0,
            liveSevenDayResetsAt: .now.addingTimeInterval(4.2 * 86400)
        )
        agyStats = UsageStats(
            sessionInput: 290_000,
            sessionOutput: 110_000,
            sessionCacheWrite: 2_500_000,
            sessionCacheRead: 2_100_000,
            sessionOldestInWindow: .now.addingTimeInterval(-2.7 * 3600),
            dailyInput: 640_000,
            dailyOutput: 245_000,
            dailyCacheWrite: 4_100_000,
            dailyCacheRead: 4_800_000,
            weeklyInput: 2_100_000,
            weeklyOutput: 780_000,
            weeklyCacheWrite: 12_400_000,
            weeklyCacheRead: 14_200_000,
            weeklyOldestInWindow: .now.addingTimeInterval(-5 * 86400)
        )
    }

    /// Migrates old 100%-cache-inflated default limits (250M/1.5B) to realistic effective-token limits.
    private func migrateLegacyLimitsIfNeeded() {
        let d = UserDefaults.standard
        if d.integer(forKey: Pref.claudeDailyLimit) == 250_000_000 && d.integer(forKey: Pref.claudeWeeklyLimit) == 1_500_000_000 {
            d.set(12_500_000, forKey: Pref.claudeDailyLimit)
            d.set(90_000_000, forKey: Pref.claudeWeeklyLimit)
        }
        if d.integer(forKey: Pref.agyDailyLimit) == 25_000_000 && d.integer(forKey: Pref.agyWeeklyLimit) == 100_000_000 {
            d.set(8_000_000, forKey: Pref.agyDailyLimit)
            d.set(50_000_000, forKey: Pref.agyWeeklyLimit)
        }
    }

    func refresh() {
        if isDemo || isRefreshing { return }
        isRefreshing = true
        lastRefreshDate = Date()
        let claude = claudeDir
        let gemini = geminiDir
        let keychainToken = cachedKeychainToken

        Task.detached(priority: .utility) {
            var cStats = await Self.computeClaude(claudeDir: claude)
            let aStats = await Self.computeAntigravity(geminiDir: gemini)

            // Try reading OAuth token from ~/.claude/.credentials.json or cached Keychain token
            if let token = keychainToken ?? Self.readClaudeCredentialsFile(claudeDir: claude),
               let oauth = await Self.fetchClaudeOAuthUsage(token: token) {
                cStats.liveFiveHourPercent = oauth.fiveHourPercent
                cStats.liveFiveHourResetsAt = oauth.fiveHourResetsAt
                cStats.liveSevenDayPercent = oauth.sevenDayPercent
                cStats.liveSevenDayResetsAt = oauth.sevenDayResetsAt
            }

            let finalCStats = cStats
            await MainActor.run {
                let tracker = AgentUsageTracker.shared
                tracker.claudeStats = finalCStats
                tracker.agyStats = aStats
                tracker.claudeOAuthConnected = (finalCStats.liveFiveHourPercent != nil || finalCStats.liveSevenDayPercent != nil)
                tracker.isRefreshing = false
            }
        }
    }

    /// Reads Claude Code's OAuth token from macOS Keychain on user request and fetches live `/usage`.
    func syncClaudeKeychain() {
        isRefreshing = true
        Task.detached(priority: .userInitiated) {
            let token = Self.readClaudeKeychainToken()
            await MainActor.run {
                let tracker = AgentUsageTracker.shared
                if let token, !token.isEmpty {
                    tracker.cachedKeychainToken = token
                }
                tracker.refresh()
            }
        }
    }

    // MARK: - Claude OAuth `/usage` Endpoint

    private struct ClaudeOAuthUsage {
        var fiveHourPercent: Double?
        var fiveHourResetsAt: Date?
        var sevenDayPercent: Double?
        var sevenDayResetsAt: Date?
    }

    nonisolated private static func readClaudeCredentialsFile(claudeDir: URL) -> String? {
        let credURL = claudeDir.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: credURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        return token
    }

    nonisolated private static func readClaudeKeychainToken() -> String? {
        let raw = shell("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        return token
    }

    nonisolated private static func fetchClaudeOAuthUsage(token: String) async -> ClaudeOAuthUsage? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 5
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        let isoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let parseDate = { (s: String?) -> Date? in
            guard let s else { return nil }
            return isoFrac.date(from: s) ?? iso.date(from: s)
        }

        var result = ClaudeOAuthUsage()
        if let fh = obj["five_hour"] as? [String: Any] {
            result.fiveHourPercent = (fh["utilization"] as? NSNumber)?.doubleValue
            result.fiveHourResetsAt = parseDate(fh["resets_at"] as? String)
        }
        if let sd = obj["seven_day"] as? [String: Any] {
            result.sevenDayPercent = (sd["utilization"] as? NSNumber)?.doubleValue
            result.sevenDayResetsAt = parseDate(sd["resets_at"] as? String)
        }
        return result
    }

    // MARK: - Local Transcript Aggregation

    nonisolated private static func computeClaude(claudeDir: URL) async -> UsageStats {
        let cal = Calendar.current
        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let startOfDay = cal.startOfDay(for: now)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 3600)

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

        let resKeys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        var seenRequests = Set<String>()

        for slug in slugs {
            let topItems = (try? FileManager.default.contentsOfDirectory(
                at: slug, includingPropertiesForKeys: resKeys)) ?? []
            var jsonlFiles: [URL] = []
            for item in topItems {
                if item.pathExtension == "jsonl" {
                    jsonlFiles.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let subDir = item.appendingPathComponent("subagents")
                    let subFiles = (try? FileManager.default.contentsOfDirectory(
                        at: subDir, includingPropertiesForKeys: resKeys)) ?? []
                    jsonlFiles.append(contentsOf: subFiles.filter { $0.pathExtension == "jsonl" })
                }
            }

            for file in jsonlFiles {
                guard let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mdate = vals.contentModificationDate,
                      mdate >= sevenDaysAgo else { continue }
                let size = UInt64(vals.fileSize ?? 0)

                let entries = await UsageFileCache.shared.claudeEntries(for: file, modDate: mdate, size: size) {
                    var parsedEntries: [UsageEntry] = []
                    autoreleasepool {
                        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return }
                        for line in data.split(separator: UInt8(ascii: "\n")) {
                            // Fast pre-filter before full JSONSerialization
                            guard line.count > 20 else { continue }
                            if let entry = parseClaudeLineToEntry(line, sevenDaysAgo: sevenDaysAgo, iso: iso, isoFrac: isoFrac, seen: &seenRequests) {
                                parsedEntries.append(entry)
                            }
                        }
                    }
                    return parsedEntries
                }

                for e in entries where e.date >= sevenDaysAgo {
                    accumulate(e, fiveHoursAgo: fiveHoursAgo, startOfDay: startOfDay, stats: &stats)
                }
            }
        }
        return stats
    }

    nonisolated private static func parseClaudeLineToEntry(_ lineSlice: Data.SubSequence, sevenDaysAgo: Date,
                                                           iso: ISO8601DateFormatter, isoFrac: ISO8601DateFormatter,
                                                           seen: inout Set<String>) -> UsageEntry? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(lineSlice)) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any],
              let tsStr = obj["timestamp"] as? String ?? obj["created_at"] as? String,
              let date = isoFrac.date(from: tsStr) ?? iso.date(from: tsStr),
              date >= sevenDaysAgo else { return nil }

        let reqId = obj["requestId"] as? String ?? msg["id"] as? String ?? ""
        if !reqId.isEmpty {
            if seen.contains(reqId) { return nil }
            seen.insert(reqId)
        }

        let int = { (k: String) in u[k] as? Int ?? 0 }
        return UsageEntry(
            date: date,
            input: int("input_tokens"),
            output: int("output_tokens"),
            cacheWrite: int("cache_creation_input_tokens"),
            cacheRead: int("cache_read_input_tokens")
        )
    }

    nonisolated private static func computeAntigravity(geminiDir: URL) async -> UsageStats {
        let cal = Calendar.current
        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let startOfDay = cal.startOfDay(for: now)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 3600)

        let iso = ISO8601DateFormatter()
        let isoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        var stats = UsageStats()
        let roots = ["antigravity-cli", "antigravity"].map { geminiDir.appendingPathComponent($0) }
        var seenConvSteps = Set<String>()

        for root in roots {
            let brainDir = root.appendingPathComponent("brain")
            guard let convs = try? FileManager.default.contentsOfDirectory(at: brainDir, includingPropertiesForKeys: nil) else {
                continue
            }
            for conv in convs {
                let convID = conv.lastPathComponent
                let file = conv.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                guard let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mdate = vals.contentModificationDate,
                      mdate >= sevenDaysAgo else { continue }
                let size = UInt64(vals.fileSize ?? 0)

                let entries = await UsageFileCache.shared.agyEntries(for: file, modDate: mdate, size: size) {
                    var parsedEntries: [UsageEntry] = []
                    autoreleasepool {
                        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return }
                        for line in data.split(separator: UInt8(ascii: "\n")) {
                            if let entry = parseAgyLineToEntry(line, convID: convID, sevenDaysAgo: sevenDaysAgo, iso: iso, isoFrac: isoFrac, seen: &seenConvSteps) {
                                parsedEntries.append(entry)
                            }
                        }
                    }
                    return parsedEntries
                }

                for e in entries where e.date >= sevenDaysAgo {
                    accumulate(e, fiveHoursAgo: fiveHoursAgo, startOfDay: startOfDay, stats: &stats)
                }
            }
        }
        return stats
    }

    nonisolated private static func parseAgyLineToEntry(_ lineSlice: Data.SubSequence, convID: String, sevenDaysAgo: Date,
                                                        iso: ISO8601DateFormatter, isoFrac: ISO8601DateFormatter,
                                                        seen: inout Set<String>) -> UsageEntry? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(lineSlice)) as? [String: Any],
              (obj["type"] as? String) == "PLANNER_RESPONSE",
              let tsStr = obj["created_at"] as? String,
              let date = isoFrac.date(from: tsStr) ?? iso.date(from: tsStr),
              date >= sevenDaysAgo else { return nil }

        if let idx = obj["step_index"] as? Int {
            let key = "\(convID):\(idx)"
            if seen.contains(key) { return nil }
            seen.insert(key)
        }

        let int = { (k: String) in obj[k] as? Int ?? 0 }
        return UsageEntry(
            date: date,
            input: int("input_tokens"),
            output: int("output_tokens"),
            cacheWrite: int("cache_creation_tokens") + int("cache_write_tokens"),
            cacheRead: int("cache_read_tokens")
        )
    }

    nonisolated private static func accumulate(_ e: UsageEntry, fiveHoursAgo: Date, startOfDay: Date, stats: inout UsageStats) {
        stats.weeklyInput += e.input
        stats.weeklyOutput += e.output
        stats.weeklyCacheWrite += e.cacheWrite
        stats.weeklyCacheRead += e.cacheRead
        if stats.weeklyOldestInWindow == nil || e.date < stats.weeklyOldestInWindow! {
            stats.weeklyOldestInWindow = e.date
        }

        if e.date >= startOfDay {
            stats.dailyInput += e.input
            stats.dailyOutput += e.output
            stats.dailyCacheWrite += e.cacheWrite
            stats.dailyCacheRead += e.cacheRead
        }

        if e.date >= fiveHoursAgo {
            stats.sessionInput += e.input
            stats.sessionOutput += e.output
            stats.sessionCacheWrite += e.cacheWrite
            stats.sessionCacheRead += e.cacheRead
            if stats.sessionOldestInWindow == nil || e.date < stats.sessionOldestInWindow! {
                stats.sessionOldestInWindow = e.date
            }
        }
    }
}

/// A compact card showing 5-hour session / daily and 7-day weekly usage and limits for a specific harness.
struct HarnessLimitsCard: View {
    let harness: Harness
    @ObservedObject private var tracker = AgentUsageTracker.shared
    @AppStorage(Pref.claudeDailyLimit) private var claudeSessionLimit = 12_500_000
    @AppStorage(Pref.claudeWeeklyLimit) private var claudeWeeklyLimit = 90_000_000
    @AppStorage(Pref.agyDailyLimit) private var agySessionLimit = 8_000_000
    @AppStorage(Pref.agyWeeklyLimit) private var agyWeeklyLimit = 50_000_000

    @State private var showDailyInsteadOf5h = false
    @State private var editingCustom = false
    @State private var customSessionMillions = ""
    @State private var customWeeklyMillions = ""

    private var stats: UsageStats {
        harness == .claude ? tracker.claudeStats : tracker.agyStats
    }

    private var sessionOrDailyLimit: Int {
        harness == .claude ? claudeSessionLimit : agySessionLimit
    }

    private var weeklyLimit: Int {
        harness == .claude ? claudeWeeklyLimit : agyWeeklyLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(harness.color).frame(width: 7, height: 7)
                Text("\(harness.rawValue) Limits")
                    .font(.caption.bold())
                if harness == .claude && tracker.claudeOAuthConnected {
                    Text("LIVE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.25), in: Capsule())
                        .foregroundStyle(.green)
                        .help("Synced with Anthropic /usage OAuth endpoint")
                }
                Spacer()

                // Toggle between 5h Session window and Today (Daily)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showDailyInsteadOf5h.toggle()
                    }
                } label: {
                    Text(showDailyInsteadOf5h ? "Today" : "5h Win")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Switch top bar between 5-Hour Session Window and Today's total")

                Menu {
                    Section("Limit Tier Presets") {
                        ForEach(harness.limitPresets, id: \.title) { preset in
                            Button {
                                if harness == .claude {
                                    claudeSessionLimit = preset.sessionOrDaily
                                    claudeWeeklyLimit = preset.weekly
                                } else {
                                    agySessionLimit = preset.sessionOrDaily
                                    agyWeeklyLimit = preset.weekly
                                }
                            } label: {
                                HStack {
                                    Text(preset.title)
                                    if sessionOrDailyLimit == preset.sessionOrDaily && weeklyLimit == preset.weekly {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Set Custom Limits (M)…") {
                        customSessionMillions = String(format: "%.1f", Double(sessionOrDailyLimit) / 1_000_000)
                        customWeeklyMillions = String(format: "%.1f", Double(weeklyLimit) / 1_000_000)
                        editingCustom.toggle()
                    }
                    if harness == .claude {
                        Divider()
                        Button("Sync Live /usage from Keychain") {
                            tracker.syncClaudeKeychain()
                        }
                    }
                    Button("Refresh Usage Now") {
                        tracker.refresh()
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18, height: 18)
                .help("Configure limit tier or sync live usage")
            }

            if editingCustom {
                customLimitEditor
            }

            Divider()

            if showDailyInsteadOf5h {
                LimitBlock(
                    title: "Today (Daily)",
                    subtitle: "since midnight",
                    used: stats.dailyEffective,
                    limit: sessionOrDailyLimit,
                    overridePercent: nil,
                    input: stats.dailyInput + stats.dailyCacheWrite,
                    output: stats.dailyOutput,
                    cacheRead: stats.dailyCacheRead,
                    color: harness.color
                )
            } else {
                LimitBlock(
                    title: "5h Session",
                    subtitle: resetText(for: stats.sessionResetsAt),
                    used: stats.sessionEffective,
                    limit: sessionOrDailyLimit,
                    overridePercent: stats.liveFiveHourPercent.map { $0 / 100.0 },
                    input: stats.sessionInput + stats.sessionCacheWrite,
                    output: stats.sessionOutput,
                    cacheRead: stats.sessionCacheRead,
                    color: harness.color
                )
            }

            Divider()

            LimitBlock(
                title: "7d Weekly",
                subtitle: resetText(for: stats.weeklyResetsAt),
                used: stats.weeklyEffective,
                limit: weeklyLimit,
                overridePercent: stats.liveSevenDayPercent.map { $0 / 100.0 },
                input: stats.weeklyInput + stats.weeklyCacheWrite,
                output: stats.weeklyOutput,
                cacheRead: stats.weeklyCacheRead,
                color: harness.color
            )

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }

    private var customLimitEditor: some View {
        HStack(spacing: 4) {
            TextField("5h (M)", text: $customSessionMillions)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            TextField("7d (M)", text: $customWeeklyMillions)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            Button("Save") {
                if let s = Double(customSessionMillions), s > 0 {
                    let val = Int(s * 1_000_000)
                    if harness == .claude { claudeSessionLimit = val } else { agySessionLimit = val }
                }
                if let w = Double(customWeeklyMillions), w > 0 {
                    let val = Int(w * 1_000_000)
                    if harness == .claude { claudeWeeklyLimit = val } else { agyWeeklyLimit = val }
                }
                editingCustom = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(harness.color.opacity(0.35), in: Capsule())
        }
    }

    private func resetText(for date: Date?) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        let hours = Int(remaining) / 3600
        let mins = (Int(remaining) % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            let remH = hours % 24
            return "resets \(days)d \(remH)h"
        } else if hours > 0 {
            return "resets \(hours)h \(mins)m"
        } else {
            return "resets \(max(1, mins))m"
        }
    }
}

private struct LimitBlock: View {
    let title: String
    let subtitle: String?
    let used: Int
    let limit: Int
    let overridePercent: Double?
    let input: Int
    let output: Int
    let cacheRead: Int
    let color: Color

    private var percent: Double {
        if let overridePercent {
            return max(0, min(1.0, overridePercent))
        }
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
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2.bold())
                if let subtitle {
                    Text("· \(subtitle)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(Int((percent * 100).rounded()))%")
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

            HStack(spacing: 4) {
                Text("\(formatTokens(used)) / \(formatTokens(limit))")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("↑\(formatTokens(input)) ↓\(formatTokens(output)) ⚡\(formatTokens(cacheRead))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("Uncached input · Output · Prompt cache hits (weighted 0.1x)")
            }
        }
    }

    private func formatTokens(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
