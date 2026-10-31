import AppKit
import SwiftUI
import ServiceManagement

extension Notification.Name {
    static let menuBarIconStyleDidChange = Notification.Name("MenuBarIconStyleDidChange")
}

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
    static let sectionQA = "showSectionQA"
    static let sectionProcs = "showSectionProcs"
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
    static let menuBarIconStyle = "menuBarIconStyle"

    static func register() {
        UserDefaults.standard.register(defaults: [
            openOnHover: true, liveAgents: true, liveMusic: true, liveBattery: true,
            agenda: true, mirror: true, replaceHUD: false, widthAdjust: 0.0, heightAdjust: 0.0,
            idleWidth: 48.0,
            tabHome: true, tabShelf: true, tabTopbar: true, music: true, airDrop: true,
            sectionGit: true, sectionWork: true, sectionContainers: true, sectionAgents: true, sectionQA: true, sectionProcs: true,
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
            menuBarIconStyle: MenuBarIconStyle.notchBezel.rawValue,
        ])
    }
}

/// Custom menu bar icon styles on the right side of the macOS menu bar (replacing the old Git branch arrow).
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case notchBezel = "notchBezel"
    case dynamicPill = "dynamicPill"
    case notchFlame = "notchFlame"
    case hidden = "hidden"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notchBezel:  return "Notch Bezel"
        case .dynamicPill: return "Dynamic Pill"
        case .notchFlame:  return "Flame Notch"
        case .hidden:      return "Hidden"
        }
    }

    var subtitle: String {
        switch self {
        case .notchBezel:  return "MacBook top bezel + flared camera notch"
        case .dynamicPill: return "Capsule island with lens & audio waves"
        case .notchFlame:  return "Notch silhouette with agent flame core"
        case .hidden:      return "Hide from menu bar (use ⚙️ inside notch)"
        }
    }
}

/// Draws crisp Retina template `NSImage` icons for the macOS status bar.
enum MenuBarIconGenerator {
    static func image(for style: MenuBarIconStyle) -> NSImage? {
        guard style != .hidden else { return nil }
        let size = NSSize(width: 20, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)

            let fg = NSColor.black.cgColor
            ctx.setFillColor(fg)
            ctx.setStrokeColor(fg)

            switch style {
            case .notchBezel:
                // Top screen bezel line
                let bezelY: CGFloat = 13.0
                ctx.setLineWidth(1.6)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: 1.5, y: bezelY))
                ctx.addLine(to: CGPoint(x: 18.5, y: bezelY))
                ctx.strokePath()

                // Flared camera notch hanging below the bezel (with lens + spark negative-space cutouts)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                let notchPath = CGMutablePath()
                notchPath.move(to: CGPoint(x: 3.5, y: bezelY))
                notchPath.addQuadCurve(to: CGPoint(x: 5.2, y: bezelY - 1.8), control: CGPoint(x: 5.2, y: bezelY))
                notchPath.addLine(to: CGPoint(x: 5.2, y: 5.4))
                notchPath.addArc(tangent1End: CGPoint(x: 5.2, y: 3.2), tangent2End: CGPoint(x: 7.4, y: 3.2), radius: 2.2)
                notchPath.addLine(to: CGPoint(x: 12.6, y: 3.2))
                notchPath.addArc(tangent1End: CGPoint(x: 14.8, y: 3.2), tangent2End: CGPoint(x: 14.8, y: 5.4), radius: 2.2)
                notchPath.addLine(to: CGPoint(x: 14.8, y: bezelY - 1.8))
                notchPath.addQuadCurve(to: CGPoint(x: 16.5, y: bezelY), control: CGPoint(x: 14.8, y: bezelY))
                notchPath.closeSubpath()
                ctx.addPath(notchPath)
                ctx.fillPath()

                // Punch out camera lens & activity dot
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: 8.4, y: 6.4, width: 3.2, height: 3.2))
                ctx.fillEllipse(in: CGRect(x: 12.3, y: 7.1, width: 1.7, height: 1.7))
                ctx.setBlendMode(.normal)
                ctx.endTransparencyLayer()

            case .dynamicPill:
                // Rounded Dynamic Island capsule outline + lens + 3 equalizer bars
                let pillRect = CGRect(x: 1.5, y: 3.2, width: 17.0, height: 9.6)
                let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 4.8, cornerHeight: 4.8, transform: nil)
                ctx.setLineWidth(1.5)
                ctx.addPath(pillPath)
                ctx.strokePath()

                // Camera lens dot on left
                ctx.fillEllipse(in: CGRect(x: 4.5, y: 6.4, width: 3.2, height: 3.2))

                // 3 mini soundwave bars on right
                ctx.setLineWidth(1.35)
                ctx.setLineCap(.round)
                let bars: [(CGFloat, CGFloat)] = [(10.2, 3.2), (12.4, 5.0), (14.6, 2.8)]
                for (x, h) in bars {
                    ctx.move(to: CGPoint(x: x, y: 8.0 - h / 2))
                    ctx.addLine(to: CGPoint(x: x, y: 8.0 + h / 2))
                }
                ctx.strokePath()

            case .notchFlame:
                // Top bezel + notch with negative-space flame icon
                let bezelY: CGFloat = 13.2
                ctx.setLineWidth(1.5)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: 1.5, y: bezelY))
                ctx.addLine(to: CGPoint(x: 18.5, y: bezelY))
                ctx.strokePath()

                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                let notchPath = CGMutablePath()
                notchPath.move(to: CGPoint(x: 3.5, y: bezelY))
                notchPath.addQuadCurve(to: CGPoint(x: 5.0, y: bezelY - 1.6), control: CGPoint(x: 5.0, y: bezelY))
                notchPath.addLine(to: CGPoint(x: 5.0, y: 4.8))
                notchPath.addArc(tangent1End: CGPoint(x: 5.0, y: 2.5), tangent2End: CGPoint(x: 7.3, y: 2.5), radius: 2.3)
                notchPath.addLine(to: CGPoint(x: 12.7, y: 2.5))
                notchPath.addArc(tangent1End: CGPoint(x: 15.0, y: 2.5), tangent2End: CGPoint(x: 15.0, y: 4.8), radius: 2.3)
                notchPath.addLine(to: CGPoint(x: 15.0, y: bezelY - 1.6))
                notchPath.addQuadCurve(to: CGPoint(x: 16.5, y: bezelY), control: CGPoint(x: 15.0, y: bezelY))
                notchPath.closeSubpath()
                ctx.addPath(notchPath)
                ctx.fillPath()

                // Negative-space flame inside the notch
                ctx.setBlendMode(.clear)
                let flame = CGMutablePath()
                let fx: CGFloat = 10.0
                let fy: CGFloat = 4.3
                flame.move(to: CGPoint(x: fx, y: fy + 6.4))
                flame.addCurve(to: CGPoint(x: fx + 2.8, y: fy + 2.6),
                               control1: CGPoint(x: fx + 1.8, y: fy + 5.6),
                               control2: CGPoint(x: fx + 2.8, y: fy + 4.2))
                flame.addCurve(to: CGPoint(x: fx, y: fy),
                               control1: CGPoint(x: fx + 2.8, y: fy + 1.1),
                               control2: CGPoint(x: fx + 1.4, y: fy))
                flame.addCurve(to: CGPoint(x: fx - 2.8, y: fy + 2.6),
                               control1: CGPoint(x: fx - 1.4, y: fy),
                               control2: CGPoint(x: fx - 2.8, y: fy + 1.1))
                flame.addCurve(to: CGPoint(x: fx, y: fy + 6.4),
                               control1: CGPoint(x: fx - 2.8, y: fy + 4.2),
                               control2: CGPoint(x: fx - 1.8, y: fy + 5.6))
                flame.closeSubpath()
                ctx.addPath(flame)
                ctx.fillPath()
                ctx.setBlendMode(.normal)
                ctx.endTransparencyLayer()

            case .hidden:
                break
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "BullshitNotch Settings"
        return img
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

    var shortTitle: String {
        switch self {
        case .fire:           return "Doom Fire"
        case .scanner:        return "Laser Scanner"
        case .lightning:      return "Tesla Arc"
        case .plasma:         return "Liquid Plasma"
        case .matrix:         return "Matrix Glitch"
        case .rave:           return "Rainbow Rave"
        case .warp:           return "Warp Starfield"
        case .randomBullshit: return "Cycle All"
        }
    }

    var subtitle: String {
        switch self {
        case .fire:           return "Classic rising pixel embers"
        case .scanner:        return "KITT crimson sweeping beam"
        case .lightning:      return "High-voltage branching arcs"
        case .plasma:         return "Synthwave neon interference"
        case .matrix:         return "Digital rain glyph cascade"
        case .rave:           return "Chromatic spectrum pulse"
        case .warp:           return "Hyperspace star streaks"
        case .randomBullshit: return "Rotates every few seconds"
        }
    }

    var symbol: String {
        switch self {
        case .fire:           return "flame.fill"
        case .scanner:        return "light.max"
        case .lightning:      return "bolt.fill"
        case .plasma:         return "waveform.path.ecg"
        case .matrix:         return "chevron.left.forwardslash.chevron.right"
        case .rave:           return "sparkles"
        case .warp:           return "sparkles.tv.fill"
        case .randomBullshit: return "shuffle"
        }
    }

    var previewColors: [Color] {
        switch self {
        case .fire:           return [Color(red: 1.0, green: 0.32, blue: 0.05), Color(red: 1.0, green: 0.78, blue: 0.15)]
        case .scanner:        return [Color(red: 1.0, green: 0.10, blue: 0.22), Color(red: 0.55, green: 0.02, blue: 0.08)]
        case .lightning:      return [Color(red: 0.35, green: 0.75, blue: 1.0), Color(red: 0.65, green: 0.45, blue: 1.0)]
        case .plasma:         return [Color(red: 0.92, green: 0.22, blue: 0.85), Color(red: 0.20, green: 0.82, blue: 0.98)]
        case .matrix:         return [Color(red: 0.12, green: 0.95, blue: 0.42), Color(red: 0.04, green: 0.45, blue: 0.18)]
        case .rave:           return [Color(red: 1.0, green: 0.25, blue: 0.55), Color(red: 0.25, green: 0.95, blue: 0.75)]
        case .warp:           return [Color(red: 0.55, green: 0.78, blue: 1.0), Color(red: 0.22, green: 0.38, blue: 0.85)]
        case .randomBullshit: return [Color(red: 1.0, green: 0.55, blue: 0.15), Color(red: 0.58, green: 0.32, blue: 1.0)]
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

/// Curated one-click appearance presets for the Studio Bento grid.
enum StudioAppearancePreset: String, CaseIterable, Identifiable {
    case liquidGlass = "liquidGlass"
    case smokyFrosted = "smokyFrosted"
    case crystalWings = "crystalWings"
    case oledBlack = "oledBlack"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidGlass:  return "Liquid Glass"
        case .smokyFrosted: return "Smoky Frosted"
        case .crystalWings: return "Crystal Clear"
        case .oledBlack:    return "OLED Pitch Black"
        }
    }

    var subtitle: String {
        switch self {
        case .liquidGlass:  return "Balanced blur + crisp rim"
        case .smokyFrosted: return "Deep obsidian frosted blur"
        case .crystalWings: return "High sheen + glass wings"
        case .oledBlack:    return "Pure matte black housing"
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case theme = "Appearance"
    case activities = "Activities"
    case notch = "Notch & Sizing"
    case tabs = "Modules & Tabs"
    case menus = "Work & Agents"
    case system = "System & Icon"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .theme:      return "Theme"
        case .activities: return "Shaders"
        case .notch:      return "Sizing"
        case .tabs:       return "Modules"
        case .menus:      return "CLI"
        case .system:     return "System"
        }
    }

    var subtitle: String {
        switch self {
        case .theme:      return "Glass, presets & music aurora"
        case .activities: return "Agent shaders & wing badges"
        case .notch:      return "Hover, HUD & dimensions"
        case .tabs:       return "Visible tabs & sections"
        case .menus:      return "Terminal, Docker & agent CLI"
        case .system:     return "Menu bar icon & startup"
        }
    }

    var icon: String {
        switch self {
        case .theme:      return "sparkles"
        case .activities: return "flame.fill"
        case .notch:      return "slider.horizontal.below.rectangle"
        case .tabs:       return "square.grid.2x2.fill"
        case .menus:      return "terminal.fill"
        case .system:     return "menubar.dock.rectangle"
        }
    }

    var accent: Color {
        switch self {
        case .theme:      return Color(red: 0.25, green: 0.75, blue: 1.0)
        case .activities: return Color(red: 1.0, green: 0.48, blue: 0.18)
        case .notch:      return Color(red: 0.62, green: 0.48, blue: 1.0)
        case .tabs:       return Color(red: 0.22, green: 0.85, blue: 0.58)
        case .menus:      return Color(red: 0.95, green: 0.72, blue: 0.22)
        case .system:     return Color(red: 0.58, green: 0.72, blue: 0.92)
        }
    }
}

// MARK: - Standalone Pro Studio Settings View & Embedded In-Notch Studio View

struct NotchSettingsView: View {
    /// When true, renders the compact In-Notch Studio layout that fits inside the expanded Notch panel.
    var embeddedInNotch: Bool = false
    var onCloseEmbedded: (() -> Void)? = nil
    var onPopOutWindow: (() -> Void)? = nil

    @State private var selectedTab: SettingsTab = .theme
    @State private var showFineTuneSliders: Bool = false
    @Namespace private var navNamespace
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
    @AppStorage(Pref.sectionQA) private var sectionQA = true
    @AppStorage(Pref.sectionProcs) private var sectionProcs = true

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
    @AppStorage(Pref.containerCLI) private var containerCLI = ContainerCLI.auto.rawValue
    @AppStorage(Pref.defaultAgentCommand) private var defaultAgentCommand = "claude"
    @AppStorage(Pref.menuBarIconStyle) private var menuBarIconStyle = MenuBarIconStyle.notchBezel.rawValue

    @ObservedObject private var projectStore = ProjectStore.shared
    @ObservedObject private var agents = AgentStore.shared
    @ObservedObject private var nowPlaying = NowPlaying.shared
    @State private var newAgentPreset = ""
    @State private var pinNotchPreview = NotchModel.shared?.pinnedPreview ?? false

    /// The notch always keeps at least one tab, so the last one left on can't be turned off.
    private var tabsOn: Int { [tabHome, tabShelf, tabTopbar].filter { $0 }.count }

    var body: some View {
        Group {
            if embeddedInNotch {
                embeddedStudioLayout
            } else {
                standaloneStudioLayout
            }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: pinNotchPreview) {
            NotchModel.shared?.pinnedPreview = pinNotchPreview
        }
        .onChange(of: menuBarIconStyle) {
            NotificationCenter.default.post(name: .menuBarIconStyleDidChange, object: nil)
        }
    }

    // MARK: - 1. Standalone Pro Studio Window Layout (Sidebar + Detail Pane)

    private var standaloneStudioLayout: some View {
        HStack(spacing: 0) {
            studioSidebar
                .frame(width: 204)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            VStack(spacing: 0) {
                studioDetailHeader
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        if selectedTab == .theme || selectedTab == .activities || selectedTab == .notch {
                            liveNotchPreviewCard
                        }
                        detailSections(compact: false)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.07, blue: 0.10),
                        Color(red: 0.04, green: 0.05, blue: 0.07)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .frame(width: 740, height: 550)
    }

    private var studioSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Space for macOS window traffic lights
            Color.clear.frame(height: 30)

            // Brand header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.16, green: 0.22, blue: 0.36),
                                    Color(red: 0.08, green: 0.10, blue: 0.16)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        )
                    if let img = MenuBarIconGenerator.image(for: .notchBezel) {
                        Image(nsImage: img)
                            .renderingMode(.template)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text("BullshitNotch")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Studio Settings")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)

            // Navigation items
            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    let isSelected = selectedTab == tab
                    Button {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isSelected ? tab.accent.opacity(0.24) : Color.white.opacity(0.05))
                                    .frame(width: 26, height: 26)
                                Image(systemName: tab.icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(isSelected ? tab.accent : .white.opacity(0.65))
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(tab.rawValue)
                                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                    .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
                                Text(tab.subtitle)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.white.opacity(isSelected ? 0.58 : 0.38))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.09))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(tab.accent.opacity(0.35), lineWidth: 1)
                                    )
                                    .matchedGeometryEffect(id: "sidebarTab", in: navNamespace)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            // Bottom Pin Notch Live Preview Card
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(pinNotchPreview ? Color.green : Color.white.opacity(0.25))
                        .frame(width: 7, height: 7)
                    Text("Pin Real Notch Open")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Toggle("", isOn: $pinNotchPreview)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                Text("Keeps the top-of-screen notch expanded while you tune settings.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(pinNotchPreview ? Color.green.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .background(
            ZStack {
                Color(red: 0.08, green: 0.09, blue: 0.13)
                LinearGradient(
                    colors: [selectedTab.accent.opacity(0.07), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
    }

    private var studioDetailHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Image(systemName: selectedTab.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selectedTab.accent)
                    Text(selectedTab.rawValue)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(selectedTab.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()

            // Quick status pill for current menu bar icon
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                    selectedTab = .system
                }
            } label: {
                HStack(spacing: 6) {
                    if let style = MenuBarIconStyle(rawValue: menuBarIconStyle),
                       let img = MenuBarIconGenerator.image(for: style) {
                        Image(nsImage: img)
                            .renderingMode(.template)
                            .foregroundStyle(.white.opacity(0.85))
                    } else {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text("Icon: \((MenuBarIconStyle(rawValue: menuBarIconStyle) ?? .notchBezel).title)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
            .help("Configure right-side Menu Bar Icon")
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    // MARK: - 2. Embedded In-Notch Studio Layout (Fits inside the 620pt Expanded Notch)

    private var embeddedStudioLayout: some View {
        VStack(spacing: 10) {
            // Top horizontal pill navigation + Pop-Out Window button
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(SettingsTab.allCases) { tab in
                        let isSelected = selectedTab == tab
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                selectedTab = tab
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(isSelected ? tab.accent : .white.opacity(0.6))
                                Text(tab.shortLabel)
                                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                    .foregroundStyle(isSelected ? .white : .white.opacity(0.68))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background {
                                if isSelected {
                                    Capsule()
                                        .fill(Color.white.opacity(0.12))
                                        .overlay(Capsule().strokeBorder(tab.accent.opacity(0.45), lineWidth: 0.9))
                                        .matchedGeometryEffect(id: "embeddedNav", in: navNamespace)
                                }
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.05))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                )

                Spacer(minLength: 4)

                Button {
                    onPopOutWindow?()
                } label: {
                    HStack(spacing: 4) {
                        Text("Studio Window")
                            .font(.system(size: 10.5, weight: .semibold))
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(Color(red: 0.35, green: 0.78, blue: 1.0))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.25, green: 0.72, blue: 1.0).opacity(0.14))
                            .overlay(Capsule().strokeBorder(Color(red: 0.25, green: 0.72, blue: 1.0).opacity(0.38), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .help("Open full standalone Studio Settings window")

                if let onCloseEmbedded {
                    Button {
                        onCloseEmbedded()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Close In-Notch Studio")
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    detailSections(compact: true)
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 290)
        }
    }

    // MARK: - Live Interactive Notch Preview Banner

    private var currentAnimationStyle: AgentAnimationStyle {
        AgentAnimationStyle(rawValue: agentAnimation) ?? .fire
    }

    private var liveNotchPreviewCard: some View {
        let isGlassTheme = theme == NotchTheme.glass.rawValue
        let animAccent = currentAnimationStyle.previewColors.first ?? .orange
        let previewWing = CGFloat(min(48, max(8, idleWidth * 0.45)))
        let previewWidth = CGFloat(140 + widthAdjust * 0.5) + previewWing * 2
        let previewHeight = CGFloat(max(22, min(38, 28 + heightAdjust * 0.4)))

        return VStack(spacing: 10) {
            ZStack(alignment: .top) {
                // Simulated macOS wallpaper backdrop
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.11, green: 0.14, blue: 0.24),
                                Color(red: 0.06, green: 0.08, blue: 0.15),
                                Color(red: 0.12, green: 0.10, blue: 0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(alignment: .top) {
                        // Simulated menu bar strip
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 24)
                            .overlay(alignment: .trailing) {
                                HStack(spacing: 10) {
                                    Image(systemName: "wifi")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.white.opacity(0.55))
                                    if let style = MenuBarIconStyle(rawValue: menuBarIconStyle),
                                       let img = MenuBarIconGenerator.image(for: style) {
                                        Image(nsImage: img)
                                            .renderingMode(.template)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 15, height: 12)
                                            .foregroundStyle(.white.opacity(0.92))
                                    }
                                    Text("9:41 AM")
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                .padding(.trailing, 12)
                            }
                            .overlay(alignment: .leading) {
                                HStack(spacing: 8) {
                                    Image(systemName: "apple.logo")
                                        .font(.system(size: 9.5))
                                    Text("BullshitNotch")
                                        .font(.system(size: 9.5, weight: .semibold))
                                }
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.leading, 12)
                            }
                    }

                // Miniature Notch Housing
                ZStack {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 11,
                        bottomTrailingRadius: 11,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .fill(
                        isGlassTheme && glassClosed
                            ? Color.black.opacity(max(0.35, glassTintOpacity))
                            : Color.black
                    )
                    .overlay {
                        if liveAgents || agentAnimationAlwaysOn {
                            Image(nsImage: agents.fire.image(style: currentAnimationStyle))
                                .resizable()
                                .interpolation(.none)
                                .opacity(0.88)
                                .clipShape(
                                    UnevenRoundedRectangle(
                                        topLeadingRadius: 0,
                                        bottomLeadingRadius: 11,
                                        bottomTrailingRadius: 11,
                                        topTrailingRadius: 0,
                                        style: .continuous
                                    )
                                )
                        }
                    }
                    .overlay(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 11,
                            bottomTrailingRadius: 11,
                            topTrailingRadius: 0,
                            style: .continuous
                        )
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.white.opacity(isGlassTheme ? max(0.14, glassBorderOpacity) : 0.14)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    )
                    .shadow(color: animAccent.opacity((liveAgents || agentAnimationAlwaysOn) ? 0.35 : 0.0), radius: 10, y: 3)

                    HStack(spacing: 0) {
                        if liveMusic {
                            Image(systemName: "music.note")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Color(red: 0.35, green: 0.82, blue: 1.0))
                                .frame(width: previewWing)
                        } else {
                            Spacer().frame(width: previewWing)
                        }

                        // Camera dot
                        Circle()
                            .fill(Color(red: 0.08, green: 0.11, blue: 0.18))
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color.cyan.opacity(0.45), lineWidth: 0.8))

                        if liveAgents {
                            Image(systemName: currentAnimationStyle.symbol)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(animAccent)
                                .frame(width: previewWing)
                        } else {
                            Spacer().frame(width: previewWing)
                        }
                    }
                }
                .frame(width: previewWidth, height: previewHeight)
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isGlassTheme ? Color.cyan : Color.white.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text("\(isGlassTheme ? "Glass (\(GlassMaterial(rawValue: glassMaterial)?.title ?? "Ultra Thin"))" : "Dark Matte") · \(currentAnimationStyle.shortTitle)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer()

                Button {
                    agentAnimationAlwaysOn.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: agentAnimationAlwaysOn ? "flame.fill" : "flame")
                            .font(.system(size: 10))
                        Text(agentAnimationAlwaysOn ? "Shader Always On" : "Preview Shader")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(agentAnimationAlwaysOn ? .orange : .white.opacity(0.7))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(agentAnimationAlwaysOn ? Color.orange.opacity(0.16) : Color.white.opacity(0.06))
                            .overlay(Capsule().strokeBorder(agentAnimationAlwaysOn ? Color.orange.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)

                Button {
                    pinNotchPreview.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: pinNotchPreview ? "pin.fill" : "pin")
                            .font(.system(size: 10))
                        Text(pinNotchPreview ? "Notch Pinned" : "Pin Real Notch")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(pinNotchPreview ? .green : .white.opacity(0.7))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(pinNotchPreview ? Color.green.opacity(0.16) : Color.white.opacity(0.06))
                            .overlay(Capsule().strokeBorder(pinNotchPreview ? Color.green.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(studioCardBackground)
    }

    // MARK: - Tab Detail Sections

    @ViewBuilder
    private func detailSections(compact: Bool) -> some View {
        switch selectedTab {
        case .theme:
            appearanceTabContent(compact: compact)
        case .activities:
            activitiesTabContent(compact: compact)
        case .notch:
            notchSizingTabContent(compact: compact)
        case .tabs:
            modulesAndTabsContent(compact: compact)
        case .menus:
            workAndAgentsContent(compact: compact)
        case .system:
            systemAndIconContent(compact: compact)
        }
    }

    // MARK: Tab 1 — Appearance & Glass

    @ViewBuilder
    private func appearanceTabContent(compact: Bool) -> some View {
        // 1. Visual Theme Presets Bento Grid
        studioSectionCard(title: "Visual Surface Presets", subtitle: "One-click curated materials for the expanded & closed notch", icon: "sparkles") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: compact ? 4 : 2), spacing: 8) {
                ForEach(StudioAppearancePreset.allCases) { preset in
                    let active = isPresetActive(preset)
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            applyPreset(preset)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            // Visual swatch preview bar
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(presetPreviewGradient(preset))
                                    .frame(height: compact ? 22 : 28)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Color.white.opacity(preset == .oledBlack ? 0.16 : 0.28), lineWidth: 1)
                                    )
                                HStack {
                                    Text(preset == .oledBlack ? "DARK" : "GLASS")
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.75))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.black.opacity(0.35), in: Capsule())
                                    Spacer()
                                    if active {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.cyan)
                                    }
                                }
                                .padding(.horizontal, 6)
                            }

                            Text(preset.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            if !compact {
                                Text(preset.subtitle)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(active ? Color.cyan.opacity(0.11) : Color.white.opacity(0.035))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(active ? Color.cyan.opacity(0.55) : Color.white.opacity(0.08), lineWidth: active ? 1.4 : 1)
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        // 2. Music Ambient Aurora Card
        studioSectionCard(title: "Music Ambient Aurora", subtitle: "Diffuses album artwork, multi-color aurora glow & rim lighting when a track is loaded", icon: "waveform.and.magnifyingglass") {
            VStack(spacing: 10) {
                studioToggleRow(
                    title: "Infuse notch with album artwork aurora",
                    subtitle: "Breathing three-color mesh glow while playing",
                    isOn: $musicAmbient
                )
                if musicAmbient {
                    Divider().overlay(Color.white.opacity(0.06))
                    studioSliderRow("Ambient intensity", value: $musicAmbientIntensity, range: 0.1...1.0, step: 0.05)
                }
            }
        }

        // 3. Collapsible Fine-Tune Glass Sliders
        if theme == NotchTheme.glass.rawValue {
            studioSectionCard(
                title: "Fine-Tune Glass & Inner Cards",
                subtitle: "Granular control over blur material, bezel fade, rim sheen, shadow & cards",
                icon: "slider.horizontal.3"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            showFineTuneSliders.toggle()
                        }
                    } label: {
                        HStack {
                            Text(showFineTuneSliders ? "Hide 11 Granular Glass Controls" : "Expand 11 Granular Glass Controls")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.cyan)
                            Spacer()
                            Image(systemName: showFineTuneSliders ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.cyan)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showFineTuneSliders {
                        Divider().overlay(Color.white.opacity(0.08))

                        HStack {
                            Text("Blur Material")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            Picker("", selection: $glassMaterial) {
                                ForEach(GlassMaterial.allCases) { m in
                                    Text(m.title).tag(m.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }

                        studioSliderRow("Blur opacity", value: $glassBlurOpacity, range: 0...1, step: 0.02)
                        studioSliderRow("Dark tint", value: $glassTintOpacity, range: 0...0.95, step: 0.02)
                        studioSliderRow("Top bezel fade", value: $glassTopFade, range: 0...1, step: 0.02)
                        studioSliderRow("Glass sheen", value: $glassSheen, range: 0...0.5, step: 0.01)
                        studioSliderRow("Rim border", value: $glassBorderOpacity, range: 0...0.8, step: 0.02)
                        studioSliderRow("Drop shadow", value: $glassShadowOpacity, range: 0...0.8, step: 0.02)
                        studioSliderRow("Accent glow", value: $glassAccentGlow, range: 0...0.6, step: 0.02)

                        studioToggleRow(
                            title: "Glass on closed notch wings",
                            subtitle: "Applies translucent glass to the closed wings instead of matte black",
                            isOn: $glassClosed
                        )

                        Divider().overlay(Color.white.opacity(0.08))

                        Text("Inner Bento Cards")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))

                        studioSliderRow("Card fill opacity", value: $glassCardOpacity, range: 0...0.35, step: 0.01)
                        studioSliderRow("Card border opacity", value: $glassCardBorderOpacity, range: 0...0.5, step: 0.01)
                        studioToggleRow(
                            title: "Extra blur inside cards",
                            subtitle: "Adds an individual ultraThinMaterial layer behind each inner card",
                            isOn: $glassCardBlur
                        )

                        Divider().overlay(Color.white.opacity(0.08))

                        HStack(spacing: 10) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(glassSummary, forType: .string)
                                copiedValues = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedValues = false }
                            } label: {
                                Label(copiedValues ? "Copied!" : "Copy Config", systemImage: copiedValues ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button {
                                resetGlassDefaults()
                            } label: {
                                Label("Reset Glass Defaults", systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.white.opacity(0.06), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: Tab 2 — Live Activities & Shaders

    @ViewBuilder
    private func activitiesTabContent(compact: Bool) -> some View {
        studioSectionCard(title: "Agent Notch Shader Style", subtitle: "Pixel shader rendered across the closed notch when Claude or Antigravity is working", icon: "flame.fill") {
            VStack(alignment: .leading, spacing: 10) {
                studioToggleRow(
                    title: "Play shader when coding agents are busy",
                    subtitle: "Triggers automatically on active Claude or Antigravity sessions",
                    isOn: $liveAgents
                )
                studioToggleRow(
                    title: "Always play animation (idle / preview mode)",
                    subtitle: "Keeps the selected shader burning even when no agents are active",
                    isOn: $agentAnimationAlwaysOn
                )

                Divider().overlay(Color.white.opacity(0.08))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: compact ? 4 : 2), spacing: 8) {
                    ForEach(AgentAnimationStyle.allCases) { style in
                        let selected = agentAnimation == style.rawValue
                        let colors = style.previewColors
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                agentAnimation = style.rawValue
                            }
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: colors,
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 28, height: 28)
                                    Image(systemName: style.symbol)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(style.shortTitle)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    if !compact {
                                        Text(style.subtitle)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.white.opacity(0.5))
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(colors.first ?? .orange)
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selected ? (colors.first ?? .orange).opacity(0.14) : Color.white.opacity(0.035))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(selected ? (colors.first ?? .orange).opacity(0.55) : Color.white.opacity(0.08), lineWidth: selected ? 1.3 : 1)
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        studioSectionCard(title: "Closed Notch Wing Badges", subtitle: "Live indicators displayed on the left and right wings of the camera housing", icon: "waveform") {
            VStack(spacing: 10) {
                studioToggleRow(
                    title: "Now Playing artwork & visualizer",
                    subtitle: "Shows album cover on the left wing and live audio bars on the right wing",
                    isOn: $liveMusic
                )
                Divider().overlay(Color.white.opacity(0.06))
                studioToggleRow(
                    title: "Battery & MagSafe charger alert",
                    subtitle: "Briefly expands wings when power is connected or disconnected",
                    isOn: $liveBattery
                )
            }
        }
    }

    // MARK: Tab 3 — Notch Behavior & Sizing

    @ViewBuilder
    private func notchSizingTabContent(compact: Bool) -> some View {
        studioSectionCard(title: "Opening Gesture & Behavior", subtitle: "Control how the notch responds to pointer hover, clicks & trackpad swipes", icon: "cursorarrow.motionlines") {
            studioToggleRow(
                title: "Expand automatically on pointer hover",
                subtitle: "When off, click the closed notch or swipe down with two fingers on the trackpad to open",
                isOn: $openOnHover
            )
        }

        studioSectionCard(title: "Closed Notch Dimensions", subtitle: "Fine-tune how wide and tall the closed notch sits around your MacBook camera", icon: "aspectratio") {
            VStack(spacing: 10) {
                studioSliderRow("Idle wing width", value: $idleWidth, range: 0...120, step: 4, format: "%.0f pt")
                Divider().overlay(Color.white.opacity(0.06))
                studioSliderRow("Housing width offset", value: $widthAdjust, range: -40...80, step: 2, format: "%+.0f pt")
                Divider().overlay(Color.white.opacity(0.06))
                studioSliderRow("Housing height offset", value: $heightAdjust, range: -15...20, step: 1, format: "%+.0f pt")

                HStack {
                    Text("Tip: Keep Idle Wing Width around 48pt so music artwork and visualizers have room.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Button {
                        idleWidth = 48.0
                        widthAdjust = 0.0
                        heightAdjust = 0.0
                    } label: {
                        Text("Reset Sizing")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Tab 4 — Modules & Tabs

    @ViewBuilder
    private func modulesAndTabsContent(compact: Bool) -> some View {
        studioSectionCard(title: "Top-Level Notch Tabs", subtitle: "Choose which tabs appear in the top-left header when expanded (at least one required)", icon: "rectangle.3.group.fill") {
            HStack(spacing: 8) {
                tabToggleCard(title: "Home", subtitle: "Music, Calendar & Mirror", icon: "house.fill", isOn: $tabHome, disabled: tabHome && tabsOn == 1)
                tabToggleCard(title: "Shelf", subtitle: "File Drop & AirDrop", icon: "tray.full.fill", isOn: $tabShelf, disabled: tabShelf && tabsOn == 1)
                tabToggleCard(title: "Workspace", subtitle: "Git, Work, Docker & Agents", icon: "rectangle.3.group.fill", isOn: $tabTopbar, disabled: tabTopbar && tabsOn == 1)
            }
        }

        HStack(alignment: .top, spacing: 10) {
            studioSectionCard(title: "Home & Shelf Widgets", subtitle: "Components inside Home & Shelf", icon: "music.note.house") {
                VStack(spacing: 8) {
                    studioToggleRow(title: "Music player", subtitle: "Spotify & Apple Music controls", isOn: $music)
                        .disabled(!tabHome)
                    Divider().overlay(Color.white.opacity(0.06))
                    studioToggleRow(title: "Calendar & reminders", subtitle: "Upcoming events & tasks", isOn: $agenda)
                        .disabled(!tabHome)
                    Divider().overlay(Color.white.opacity(0.06))
                    studioToggleRow(title: "Camera mirror", subtitle: "Quick FaceTime check on Home", isOn: $mirror)
                        .disabled(!tabHome)
                    Divider().overlay(Color.white.opacity(0.06))
                    studioToggleRow(title: "AirDrop dropzone", subtitle: "Quick share card on Shelf", isOn: $airDrop)
                        .disabled(!tabShelf)
                }
            }

            studioSectionCard(title: "Workspace Sections", subtitle: "Sub-tabs in the Workspace view", icon: "square.stack.3d.up.fill") {
                VStack(spacing: 8) {
                    studioToggleRow(title: "Git Pull Requests", subtitle: "Assigned & review PRs via gh", isOn: $sectionGit)
                    Divider().overlay(Color.white.opacity(0.06))
                    studioToggleRow(title: "Work Project Runner", subtitle: "One-click dev server & agent launcher", isOn: $sectionWork)
                    Divider().overlay(Color.white.opacity(0.06))
                    studioToggleRow(title: "Containers", subtitle: "Docker, OrbStack & Podman", isOn: $sectionContainers)
                    Divider().overlay(Color.white.opacity(0.06))
                    studioToggleRow(title: "Live Agents", subtitle: "Claude & Antigravity sessions/usage", isOn: $sectionAgents)
                    Divider().overlay(Color.white.opacity(0.06))
                    studioToggleRow(title: "QA Recorder", subtitle: "Screen + Firefox telemetry capture", isOn: $sectionQA)
                    Divider().overlay(Color.white.opacity(0.06))
                    studioToggleRow(title: "Ports & Bash Killer", subtitle: "Listening TCP ports & running bash/dev processes", isOn: $sectionProcs)
                }
                .disabled(!tabTopbar)
            }
        }
    }

    // MARK: Tab 5 — Work & Agents CLI

    @ViewBuilder
    private func workAndAgentsContent(compact: Bool) -> some View {
        studioSectionCard(title: "Developer Environment & Runtimes", subtitle: "Preferred terminal emulator and container runtime for the Workspace tab", icon: "terminal.fill") {
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preferred Terminal App")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        Text("Used when launching projects or opening agent sessions")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Picker("", selection: $preferredTerminal) {
                        ForEach(TerminalApp.allCases) { term in
                            Text(term.title).tag(term.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }

                Divider().overlay(Color.white.opacity(0.06))

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Container Engine CLI")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        Text("Used by the Containers tab to list and control containers")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Picker("", selection: $containerCLI) {
                        ForEach(ContainerCLI.allCases) { cli in
                            Text(cli.title).tag(cli.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }
        }

        studioSectionCard(title: "Coding Agent CLI Presets", subtitle: "Default command and reusable presets for Work Project Runner & QA hand-off", icon: "cpu.fill") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Default Agent Command")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    TextField("e.g. claude or agy", text: $defaultAgentCommand)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                Divider().overlay(Color.white.opacity(0.06))

                HStack(spacing: 8) {
                    TextField("Add preset (e.g. claude --dangerously-skip-permissions)", text: $newAgentPreset)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            projectStore.addAgentPreset(newAgentPreset)
                            newAgentPreset = ""
                        }
                    Button {
                        projectStore.addAgentPreset(newAgentPreset)
                        newAgentPreset = ""
                    } label: {
                        Text("Add Preset")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.cyan.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(newAgentPreset.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(projectStore.agentPresets, id: \.self) { preset in
                            HStack(spacing: 5) {
                                Text(preset)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.88))
                                Button {
                                    projectStore.removeAgentPreset(preset)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.07))
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: Tab 6 — System & Menu Bar Icon

    @ViewBuilder
    private func systemAndIconContent(compact: Bool) -> some View {
        // 1. Right-side Menu Bar Icon Picker (replaces the old 2-way branch arrow)
        studioSectionCard(
            title: "Menu Bar Icon (Top Right of Screen)",
            subtitle: "Choose the status bar icon style on the right of your Mac's menu bar. Left-click opens Studio; right-click opens Quick Actions.",
            icon: "menubar.dock.rectangle"
        ) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: compact ? 4 : 2), spacing: 8) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    let isSelected = menuBarIconStyle == style.rawValue
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                            menuBarIconStyle = style.rawValue
                        }
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? Color.cyan.opacity(0.22) : Color.white.opacity(0.06))
                                    .frame(width: 38, height: 32)
                                if let img = MenuBarIconGenerator.image(for: style) {
                                    Image(nsImage: img)
                                        .renderingMode(.template)
                                        .foregroundStyle(isSelected ? Color.cyan : .white.opacity(0.88))
                                } else {
                                    Image(systemName: "eye.slash")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if !compact {
                                    Text(style.subtitle)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.48))
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.cyan)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isSelected ? Color.cyan.opacity(0.11) : Color.white.opacity(0.035))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(isSelected ? Color.cyan.opacity(0.55) : Color.white.opacity(0.08), lineWidth: isSelected ? 1.4 : 1)
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        // 2. Startup & System HUD
        studioSectionCard(title: "macOS Integration & Startup", subtitle: "Login item registration & media key HUD replacement", icon: "gearshape.2.fill") {
            VStack(spacing: 10) {
                studioToggleRow(
                    title: "Launch BullshitNotch at login",
                    subtitle: "Starts automatically in the background when you sign into your Mac",
                    isOn: Binding(
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
                    )
                )
                .onAppear {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }

                Divider().overlay(Color.white.opacity(0.06))

                studioToggleRow(
                    title: "Replace macOS volume & brightness HUD",
                    subtitle: "Renders volume/brightness inside the notch wings (requires Accessibility permission)",
                    isOn: $replaceHUD
                )
                .onChange(of: replaceHUD) { HUD.shared.setEnabled(replaceHUD) }
            }
        }

        // 3. App Quit Footer
        HStack {
            Text("BullshitNotch · Native macOS Notch Studio")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "power")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("Quit BullshitNotch")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Color(red: 1.0, green: 0.38, blue: 0.38))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.red.opacity(0.14))
                        .overlay(Capsule().strokeBorder(Color.red.opacity(0.32), lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    // MARK: - Studio Bento Building Blocks

    private var studioCardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func studioSectionCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selectedTab.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
            }
            content()
        }
        .padding(13)
        .background(studioCardBackground)
    }

    private func studioToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.46))
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func studioSliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String = "%.2f"
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 135, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func tabToggleCard(title: String, subtitle: String, icon: String, isOn: Binding<Bool>, disabled: Bool) -> some View {
        Button {
            if !disabled {
                isOn.wrappedValue.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isOn.wrappedValue ? Color.emerald : .white.opacity(0.45))
                    Spacer()
                    Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isOn.wrappedValue ? Color.emerald : .white.opacity(0.28))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn.wrappedValue ? Color.emerald.opacity(0.11) : Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isOn.wrappedValue ? Color.emerald.opacity(0.45) : Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .opacity(disabled ? 0.65 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preset Helpers

    private func presetPreviewGradient(_ preset: StudioAppearancePreset) -> LinearGradient {
        switch preset {
        case .liquidGlass:
            return LinearGradient(
                colors: [Color.white.opacity(0.22), Color.cyan.opacity(0.28), Color.black.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .smokyFrosted:
            return LinearGradient(
                colors: [Color(red: 0.22, green: 0.25, blue: 0.34), Color(red: 0.06, green: 0.07, blue: 0.11)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .crystalWings:
            return LinearGradient(
                colors: [Color.white.opacity(0.35), Color.purple.opacity(0.28), Color.cyan.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .oledBlack:
            return LinearGradient(
                colors: [Color(white: 0.04), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func isPresetActive(_ preset: StudioAppearancePreset) -> Bool {
        switch preset {
        case .oledBlack:
            return theme == NotchTheme.dark.rawValue
        case .liquidGlass:
            return theme == NotchTheme.glass.rawValue
                && glassMaterial == GlassMaterial.ultraThin.rawValue
                && abs(glassTintOpacity - 0.32) < 0.03
                && !glassClosed
        case .smokyFrosted:
            return theme == NotchTheme.glass.rawValue
                && glassMaterial == GlassMaterial.thick.rawValue
                && abs(glassTintOpacity - 0.52) < 0.04
        case .crystalWings:
            return theme == NotchTheme.glass.rawValue
                && glassClosed
                && abs(glassTintOpacity - 0.16) < 0.04
        }
    }

    private func applyPreset(_ preset: StudioAppearancePreset) {
        switch preset {
        case .liquidGlass:
            theme = NotchTheme.glass.rawValue
            resetGlassDefaults()
        case .smokyFrosted:
            theme = NotchTheme.glass.rawValue
            glassMaterial = GlassMaterial.thick.rawValue
            glassBlurOpacity = 0.96
            glassTintOpacity = 0.52
            glassTopFade = 0.82
            glassSheen = 0.08
            glassBorderOpacity = 0.22
            glassShadowOpacity = 0.50
            glassAccentGlow = 0.15
            glassCardOpacity = 0.06
            glassCardBorderOpacity = 0.14
            glassCardBlur = false
            glassClosed = false
        case .crystalWings:
            theme = NotchTheme.glass.rawValue
            glassMaterial = GlassMaterial.ultraThin.rawValue
            glassBlurOpacity = 0.82
            glassTintOpacity = 0.16
            glassTopFade = 0.55
            glassSheen = 0.22
            glassBorderOpacity = 0.38
            glassShadowOpacity = 0.35
            glassAccentGlow = 0.26
            glassCardOpacity = 0.09
            glassCardBorderOpacity = 0.20
            glassCardBlur = true
            glassClosed = true
        case .oledBlack:
            theme = NotchTheme.dark.rawValue
            glassClosed = false
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

private extension Color {
    static let emerald = Color(red: 0.20, green: 0.84, blue: 0.54)
}

/// Standalone dark Studio window for BullshitNotch Settings.
@MainActor
enum NotchSettingsWindow {
    static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: NotchSettingsView()))
            w.title = "BullshitNotch Studio"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1.0)
            w.isReleasedWhenClosed = false
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                let size = w.frame.size
                // Position below the expanded notch so live preview is unobstructed.
                w.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                         y: max(frame.minY + 40, frame.midY - size.height / 2 - 70)))
            } else {
                w.center()
            }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    NotchModel.shared?.pinnedPreview = false
                    if let obs = closeObserver {
                        NotificationCenter.default.removeObserver(obs)
                        closeObserver = nil
                    }
                    window?.contentViewController = nil
                    window = nil
                }
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
