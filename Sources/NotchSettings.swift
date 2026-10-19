import SwiftUI
import ServiceManagement

/// UserDefaults keys for the notch's settings.
enum Pref {
    static let openOnHover = "openOnHover"
    static let liveAgents = "liveAgents"
    static let liveMusic = "liveMusic"
    static let liveBattery = "liveBattery"
    static let agenda = "showAgenda"
    static let mirror = "showMirror"
    static let replaceHUD = "replaceHUD"
    static let widthAdjust = "notchWidthAdjust"
    static let heightAdjust = "notchHeightAdjust"
    static let idleWidth = "notchIdleWidth"
    // Show / hide parts of the open notch.
    static let tabHome = "showTabHome"
    static let tabShelf = "showTabShelf"
    static let tabTopbar = "showTabTopbar"
    static let music = "showMusic"
    static let airDrop = "showAirDrop"
    static let sectionGit = "showSectionGit"
    static let sectionWork = "showSectionWork"
    static let sectionContainers = "showSectionContainers"
    static let sectionAgents = "showSectionAgents"
    // Agent limits.
    static let claudeDailyLimit = "claudeDailyLimit"
    static let claudeWeeklyLimit = "claudeWeeklyLimit"
    static let agyDailyLimit = "agyDailyLimit"
    static let agyWeeklyLimit = "agyWeeklyLimit"
    // Theme & Glass tuning.
    static let theme = "notchTheme"
    static let glassMaterial = "glassMaterial"
    static let glassBlurOpacity = "glassBlurOpacity"
    static let glassTintOpacity = "glassTintOpacity"
    static let glassTopFade = "glassTopFade"
    static let glassSheen = "glassSheen"
    static let glassBorderOpacity = "glassBorderOpacity"
    static let glassShadowOpacity = "glassShadowOpacity"
    static let glassAccentGlow = "glassAccentGlow"
    static let glassCardOpacity = "glassCardOpacity"
    static let glassCardBorderOpacity = "glassCardBorderOpacity"
    static let glassCardBlur = "glassCardBlur"
    static let glassClosed = "glassClosed"
    static let musicAmbient = "musicAmbient"
    static let musicAmbientIntensity = "musicAmbientIntensity"
    static let agentAnimation = "agentAnimation"
    static let agentAnimationAlwaysOn = "agentAnimationAlwaysOn"
    static let preferredTerminal = "preferredTerminal"
    static let defaultAgentCommand = "defaultAgentCommand"
    static let containerCLI = "containerCLI"

    static func register() {
        UserDefaults.standard.register(defaults: [
            openOnHover: true, liveAgents: true, liveMusic: true, liveBattery: true,
            agenda: true, mirror: true, replaceHUD: false, widthAdjust: 0.0, heightAdjust: 0.0,
            idleWidth: 48.0,
            tabHome: true, tabShelf: true, tabTopbar: true, music: true, airDrop: true,
            sectionGit: true, sectionWork: true, sectionContainers: true, sectionAgents: true,
            claudeDailyLimit: 12_500_000, claudeWeeklyLimit: 90_000_000,
            agyDailyLimit: 8_000_000, agyWeeklyLimit: 50_000_000,
            theme: NotchTheme.glass.rawValue,
            glassMaterial: GlassMaterial.ultraThin.rawValue,
            glassBlurOpacity: 0.90,
            glassTintOpacity: 0.32,
            glassTopFade: 0.75,
            glassSheen: 0.12,
            glassBorderOpacity: 0.28,
            glassShadowOpacity: 0.40,
            glassAccentGlow: 0.18,
            glassCardOpacity: 0.07,
            glassCardBorderOpacity: 0.15,
            glassCardBlur: false,
            glassClosed: false,
            musicAmbient: true,
            musicAmbientIntensity: 0.75,
            agentAnimation: AgentAnimationStyle.fire.rawValue,
            agentAnimationAlwaysOn: false,
            preferredTerminal: TerminalApp.auto.rawValue,
            defaultAgentCommand: "claude",
            containerCLI: ContainerCLI.auto.rawValue,
        ])
    }
}

enum AgentAnimationStyle: String, CaseIterable, Identifiable {
    case fire = "fire"
    case scanner = "scanner"
    case lightning = "lightning"
    case plasma = "plasma"
    case matrix = "matrix"
    case rave = "rave"
    case warp = "warp"
    case randomBullshit = "randomBullshit"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fire:           return "Doom Fire"
        case .scanner:        return "Laser Scanner (Knight Rider)"
        case .lightning:      return "Electric Lightning (Tesla Arc)"
        case .plasma:         return "Liquid Plasma Wave"
        case .matrix:         return "Matrix Glitch Stream"
        case .rave:           return "Rainbow Rave"
        case .warp:           return "Warp Speed Starfield"
        case .randomBullshit: return "Random Bullshit Go! (Cycle All)"
        }
    }
}

enum NotchTheme: String, CaseIterable, Identifiable {
    case dark = "dark"
    case glass = "glass"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark:  return "Dark"
        case .glass: return "Glass"
        }
    }
}

enum GlassMaterial: String, CaseIterable, Identifiable {
    case ultraThin = "ultraThin"
    case thin = "thin"
    case regular = "regular"
    case thick = "thick"
    case ultraThick = "ultraThick"
    case bar = "bar"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultraThin:  return "Ultra Thin"
        case .thin:       return "Thin"
        case .regular:    return "Regular"
        case .thick:      return "Thick"
        case .ultraThick: return "Ultra Thick"
        case .bar:        return "Bar"
        }
    }

    var swiftUIMaterial: Material {
        switch self {
        case .ultraThin:  return .ultraThinMaterial
        case .thin:       return .thinMaterial
        case .regular:    return .regularMaterial
        case .thick:      return .thickMaterial
        case .ultraThick: return .ultraThickMaterial
        case .bar:        return .bar
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case notch = "Notch"
    case theme = "Theme"
    case activities = "Activities"
    case tabs = "Tabs"
    case menus = "Menus"
    case system = "System"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .notch:      return "display"
        case .theme:      return "sparkles"
        case .activities: return "flame.fill"
        case .tabs:       return "rectangle.3.group.fill"
        case .menus:      return "checklist"
        case .system:     return "gearshape.fill"
        }
    }
}

struct NotchSettingsView: View {
    @State private var selectedTab: SettingsTab = .theme
    @Namespace private var tabPill
    @State private var copiedValues = false

    @AppStorage(Pref.openOnHover) private var openOnHover = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(Pref.liveAgents) private var liveAgents = true
    @AppStorage(Pref.liveMusic) private var liveMusic = true
    @AppStorage(Pref.liveBattery) private var liveBattery = true
    @AppStorage(Pref.agenda) private var agenda = true
    @AppStorage(Pref.mirror) private var mirror = true
    @AppStorage(Pref.replaceHUD) private var replaceHUD = false
    @AppStorage(Pref.widthAdjust) private var widthAdjust = 0.0
    @AppStorage(Pref.heightAdjust) private var heightAdjust = 0.0
    @AppStorage(Pref.idleWidth) private var idleWidth = 48.0
    @AppStorage(Pref.tabHome) private var tabHome = true
    @AppStorage(Pref.tabShelf) private var tabShelf = true
    @AppStorage(Pref.tabTopbar) private var tabTopbar = true
    @AppStorage(Pref.music) private var music = true
    @AppStorage(Pref.airDrop) private var airDrop = true
    @AppStorage(Pref.sectionGit) private var sectionGit = true
    @AppStorage(Pref.sectionWork) private var sectionWork = true
    @AppStorage(Pref.sectionContainers) private var sectionContainers = true
    @AppStorage(Pref.sectionAgents) private var sectionAgents = true

    // Theme & Glass settings
    @AppStorage(Pref.theme) private var theme = NotchTheme.glass.rawValue
    @AppStorage(Pref.glassMaterial) private var glassMaterial = GlassMaterial.ultraThin.rawValue
    @AppStorage(Pref.glassBlurOpacity) private var glassBlurOpacity = 0.90
    @AppStorage(Pref.glassTintOpacity) private var glassTintOpacity = 0.32
    @AppStorage(Pref.glassTopFade) private var glassTopFade = 0.75
    @AppStorage(Pref.glassSheen) private var glassSheen = 0.12
    @AppStorage(Pref.glassBorderOpacity) private var glassBorderOpacity = 0.28
    @AppStorage(Pref.glassShadowOpacity) private var glassShadowOpacity = 0.40
    @AppStorage(Pref.glassAccentGlow) private var glassAccentGlow = 0.18
    @AppStorage(Pref.glassCardOpacity) private var glassCardOpacity = 0.07
    @AppStorage(Pref.glassCardBorderOpacity) private var glassCardBorderOpacity = 0.15
    @AppStorage(Pref.glassCardBlur) private var glassCardBlur = false
    @AppStorage(Pref.glassClosed) private var glassClosed = false
    @AppStorage(Pref.musicAmbient) private var musicAmbient = true
    @AppStorage(Pref.musicAmbientIntensity) private var musicAmbientIntensity = 0.75
    @AppStorage(Pref.agentAnimation) private var agentAnimation = AgentAnimationStyle.fire.rawValue
    @AppStorage(Pref.agentAnimationAlwaysOn) private var agentAnimationAlwaysOn = false
    @AppStorage(Pref.preferredTerminal) private var preferredTerminal = TerminalApp.auto.rawValue
    @AppStorage(Pref.defaultAgentCommand) private var defaultAgentCommand = "claude"
    @ObservedObject private var projectStore = ProjectStore.shared
    @State private var newAgentPreset = ""
    @State private var pinNotchPreview = false

    /// The notch always keeps at least one tab, so the last one left on can't be turned off.
    private var tabsOn: Int { [tabHome, tabShelf, tabTopbar].filter { $0 }.count }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            formContent
        }
        .frame(width: 500, height: 460)
        .onChange(of: pinNotchPreview) {
            NotchModel.shared?.pinnedPreview = pinNotchPreview
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14, weight: .medium))
                        Text(tab.rawValue)
                            .font(.caption2)
                            .fontWeight(selectedTab == tab ? .semibold : .regular)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.1))
                                .matchedGeometryEffect(id: "settingTab", in: tabPill)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? .primary : .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var formContent: some View {
        Form {
            switch selectedTab {
            case .notch:
                Section("Notch Behavior & Sizing") {
                    Toggle("Open on hover", isOn: $openOnHover)
                    Text("When off, click or swipe down on the notch to open it.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Idle extra width") {
                        Slider(value: $idleWidth, in: 0...120, step: 4) { Text("\(Int(idleWidth)) pt") }
                    }
                    Text("Extra width beyond the camera notch when idle, keeping the notch visible when no agent or music is active.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Width adjustment") {
                        Slider(value: $widthAdjust, in: -40...80, step: 2) { Text("\(Int(widthAdjust)) pt") }
                    }
                    LabeledContent("Height adjustment") {
                        HStack(spacing: 8) {
                            Slider(value: $heightAdjust, in: -15...20, step: 1)
                            Text("\(Int(heightAdjust)) pt")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            case .theme:
                Section("Appearance") {
                    Picker("Theme", selection: $theme) {
                        ForEach(NotchTheme.allCases) { t in
                            Text(t.title).tag(t.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Keep notch open to preview live", isOn: $pinNotchPreview)
                    Text("Keeps the notch expanded at the top of your screen while you adjust sliders below.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Music Ambient") {
                    Toggle("Music changes bar ambient atmosphere", isOn: $musicAmbient)
                    if musicAmbient {
                        sliderRow("Ambient intensity", value: $musicAmbientIntensity, range: 0.1...1.0, step: 0.05)
                    }
                    Text("Diffuses album artwork, multi-color aurora glow, rim lighting, and UI accents across the notch when a track is loaded (with breathing motion while playing).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if theme == NotchTheme.glass.rawValue {
                    Section("Glass Surface") {
                        Picker("Blur material", selection: $glassMaterial) {
                            ForEach(GlassMaterial.allCases) { m in
                                Text(m.title).tag(m.rawValue)
                            }
                        }
                        sliderRow("Blur opacity", value: $glassBlurOpacity, range: 0...1, step: 0.02)
                        sliderRow("Dark tint", value: $glassTintOpacity, range: 0...0.95, step: 0.02)
                        sliderRow("Top bezel fade", value: $glassTopFade, range: 0...1, step: 0.02)
                        sliderRow("Glass sheen", value: $glassSheen, range: 0...0.5, step: 0.01)
                        sliderRow("Rim border", value: $glassBorderOpacity, range: 0...0.8, step: 0.02)
                        sliderRow("Drop shadow", value: $glassShadowOpacity, range: 0...0.8, step: 0.02)
                        sliderRow("Accent glow", value: $glassAccentGlow, range: 0...0.6, step: 0.02)
                        Toggle("Glass on closed notch wings", isOn: $glassClosed)
                    }

                    Section("Glass Inner Cards") {
                        sliderRow("Card fill opacity", value: $glassCardOpacity, range: 0...0.35, step: 0.01)
                        sliderRow("Card border opacity", value: $glassCardBorderOpacity, range: 0...0.5, step: 0.01)
                        Toggle("Extra blur inside cards", isOn: $glassCardBlur)
                    }

                    Section("Current Values") {
                        Text(glassSummary)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack {
                            Button(copiedValues ? "Copied!" : "Copy Values") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(glassSummary, forType: .string)
                                copiedValues = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedValues = false }
                            }
                            Spacer()
                            Button("Reset Glass Defaults") {
                                resetGlassDefaults()
                            }
                        }
                    }
                }
            case .activities:
                Section("Notch Animation (Agents)") {
                    Toggle("Play when agents are working (Claude / Antigravity)", isOn: $liveAgents)
                    Picker("Animation style", selection: $agentAnimation) {
                        ForEach(AgentAnimationStyle.allCases) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                    Toggle("Always play animation (preview / idle)", isOn: $agentAnimationAlwaysOn)
                    Text("Renders the selected animation across the closed notch's current width and height.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Live Wing Badges") {
                    Toggle("Music playing", isOn: $liveMusic)
                    Toggle("Charger connected / removed", isOn: $liveBattery)
                }
                Text("When active, these badges appear on the left and right wings of the camera notch.")
                    .font(.caption).foregroundStyle(.secondary)
            case .tabs:
                Section("Visible Tabs") {
                    Toggle("Home", isOn: $tabHome).disabled(tabHome && tabsOn == 1)
                    Toggle("Shelf", isOn: $tabShelf).disabled(tabShelf && tabsOn == 1)
                    Toggle("Git, Work & Agents", isOn: $tabTopbar).disabled(tabTopbar && tabsOn == 1)
                }
                Text("Control which top-level tabs appear when the notch is opened. At least one must stay active.")
                    .font(.caption).foregroundStyle(.secondary)
            case .menus:
                Section("Home Tab Items") {
                    Toggle("Music player", isOn: $music)
                    Toggle("Calendar and reminders", isOn: $agenda)
                }
                .disabled(!tabHome)

                Section("Shelf Tab Items") {
                    Toggle("AirDrop", isOn: $airDrop)
                }
                .disabled(!tabShelf)

                Section("Git, Work, Containers & Agents Items") {
                    Toggle("Git (pull requests)", isOn: $sectionGit)
                    Toggle("Work (project runner)", isOn: $sectionWork)
                    Toggle("Containers (Docker / OrbStack / Podman)", isOn: $sectionContainers)
                    Toggle("Agents", isOn: $sectionAgents)
                }
                .disabled(!tabTopbar)

                Section("Work Project Runner & Agents") {
                    Picker("Terminal app", selection: $preferredTerminal) {
                        ForEach(TerminalApp.allCases) { term in
                            Text(term.title).tag(term.rawValue)
                        }
                    }
                    LabeledContent("Default agent CLI") {
                        TextField("e.g. claude or agy", text: $defaultAgentCommand)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                    LabeledContent("Add agent preset") {
                        HStack(spacing: 6) {
                            TextField("e.g. claude --dangerously-skip-permissions", text: $newAgentPreset)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    projectStore.addAgentPreset(newAgentPreset)
                                    newAgentPreset = ""
                                }
                            Button("Add") {
                                projectStore.addAgentPreset(newAgentPreset)
                                newAgentPreset = ""
                            }
                            .disabled(newAgentPreset.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(projectStore.agentPresets, id: \.self) { preset in
                                HStack(spacing: 4) {
                                    Text(preset)
                                        .font(.system(.caption, design: .monospaced))
                                    Button {
                                        projectStore.removeAgentPreset(preset)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                        }
                    }
                }
            case .system:
                Section("Startup") {
                    Toggle("Launch at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { enable in
                            do {
                                if enable {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                print("Launch at login error: \(error)")
                            }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    ))
                    .onAppear {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                    Text("Starts BullshitNotch automatically when you log into your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("System HUD") {
                    Toggle("Replace volume and brightness HUD", isOn: $replaceHUD)
                        .onChange(of: replaceHUD) { HUD.shared.setEnabled(replaceHUD) }
                    Text("Needs Accessibility permission. After granting it, turn this off and on again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Quit BullshitNotch", role: .destructive) { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step)
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    private var glassSummary: String {
        String(
            format: "material=%@ blur=%.2f tint=%.2f topFade=%.2f sheen=%.2f border=%.2f shadow=%.2f glow=%.2f card=%.2f cardBorder=%.2f cardBlur=%@ closed=%@",
            glassMaterial, glassBlurOpacity, glassTintOpacity, glassTopFade, glassSheen,
            glassBorderOpacity, glassShadowOpacity, glassAccentGlow,
            glassCardOpacity, glassCardBorderOpacity,
            glassCardBlur ? "true" : "false", glassClosed ? "true" : "false"
        )
    }

    private func resetGlassDefaults() {
        glassMaterial = GlassMaterial.ultraThin.rawValue
        glassBlurOpacity = 0.90
        glassTintOpacity = 0.32
        glassTopFade = 0.75
        glassSheen = 0.12
        glassBorderOpacity = 0.28
        glassShadowOpacity = 0.40
        glassAccentGlow = 0.18
        glassCardOpacity = 0.07
        glassCardBorderOpacity = 0.15
        glassCardBlur = false
        glassClosed = false
    }
}

/// A plain window for settings: SwiftUI's Settings scene won't come forward in a menu-bar-only app.
@MainActor
enum NotchSettingsWindow {
    static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: NotchSettingsView()))
            w.title = "BullshitNotch Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                let size = w.frame.size
                // Position below the expanded notch so live preview is unobstructed.
                w.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                         y: max(frame.minY + 40, frame.midY - size.height / 2 - 80)))
            } else {
                w.center()
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { NotchModel.shared?.pinnedPreview = false }
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
