import AppKit

/// Lists the project folders under ~/work/.
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

    /// Plain click → Finder, Shift → VS Code, Shift+Cmd → iTerm.
    static func open(_ url: URL) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) && flags.contains(.command) {
            openWith("iTerm", url)
        } else if flags.contains(.shift) {
            openWith("Visual Studio Code", url)
        } else if flags.contains(.shift) && flags.contains(.option) {
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private static func openWith(_ app: String, _ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app, url.path]
        try? process.run()
    }
}
