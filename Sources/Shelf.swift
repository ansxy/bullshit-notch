import AppKit
import UniformTypeIdentifiers

/// Files dropped onto the notch, kept by path (not copied) and persisted across launches.
@MainActor
final class Shelf: ObservableObject {
    static let shared = Shelf()

    @Published private(set) var items: [URL] = [] { didSet { save() } }
    private let key = "shelfItems"

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map(URL.init(fileURLWithPath:)).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        items += urls.filter { !items.contains($0) }
    }

    /// Pulls file URLs out of a SwiftUI drop and adds them.
    func add(from providers: [NSItemProvider]) {
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { Shelf.shared.add([url]) }
            }
        }
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
    }

    func clear() {
        items = []
    }

    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)  // the AirDrop sheet needs us frontmost
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    /// Same as `add(from:)` but sends the dropped files straight to AirDrop.
    static func airDrop(from providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url, url.isFileURL { urls.append(url) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { airDrop(urls) }
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: key)
    }
}
