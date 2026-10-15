import AppKit
import SwiftUI

/// Slides ContentView in from the right screen edge when the pointer touches that edge.
/// ponytail: one 2pt trigger strip on the main screen; add per-screen strips if multi-monitor matters.
final class EdgePanel: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var trigger: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let screen = NSScreen.main else { return }
        let edge = screen.visibleFrame

        let strip = NSWindow(
            contentRect: NSRect(x: edge.maxX - 2, y: edge.minY, width: 2, height: edge.height),
            styleMask: .borderless, backing: .buffered, defer: false)
        strip.contentView = HoverStrip { [weak self] in self?.show() }
        strip.backgroundColor = .clear
        strip.isOpaque = false
        strip.alphaValue = 0.01  // fully transparent windows stop receiving mouse events
        strip.level = .statusBar
        strip.ignoresMouseEvents = false
        strip.collectionBehavior = [.canJoinAllSpaces, .stationary]
        strip.orderFrontRegardless()
        trigger = strip
    }

    private func show() {
        guard let screen = NSScreen.main else { return }
        let edge = screen.visibleFrame

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: edge.maxX, y: edge.maxY - size.height - 8))
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(NSPoint(x: edge.maxX - size.width, y: panel.frame.minY))
        }
    }

    private func hide() {
        guard let panel, panel.isVisible, let screen = NSScreen.main else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX, y: panel.frame.minY))
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let root = ContentView()
            .environmentObject(TopBarApp.store)
            .environmentObject(TopBarApp.custom)
            .background(.ultraThinMaterial)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12))
            .onHover { [weak self] inside in
                if !inside { self?.hide() }
            }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.contentViewController = NSHostingController(rootView: root)  // window resizes to fit content
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Content height changes when a section opens; keep the top edge pinned.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            guard let panel, panel.isVisible, let screen = NSScreen.main else { return }
            let top = screen.visibleFrame.maxY - 8
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        }
        return panel
    }
}

/// Invisible edge strip that fires once when the pointer enters it.
private final class HoverStrip: NSView {
    private let onEnter: () -> Void

    init(onEnter: @escaping () -> Void) {
        self.onEnter = onEnter
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
}
