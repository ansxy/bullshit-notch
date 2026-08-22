import SwiftUI

/// What a custom item points at. Each maps to a URL macOS already knows how to open.
enum ItemKind: String, Codable, CaseIterable, Identifiable {
    case folder, ssh, url

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .folder: return "folder"
        case .ssh:    return "terminal"
        case .url:    return "link"
        }
    }
    var placeholder: String {
        switch self {
        case .folder: return "~/path/to/folder"
        case .ssh:    return "user@host"
        case .url:    return "https://…"
        }
    }
}

struct CustomItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: ItemKind
    var value: String

    /// URL to hand to NSWorkspace — file://, ssh://, or https:// as appropriate.
    var openURL: URL? {
        switch kind {
        case .folder:
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        case .ssh:
            return URL(string: value.hasPrefix("ssh://") ? value : "ssh://\(value)")
        case .url:
            return URL(string: value.contains("://") ? value : "https://\(value)")
        }
    }
}

struct CustomSection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var items: [CustomItem] = []
}

/// User-defined sections, persisted to UserDefaults.
@MainActor
final class CustomStore: ObservableObject {
    @Published var sections: [CustomSection] = [] { didSet { save() } }
    private let key = "customSections"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([CustomSection].self, from: data) {
            sections = decoded
        }
    }

    func addSection(named name: String) {
        sections.append(CustomSection(name: name))
    }

    func removeSection(_ id: UUID) {
        sections.removeAll { $0.id == id }
    }

    func addItem(_ item: CustomItem, to sectionID: UUID) {
        guard let i = sections.firstIndex(where: { $0.id == sectionID }) else { return }
        sections[i].items.append(item)
    }

    func removeItem(_ itemID: UUID, from sectionID: UUID) {
        guard let i = sections.firstIndex(where: { $0.id == sectionID }) else { return }
        sections[i].items.removeAll { $0.id == itemID }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sections) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
