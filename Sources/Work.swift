import AppKit
import SwiftUI

/// Preferred terminal application for opening project folders, running services, and launching agents.
enum TerminalApp: String, CaseIterable, Identifiable {
    case auto = "auto"
    case iterm = "iterm"
    case terminal = "terminal"
    case warp = "warp"
    case ghostty = "ghostty"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:     return "Auto (iTerm2 / Terminal)"
        case .iterm:    return "iTerm2"
        case .terminal: return "Terminal.app"
        case .warp:     return "Warp"
        case .ghostty:  return "Ghostty"
        }
    }
}

/// A saved project folder with its service command and preferred coding agent CLI command.
struct ProjectItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var serviceCommand: String
    var agentCommand: String

    var expandedPath: String {
        (path as NSString).expandingTildeInPath
    }

    var displayPath: String {
        (expandedPath as NSString).abbreviatingWithTildeInPath
    }

    var folderURL: URL {
        URL(fileURLWithPath: expandedPath)
    }
}

/// Manages saved projects, background service processes, and launching terminals / coding agents.
@MainActor
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    @Published var projects: [ProjectItem] = [] {
        didSet { saveProjects() }
    }
    @Published var agentPresets: [String] = [] {
        didSet { savePresets() }
    }
    @Published private(set) var runningIDs: Set<UUID> = []
    @Published private(set) var logs: [UUID: String] = [:]
    @Published private(set) var lastExitCode: [UUID: Int32] = [:]

    private var processes: [UUID: Process] = [:]
    private let projectsKey = "savedWorkProjects"
    private let presetsKey = "savedAgentPresets"

    static let defaultPresets = ["claude", "agy", "codex", "opencode", "aider"]

    private init() {
        if let data = UserDefaults.standard.data(forKey: presetsKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data),
           !decoded.isEmpty {
            agentPresets = decoded
        } else {
            agentPresets = Self.defaultPresets
        }

        if let data = UserDefaults.standard.data(forKey: projectsKey),
           let decoded = try? JSONDecoder().decode([ProjectItem].self, from: data) {
            projects = decoded
        } else {
            // Seed from ~/work if it exists on first launch.
            let initial = Work.folders().map { url in
                ProjectItem(
                    name: url.lastPathComponent,
                    path: url.path,
                    serviceCommand: Self.detectDefaultServiceCommand(for: url),
                    agentCommand: agentPresets.first ?? "claude"
                )
            }
            projects = initial
        }
    }

    // MARK: - CRUD

    func addFolder(_ url: URL, serviceCommand: String? = nil, agentCommand: String? = nil) {
        let cleanPath = url.path
        guard !projects.contains(where: { $0.expandedPath == cleanPath }) else { return }
        let cmd = (serviceCommand?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.detectDefaultServiceCommand(for: url)
        let agent = (agentCommand?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (UserDefaults.standard.string(forKey: Pref.defaultAgentCommand) ?? agentPresets.first ?? "claude")
        let item = ProjectItem(
            name: url.lastPathComponent.isEmpty ? cleanPath : url.lastPathComponent,
            path: cleanPath,
            serviceCommand: cmd,
            agentCommand: agent
        )
        projects.append(item)
    }

    func addPath(_ rawPath: String, serviceCommand: String? = nil, agentCommand: String? = nil) {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        addFolder(url, serviceCommand: serviceCommand, agentCommand: agentCommand)
    }

    func update(_ item: ProjectItem) {
        guard let idx = projects.firstIndex(where: { $0.id == item.id }) else { return }
        projects[idx] = item
    }

    func remove(_ id: UUID) {
        stopService(id)
        projects.removeAll { $0.id == id }
        logs.removeValue(forKey: id)
        lastExitCode.removeValue(forKey: id)
    }

    func importWorkFolders() {
        for url in Work.folders() {
            addFolder(url)
        }
    }

    func addAgentPreset(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !agentPresets.contains(cmd) else { return }
        agentPresets.append(cmd)
    }

    func removeAgentPreset(_ cmd: String) {
        agentPresets.removeAll { $0 == cmd }
        if agentPresets.isEmpty {
            agentPresets = Self.defaultPresets
        }
    }

    /// Opens a macOS directory picker so the user can choose one or more project folders.
    func pickFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Select Project Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls {
                addFolder(url)
            }
        }
    }

    // MARK: - Background Service Runner

    func isRunning(_ id: UUID) -> Bool {
        runningIDs.contains(id)
    }

    func toggleService(_ item: ProjectItem) {
        if isRunning(item.id) {
            stopService(item.id)
        } else {
            startService(item)
        }
    }

    func startService(_ item: ProjectItem) {
        let cmd = item.serviceCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        if isRunning(item.id) {
            stopService(item.id)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", cmd]
        proc.currentDirectoryURL = item.folderURL

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let id = item.id
        logs[id] = "$ \(cmd)\n"
        lastExitCode.removeValue(forKey: id)

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                let store = ProjectStore.shared
                var current = store.logs[id] ?? ""
                current.append(chunk)
                if current.count > 4000 {
                    current = String(current.suffix(4000))
                }
                store.logs[id] = current
            }
        }

        proc.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            Task { @MainActor in
                let store = ProjectStore.shared
                store.processes.removeValue(forKey: id)
                store.runningIDs.remove(id)
                store.lastExitCode[id] = status
            }
        }

        do {
            try proc.run()
            processes[id] = proc
            runningIDs.insert(id)
        } catch {
            logs[id, default: ""] += "\nFailed to start: \(error.localizedDescription)\n"
            lastExitCode[id] = -1
        }
    }

    func stopService(_ id: UUID) {
        guard let proc = processes[id] else {
            runningIDs.remove(id)
            return
        }
        let pid = proc.processIdentifier
        if pid > 0 {
            // Terminate child processes spawned by the login shell (e.g. node, vite, cargo, python).
            let killer = Process()
            killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killer.arguments = ["-TERM", "-P", "\(pid)"]
            try? killer.run()
            killer.waitUntilExit()
        }
        proc.terminate()
        processes.removeValue(forKey: id)
        runningIDs.remove(id)
        logs[id, default: ""] += "\n[Stopped]\n"
    }

    func clearLog(_ id: UUID) {
        logs[id] = ""
    }

    // MARK: - Terminal & Agent Launchers

    /// Opens the project folder in the user's preferred terminal without running an extra command.
    func openInTerminal(_ item: ProjectItem) {
        launchInTerminal(directory: item.expandedPath, command: nil)
    }

    /// Opens the project folder in the user's preferred terminal and runs its service command.
    func runServiceInTerminal(_ item: ProjectItem) {
        let cmd = item.serviceCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        launchInTerminal(directory: item.expandedPath, command: cmd.isEmpty ? nil : cmd)
    }

    /// Opens the project folder in the user's preferred terminal and launches the desired coding agent CLI.
    func openWithAgent(_ item: ProjectItem, overrideAgent: String? = nil) {
        let raw = (overrideAgent ?? item.agentCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = raw.isEmpty ? (agentPresets.first ?? "claude") : raw
        launchInTerminal(directory: item.expandedPath, command: cmd)
    }

    func openInFinder(_ item: ProjectItem) {
        NSWorkspace.shared.open(item.folderURL)
    }

    func openInVSCode(_ item: ProjectItem) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Visual Studio Code", item.expandedPath]
        try? p.run()
    }

    func launchInTerminal(directory: String, command: String?) {
        let prefRaw = UserDefaults.standard.string(forKey: Pref.preferredTerminal) ?? TerminalApp.auto.rawValue
        let preferred = TerminalApp(rawValue: prefRaw) ?? .auto

        let target: TerminalApp = {
            if preferred != .auto { return preferred }
            if FileManager.default.fileExists(atPath: "/Applications/iTerm.app") {
                return .iterm
            }
            return .terminal
        }()

        let quotedDir = Self.shellSingleQuote(directory)
        let fullShellCommand: String = {
            if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "cd \(quotedDir) && \(command)"
            } else {
                return "cd \(quotedDir) && clear"
            }
        }()

        DispatchQueue.global(qos: .userInitiated).async {
            switch target {
            case .iterm:
                if command == nil {
                    // If no command needs to run, `open -a iTerm <dir>` opens directly if AppleScript isn't needed,
                    // but AppleScript opens a clean tab in the current window.
                    if Self.runITermAppleScript(command: fullShellCommand) { return }
                    Self.openFolderWithApp("iTerm", directory: directory)
                } else {
                    if Self.runITermAppleScript(command: fullShellCommand) { return }
                    Self.launchViaCommandScript(app: "iTerm", directory: directory, command: command)
                }

            case .terminal:
                if command == nil {
                    if Self.runTerminalAppleScript(command: fullShellCommand) { return }
                    Self.openFolderWithApp("Terminal", directory: directory)
                } else {
                    if Self.runTerminalAppleScript(command: fullShellCommand) { return }
                    Self.launchViaCommandScript(app: "Terminal", directory: directory, command: command)
                }

            case .warp:
                if command == nil {
                    Self.openFolderWithApp("Warp", directory: directory)
                } else {
                    if !Self.runTerminalAppleScript(command: fullShellCommand) {
                        Self.launchViaCommandScript(app: "Terminal", directory: directory, command: command)
                    }
                }

            case .ghostty:
                if command == nil {
                    Self.openFolderWithApp("Ghostty", directory: directory)
                } else {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    p.arguments = ["-na", "Ghostty", "--args", "--working-directory=\(directory)", "-e", "/bin/zsh", "-lic", "\(command!); exec /bin/zsh -l"]
                    if (try? p.run()) != nil { return }
                    Self.launchViaCommandScript(app: "Terminal", directory: directory, command: command)
                }

            case .auto:
                break
            }
        }
    }

    private nonisolated static func runITermAppleScript(command: String) -> Bool {
        let escaped = appleScriptEscape(command)
        let script = """
        tell application "iTerm"
            activate
            if (count of windows) = 0 then
                create window with default profile
                tell current session of current window
                    write text "\(escaped)"
                end tell
            else
                tell current window
                    create tab with default profile
                    tell current session of current window
                        write text "\(escaped)"
                    end tell
                end tell
            end if
        end tell
        """
        return runOsascript(script)
    }

    private nonisolated static func runTerminalAppleScript(command: String) -> Bool {
        let escaped = appleScriptEscape(command)
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        return runOsascript(script)
    }

    private nonisolated static func runOsascript(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private nonisolated static func openFolderWithApp(_ app: String, directory: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app, directory]
        try? process.run()
    }

    /// Fallback when AppleEvents automation isn't authorized: writes a temporary `.command` script and opens it.
    private nonisolated static func launchViaCommandScript(app: String, directory: String, command: String?) {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bullshitnotch-\(UUID().uuidString.prefix(8)).command")
        let quotedDir = shellSingleQuote(directory)
        let quotedSelf = shellSingleQuote(fileURL.path)
        let body = """
        #!/bin/zsh -l
        rm -f \(quotedSelf)
        cd \(quotedDir) || exit 1
        \(command ?? "")
        exec /bin/zsh -l
        """
        do {
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", app, fileURL.path]
            try p.run()
        } catch {
            openFolderWithApp(app, directory: directory)
        }
    }

    private nonisolated static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Auto-detect Service Command

    static func detectDefaultServiceCommand(for folderURL: URL) -> String {
        let fm = FileManager.default
        let path = folderURL.path

        let pkgURL = folderURL.appendingPathComponent("package.json")
        if fm.fileExists(atPath: pkgURL.path) {
            let runner: String = {
                if fm.fileExists(atPath: folderURL.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm" }
                if fm.fileExists(atPath: folderURL.appendingPathComponent("bun.lockb").path) ||
                   fm.fileExists(atPath: folderURL.appendingPathComponent("bun.lock").path) { return "bun run" }
                if fm.fileExists(atPath: folderURL.appendingPathComponent("yarn.lock").path) { return "yarn" }
                return "npm run"
            }()
            if let data = try? Data(contentsOf: pkgURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let scripts = json["scripts"] as? [String: Any] {
                if scripts["dev"] != nil { return "\(runner) dev" }
                if scripts["start"] != nil { return runner == "npm run" ? "npm start" : "\(runner) start" }
                if scripts["serve"] != nil { return "\(runner) serve" }
            }
            return "\(runner) dev"
        }

        if fm.fileExists(atPath: "\(path)/build.sh") { return "./build.sh" }
        if fm.fileExists(atPath: "\(path)/Package.swift") { return "swift run" }
        if fm.fileExists(atPath: "\(path)/Cargo.toml") { return "cargo run" }
        if fm.fileExists(atPath: "\(path)/go.mod") { return "go run ." }
        if fm.fileExists(atPath: "\(path)/docker-compose.yml") || fm.fileExists(atPath: "\(path)/compose.yml") {
            return "docker compose up"
        }
        if fm.fileExists(atPath: "\(path)/manage.py") { return "python3 manage.py runserver" }
        if fm.fileExists(atPath: "\(path)/Makefile") { return "make" }
        return "npm run dev"
    }

    // MARK: - Persistence

    private func saveProjects() {
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: projectsKey)
        }
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(agentPresets) {
            UserDefaults.standard.set(data, forKey: presetsKey)
        }
    }
}

/// Legacy helper for ~/work discovery.
enum Work {
    static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("work")

    static func folders() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Project Runner View (Work Section)

struct ProjectRunnerView: View {
    @ObservedObject private var store = ProjectStore.shared
    @ObservedObject private var music = NowPlaying.shared
    @AppStorage(Pref.musicAmbient) private var musicAmbient = true

    @State private var addingInline = false
    @State private var newPath = ""
    @State private var newServiceCmd = ""
    @State private var newAgentCmd = ""
    @State private var expandedID: UUID?
    @State private var dropTargeted = false

    private var palette: NowPlaying.Palette? {
        musicAmbient ? music.activePalette : nil
    }

    private var accentColor: Color {
        palette?.primaryColor ?? .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerBar
            if addingInline {
                inlineAddBar
            }
            if store.projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.projects) { item in
                            ProjectRowView(
                                item: item,
                                isExpanded: expandedID == item.id,
                                accentColor: accentColor,
                                onToggleExpand: {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                        expandedID = (expandedID == item.id) ? nil : item.id
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                            let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
                            ProjectStore.shared.addFolder(folder)
                        }
                    }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Projects")
                .font(.headline)
            Text("\(store.projects.count)")
                .font(.caption.bold().monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.white.opacity(0.12), in: Capsule())

            if !store.runningIDs.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("\(store.runningIDs.count) running")
                        .font(.caption2.bold())
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.18), in: Capsule())
                .foregroundStyle(.green)
            }

            Spacer()

            if !Work.folders().isEmpty {
                Button {
                    store.importWorkFolders()
                } label: {
                    Label("Import ~/work", systemImage: "tray.and.arrow.down")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Import all project folders from ~/work")
            }

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    addingInline.toggle()
                    if addingInline && newAgentCmd.isEmpty {
                        newAgentCmd = store.agentPresets.first ?? "claude"
                    }
                }
            } label: {
                Label("Path", systemImage: addingInline ? "chevron.up" : "plus")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Type or paste a project folder path")

            Button {
                store.pickFolder()
            } label: {
                Label("Add Folder…", systemImage: "folder.badge.plus")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(accentColor.opacity(0.35), in: Capsule())
                    .overlay(Capsule().strokeBorder(accentColor.opacity(0.6), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("Choose a project folder from Finder")
        }
    }

    private var inlineAddBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("~/path/to/project", text: $newPath)
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .frame(minWidth: 140)
                .onSubmit(commitInlineAdd)

            Divider().frame(height: 14)

            Image(systemName: "bolt.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Run cmd (auto if empty)", text: $newServiceCmd)
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .frame(width: 130)
                .onSubmit(commitInlineAdd)

            Divider().frame(height: 14)

            Image(systemName: "sparkles")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Agent (e.g. claude, agy)", text: $newAgentCmd)
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .frame(width: 95)
                .onSubmit(commitInlineAdd)

            Button("Add", action: commitInlineAdd)
                .buttonStyle(.plain)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(accentColor.opacity(0.45), in: Capsule())
                .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)

            Button {
                addingInline = false
                newPath = ""
                newServiceCmd = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Add a project folder to run its service, open in Terminal, or launch with an AI agent")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button {
                    store.pickFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(accentColor.opacity(0.35), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    addingInline = true
                } label: {
                    Label("Paste Path", systemImage: "keyboard")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func commitInlineAdd() {
        let p = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        store.addPath(p, serviceCommand: newServiceCmd, agentCommand: newAgentCmd)
        newPath = ""
        newServiceCmd = ""
        addingInline = false
    }
}

private struct ProjectRowView: View {
    let item: ProjectItem
    let isExpanded: Bool
    let accentColor: Color
    let onToggleExpand: () -> Void

    @ObservedObject private var store = ProjectStore.shared
    @State private var serviceCmdDraft: String = ""
    @State private var agentCmdDraft: String = ""

    private var isRunning: Bool { store.isRunning(item.id) }
    private var logText: String { store.logs[item.id] ?? "" }
    private var exitCode: Int32? { store.lastExitCode[item.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Status indicator + folder icon
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.expandedPath))
                        .resizable()
                        .frame(width: 26, height: 26)
                    if isRunning {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                    } else if let code = exitCode, code != 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                    }
                }

                // Project Name + Path + Command summary
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(item.displayPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            Image(systemName: isRunning ? "bolt.fill" : "bolt")
                                .font(.system(size: 9))
                                .foregroundStyle(isRunning ? .green : .secondary)
                            Text(item.serviceCommand.isEmpty ? "no cmd" : item.serviceCommand)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(isRunning ? .green : .secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.06), in: Capsule())

                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                                .foregroundStyle(accentColor)
                            Text(item.agentCommand)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(accentColor.opacity(0.16), in: Capsule())
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleExpand)

                Spacer(minLength: 4)

                // Action Buttons
                HStack(spacing: 5) {
                    // 1. Background Start / Stop Service
                    Button {
                        store.toggleService(item)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(isRunning ? "Stop" : "Run")
                                .font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            (isRunning ? Color.red : Color.green).opacity(0.26),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder((isRunning ? Color.red : Color.green).opacity(0.55), lineWidth: 0.8)
                        )
                        .foregroundStyle(isRunning ? .red : .green)
                    }
                    .buttonStyle(.plain)
                    .help(isRunning ? "Stop background service (\(item.serviceCommand))" : "Run service in background (\(item.serviceCommand))")

                    // 2. Run Service in Terminal
                    Button {
                        store.runServiceInTerminal(item)
                    } label: {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 12))
                            .frame(width: 26, height: 24)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open Terminal & run service: \(item.serviceCommand)")

                    // 3. Open in Terminal (cd into folder)
                    Button {
                        store.openInTerminal(item)
                    } label: {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 11))
                            .frame(width: 26, height: 24)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open project folder in Terminal")

                    // 4. Open with Desired Agent in Terminal + Quick Agent Selector Menu
                    HStack(spacing: 0) {
                        Button {
                            store.openWithAgent(item)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Agent")
                                    .font(.caption2.weight(.semibold))
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 6)
                            .frame(height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Open in Terminal with \(item.agentCommand)")

                        Rectangle()
                            .fill(.white.opacity(0.2))
                            .frame(width: 1, height: 12)

                        Menu {
                            Section("Launch in Terminal with Agent") {
                                ForEach(store.agentPresets, id: \.self) { preset in
                                    Button {
                                        var updated = item
                                        updated.agentCommand = preset
                                        store.update(updated)
                                        agentCmdDraft = preset
                                        store.openWithAgent(updated, overrideAgent: preset)
                                    } label: {
                                        HStack {
                                            Text(preset)
                                            if item.agentCommand == preset {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Configure Custom Command…") {
                                if !isExpanded { onToggleExpand() }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 18, height: 24)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 18, height: 24)
                    }
                    .background(accentColor.opacity(0.28), in: Capsule())
                    .overlay(Capsule().strokeBorder(accentColor.opacity(0.55), lineWidth: 0.8))

                    // 5. Expand Config & Logs
                    Button(action: onToggleExpand) {
                        Image(systemName: isExpanded ? "chevron.up" : "slider.horizontal.3")
                            .font(.system(size: 11))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(isExpanded ? 0.18 : 0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Configure service command, custom agent CLI & view logs")
                }
            }

            if isExpanded {
                expandedEditor
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.white.opacity(isExpanded ? 0.075 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isRunning ? Color.green.opacity(0.45) : .white.opacity(0.07), lineWidth: 1)
        )
        .contextMenu {
            Button("Run Service in Background (\(item.serviceCommand))") { store.toggleService(item) }
            Button("Run Service in Terminal") { store.runServiceInTerminal(item) }
            Button("Open in Terminal") { store.openInTerminal(item) }
            Button("Open with Agent (\(item.agentCommand))") { store.openWithAgent(item) }
            Divider()
            Button("Open in Visual Studio Code") { store.openInVSCode(item) }
            Button("Show in Finder") { store.openInFinder(item) }
            Divider()
            Button("Remove Project", role: .destructive) { store.remove(item.id) }
        }
        .onAppear {
            serviceCmdDraft = item.serviceCommand
            agentCmdDraft = item.agentCommand
        }
    }

    private var expandedEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Service:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("npm run dev", text: $serviceCmdDraft)
                        .textFieldStyle(.plain)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                        .onSubmit(saveDrafts)
                }

                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(accentColor)
                    Text("Agent CLI:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("claude / agy / custom", text: $agentCmdDraft)
                        .textFieldStyle(.plain)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                        .onSubmit(saveDrafts)
                }

                Button("Save") {
                    saveDrafts()
                }
                .buttonStyle(.plain)
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(accentColor.opacity(0.35), in: Capsule())

                Button {
                    store.openInVSCode(item)
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption2)
                        .padding(4)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Open in VS Code")

                Button {
                    store.openInFinder(item)
                } label: {
                    Image(systemName: "folder")
                        .font(.caption2)
                        .padding(4)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                Button {
                    store.remove(item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(4)
                        .background(.red.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Remove project from list")
            }

            // Quick Agent Preset Pills
            HStack(spacing: 4) {
                Text("Presets:")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                ForEach(store.agentPresets, id: \.self) { preset in
                    Button {
                        agentCmdDraft = preset
                        saveDrafts()
                    } label: {
                        Text(preset)
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                agentCmdDraft == preset ? accentColor.opacity(0.42) : .white.opacity(0.07),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if !logText.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(isRunning ? "Live Service Output" : "Last Service Output")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(logText, forType: .string)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                        Button("Clear") {
                            store.clearLog(item.id)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(logText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 68)
                    .padding(6)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func saveDrafts() {
        var updated = item
        updated.serviceCommand = serviceCmdDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAgent = agentCmdDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAgent.isEmpty {
            updated.agentCommand = trimmedAgent
            store.addAgentPreset(trimmedAgent)
        }
        store.update(updated)
    }
}
