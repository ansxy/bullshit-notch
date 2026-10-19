import SwiftUI

/// A selectable top-level tab: a built-in section or a user-created one.
enum Tab: Hashable {
    case builtin(AppSection)
    case custom(UUID)
}

struct ContentView: View {
    @EnvironmentObject private var store: PullRequestStore
    @EnvironmentObject private var custom: CustomStore
    @State private var selection: Tab?
    @State private var selectedList: PRList = .mine
    @State private var appeared = false
    @State private var showAddSection = false
    @State private var newSectionName = ""

    private var pullRequests: [PullRequest] { store.pullRequests(for: selectedList) }

    var body: some View {
        VStack(spacing: 0) {
            sectionBar
            if showAddSection {
                Divider()
                addSectionRow
            }
            if let selection {
                Divider()
                expanded(for: selection)
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -8)
        .onAppear {
            store.start()
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
        }
    }

    /// Inline "new section" form — inline because MenuBarExtra can't focus modal sheets/alerts.
    private var addSectionRow: some View {
        HStack {
            TextField("Section name", text: $newSectionName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitSection)
            Button("Add", action: commitSection)
                .disabled(newSectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { showAddSection = false; newSectionName = "" }
        }
        .padding(8)
    }

    private func commitSection() {
        let name = newSectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        custom.addSection(named: name)
        newSectionName = ""
        showAddSection = false
    }

    @ViewBuilder
    private func expanded(for tab: Tab) -> some View {
        switch tab {
        case .builtin(.git):
            subTabBar
            Divider()
            content
        case .builtin(.work):
            WorkView()
        case .builtin(.containers):
            ContainersView()
        case .builtin(.agents):
            AgentsView()
        case .custom(let id):
            CustomSectionView(sectionID: id)
        }
    }

    /// Top row of section tabs. Tapping a section toggles it open/closed.
    private var sectionBar: some View {
        HStack(spacing: 6) {
            ForEach(AppSection.allCases) { section in
                tabButton(.builtin(section), label: section.rawValue, icon: section.icon)
            }
            ForEach(custom.sections) { section in
                tabButton(.custom(section.id), label: section.name, icon: "star")
                    .contextMenu {
                        Button("Delete Section", role: .destructive) {
                            if selection == .custom(section.id) { selection = nil }
                            custom.removeSection(section.id)
                        }
                    }
            }
            Button(action: { showAddSection = true }) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add a section")

            Spacer()
            Button(action: { Task { await store.refresh() } }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isLoading)
        }
        .padding(8)
    }

    private func tabButton(_ tab: Tab, label: String, icon: String) -> some View {
        Button(action: { toggle(tab) }) {
            Label(label, systemImage: icon)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(selection == tab ? Color.accentColor.opacity(0.2) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// Second row: the two PR lists, shown only while a section is open.
    private var subTabBar: some View {
        Picker("", selection: $selectedList) {
            ForEach(PRList.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(8)
    }

    private func toggle(_ tab: Tab) {
        withAnimation(.easeInOut(duration: 0.18)) {
            selection = (selection == tab) ? nil : tab
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && pullRequests.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if let errorMessage = store.errorMessage {
            Text(errorMessage).foregroundStyle(.red).padding()
        } else if pullRequests.isEmpty {
            Text("No open PRs").foregroundStyle(.secondary).padding()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(pullRequests) { pr in
                        PullRequestRow(
                            pullRequest: pr,
                            reviewed: selectedList == .review
                                ? store.reviewedURLs.contains(pr.url) : nil,
                            mergeStatus: selectedList == .mine ? store.mergeStatus[pr.url] : nil
                        )
                        Divider()
                    }
                }
            }
            .frame(minHeight: 320, maxHeight: 500)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .padding(8)
    }
}

private struct WorkView: View {
    private let folders = Work.folders()

    var body: some View {
        if folders.isEmpty {
            Text("No folders in ~/work").foregroundStyle(.secondary).padding()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(folders, id: \.path) { url in
                        Button(action: { Work.open(url) }) {
                            Label(url.lastPathComponent, systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 320, maxHeight: 500)
        }
    }
}

struct CustomSectionView: View {
    @EnvironmentObject private var custom: CustomStore
    let sectionID: UUID
    @State private var showAddItem = false

    private var items: [CustomItem] {
        custom.sections.first { $0.id == sectionID }?.items ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if showAddItem {
                addItemForm
                Divider()
            }
            if items.isEmpty {
                if !showAddItem { emptyState }
            } else {
                if !showAddItem {
                    HStack {
                        Spacer()
                        Button(action: { showAddItem = true }) { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("Add item")
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }
                list
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Button(action: { showAddItem = true }) {
                Image(systemName: "plus.circle").font(.system(size: 44))
            }
            .buttonStyle(.plain)
            Text("Add a folder, SSH, or URL")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    Button(action: { open(item) }) {
                        Label(item.name, systemImage: item.kind.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            custom.removeItem(item.id, from: sectionID)
                        }
                    }
                    Divider()
                }
            }
        }
        .frame(minHeight: 260, maxHeight: 420)
    }

    /// Inline add-item form (MenuBarExtra can't focus modal sheets).
    @State private var newName = ""
    @State private var newKind: ItemKind = .folder
    @State private var newValue = ""

    private var addItemForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $newName)
            Picker("Type", selection: $newKind) {
                ForEach(ItemKind.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField(newKind.placeholder, text: $newValue)
                .onSubmit(commitItem)
            HStack {
                Spacer()
                Button("Cancel") { resetForm() }
                Button("Add", action: commitItem)
                    .disabled(newName.isEmpty || newValue.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(8)
    }

    private func commitItem() {
        guard !newName.isEmpty, !newValue.isEmpty else { return }
        custom.addItem(CustomItem(name: newName, kind: newKind, value: newValue), to: sectionID)
        resetForm()
    }

    private func resetForm() {
        newName = ""; newValue = ""; newKind = .folder
        showAddItem = false
    }

    private func open(_ item: CustomItem) {
        guard let url = item.openURL else { return }
        NSWorkspace.shared.open(url)
    }
}

struct PullRequestRow: View {
    let pullRequest: PullRequest
    /// nil = don't show review state (e.g. the "Mine" tab).
    var reviewed: Bool? = nil
    /// GitHub mergeStateStatus; nil = don't show the merge dot (e.g. the "To Review" tab).
    var mergeStatus: String? = nil

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 6) {
                if let reviewed {
                    Image(systemName: reviewed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(reviewed ? .green : .secondary)
                        .help(reviewed ? "You reviewed this" : "Not reviewed yet")
                }
                if let mergeStatus {
                    Circle()
                        .fill(mergeColor(mergeStatus))
                        .frame(width: 9, height: 9)
                        .padding(.top, 3)
                        .help(mergeStatus.capitalized)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(pullRequest.title).lineLimit(2)
                    Text("\(pullRequest.repository.nameWithOwner) #\(pullRequest.number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
    }

    private func open() {
        guard let url = URL(string: pullRequest.url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// green = ready to merge, orange = mergeable but not ready, red = blocked/conflicts, gray = draft/unknown.
    private func mergeColor(_ status: String) -> Color {
        switch status {
        case "CLEAN": return .green
        case "UNSTABLE", "BEHIND": return .orange
        case "BLOCKED", "DIRTY": return .red
        default: return .gray  // DRAFT, UNKNOWN, HAS_HOOKS
        }
    }
}
