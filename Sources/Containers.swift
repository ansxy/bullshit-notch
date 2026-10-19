import AppKit
import SwiftUI

/// Which container CLI backend to query.
enum ContainerCLI: String, CaseIterable, Identifiable {
    case auto = "auto"
    case docker = "docker"
    case podman = "podman"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:   return "Auto"
        case .docker: return "Docker / OrbStack"
        case .podman: return "Podman"
        }
    }
}

/// A single container returned by `docker ps -a` or `podman ps -a`.
struct ContainerItem: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let state: String       // "running", "exited", "paused", "created", etc.
    let status: String      // "Up 2 hours", "Exited (0) 5 minutes ago"
    let ports: [Int]        // Host ports mapped to this container (e.g. [3000, 8080])
    let rawPorts: String
    let composeProject: String?
    let cli: String         // "docker" or "podman"

    var isRunning: Bool {
        state.lowercased() == "running"
    }
}

/// Discovers and manages Docker / OrbStack / Podman engines and containers.
@MainActor
final class ContainerStore: ObservableObject {
    static let shared = ContainerStore()

    @Published private(set) var containers: [ContainerItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var activeBackendName = "Docker"
    @Published private(set) var engineRunning = false
    @Published private(set) var orbStackInstalled = false
    @Published private(set) var orbStackRunning = false
    @Published private(set) var podmanInstalled = false
    @Published private(set) var podmanRunning = false
    @Published private(set) var busyContainerIDs: Set<String> = []
    @Published private(set) var engineActionBusy = false
    @Published private(set) var containerLogs: [String: String] = [:]
    @Published private(set) var errorMessage: String?

    private var pollTimer: Timer?
    private var isDemo = false

    private init() {
        if CommandLine.arguments.contains("--demo") {
            loadDemoData()
        }
    }

    func loadDemoData() {
        isDemo = true
        engineRunning = true
        orbStackInstalled = true
        orbStackRunning = true
        activeBackendName = "OrbStack"
        containers = [
            ContainerItem(id: "c1a2b3c4d5e6", name: "postgres-prod-local", image: "postgres:16-alpine", state: "running", status: "Up 4 hours", ports: [5432], rawPorts: "0.0.0.0:5432->5432/tcp", composeProject: "bullshit-stack", cli: "docker"),
            ContainerItem(id: "f6e5d4c3b2a1", name: "redis-cache", image: "redis:7-alpine", state: "running", status: "Up 4 hours", ports: [6379], rawPorts: "0.0.0.0:6379->6379/tcp", composeProject: "bullshit-stack", cli: "docker"),
            ContainerItem(id: "998877665544", name: "otel-collector", image: "otel/opentelemetry-collector:latest", state: "exited", status: "Exited (0) 12 minutes ago", ports: [], rawPorts: "", composeProject: "monitoring", cli: "docker")
        ]
    }

    func startPolling() {
        if isDemo { return }
        refresh()
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                ContainerStore.shared.refresh(silent: true)
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh(silent: Bool = false) {
        if isDemo { return }
        if !silent { isLoading = true }
        let cliPrefRaw = UserDefaults.standard.string(forKey: Pref.containerCLI) ?? ContainerCLI.auto.rawValue
        let cliPref = ContainerCLI(rawValue: cliPrefRaw) ?? .auto

        Task.detached(priority: .userInitiated) {
            let status = Self.probeEnvironment(preference: cliPref)
            await MainActor.run {
                let store = ContainerStore.shared
                store.orbStackInstalled = status.orbStackInstalled
                store.orbStackRunning = status.orbStackRunning
                store.podmanInstalled = status.podmanInstalled
                store.podmanRunning = status.podmanRunning
                store.activeBackendName = status.backendLabel
                store.engineRunning = status.engineRunning
                store.containers = status.containers
                store.errorMessage = status.error
                store.isLoading = false
            }
        }
    }

    // MARK: - Container Actions

    func toggleContainer(_ item: ContainerItem) {
        performAction(item, action: item.isRunning ? "stop" : "start")
    }

    func restartContainer(_ item: ContainerItem) {
        performAction(item, action: "restart")
    }

    func removeContainer(_ item: ContainerItem) {
        performAction(item, action: "rm", extraArgs: ["-f"])
    }

    private func performAction(_ item: ContainerItem, action: String, extraArgs: [String] = []) {
        busyContainerIDs.insert(item.id)
        let cli = item.cli
        let id = item.id
        Task.detached(priority: .userInitiated) {
            guard let bin = Self.findBinary(cli) else {
                _ = await MainActor.run {
                    ContainerStore.shared.busyContainerIDs.remove(id)
                }
                return
            }
            _ = Self.runCommand(bin, extraArgs + [action, id])
            await MainActor.run {
                let store = ContainerStore.shared
                store.busyContainerIDs.remove(id)
                store.refresh(silent: true)
            }
        }
    }

    func fetchLogs(for item: ContainerItem) {
        let cli = item.cli
        let id = item.id
        Task.detached(priority: .userInitiated) {
            guard let bin = Self.findBinary(cli) else { return }
            let res = Self.runCommand(bin, ["logs", "--tail", "80", id])
            let combined = (res.stdout + (res.stderr.isEmpty ? "" : "\n" + res.stderr))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                ContainerStore.shared.containerLogs[id] = combined.isEmpty ? "(No log output)" : combined
            }
        }
    }

    /// Opens an interactive shell (`bash` or `sh`) inside the container in the user's preferred terminal.
    func openShellInTerminal(_ item: ContainerItem) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cmd = "\(item.cli) exec -it \(Self.shellQuote(item.name)) /bin/sh -c 'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'"
        ProjectStore.shared.launchInTerminal(directory: home, command: cmd)
    }

    /// Opens live streaming container logs (`logs -f`) in the user's preferred terminal.
    func openLogsInTerminal(_ item: ContainerItem) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cmd = "\(item.cli) logs -f --tail 200 \(Self.shellQuote(item.name))"
        ProjectStore.shared.launchInTerminal(directory: home, command: cmd)
    }

    func openPortInBrowser(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Engine Controls (OrbStack & Podman)

    func toggleOrbStack() {
        engineActionBusy = true
        let currentlyRunning = orbStackRunning
        Task.detached(priority: .userInitiated) {
            if currentlyRunning {
                if let orbctl = Self.findBinary("orbctl") ?? Self.findBinary("orb") {
                    _ = Self.runCommand(orbctl, ["stop"])
                } else {
                    _ = Self.runCommand("/usr/bin/killall", ["OrbStack"])
                }
            } else {
                if let orbctl = Self.findBinary("orbctl") ?? Self.findBinary("orb") {
                    _ = Self.runCommand(orbctl, ["start"])
                } else {
                    _ = Self.runCommand("/usr/bin/open", ["-a", "OrbStack"])
                }
            }
            try? await Task.sleep(for: .milliseconds(900))
            await MainActor.run {
                let store = ContainerStore.shared
                store.engineActionBusy = false
                store.refresh()
            }
        }
    }

    func openOrbStackApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "OrbStack"]
        try? p.run()
    }

    func togglePodmanMachine() {
        engineActionBusy = true
        let currentlyRunning = podmanRunning
        Task.detached(priority: .userInitiated) {
            if let podman = Self.findBinary("podman") {
                _ = Self.runCommand(podman, ["machine", currentlyRunning ? "stop" : "start"])
            }
            try? await Task.sleep(for: .milliseconds(900))
            await MainActor.run {
                let store = ContainerStore.shared
                store.engineActionBusy = false
                store.refresh()
            }
        }
    }

    // MARK: - CLI Discovery & Parsing

    private struct ProbeResult {
        var orbStackInstalled: Bool
        var orbStackRunning: Bool
        var podmanInstalled: Bool
        var podmanRunning: Bool
        var backendLabel: String
        var engineRunning: Bool
        var containers: [ContainerItem]
        var error: String?
    }

    private nonisolated static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.orbstack/bin",
            "/Applications/OrbStack.app/Contents/MacOS/xbin",
            "/Applications/OrbStack.app/Contents/MacOS/bin",
            "/opt/podman/bin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
    }

    private nonisolated static func findBinary(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in searchPaths {
            let full = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }

    private nonisolated static func runCommand(_ executable: String, _ args: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPaths.joined(separator: ":")
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        guard (try? process.run()) != nil else {
            return (-1, "", "Failed to run \(executable)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    private nonisolated static func probeEnvironment(preference: ContainerCLI) -> ProbeResult {
        let fm = FileManager.default
        let orbInstalled = fm.fileExists(atPath: "/Applications/OrbStack.app") || findBinary("orbctl") != nil
        let podmanBin = findBinary("podman")
        let dockerBin = findBinary("docker")
        let podInstalled = podmanBin != nil

        // Check OrbStack running status
        var orbRunning = false
        if orbInstalled {
            if let orbctl = findBinary("orbctl") ?? findBinary("orb") {
                let st = runCommand(orbctl, ["status"])
                orbRunning = st.status == 0 && st.stdout.lowercased().contains("running")
            } else {
                let pgrep = runCommand("/usr/bin/pgrep", ["-f", "OrbStack"])
                orbRunning = pgrep.status == 0
            }
        }

        // Check Podman running status
        var podRunning = false
        if let podmanBin {
            let info = runCommand(podmanBin, ["machine", "list", "--format", "{{.Running}}"])
            if info.status == 0 && info.stdout.lowercased().contains("true") {
                podRunning = true
            }
        }

        // Decide which CLI to query for containers
        let usePodman: Bool = {
            switch preference {
            case .docker: return false
            case .podman: return true
            case .auto:
                if dockerBin != nil && (orbRunning || !podRunning) { return false }
                if podmanBin != nil && podRunning { return true }
                return dockerBin == nil && podmanBin != nil
            }
        }()

        if usePodman, let podmanBin {
            let res = runCommand(podmanBin, ["ps", "-a", "--format", "json"])
            if res.status == 0 {
                let list = parsePodmanJSON(res.stdout)
                return ProbeResult(
                    orbStackInstalled: orbInstalled,
                    orbStackRunning: orbRunning,
                    podmanInstalled: podInstalled,
                    podmanRunning: true,
                    backendLabel: "Podman",
                    engineRunning: true,
                    containers: list,
                    error: nil
                )
            } else {
                return ProbeResult(
                    orbStackInstalled: orbInstalled,
                    orbStackRunning: orbRunning,
                    podmanInstalled: podInstalled,
                    podmanRunning: podRunning,
                    backendLabel: "Podman",
                    engineRunning: false,
                    containers: [],
                    error: "Podman machine is not running."
                )
            }
        } else if let dockerBin {
            let res = runCommand(dockerBin, ["ps", "-a", "--format", "{{json .}}"])
            let label = orbInstalled ? "OrbStack" : "Docker"
            if res.status == 0 {
                let list = parseDockerNDJSON(res.stdout, cli: "docker")
                return ProbeResult(
                    orbStackInstalled: orbInstalled,
                    orbStackRunning: orbInstalled ? true : orbRunning,
                    podmanInstalled: podInstalled,
                    podmanRunning: podRunning,
                    backendLabel: label,
                    engineRunning: true,
                    containers: list,
                    error: nil
                )
            } else {
                // If auto mode and Podman is running while Docker isn't, fall back to Podman!
                if preference == .auto, let podmanBin {
                    let podRes = runCommand(podmanBin, ["ps", "-a", "--format", "json"])
                    if podRes.status == 0 {
                        let list = parsePodmanJSON(podRes.stdout)
                        return ProbeResult(
                            orbStackInstalled: orbInstalled,
                            orbStackRunning: orbRunning,
                            podmanInstalled: podInstalled,
                            podmanRunning: true,
                            backendLabel: "Podman",
                            engineRunning: true,
                            containers: list,
                            error: nil
                        )
                    }
                }
                return ProbeResult(
                    orbStackInstalled: orbInstalled,
                    orbStackRunning: orbRunning,
                    podmanInstalled: podInstalled,
                    podmanRunning: podRunning,
                    backendLabel: label,
                    engineRunning: false,
                    containers: [],
                    error: "\(label) engine is stopped."
                )
            }
        } else {
            return ProbeResult(
                orbStackInstalled: orbInstalled,
                orbStackRunning: orbRunning,
                podmanInstalled: podInstalled,
                podmanRunning: podRunning,
                backendLabel: "Docker / Podman",
                engineRunning: false,
                containers: [],
                error: "Neither docker nor podman CLI was found."
            )
        }
    }

    private nonisolated static func parseDockerNDJSON(_ text: String, cli: String) -> [ContainerItem] {
        var items: [ContainerItem] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = (obj["ID"] as? String) ?? (obj["Id"] as? String) ?? UUID().uuidString
            let name = (obj["Names"] as? String) ?? id
            let image = (obj["Image"] as? String) ?? ""
            let state = (obj["State"] as? String) ?? "unknown"
            let status = (obj["Status"] as? String) ?? state
            let portsStr = (obj["Ports"] as? String) ?? ""
            let labelsStr = (obj["Labels"] as? String) ?? ""
            let compose = extractComposeProject(from: labelsStr)
            let ports = extractHostPorts(from: portsStr)
            items.append(ContainerItem(
                id: String(id.prefix(12)),
                name: name.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                image: image,
                state: state,
                status: status,
                ports: ports,
                rawPorts: portsStr,
                composeProject: compose,
                cli: cli
            ))
        }
        return sortContainers(items)
    }

    private nonisolated static func parsePodmanJSON(_ text: String) -> [ContainerItem] {
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return parseDockerNDJSON(text, cli: "podman")
        }
        var items: [ContainerItem] = []
        for obj in arr {
            let fullID = (obj["Id"] as? String) ?? (obj["ID"] as? String) ?? UUID().uuidString
            let id = String(fullID.prefix(12))
            let name: String = {
                if let names = obj["Names"] as? [String], let first = names.first { return first }
                if let n = obj["Names"] as? String { return n }
                return id
            }()
            let image = (obj["Image"] as? String) ?? ""
            let state = (obj["State"] as? String) ?? "unknown"
            let status = (obj["Status"] as? String) ?? state
            var ports: [Int] = []
            if let portArr = obj["Ports"] as? [[String: Any]] {
                for p in portArr {
                    if let hp = p["host_port"] as? Int, hp > 0, !ports.contains(hp) {
                        ports.append(hp)
                    } else if let hp = p["hostPort"] as? Int, hp > 0, !ports.contains(hp) {
                        ports.append(hp)
                    }
                }
            } else if let portStr = obj["Ports"] as? String {
                ports = extractHostPorts(from: portStr)
            }
            var compose: String? = nil
            if let labels = obj["Labels"] as? [String: Any] {
                compose = (labels["com.docker.compose.project"] as? String)
                    ?? (labels["io.podman.compose.project"] as? String)
            }
            items.append(ContainerItem(
                id: id,
                name: name,
                image: image,
                state: state,
                status: status,
                ports: ports.sorted(),
                rawPorts: ports.map { ":\($0)" }.joined(separator: ", "),
                composeProject: compose,
                cli: "podman"
            ))
        }
        return sortContainers(items)
    }

    private nonisolated static func extractHostPorts(from text: String) -> [Int] {
        // Matches patterns like 0.0.0.0:3000->3000/tcp or :::8080->80/tcp
        var result: [Int] = []
        let parts = text.components(separatedBy: "->")
        for chunk in parts.dropLast() {
            if let colonIdx = chunk.lastIndex(of: ":") {
                let portSub = chunk[chunk.index(after: colonIdx)...]
                if let port = Int(portSub), port > 0, !result.contains(port) {
                    result.append(port)
                }
            }
        }
        return result.sorted()
    }

    private nonisolated static func extractComposeProject(from labels: String) -> String? {
        for pair in labels.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && (kv[0] == "com.docker.compose.project" || kv[0] == "io.podman.compose.project") {
                return String(kv[1])
            }
        }
        return nil
    }

    private nonisolated static func sortContainers(_ list: [ContainerItem]) -> [ContainerItem] {
        list.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning && !$1.isRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Containers View

struct ContainersView: View {
    @ObservedObject private var store = ContainerStore.shared
    @ObservedObject private var music = NowPlaying.shared
    @AppStorage(Pref.musicAmbient) private var musicAmbient = true
    @AppStorage(Pref.containerCLI) private var containerCLI = ContainerCLI.auto.rawValue

    @State private var runningOnly = false
    @State private var expandedID: String?

    private var palette: NowPlaying.Palette? {
        musicAmbient ? music.activePalette : nil
    }

    private var accentColor: Color {
        palette?.primaryColor ?? .cyan
    }

    private var filteredContainers: [ContainerItem] {
        runningOnly ? store.containers.filter(\.isRunning) : store.containers
    }

    private var runningCount: Int {
        store.containers.filter(\.isRunning).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerBar
            if !store.engineRunning {
                engineOfflineView
            } else if filteredContainers.isEmpty {
                emptyContainersView
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredContainers) { item in
                            ContainerRowView(
                                item: item,
                                isExpanded: expandedID == item.id,
                                accentColor: accentColor,
                                onToggleExpand: {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                        if expandedID == item.id {
                                            expandedID = nil
                                        } else {
                                            expandedID = item.id
                                            store.fetchLogs(for: item)
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(store.engineRunning ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text("Containers")
                    .font(.headline)
            }

            if store.engineRunning {
                Text("\(runningCount)/\(store.containers.count) running")
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((runningCount > 0 ? Color.green : Color.white).opacity(0.16), in: Capsule())
                    .foregroundStyle(runningCount > 0 ? .green : .secondary)
            }

            // Filter pill: All vs Running
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { runningOnly.toggle() }
            } label: {
                Text(runningOnly ? "Running Only" : "All")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(runningOnly ? accentColor.opacity(0.32) : .white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Toggle between all containers and running containers only")

            Spacer()

            Button {
                store.refresh()
            } label: {
                if store.isLoading {
                    ProgressView().controlSize(.small).frame(width: 24, height: 24)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.08), in: Circle())
                }
            }
            .buttonStyle(.plain)
            .help("Refresh containers")
        }
    }

    private var engineOfflineView: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(store.errorMessage ?? "Container engine is stopped")
                .font(.callout.weight(.medium))
            Text("Start OrbStack or Podman to view and control your containers.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if store.orbStackInstalled {
                    Button {
                        store.toggleOrbStack()
                    } label: {
                        Label("Start OrbStack", systemImage: "play.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.green.opacity(0.32), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.green.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.engineActionBusy)
                }
                if store.podmanInstalled {
                    Button {
                        store.togglePodmanMachine()
                    } label: {
                        Label("Start Podman Machine", systemImage: "play.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.purple.opacity(0.32), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.purple.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.engineActionBusy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyContainersView: some View {
        VStack(spacing: 6) {
            Image(systemName: "shippingbox")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(runningOnly ? "No running containers" : "No containers found")
                .font(.callout)
                .foregroundStyle(.secondary)
            if runningOnly && !store.containers.isEmpty {
                Button("Show All (\(store.containers.count))") {
                    runningOnly = false
                }
                .buttonStyle(.plain)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.white.opacity(0.1), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ContainerRowView: View {
    let item: ContainerItem
    let isExpanded: Bool
    let accentColor: Color
    let onToggleExpand: () -> Void

    @ObservedObject private var store = ContainerStore.shared
    private var isBusy: Bool { store.busyContainerIDs.contains(item.id) }
    private var logText: String { store.containerLogs[item.id] ?? "Loading logs…" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Status dot
                Circle()
                    .fill(item.isRunning ? Color.green : Color.white.opacity(0.28))
                    .frame(width: 9, height: 9)
                    .shadow(color: item.isRunning ? Color.green.opacity(0.6) : .clear, radius: 3)

                // Container Name, Image, Compose Stack, Status
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if let stack = item.composeProject {
                            Text(stack)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(accentColor.opacity(0.2), in: Capsule())
                                .foregroundStyle(accentColor)
                        }
                        Text(item.image)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: 6) {
                        Text(item.status)
                            .font(.system(size: 10))
                            .foregroundStyle(item.isRunning ? .green.opacity(0.9) : .secondary)
                            .lineLimit(1)

                        // Clickable Exposed Host Ports -> open http://localhost:<port>
                        ForEach(item.ports, id: \.self) { port in
                            Button {
                                store.openPortInBrowser(port)
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "globe")
                                        .font(.system(size: 8))
                                    Text(":\(String(port))")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.cyan.opacity(0.22), in: Capsule())
                                .foregroundStyle(.cyan)
                            }
                            .buttonStyle(.plain)
                            .help("Open http://localhost:\(port) in browser")
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleExpand)

                Spacer(minLength: 4)

                // Container Action Buttons
                HStack(spacing: 5) {
                    if isBusy {
                        ProgressView().controlSize(.small).frame(width: 48, height: 24)
                    } else {
                        // 1. Start / Stop
                        Button {
                            store.toggleContainer(item)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: item.isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text(item.isRunning ? "Stop" : "Start")
                                    .font(.caption2.weight(.semibold))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background((item.isRunning ? Color.red : Color.green).opacity(0.25), in: Capsule())
                            .overlay(
                                Capsule().strokeBorder((item.isRunning ? Color.red : Color.green).opacity(0.55), lineWidth: 0.8)
                            )
                            .foregroundStyle(item.isRunning ? .red : .green)
                        }
                        .buttonStyle(.plain)
                        .help(item.isRunning ? "Stop container" : "Start container")

                        // 2. Restart (when running)
                        if item.isRunning {
                            Button {
                                store.restartContainer(item)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 24, height: 24)
                                    .background(.white.opacity(0.08), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Restart container")
                        }
                    }

                    // 3. Exec Shell in Terminal (when running)
                    if item.isRunning {
                        Button {
                            store.openShellInTerminal(item)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 10))
                                Text("Shell")
                                    .font(.caption2.weight(.medium))
                            }
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background(accentColor.opacity(0.24), in: Capsule())
                            .overlay(Capsule().strokeBorder(accentColor.opacity(0.5), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Open interactive shell (\(item.cli) exec -it \(item.name) sh/bash) in Terminal")
                    }

                    // 4. Stream Logs in Terminal
                    Button {
                        store.openLogsInTerminal(item)
                    } label: {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 11))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stream live logs (\(item.cli) logs -f \(item.name)) in Terminal")

                    // 5. Expand Inline Logs & Remove
                    Button(action: onToggleExpand) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(isExpanded ? 0.18 : 0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Preview container logs inside notch")
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Divider().opacity(0.4)
                    HStack {
                        Text("Container ID: \(item.id)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh Logs") {
                            store.fetchLogs(for: item)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                        Button("Copy Logs") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(logText, forType: .string)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                        Button {
                            store.removeContainer(item)
                        } label: {
                            Label("Remove", systemImage: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Force remove container (\(item.cli) rm -f \(item.name))")
                    }

                    ScrollView {
                        Text(logText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 74)
                    .padding(6)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.white.opacity(isExpanded ? 0.075 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(item.isRunning ? Color.green.opacity(0.40) : .white.opacity(0.07), lineWidth: 1)
        )
        .contextMenu {
            Button(item.isRunning ? "Stop Container" : "Start Container") { store.toggleContainer(item) }
            if item.isRunning {
                Button("Restart Container") { store.restartContainer(item) }
                Button("Open Shell in Terminal") { store.openShellInTerminal(item) }
            }
            Button("Stream Logs in Terminal") { store.openLogsInTerminal(item) }
            ForEach(item.ports, id: \.self) { port in
                Button("Open http://localhost:\(port)") { store.openPortInBrowser(port) }
            }
            Divider()
            Button("Remove Container", role: .destructive) { store.removeContainer(item) }
        }
    }
}
