import AppKit
import Darwin
import SwiftUI

/// A listening TCP dev port or active bash/developer process discovered on the system.
struct DevProcItem: Identifiable, Hashable {
    enum Kind: String {
        case port = "PORT"
        case bash = "BASH"
    }

    let pid: Int32
    let ppid: Int32
    let name: String
    let command: String
    let ports: [Int]
    let cwd: String?
    let cpuPercent: Double
    let memoryMB: Double
    let elapsed: String

    var id: Int32 { pid }

    var kind: Kind {
        ports.isEmpty ? .bash : .port
    }

    var primaryPort: Int? {
        ports.first
    }

    var displayCwd: String? {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return nil }
        return (cwd as NSString).abbreviatingWithTildeInPath
    }

    var projectName: String? {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var shortCommand: String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }
        // Strip leading full binary paths (e.g. /opt/homebrew/bin/node -> node) for readability
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return trimmed }
        let base = URL(fileURLWithPath: String(first)).lastPathComponent
        if parts.count > 1 {
            return "\(base) \(parts[1])"
        }
        return base
    }
}

/// Live toast shown on the closed notch wings when a watched process or Work service exits.
struct WatchedProcAlert: Equatable {
    let id = UUID()
    let title: String
    let badge: String
    let succeeded: Bool
    let targetSection: AppSection
}

/// Discovers active listening TCP ports and running bash/developer processes, terminates hung
/// processes + their child trees, and watches PIDs to flash closed-notch Done/Crash badges.
@MainActor
final class ProcsStore: ObservableObject {
    static let shared = ProcsStore()

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case ports = "Ports"
        case bash = "Bash & Dev"

        var id: String { rawValue }
    }

    @Published private(set) var items: [DevProcItem] = []
    @Published private(set) var isLoading = false
    @Published var filter: Filter = .all
    @Published var searchText: String = ""
    @Published private(set) var watchedPIDs: Set<Int32> = []
    @Published private(set) var activeAlert: WatchedProcAlert?

    private var watchedSnapshots: [Int32: DevProcItem] = [:]
    private var killedByUser: Set<Int32> = []
    private var pollTimer: Timer?
    private var alertDismissTask: Task<Void, Never>?

    private init() {
        if CommandLine.arguments.contains("--demo") {
            loadDemoData()
            return
        }
        startWatcherLoop()
    }

    private func loadDemoData() {
        items = [
            DevProcItem(
                pid: 48210, ppid: 1, name: "node",
                command: "node /Users/dev/work/web-app/node_modules/.bin/next dev -p 3000",
                ports: [3000], cwd: "/Users/dev/work/web-app",
                cpuPercent: 4.2, memoryMB: 184, elapsed: "14:22"
            ),
            DevProcItem(
                pid: 51092, ppid: 1, name: "python3.12",
                command: "uvicorn app.main:app --reload --port 8000",
                ports: [8000], cwd: "/Users/dev/work/hyperdrive-api",
                cpuPercent: 1.8, memoryMB: 96, elapsed: "08:45"
            ),
            DevProcItem(
                pid: 53901, ppid: 4100, name: "bash",
                command: "bash ./scripts/seed_db.sh --env local",
                ports: [], cwd: "/Users/dev/work/hyperdrive-api",
                cpuPercent: 32.5, memoryMB: 24, elapsed: "00:42"
            )
        ]
        watchedPIDs = [53901]
    }

    var filteredItems: [DevProcItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            switch filter {
            case .all:   break
            case .ports: if item.ports.isEmpty { return false }
            case .bash:  if !item.ports.isEmpty { return false }
            }
            guard !q.isEmpty else { return true }
            if item.name.lowercased().contains(q) { return true }
            if item.command.lowercased().contains(q) { return true }
            if let cwd = item.cwd?.lowercased(), cwd.contains(q) { return true }
            if item.ports.contains(where: { ":\($0)".contains(q) || "\($0)".contains(q) }) { return true }
            if "\(item.pid)".contains(q) { return true }
            return false
        }
    }

    var portCount: Int {
        items.filter { !$0.ports.isEmpty }.count
    }

    var bashCount: Int {
        items.filter { $0.ports.isEmpty }.count
    }

    // MARK: - Watching & Closed-Notch Alerts

    func isWatching(_ pid: Int32) -> Bool {
        watchedPIDs.contains(pid)
    }

    func toggleWatch(_ item: DevProcItem) {
        if watchedPIDs.contains(item.pid) {
            watchedPIDs.remove(item.pid)
            watchedSnapshots.removeValue(forKey: item.pid)
        } else {
            watchedPIDs.insert(item.pid)
            watchedSnapshots[item.pid] = item
        }
    }

    func triggerAlert(title: String, badge: String, succeeded: Bool, targetSection: AppSection = .procs) {
        alertDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            activeAlert = WatchedProcAlert(
                title: title,
                badge: badge,
                succeeded: succeeded,
                targetSection: targetSection
            )
        }
        alertDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6.0))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                self.activeAlert = nil
            }
        }
    }

    func clearAlert() {
        alertDismissTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            activeAlert = nil
        }
    }

    private func startWatcherLoop() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkWatchedPIDs()
            }
        }
    }

    private func checkWatchedPIDs() {
        guard !watchedPIDs.isEmpty else { return }
        for pid in Array(watchedPIDs) {
            if kill(pid, 0) != 0 && errno == ESRCH {
                watchedPIDs.remove(pid)
                let snap = watchedSnapshots.removeValue(forKey: pid)
                let wasUserKilled = killedByUser.remove(pid) != nil
                guard !wasUserKilled else { continue }

                if let snap {
                    if let port = snap.primaryPort {
                        triggerAlert(
                            title: ":\(port) stopped",
                            badge: snap.name,
                            succeeded: false,
                            targetSection: .procs
                        )
                    } else {
                        triggerAlert(
                            title: snap.projectName ?? snap.name,
                            badge: "Done",
                            succeeded: true,
                            targetSection: .procs
                        )
                    }
                }
                refresh()
            }
        }
    }

    // MARK: - Actions: Open Browser, Stop (SIGTERM), Force Kill (SIGKILL -9)

    func openPort(_ port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func stop(_ item: DevProcItem) {
        terminateProcess(pid: item.pid, force: false)
    }

    func forceKill(_ item: DevProcItem) {
        terminateProcess(pid: item.pid, force: true)
    }

    func killAllPorts() {
        let portItems = items.filter { !$0.ports.isEmpty }
        for item in portItems {
            terminateProcess(pid: item.pid, force: false)
        }
    }

    private func terminateProcess(pid: Int32, force: Bool) {
        killedByUser.insert(pid)
        watchedPIDs.remove(pid)
        watchedSnapshots.removeValue(forKey: pid)

        let sigFlag = force ? "-KILL" : "-TERM"
        let signal: Int32 = force ? SIGKILL : SIGTERM

        DispatchQueue.global(qos: .userInitiated).async {
            // 1. Terminate child processes first so wrapper scripts don't leave orphans
            _ = shell("/usr/bin/pkill", [sigFlag, "-P", "\(pid)"])
            // 2. Signal the process itself
            _ = Darwin.kill(pid, signal)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                ProcsStore.shared.refresh()
            }
        }
    }

    // MARK: - Process & Port Discovery

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let discovered = Self.scanSystemProcs()
            DispatchQueue.main.async {
                let store = ProcsStore.shared
                store.items = discovered
                store.isLoading = false
                for item in discovered where store.watchedPIDs.contains(item.pid) {
                    store.watchedSnapshots[item.pid] = item
                }
                store.checkWatchedPIDs()
            }
        }
    }

    nonisolated private static let ignoredSystemNames: Set<String> = [
        "rapportd", "controlce", "controlcenter", "sharingd", "airplayxpchelper",
        "windowserver", "loginwindow", "launchd", "mdnsresponder", "apsd",
        "identityservicesd", "cloudd", "symptomsd", "wifi", "bluetoothd",
        "coreaudiod", "figurerental", "figma_agent", "spotify", "music",
        "bullshitnotch", "topbar"
    ]

    nonisolated private static let devBinaryKeywords: Set<String> = [
        "bash", "zsh", "sh", "fish",
        "node", "bun", "deno", "ts-node", "tsx", "vite", "next", "next-server", "webpack", "esbuild", "turbo",
        "python", "python3", "uvicorn", "gunicorn", "celery", "pytest", "flask", "django",
        "cargo", "rustc", "go", "air",
        "ruby", "rails", "puma", "sidekiq",
        "php", "artisan", "composer",
        "java", "gradle", "mvn",
        "docker-compose", "kubectl", "cloudflared", "ngrok", "tailscale",
        "make", "cmake", "ninja", "playwright", "jest", "vitest"
    ]

    nonisolated private static func scanSystemProcs() -> [DevProcItem] {
        let myPID = ProcessInfo.processInfo.processIdentifier

        // 1. Discover all listening TCP ports via lsof
        // Example line: node 48210 ansar 23u IPv6 0x... 0t0 TCP *:3000 (LISTEN)
        let lsofOut = shell("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-n", "-P", "-Fpcn"])
        var portsByPID: [Int32: Set<Int>] = [:]
        var currentPID: Int32?
        for rawLine in lsofOut.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("p"), let p = Int32(line.dropFirst()) {
                currentPID = p
            } else if line.hasPrefix("n"), let pid = currentPID {
                // n*:3000 or n127.0.0.1:8000 or n[::1]:5173
                if let colonIdx = line.lastIndex(of: ":") {
                    let portStr = line[line.index(after: colonIdx)...]
                    if let port = Int(portStr), port > 0 {
                        portsByPID[pid, default: []].insert(port)
                    }
                }
            }
        }

        // 2. Read process table via ps
        let psOut = shell("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,etime=,comm=,args="])
        struct RawPS {
            let pid: Int32
            let ppid: Int32
            let cpu: Double
            let rssKB: Double
            let elapsed: String
            let comm: String
            let args: String
        }

        var candidates: [RawPS] = []
        for rawLine in psOut.split(separator: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let tokens = trimmed.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
            guard tokens.count >= 6,
                  let pid = Int32(tokens[0]),
                  let ppid = Int32(tokens[1]),
                  pid != myPID, pid > 1 else { continue }

            let cpu = Double(tokens[2]) ?? 0.0
            let rssKB = Double(tokens[3]) ?? 0.0
            let elapsed = String(tokens[4])
            let commPath = String(tokens[5])
            let args = tokens.count >= 7 ? String(tokens[6]) : commPath
            let baseName = URL(fileURLWithPath: commPath).lastPathComponent.lowercased()

            // Skip system binaries & noise
            if commPath.hasPrefix("/System/") || commPath.hasPrefix("/usr/libexec/") || commPath.hasPrefix("/sbin/") {
                continue
            }
            if ignoredSystemNames.contains(baseName) {
                continue
            }
            // Skip browser helper processes & Electron UI renderers unless they hold a dev port
            if (args.contains("--type=renderer") || args.contains("--type=gpu-process") || args.contains(".app/Contents/")) && portsByPID[pid] == nil {
                continue
            }

            let hasPort = portsByPID[pid] != nil
            var isDevOrBash = false

            if !hasPort {
                let matchesKeyword = devBinaryKeywords.contains(baseName)
                    || baseName.hasPrefix("python")
                    || baseName.hasPrefix("node")
                    || baseName.hasPrefix("ruby")
                    || baseName.hasPrefix("php")

                if matchesKeyword {
                    // Filter out idle interactive login shells (-zsh, -bash) waiting at prompt
                    let cleanArgs = args.trimmingCharacters(in: .whitespaces)
                    let isIdleShell = (baseName == "zsh" || baseName == "bash" || baseName == "sh" || baseName == "fish")
                        && (cleanArgs == "-zsh" || cleanArgs == "-bash" || cleanArgs == "/bin/zsh" || cleanArgs == "/bin/bash" || cleanArgs == "zsh" || cleanArgs == "bash" || cleanArgs.hasPrefix("/bin/zsh -l") && !cleanArgs.contains("-c"))
                        && cpu < 1.0
                    // Also skip our own short-lived ps/lsof subshells
                    let isSelfProbe = cleanArgs.contains("ps -axo") || cleanArgs.contains("lsof -iTCP")
                    if !isIdleShell && !isSelfProbe {
                        isDevOrBash = true
                    }
                }
            }

            if hasPort || isDevOrBash {
                candidates.append(RawPS(
                    pid: pid,
                    ppid: ppid,
                    cpu: cpu,
                    rssKB: rssKB,
                    elapsed: elapsed,
                    comm: URL(fileURLWithPath: commPath).lastPathComponent,
                    args: args
                ))
            }
        }

        // 3. Batch-resolve working directories (cwd) for candidate PIDs via a single lsof call
        var cwdByPID: [Int32: String] = [:]
        if !candidates.isEmpty {
            let pidList = candidates.prefix(60).map { "\($0.pid)" }.joined(separator: ",")
            let cwdOut = shell("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", pidList])
            var curPID: Int32?
            for rawLine in cwdOut.split(separator: "\n") {
                let line = String(rawLine)
                if line.hasPrefix("p"), let p = Int32(line.dropFirst()) {
                    curPID = p
                } else if line.hasPrefix("n"), let p = curPID {
                    let path = String(line.dropFirst())
                    if path.hasPrefix("/") {
                        cwdByPID[p] = path
                    }
                }
            }
        }

        // 4. Build DevProcItem array sorted: listening ports first (by lowest port), then high CPU / bash scripts
        let result: [DevProcItem] = candidates.map { c in
            let sortedPorts = Array(portsByPID[c.pid] ?? []).sorted()
            return DevProcItem(
                pid: c.pid,
                ppid: c.ppid,
                name: c.comm,
                command: c.args,
                ports: sortedPorts,
                cwd: cwdByPID[c.pid],
                cpuPercent: c.cpu,
                memoryMB: c.rssKB / 1024.0,
                elapsed: c.elapsed
            )
        }

        return result.sorted { a, b in
            if !a.ports.isEmpty && b.ports.isEmpty { return true }
            if a.ports.isEmpty && !b.ports.isEmpty { return false }
            if let pa = a.primaryPort, let pb = b.primaryPort, pa != pb {
                return pa < pb
            }
            if abs(a.cpuPercent - b.cpuPercent) > 0.5 {
                return a.cpuPercent > b.cpuPercent
            }
            return a.pid > b.pid
        }
    }
}

// MARK: - Ports & Bash Process Killer View (Workspace Section after QA)

struct ProcsView: View {
    @ObservedObject private var store = ProcsStore.shared
    @ObservedObject private var music = NowPlaying.shared
    @AppStorage(Pref.musicAmbient) private var musicAmbient = true

    private var palette: NowPlaying.Palette? {
        musicAmbient ? music.activePalette : nil
    }

    private var accentColor: Color {
        palette?.primaryColor ?? .cyan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerBar
            filterAndSearchBar

            if store.isLoading && store.items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.filteredItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(store.filteredItems) { item in
                            ProcRowView(item: item, accentColor: accentColor)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear {
            store.refresh()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Ports & Bash")
                .font(.headline)

            HStack(spacing: 4) {
                Circle().fill(Color.cyan).frame(width: 6, height: 6)
                Text("\(store.portCount) ports")
                    .font(.caption2.bold().monospacedDigit())
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.cyan.opacity(0.16), in: Capsule())
            .foregroundStyle(.cyan)

            HStack(spacing: 4) {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text("\(store.bashCount) bash/dev")
                    .font(.caption2.bold().monospacedDigit())
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.16), in: Capsule())
            .foregroundStyle(.orange)

            if !store.watchedPIDs.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 9))
                    Text("\(store.watchedPIDs.count) watching")
                        .font(.caption2.bold())
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.18), in: Capsule())
                .foregroundStyle(.green)
            }

            Spacer()

            if store.portCount > 0 {
                Button {
                    store.killAllPorts()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 10))
                        Text("Kill All Ports")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.18))
                            .overlay(Capsule().strokeBorder(Color.red.opacity(0.4), lineWidth: 0.8))
                    )
                }
                .buttonStyle(.plain)
                .help("Send SIGTERM to all listening dev port processes")
            }

            Button {
                store.refresh()
            } label: {
                if store.isLoading {
                    ProgressView().controlSize(.small).frame(width: 22, height: 22)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.08), in: Circle())
                }
            }
            .buttonStyle(.plain)
            .help("Refresh listening ports and running bash/dev processes")
        }
    }

    private var filterAndSearchBar: some View {
        HStack(spacing: 6) {
            ForEach(ProcsStore.Filter.allCases) { f in
                let selected = store.filter == f
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        store.filter = f
                    }
                } label: {
                    Text(f.rawValue)
                        .font(.caption2.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .white : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(selected ? accentColor.opacity(0.28) : Color.white.opacity(0.06))
                                .overlay(
                                    Capsule().strokeBorder(selected ? accentColor.opacity(0.55) : Color.clear, lineWidth: 0.8)
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Filter :3000, node, bash, project…", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.06), in: Capsule())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(store.searchText.isEmpty ? "No active dev ports or running bash scripts found" : "No processes match \"\(store.searchText)\"")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProcRowView: View {
    let item: DevProcItem
    let accentColor: Color
    @ObservedObject private var store = ProcsStore.shared

    private var isWatched: Bool {
        store.isWatching(item.pid)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Left Badge: Port(s) or BASH
            if let port = item.primaryPort {
                Button {
                    store.openPort(port)
                } label: {
                    HStack(spacing: 3) {
                        Text(":\(String(port))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Color.cyan)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.cyan.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.cyan.opacity(0.4), lineWidth: 0.8)
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("Open http://localhost:\(port) in browser")
            } else {
                Text("BASH")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.orange.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.orange.opacity(0.38), lineWidth: 0.8)
                            )
                    )
            }

            // Middle: Process Name, Project/CWD, Command & Metrics
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if let project = item.projectName {
                        Text(project)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(accentColor.opacity(0.14), in: Capsule())
                            .lineLimit(1)
                    }

                    if item.ports.count > 1 {
                        Text(item.ports.dropFirst().map { ":\($0)" }.joined(separator: " "))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)

                    Text(String(format: "%.1f%% CPU · %.0f MB · PID %d", item.cpuPercent, item.memoryMB, item.pid))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(item.shortCommand)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let cwd = item.displayCwd {
                        Text("· \(cwd)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }

            Spacer(minLength: 4)

            // Right Action Buttons: Watch, Graceful Stop (SIGTERM), Force Kill (SIGKILL -9)
            actionButtons
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(rowBackground)
        .hoverHighlight(radius: 9)
    }

    private var actionButtons: some View {
        let watchFill = isWatched ? Color.green.opacity(0.18) : Color.white.opacity(0.07)
        let watchBorder = isWatched ? Color.green.opacity(0.45) : Color.clear
        let watchColor = isWatched ? Color.green : Color.white.opacity(0.65)
        return HStack(spacing: 4) {
            Button {
                store.toggleWatch(item)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: isWatched ? "eye.fill" : "eye")
                        .font(.system(size: 9.5, weight: .semibold))
                    if isWatched {
                        Text("Watching")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                }
                .foregroundStyle(watchColor)
                .padding(.horizontal, isWatched ? 7 : 6)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(watchFill)
                        .overlay(Capsule().strokeBorder(watchBorder, lineWidth: 0.8))
                )
            }
            .buttonStyle(.plain)
            .help(isWatched ? "Stop watching PID \(item.pid) on closed notch" : "Watch PID \(item.pid) — flashes closed notch when it exits or crashes")

            Button {
                store.stop(item)
            } label: {
                Text("Stop")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.25))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.16))
                            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.38), lineWidth: 0.8))
                    )
            }
            .buttonStyle(.plain)
            .help("Graceful Stop (SIGTERM to PID \(item.pid) and child processes)")

            Button {
                store.forceKill(item)
            } label: {
                Text("Kill -9")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.22))
                            .overlay(Capsule().strokeBorder(Color.red.opacity(0.48), lineWidth: 0.8))
                    )
            }
            .buttonStyle(.plain)
            .help("Force Terminate (SIGKILL -9 to PID \(item.pid) and child processes)")
        }
    }

    private var rowBackground: some View {
        let fill = isWatched ? Color.green.opacity(0.06) : Color.white.opacity(0.035)
        let border = isWatched ? Color.green.opacity(0.28) : Color.white.opacity(0.07)
        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
    }
}
