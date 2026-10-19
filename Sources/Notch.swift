import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers

/// boring.notch-style panel: a black shape hugging the camera notch. Live activities (HUD, charger,
/// agents, music) show beside the notch; hovering springs it open into Home / Shelf / TopBar tabs.
///
/// The window is a fixed, mostly transparent box under the notch. It ignores the mouse except while
/// the pointer is over the black shape, so the menu bar beneath it keeps working.
/// ponytail: built once for the notched (or main) screen at launch; rebuild on screen changes if displays get swapped.
@MainActor
final class NotchController: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var model: NotchModel!
    private var monitors: [Any] = []
    private var swipe = CGSize.zero
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        model = NotchModel(notch: Self.notchSize(of: screen))
        NotchModel.shared = model
        _ = (Battery.shared, NowPlaying.shared)  // start listening right away
        HUD.shared.setEnabled(UserDefaults.standard.bool(forKey: Pref.replaceHUD))

        // Menu bar icon: one click opens settings (a MenuBarExtra would always open a dropdown).
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "TopBar settings")
        item.button?.target = self
        item.button?.action = #selector(openSettings)
        statusItem = item

        let size = NSSize(width: 760, height: 820)  // room for the fully expanded panel
        panel = KeyablePanel(
            contentRect: NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)  // above the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: NotchView(model: model))
        host.sizingOptions = []  // keep the window its fixed size; the shape animates inside it
        panel.contentView = host
        panel.orderFrontRegardless()

        // Mouse monitors need no Accessibility permission (only key monitors do). Global ones also see
        // drags out of Finder, which is how a dragged file opens the notch for the shelf.
        let pointer: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: pointer) { [weak self] event in
            MainActor.assumeIsolated { self?.track(event.type) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: pointer) { [weak self] event in
            MainActor.assumeIsolated { self?.track(event.type) }
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.scroll(event) }
            return event
        } as Any)
    }

    @objc private func openSettings() {
        NotchSettingsWindow.show()
    }

    /// Open when the pointer reaches the black shape (or a file is dragged onto it); close when it leaves.
    /// Mouse events reach the window only while the pointer is over the shape.
    private func track(_ type: NSEvent.EventType) {
        if model.pinnedPreview {
            if !model.expanded { model.setExpanded(true) }
            if let settingsWindow = NotchSettingsWindow.window, settingsWindow.isVisible,
               settingsWindow.frame.contains(NSEvent.mouseLocation) {
                panel.ignoresMouseEvents = true
                return
            }
            let frame = panel.frame, size = model.shapeSize
            let shape = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                               width: size.width, height: size.height)
            let inside = shape.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
            panel.ignoresMouseEvents = !inside
            return
        }

        if let settingsWindow = NotchSettingsWindow.window, settingsWindow.isVisible,
           settingsWindow.frame.contains(NSEvent.mouseLocation) {
            if model.expanded { model.setExpanded(false) }
            panel.ignoresMouseEvents = true
            return
        }

        let frame = panel.frame, size = model.shapeSize
        let shape = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                           width: size.width, height: size.height)
        let inside = shape.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        let openOnHover = UserDefaults.standard.bool(forKey: Pref.openOnHover)
        if inside && !model.expanded && (openOnHover || type == .leftMouseDragged) { model.setExpanded(true) }
        if !inside && model.expanded { model.setExpanded(false) }
    }

    /// Trackpad gestures: swipe down on the closed notch opens it; swipe sideways on Home skips tracks.
    private func scroll(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return }  // trackpad, not a wheel mouse
        guard event.window === panel else { return }

        let frame = panel.frame, size = model.shapeSize
        let shape = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                           width: size.width, height: size.height)
        guard shape.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) else { return }

        if event.phase == .began { swipe = .zero }
        // Normalize "natural scrolling" so + means the fingers moved right / down.
        let finger: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        swipe.width += event.scrollingDeltaX * finger
        swipe.height += event.scrollingDeltaY * finger
        guard event.phase == .ended else { return }
        if !model.expanded, swipe.height > 30 {
            model.setExpanded(true)
        } else if model.expanded, model.tab == .home, abs(swipe.width) > 80, abs(swipe.width) > abs(swipe.height) {
            NowPlaying.shared.send(swipe.width < 0 ? .next : .previous)
        }
    }

    /// The camera housing's size; on screens without one, a menu-bar-high fake notch.
    private static func notchSize(of screen: NSScreen) -> CGSize {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        return CGSize(width: 190, height: max(screen.frame.maxY - screen.visibleFrame.maxY, 24))
    }
}

/// Borderless panels can't become key by default, which would block typing in the add-section/item fields.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum NotchTab: CaseIterable {
    case home, shelf, topbar

    var icon: String {
        switch self {
        case .home:   return "house.fill"
        case .shelf:  return "tray.full.fill"
        case .topbar: return "rectangle.3.group.fill"
        }
    }
    var title: String {
        switch self {
        case .home:   return "Home"
        case .shelf:  return "Shelf"
        case .topbar: return "Git, Work & Agents"
        }
    }
}

@MainActor
final class NotchModel: ObservableObject {
    static var shared: NotchModel?
    let notch: CGSize
    @Published private(set) var expanded = false
    @Published var pinnedPreview = false {
        didSet { setExpanded(pinnedPreview) }
    }
    @Published var tab = NotchTab.home
    /// Laid-out size of the black shape, for hit-testing the pointer (not published: layout writes it).
    var shapeSize: CGSize

    init(notch: CGSize) {
        self.notch = notch
        shapeSize = notch
    }

    func setExpanded(_ on: Bool) {
        // Opening overshoots a little so the drop wobbles like liquid; closing stays crisp.
        withAnimation(on ? .spring(response: 0.45, dampingFraction: 0.62) : .spring(response: 0.32, dampingFraction: 0.9)) {
            expanded = on
        }
    }
}

private struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var agents = AgentStore.shared
    @ObservedObject private var music = NowPlaying.shared
    @ObservedObject private var battery = Battery.shared
    @ObservedObject private var hud = HUD.shared
    @AppStorage(Pref.liveAgents) private var liveAgents = true
    @AppStorage(Pref.liveMusic) private var liveMusic = true
    @AppStorage(Pref.liveBattery) private var liveBattery = true
    @AppStorage(Pref.widthAdjust) private var widthAdjust = 0.0
    @AppStorage(Pref.heightAdjust) private var heightAdjust = 0.0
    @AppStorage(Pref.idleWidth) private var idleWidth = 48.0
    @AppStorage(Pref.tabHome) private var tabHome = true
    @AppStorage(Pref.tabShelf) private var tabShelf = true
    @AppStorage(Pref.tabTopbar) private var tabTopbar = true

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
    @AppStorage(Pref.glassClosed) private var glassClosed = false
    @AppStorage(Pref.musicAmbient) private var musicAmbient = true
    @AppStorage(Pref.musicAmbientIntensity) private var musicAmbientIntensity = 0.75

    @State private var dropTargeted = false
    @State private var breathe = false
    @Namespace private var tabHighlight

    private var isGlass: Bool {
        theme == NotchTheme.glass.rawValue && (model.expanded || glassClosed)
    }

    private var currentMaterial: Material {
        (GlassMaterial(rawValue: glassMaterial) ?? .ultraThin).swiftUIMaterial
    }

    /// Active vibrant palette when music ambient is enabled and a track is loaded (playing or paused).
    private var musicPalette: NowPlaying.Palette? {
        musicAmbient ? music.activePalette : nil
    }

    /// Effective strength of the music ambient effect (full while playing, softly blended while paused).
    private var ambientLevel: Double {
        guard musicPalette != nil else { return 0 }
        return musicAmbientIntensity * (music.playing ? 1.0 : 0.58)
    }

    /// Tabs switched on in Settings (never empty: Settings keeps at least one on).
    private var visibleTabs: [NotchTab] {
        let on = NotchTab.allCases.filter {
            switch $0 {
            case .home:   return tabHome
            case .shelf:  return tabShelf
            case .topbar: return tabTopbar
            }
        }
        return on.isEmpty ? [.home] : on
    }

    /// The selected tab, or the first visible one if it was just switched off.
    private var currentTab: NotchTab { visibleTabs.contains(model.tab) ? model.tab : visibleTabs[0] }

    private let activeWing: CGFloat = 64  // each live-activity "ear" beside the notch
    /// Wing width: full width during active HUD/music/agents, or resting width when idle so the notch stays visible.
    private var wing: CGFloat {
        activity != .none ? activeWing : max(0, idleWidth / 2)
    }

    /// Closed: a tight notch. Open: smooth water-drop/slime meniscus at top corners, straight sides, rounded bottom.
    private var shape: NotchShape {
        model.expanded
            ? NotchShape(flare: 24, flareDepth: 26, bottom: 26, bulge: 0)
            : NotchShape(flare: 8, flareDepth: 8, bottom: 10, bulge: 0)
    }

    private var notch: CGSize {
        CGSize(width: model.notch.width + widthAdjust, height: model.notch.height + heightAdjust)
    }

    /// What shows beside the closed notch, highest priority first.
    private enum Activity { case none, hud, battery, agents, music }
    private var activity: Activity {
        if hud.visible { return .hud }
        if liveBattery && battery.justChanged { return .battery }
        if liveAgents && agents.busyCount > 0 { return .agents }
        if liveMusic && music.playing { return .music }
        return .none
    }

    private var rimOpacity: Double {
        if isGlass {
            return model.expanded ? glassBorderOpacity : glassBorderOpacity * 0.6
        }
        return model.expanded ? 0.16 : 0.08
    }

    private var shadowStrength: Double {
        theme == NotchTheme.glass.rawValue ? glassShadowOpacity : 0.35
    }

    private var glowStrength: Double {
        theme == NotchTheme.glass.rawValue ? glassAccentGlow : 0.08
    }

    var body: some View {
        Group {
            if model.expanded { expanded } else { collapsed }
        }
        .padding(.horizontal, shape.flare)
        .background { surface }
        .clipShape(shape)
        // Shadow is cast by a backing shape outside clipShape so we don't need .compositingGroup(),
        // keeping SwiftUI's Material backdrop blur live over windows behind the notch.
        .background {
            if model.expanded {
                shape
                    .fill(.black.opacity(0.01))
                    .shadow(color: .black.opacity(shadowStrength), radius: 14, y: 6)
                    .shadow(color: (accent ?? .clear).opacity(glowStrength * 0.7), radius: 12, y: 4)
            }
        }
        // Hairline rim that fades in from the top, so the flared corners still melt into the bezel.
        .overlay {
            shape.stroke(
                LinearGradient(
                    colors: [
                        .white.opacity(isGlass ? rimOpacity * (1 - glassTopFade) : 0),
                        .white.opacity(rimOpacity)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .background(GeometryReader { geo in
            Color.clear.task(id: geo.size) { model.shapeSize = geo.size }
        })
        // Files dropped anywhere on the notch land on the shelf.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Shelf.shared.add(from: providers)
            return true
        }
        .onChange(of: dropTargeted) { if dropTargeted && tabShelf { model.tab = .shelf } }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.controlActiveState, .key)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: wing)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: activity)
        .animation(.easeInOut(duration: 0.55), value: music.palette)
        .task(id: music.playing) {
            if music.playing {
                breathe = false
                withAnimation(.easeInOut(duration: 3.1).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.6)) {
                    breathe = false
                }
            }
        }
    }

    /// Surface background: outside/closed notch follows Settings; inside (expanded) infuses the music ambient aurora.
    private var surface: some View {
        ZStack {
            if isGlass {
                Rectangle()
                    .fill(currentMaterial)
                    .opacity(glassBlurOpacity)
                Color.black.opacity(glassTintOpacity)
            } else {
                Color.black
                if model.expanded {
                    LinearGradient(colors: [.black, Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                }
            }

            if model.expanded {
                if let palette = musicPalette {
                    expandedMusicAmbient(palette: palette)
                } else if let accent {
                    RadialGradient(
                        colors: [accent.opacity(isGlass ? glassAccentGlow : 0.08), .clear],
                        center: .bottom,
                        startRadius: 0,
                        endRadius: isGlass ? 300 : 280
                    )
                }
            }

            if isGlass {
                if glassSheen > 0 {
                    LinearGradient(
                        colors: [.white.opacity(glassSheen), .clear, .white.opacity(glassSheen * 0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                if glassTopFade > 0 {
                    LinearGradient(
                        colors: [.black.opacity(glassTopFade), .clear],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: model.expanded ? 0.38 : 1.0)
                    )
                }
            } else if model.expanded && musicPalette != nil {
                LinearGradient(
                    colors: [.black.opacity(0.82), .clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.32)
                )
            }
        }
    }

    /// Expanded bar ambient: diffused album cover + three-color breathing aurora mesh inside the open panel.
    @ViewBuilder
    private func expandedMusicAmbient(palette: NowPlaying.Palette) -> some View {
        ZStack {
            if let art = music.artwork {
                GeometryReader { geo in
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(breathe ? 1.24 : 1.06)
                        .offset(x: breathe ? 14 : -14, y: breathe ? -6 : 6)
                        .blur(radius: 36)
                        .opacity((isGlass ? 0.40 : 0.32) * ambientLevel)
                }
            }
            RadialGradient(
                colors: [
                    palette.primaryColor.opacity((isGlass ? 0.46 : 0.34) * ambientLevel),
                    .clear
                ],
                center: breathe ? UnitPoint(x: 0.22, y: 0.55) : UnitPoint(x: 0.14, y: 0.88),
                startRadius: 4,
                endRadius: breathe ? 340 : 270
            )
            RadialGradient(
                colors: [
                    palette.secondaryColor.opacity((isGlass ? 0.40 : 0.30) * ambientLevel),
                    .clear
                ],
                center: breathe ? UnitPoint(x: 0.78, y: 0.86) : UnitPoint(x: 0.86, y: 0.46),
                startRadius: 4,
                endRadius: breathe ? 320 : 260
            )
            RadialGradient(
                colors: [
                    palette.tertiaryColor.opacity((isGlass ? 0.32 : 0.24) * ambientLevel),
                    .clear
                ],
                center: breathe ? UnitPoint(x: 0.52, y: 0.96) : UnitPoint(x: 0.48, y: 0.72),
                startRadius: 0,
                endRadius: 240
            )
        }
    }

    /// Glow colour from the live activity: the fire's colour, the album art, the charger, the HUD.
    private var accent: Color? {
        switch activity {
        case .agents:  return Color(nsColor: agents.fire.accent)
        case .music:   return music.tint.map { Color(nsColor: $0) } ?? .white
        case .battery: return .green
        case .hud:     return .white
        case .none:    return nil
        }
    }

    // MARK: Closed

    private var collapsed: some View {
        HStack(spacing: 0) {
            if wing > 0 {
                leftWing
                    .frame(width: wing)
                    .transition(.opacity)
            }
            Color.clear.frame(width: notch.width)  // the camera housing itself
            if wing > 0 {
                rightWing
                    .frame(width: wing)
                    .transition(.opacity)
            }
        }
        .frame(height: notch.height)
        .contentShape(Rectangle())
        .onTapGesture { model.setExpanded(true) }  // for when "open on hover" is off
    }

    @ViewBuilder private var leftWing: some View {
        switch activity {
        case .hud:
            Image(systemName: hudIcon).foregroundStyle(.white)
        case .battery:
            Image(systemName: battery.pluggedIn ? "bolt.fill" : "powerplug")
                .foregroundStyle(battery.pluggedIn ? .green : .white)
        case .agents:
            Image(nsImage: agents.fire.image())
        case .music:
            ArtworkView(image: music.artwork, size: 22, radius: 5)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private var rightWing: some View {
        switch activity {
        case .hud:
            LevelBar(value: hud.muted ? 0 : Double(hud.level)).frame(width: 42, height: 5)
        case .battery:
            BatteryLabel(battery: battery)
        case .agents:
            Text("\(agents.busyCount)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: agents.fire.accent))
        case .music:
            Visualizer(playing: music.playing).frame(width: 22, height: 14)
        case .none:
            EmptyView()
        }
    }

    private var hudIcon: String {
        if hud.kind == .brightness { return "sun.max.fill" }
        return hud.muted || hud.level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }

    // MARK: Open

    private var expanded: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch currentTab {
                case .home:
                    HomeView()
                case .shelf:
                    ShelfView()
                case .topbar:
                    WorkspaceView()
                        .environmentObject(TopBarApp.store)
                        .environmentObject(TopBarApp.custom)
                }
            }
            .padding(.top, 8)
        }
        .frame(width: 620)
        .padding([.horizontal, .bottom], 14)
        .transition(.blurReplace)
    }

    /// Tabs left of the camera, battery + settings right of it.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(visibleTabs, id: \.self) { tab in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.tab = tab }
                    } label: {
                        Image(systemName: tab.icon)
                            .frame(width: 32, height: 24)
                            .foregroundStyle(currentTab == tab ? .white : .white.opacity(0.55))
                            .background {
                                if currentTab == tab {
                                    if let palette = musicPalette {
                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        palette.primaryColor.opacity(0.42),
                                                        palette.secondaryColor.opacity(0.34)
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .overlay(
                                                Capsule().strokeBorder(palette.primaryColor.opacity(0.55), lineWidth: 0.8)
                                            )
                                            .matchedGeometryEffect(id: "tab", in: tabHighlight)
                                    } else {
                                        Capsule().fill(.white.opacity(0.16)).matchedGeometryEffect(id: "tab", in: tabHighlight)
                                    }
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notch.width)
            HStack(spacing: 12) {
                if battery.hasBattery { BatteryLabel(battery: battery) }
                Button { NotchSettingsWindow.show() } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(.plain)
                    .help("Settings")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: notch.height)
        .foregroundStyle(.white.opacity(0.85))
    }
}

// MARK: - Home: music, calendar

private struct HomeView: View {
    @AppStorage(Pref.music) private var music = true
    @AppStorage(Pref.agenda) private var agenda = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if music { MusicCard().frame(width: 150) }  // square: matches the row height below
            if agenda {
                AgendaCard().notchCard()
            } else if !music {
                Text("Everything on Home is turned off in Settings")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 150)
    }
}

/// Album cover fills the card; title, progress and controls sit on a dark fade at the bottom.
private struct MusicCard: View {
    @ObservedObject private var music = NowPlaying.shared
    @AppStorage(Pref.musicAmbient) private var musicAmbient = true

    private var palette: NowPlaying.Palette? {
        musicAmbient ? music.activePalette : nil
    }

    var body: some View {
        if music.player == nil {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.title)
                Text("Nothing playing").font(.callout)
                Text("Play something in Music or Spotify").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { music.openPlayer() }
            .help("Click to open Music or Spotify")
            .notchCard()
        } else {
            let rect = RoundedRectangle(cornerRadius: 14, style: .continuous)
            VStack(spacing: 4) {
                // Top area: mini equalizer badge in corner; clicking opens the player.
                HStack {
                    Spacer()
                    if music.playing {
                        Visualizer(playing: true, palette: palette)
                            .frame(width: 18, height: 11)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .contentShape(Rectangle())
                .onTapGesture { music.openPlayer() }
                .help("Click to open \(music.player?.rawValue ?? "player")")

                VStack(spacing: 0) {
                    Text(music.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(music.artist)
                        .font(.caption)
                        .foregroundStyle(palette?.primaryColor.opacity(0.95) ?? .white.opacity(0.7))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { music.openPlayer() }
                progress
                HStack(spacing: 20) {
                    control("backward.fill", .previous)
                    Button { music.send(.playPause) } label: {
                        Image(systemName: music.playing ? "pause.fill" : "play.fill")
                            .font(.callout.weight(.bold))
                            .frame(width: 26, height: 26)
                            .background {
                                if let palette {
                                    Circle().fill(
                                        LinearGradient(
                                            colors: [palette.primaryColor.opacity(0.55), palette.secondaryColor.opacity(0.45)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                } else {
                                    Circle().fill(.white.opacity(0.18))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    control("forward.fill", .next)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background {
                ZStack {
                    if let art = music.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else if let palette {
                        LinearGradient(
                            colors: [palette.primaryColor.opacity(0.45), palette.secondaryColor.opacity(0.35), .black],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "music.note").font(.system(size: 40)).foregroundStyle(.white.opacity(0.5))
                    } else {
                        Color.white.opacity(0.08)
                        Image(systemName: "music.note").font(.system(size: 40)).foregroundStyle(.secondary)
                    }
                    LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.55), .black.opacity(0.88)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(rect)
            .overlay(
                rect.strokeBorder(
                    LinearGradient(
                        colors: [
                            (palette?.primaryColor ?? .white).opacity(palette != nil ? 0.45 : 0.1),
                            (palette?.secondaryColor ?? .white).opacity(palette != nil ? 0.28 : 0.1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
        }
    }

    /// Click anywhere on the bar to seek.
    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = music.elapsed(at: context.date)
            VStack(spacing: 2) {
                GeometryReader { geo in
                    LevelBar(value: music.duration > 0 ? elapsed / music.duration : 0, palette: palette)
                        .contentShape(Rectangle())
                        .onTapGesture { point in
                            music.seek(to: max(0, min(1, point.x / geo.size.width)) * music.duration)
                        }
                }
                .frame(height: 5)
                HStack {
                    Text(Self.time(elapsed))
                    Spacer()
                    Text("-" + Self.time(music.duration - elapsed))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func control(_ icon: String, _ command: NowPlaying.Command) -> some View {
        Button { music.send(command) } label: { Image(systemName: icon) }
            .buttonStyle(.plain)
    }

    private static func time(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
    }
}

private struct AgendaCard: View {
    @ObservedObject private var agenda = Agenda.shared
    @ObservedObject private var music = NowPlaying.shared
    @AppStorage(Pref.musicAmbient) private var musicAmbient = true
    private var today: Date { Calendar.current.startOfDay(for: .now) }

    private var palette: NowPlaying.Palette? {
        musicAmbient ? music.activePalette : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            days
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if !agenda.calendarAccess && !agenda.remindersAccess {
                        Text("Allow Calendars and Reminders for TopBar in System Settings › Privacy & Security.")
                            .foregroundStyle(.secondary)
                    } else if agenda.events.isEmpty && agenda.reminders.isEmpty {
                        Text("Nothing scheduled").foregroundStyle(.secondary)
                    }
                    ForEach(Array(agenda.events.enumerated()), id: \.offset) { _, event in
                        HStack(spacing: 6) {
                            Capsule().fill(Color(nsColor: event.calendar.color)).frame(width: 3, height: 14)
                            Text(event.title).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(event.isAllDay ? "all-day" : event.startDate.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        .id("\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)|\(event.title ?? "")")
                        .contentShape(Rectangle())
                        .hoverHighlight(radius: 5)
                        .onTapGesture { Agenda.open(event) }
                        .help("Open in Calendar")
                    }
                    ForEach(Array(agenda.reminders.enumerated()), id: \.offset) { _, reminder in
                        HStack(spacing: 6) {
                            Button { agenda.complete(reminder) } label: { Image(systemName: "circle") }
                                .buttonStyle(.plain)
                                .help("Mark as done")
                            Text(reminder.title ?? "").lineLimit(1)
                        }
                        .id("\(reminder.calendarItemIdentifier)|\(reminder.title ?? "")")
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { Agenda.openCalendarApp() }
            .help("Click to open Calendar")

            if let meeting = agenda.nextMeeting { nextMeetingRow(meeting) }
        }
        .onAppear { agenda.start() }
    }

    /// "Next: Standup · 15:00   [Join]" — Join opens the call link, the rest opens the event.
    private func nextMeetingRow(_ event: EKEvent) -> some View {
        let live = event.startDate <= .now
        return HStack(spacing: 6) {
            Image(systemName: "video.fill").font(.caption2).foregroundStyle(live ? .green : .secondary)
            Text(event.title ?? "Meeting").lineLimit(1)
            Text(live ? "now" : Self.when(event.startDate)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if let link = agenda.nextMeetingLink {
                Button("Join") { NSWorkspace.shared.open(link) }
                    .buttonStyle(.plain)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background((live ? Color.green : (palette?.primaryColor ?? Color.accentColor)).opacity(0.8), in: Capsule())
                    .help(link.absoluteString)
            }
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { Agenda.open(event) }
    }

    /// "15:00" today, otherwise "Fri 15:00".
    private static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Full week (-1...5) stretched across the entire width of the card; tap to switch day.
    private var days: some View {
        HStack(spacing: 4) {
            ForEach(-1...5, id: \.self) { offset in
                let day = Calendar.current.date(byAdding: .day, value: offset, to: today) ?? today
                let selected = day == agenda.day
                Button { agenda.day = day } label: {
                    VStack(spacing: 1) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundStyle(.secondary)
                        Text(day.formatted(.dateTime.day())).font(.caption.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                        if selected {
                            if let palette {
                                shape.fill(
                                    LinearGradient(
                                        colors: [palette.primaryColor.opacity(0.72), palette.secondaryColor.opacity(0.58)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            } else {
                                shape.fill(Color.accentColor.opacity(0.8))
                            }
                        } else {
                            shape.fill(.white.opacity(0.04))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Button {
                agenda.checkAuthorizationAndReload(resetCache: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 30)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Refresh calendar and reminders")
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shelf

private struct ShelfView: View {
    @ObservedObject private var shelf = Shelf.shared
    @AppStorage(Pref.airDrop) private var airDrop = true
    @State private var airDropTargeted = false

    var body: some View {
        HStack(spacing: 12) {
            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.title)
                    Text("Drop files here").font(.callout)
                    Text(airDrop ? "Drag them out again, or AirDrop them" : "Drag them out again")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(shelf.items, id: \.self) { ShelfItem(url: $0, airDrop: airDrop) }
                    }
                }
                .notchCard()
            }
            VStack(spacing: 8) {
                if airDrop {
                    VStack(spacing: 4) {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.title2)
                        Text("AirDrop").font(.caption)
                    }
                    .frame(width: 96, height: 90)
                    .background(airDropTargeted ? Color.blue.opacity(0.6) : Color.white.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07)))
                    .contentShape(Rectangle())
                    .onDrop(of: [.fileURL], isTargeted: $airDropTargeted) { providers in
                        Shelf.airDrop(from: providers)
                        return true
                    }
                    .onTapGesture { Shelf.airDrop(shelf.items) }
                    .help("Drop files here to AirDrop them, or click to AirDrop everything on the shelf")
                }
                Button("Clear") { shelf.clear() }
                    .buttonStyle(.borderless)
                    .disabled(shelf.items.isEmpty)
            }
        }
        .frame(height: 150)
    }
}

private struct ShelfItem: View {
    let url: URL
    let airDrop: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 52, height: 52)
            Text(url.lastPathComponent)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 76)
        }
        .padding(6)
        .contentShape(Rectangle())
        .hoverHighlight(radius: 10)
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if airDrop { Button("AirDrop") { Shelf.airDrop([url]) } }
            Divider()
            Button("Remove from Shelf") { Shelf.shared.remove(url) }
        }
        .help(url.path)
    }
}

// MARK: - Small pieces

private struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    var palette: NowPlaying.Palette? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(palette?.primaryColor ?? .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background((palette?.primaryColor ?? Color.white).opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay {
            if let palette {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [palette.primaryColor.opacity(0.8), palette.secondaryColor.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
        }
        .shadow(color: (palette?.primaryColor ?? .clear).opacity(0.45), radius: 4)
    }
}

/// ponytail: decorative bars, not a real spectrum — apps can't tap system audio without a capture permission.
private struct Visualizer: View {
    let playing: Bool
    var palette: NowPlaying.Palette? = nil
    @State private var heights: [CGFloat] = [5, 10, 6, 9]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(barFill(index: i))
                    .frame(width: 3, height: playing ? heights[i] : 3)
            }
        }
        .shadow(color: (palette?.primaryColor ?? .clear).opacity(playing ? 0.5 : 0), radius: 3)
        .task(id: playing) {
            guard playing else { return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.45)) {
                    heights = heights.map { $0 > 8 ? .random(in: 4...7) : .random(in: 9...13) }
                }
                try? await Task.sleep(for: .milliseconds(440))
            }
        }
    }

    private func barFill(index: Int) -> AnyShapeStyle {
        if let palette {
            let top = index % 2 == 0 ? palette.primaryColor : palette.secondaryColor
            let bottom = index % 2 == 0 ? palette.secondaryColor : palette.tertiaryColor
            return AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(Color.white)
    }
}

private struct LevelBar: View {
    let value: Double  // 0...1
    var palette: NowPlaying.Palette? = nil

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.white.opacity(0.2))
                .overlay(alignment: .leading) {
                    if let palette {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [palette.primaryColor, palette.secondaryColor],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * max(0, min(1, value)))
                            .shadow(color: palette.primaryColor.opacity(0.6), radius: 3)
                    } else {
                        Capsule()
                            .fill(.white)
                            .frame(width: geo.size.width * max(0, min(1, value)))
                    }
                }
        }
    }
}

private struct BatteryLabel: View {
    @ObservedObject var battery: Battery

    var body: some View {
        HStack(spacing: 3) {
            Text("\(battery.level)%").font(.caption.monospacedDigit())
            Image(systemName: icon).foregroundStyle(color)
        }
    }

    private var icon: String {
        if battery.charging { return "battery.100percent.bolt" }
        switch battery.level {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default:    return "battery.0percent"
        }
    }

    private var color: Color {
        if battery.charging { return .green }
        return battery.level <= 20 && !battery.pluggedIn ? .red : .white
    }
}

/// The notch silhouette. Top corners flare outward into the screen edge (a meniscus: deep and smooth
/// when open, like a drop clinging to the bezel); sides bow out by `bulge`; bottom corners are rounded.
/// Every parameter animates, so opening morphs the tight notch into the drop.
private struct NotchShape: Shape {
    var flare: CGFloat       // how far each top corner reaches out sideways
    var flareDepth: CGFloat  // how far down that curve runs before meeting the side
    var bottom: CGFloat
    var bulge: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(flare, flareDepth), AnimatablePair(bottom, bulge)) }
        set {
            flare = newValue.first.first; flareDepth = newValue.first.second
            bottom = newValue.second.first; bulge = newValue.second.second
        }
    }

    func path(in r: CGRect) -> Path {
        let left = r.minX + flare, right = r.maxX - flare
        let depth = min(flareDepth, r.height / 2), radius = min(bottom, (r.height - depth) / 2, (right - left) / 2)
        let midY = (r.minY + depth + r.maxY - radius) / 2
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        // Left meniscus: smooth, organic fluid flare spreading into the top bezel.
        p.addCurve(to: CGPoint(x: left, y: r.minY + depth),
                   control1: CGPoint(x: left - flare * 0.45, y: r.minY),
                   control2: CGPoint(x: left, y: r.minY + depth * 0.45))
        // Left side: straight down to the bottom corner.
        if bulge != 0 {
            p.addQuadCurve(to: CGPoint(x: left, y: r.maxY - radius), control: CGPoint(x: left - bulge * 2, y: midY))
        } else {
            p.addLine(to: CGPoint(x: left, y: r.maxY - radius))
        }
        // Bottom-left: a soft, continuous (squircle-ish) corner.
        p.addCurve(to: CGPoint(x: left + radius, y: r.maxY),
                   control1: CGPoint(x: left, y: r.maxY - radius * 0.45),
                   control2: CGPoint(x: left + radius * 0.45, y: r.maxY))
        p.addLine(to: CGPoint(x: right - radius, y: r.maxY))
        p.addCurve(to: CGPoint(x: right, y: r.maxY - radius),
                   control1: CGPoint(x: right - radius * 0.45, y: r.maxY),
                   control2: CGPoint(x: right, y: r.maxY - radius * 0.45))
        // Right side: straight up to the top curve.
        if bulge != 0 {
            p.addQuadCurve(to: CGPoint(x: right, y: r.minY + depth), control: CGPoint(x: right + bulge * 2, y: midY))
        } else {
            p.addLine(to: CGPoint(x: right, y: r.minY + depth))
        }
        // Right meniscus: curves out smoothly into the top bezel.
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY),
                   control1: CGPoint(x: right, y: r.minY + depth * 0.45),
                   control2: CGPoint(x: right + flare * 0.45, y: r.minY))
        p.closeSubpath()
        return p
    }
}
