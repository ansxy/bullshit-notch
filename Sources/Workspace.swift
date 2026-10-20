import SwiftUI

/// The notch's Git / Work / Agents tab: section pills on top, one fixed-height area below,
/// so switching sections never makes the panel jump.
struct WorkspaceView: View {
    @EnvironmentObject private var store: PullRequestStore
    @EnvironmentObject private var custom: CustomStore
    @ObservedObject private var music = NowPlaying.shared
    @AppStorage(Pref.sectionGit) private var showGit = true
    @AppStorage(Pref.sectionWork) private var showWork = true
    @AppStorage(Pref.sectionContainers) private var showContainers = true
    @AppStorage(Pref.sectionAgents) private var showAgents = true
    @AppStorage(Pref.sectionQA) private var showQA = true
    @AppStorage(Pref.musicAmbient) private var musicAmbient = true
    @State private var section: Tab = CommandLine.arguments.contains("--demo") ? .builtin(.agents) : .builtin(.git)
    @State private var adding = false
    @State private var newName = ""
    @Namespace private var pill

    private var palette: NowPlaying.Palette? {
        musicAmbient ? music.activePalette : nil
    }

    /// Built-in sections switched on in Settings.
    private var builtins: [AppSection] {
        AppSection.allCases.filter {
            switch $0 {
            case .git:        return showGit
            case .work:       return showWork
            case .containers: return showContainers
            case .agents:     return showAgents
            case .qa:         return showQA
            }
        }
    }

    /// The selected section, or the first one still shown if it was just switched off.
    private var current: Tab? {
        let visible = builtins.map { Tab.builtin($0) } + custom.sections.map { Tab.custom($0.id) }
        return visible.contains(section) ? section : visible.first
    }

    var body: some View {
        VStack(spacing: 10) {
            pills
            content.frame(height: 300)
        }
        .onAppear {
            if current == .builtin(.git) { store.start() }
        }
        .onChange(of: current) {
            if current == .builtin(.git) { store.start() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DemoSwitchSection"))) { note in
            if let appSec = note.object as? AppSection {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    section = .builtin(appSec)
                }
            }
        }
    }

    private var pills: some View {
        HStack(spacing: 4) {
            ForEach(builtins) { pillButton(.builtin($0), $0.rawValue, $0.icon) }
            ForEach(custom.sections) { s in
                pillButton(.custom(s.id), s.name, "star.fill")
                    .contextMenu {
                        Button("Delete Section", role: .destructive) {
                            if section == .custom(s.id) { section = .builtin(.git) }
                            custom.removeSection(s.id)
                        }
                    }
            }
            if adding {
                // Inline, because the notch can't host modal sheets/alerts.
                TextField("Section name", text: $newName)
                    .textFieldStyle(.plain)
                    .frame(width: 110)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.1), in: Capsule())
                    .onSubmit(commitSection)
                    .onExitCommand { adding = false; newName = "" }
            } else {
                Button { adding = true } label: {
                    Image(systemName: "plus").frame(width: 26, height: 26).background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Add a section")
            }
            Spacer()
            if current == .builtin(.git) {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .help("Refresh pull requests")
                }
            }
        }
        .font(.callout)
    }

    private func pillButton(_ tab: Tab, _ label: String, _ icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { section = tab }
        } label: {
            Label(label, systemImage: icon)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if current == tab {
                        if let palette {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            palette.primaryColor.opacity(0.38),
                                            palette.secondaryColor.opacity(0.30)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(
                                    Capsule().strokeBorder(palette.primaryColor.opacity(0.5), lineWidth: 0.8)
                                )
                                .matchedGeometryEffect(id: "pill", in: pill)
                        } else {
                            Capsule().fill(.white.opacity(0.16)).matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                }
                .foregroundStyle(current == tab ? .primary : .secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        switch current {
        case .builtin(.git):
            HStack(spacing: 10) {
                PRColumn(list: .mine)
                PRColumn(list: .review)
            }
        case .builtin(.work):
            ProjectRunnerView().notchCard()
        case .builtin(.containers):
            ContainersView().notchCard()
        case .builtin(.agents):
            AgentsView().notchCard()
        case .builtin(.qa):
            QARecorderView().notchCard()
        case .custom(let id):
            CustomSectionView(sectionID: id).notchCard()
        case nil:
            Text("All sections are turned off in Settings — add one with +")
                .foregroundStyle(.secondary)
                .notchCard()
        }
    }

    private func commitSection() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        custom.addSection(named: name)
        if let id = custom.sections.last?.id { section = .custom(id) }
        newName = ""
        adding = false
    }
}

/// One PR list as a card: title + count, then the rows.
private struct PRColumn: View {
    @EnvironmentObject private var store: PullRequestStore
    let list: PRList

    private var prs: [PullRequest] { store.pullRequests(for: list) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(list.rawValue).font(.headline)
                Text("\(prs.count)")
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            if store.isLoading && prs.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.errorMessage, prs.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if prs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: list == .mine ? "checkmark.seal" : "tray").font(.title2)
                    Text(list == .mine ? "No open PRs" : "Nothing to review")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(prs) { pr in
                            PullRequestRow(
                                pullRequest: pr,
                                reviewed: list == .review ? store.reviewedURLs.contains(pr.url) : nil,
                                mergeStatus: list == .mine ? store.mergeStatus[pr.url] : nil)
                        }
                    }
                }
            }
        }
        .notchCard()
    }
}


extension View {
    /// A softly lit rounded panel, the building block of the open notch.
    func notchCard() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .notchCardBackground(radius: 14)
    }

    /// Applies the themed card fill, optional inner blur, and border stroke.
    func notchCardBackground(radius: CGFloat = 14) -> some View {
        modifier(NotchCardBackground(radius: radius))
    }

    /// Soft highlight under the pointer, for clickable rows and tiles.
    func hoverHighlight(radius: CGFloat = 8) -> some View {
        modifier(HoverHighlight(radius: radius))
    }
}

private struct NotchCardBackground: ViewModifier {
    let radius: CGFloat
    @ObservedObject private var music = NowPlaying.shared
    @AppStorage(Pref.theme) private var theme = NotchTheme.glass.rawValue
    @AppStorage(Pref.glassCardOpacity) private var glassCardOpacity = 0.07
    @AppStorage(Pref.glassCardBorderOpacity) private var glassCardBorderOpacity = 0.15
    @AppStorage(Pref.glassCardBlur) private var glassCardBlur = false
    @AppStorage(Pref.musicAmbient) private var musicAmbient = true
    @AppStorage(Pref.musicAmbientIntensity) private var musicAmbientIntensity = 0.75

    private var isGlass: Bool { theme == NotchTheme.glass.rawValue }
    private var fillOpacity: Double { isGlass ? glassCardOpacity : 0.045 }
    private var borderOpacity: Double { isGlass ? glassCardBorderOpacity : 0.07 }
    private var palette: NowPlaying.Palette? { musicAmbient ? music.activePalette : nil }
    private var ambientStrength: Double { musicAmbientIntensity * (music.playing ? 1.0 : 0.6) }

    func body(content: Content) -> some View {
        let rect = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    if isGlass && glassCardBlur {
                        rect.fill(.ultraThinMaterial)
                    }
                    rect.fill(.white.opacity(fillOpacity))
                    if let palette {
                        rect.fill(
                            LinearGradient(
                                colors: [
                                    palette.primaryColor.opacity(0.11 * ambientStrength),
                                    palette.secondaryColor.opacity(0.07 * ambientStrength)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                }
            }
            .clipShape(rect)
            .overlay {
                if let palette {
                    rect.strokeBorder(
                        LinearGradient(
                            colors: [
                                palette.primaryColor.opacity(min(0.65, borderOpacity + 0.22 * ambientStrength)),
                                palette.secondaryColor.opacity(min(0.55, borderOpacity + 0.14 * ambientStrength))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                } else {
                    rect.strokeBorder(.white.opacity(borderOpacity))
                }
            }
    }
}

private struct HoverHighlight: ViewModifier {
    let radius: CGFloat
    @ObservedObject private var music = NowPlaying.shared
    @AppStorage(Pref.musicAmbient) private var musicAmbient = true
    @State private var hovering = false

    private var tint: Color {
        if musicAmbient, let p = music.activePalette {
            return p.primaryColor
        }
        return .primary
    }

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(tint.opacity(hovering ? (musicAmbient && music.hasTrack ? 0.16 : 0.08) : 0)))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
