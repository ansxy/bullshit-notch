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
    static let sectionAgents = "showSectionAgents"
    // Agent limits.
    static let claudeDailyLimit = "claudeDailyLimit"
    static let claudeWeeklyLimit = "claudeWeeklyLimit"
    static let agyDailyLimit = "agyDailyLimit"
    static let agyWeeklyLimit = "agyWeeklyLimit"

    static func register() {
        UserDefaults.standard.register(defaults: [
            openOnHover: true, liveAgents: true, liveMusic: true, liveBattery: true,
            agenda: true, mirror: true, replaceHUD: false, widthAdjust: 0.0, heightAdjust: 0.0,
            idleWidth: 48.0,
            tabHome: true, tabShelf: true, tabTopbar: true, music: true, airDrop: true,
            sectionGit: true, sectionWork: true, sectionAgents: true,
            claudeDailyLimit: 250_000_000, claudeWeeklyLimit: 1_500_000_000,
            agyDailyLimit: 25_000_000, agyWeeklyLimit: 100_000_000,
        ])
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case notch = "Notch"
    case activities = "Activities"
    case tabs = "Tabs"
    case menus = "Menus"
    case system = "System"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .notch:      return "display"
        case .activities: return "flame.fill"
        case .tabs:       return "rectangle.3.group.fill"
        case .menus:      return "checklist"
        case .system:     return "gearshape.fill"
        }
    }
}

struct NotchSettingsView: View {
    @State private var selectedTab: SettingsTab = .notch
    @Namespace private var tabPill

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
    @AppStorage(Pref.sectionAgents) private var sectionAgents = true

    /// The notch always keeps at least one tab, so the last one left on can't be turned off.
    private var tabsOn: Int { [tabHome, tabShelf, tabTopbar].filter { $0 }.count }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            formContent
        }
        .frame(width: 480, height: 380)
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
                        Slider(value: $heightAdjust, in: -10...20, step: 1) { Text("\(Int(heightAdjust)) pt") }
                    }
                }
            case .activities:
                Section("Live Activities Beside Notch") {
                    Toggle("Agents working — Claude / Antigravity (fire)", isOn: $liveAgents)
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
                    Toggle("Mirror (camera)", isOn: $mirror)
                }
                .disabled(!tabHome)

                Section("Shelf Tab Items") {
                    Toggle("AirDrop", isOn: $airDrop)
                }
                .disabled(!tabShelf)

                Section("Git, Work & Agents Items") {
                    Toggle("Git (pull requests)", isOn: $sectionGit)
                    Toggle("Work (folders)", isOn: $sectionWork)
                    Toggle("Agents", isOn: $sectionAgents)
                }
                .disabled(!tabTopbar)
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
                    Text("Starts TopBar automatically when you log into your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("System HUD") {
                    Toggle("Replace volume and brightness HUD", isOn: $replaceHUD)
                        .onChange(of: replaceHUD) { HUD.shared.setEnabled(replaceHUD) }
                    Text("Needs Accessibility permission. After granting it, turn this off and on again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Quit TopBar", role: .destructive) { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A plain window for settings: SwiftUI's Settings scene won't come forward in a menu-bar-only app.
@MainActor
enum NotchSettingsWindow {
    static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: NotchSettingsView()))
            w.title = "TopBar Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
