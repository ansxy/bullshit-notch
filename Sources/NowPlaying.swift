import AppKit
import SwiftUI

/// What's playing in Music or Spotify.
///
/// Since macOS 15.4 third-party apps can't read the system Now Playing info (MediaRemote), so this
/// listens for the players' own "state changed" broadcasts and asks them for details over AppleScript.
/// ponytail: Music + Spotify only; browser audio (YouTube etc.) isn't visible this way.
@MainActor
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    enum Player: String, CaseIterable {
        case spotify = "Spotify", music = "Music"
        var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    }
    enum Command: String { case playPause = "playpause", next = "next track", previous = "previous track" }

    /// Three-tone vibrant color palette extracted from album artwork (or generated as a fallback when a track has no cover).
    struct Palette: Equatable {
        let primary: NSColor
        let secondary: NSColor
        let tertiary: NSColor

        var primaryColor: Color { Color(nsColor: primary) }
        var secondaryColor: Color { Color(nsColor: secondary) }
        var tertiaryColor: Color { Color(nsColor: tertiary) }

        static let fallback = Palette(
            primary: NSColor(calibratedHue: 0.76, saturation: 0.78, brightness: 0.92, alpha: 1),
            secondary: NSColor(calibratedHue: 0.90, saturation: 0.75, brightness: 0.88, alpha: 1),
            tertiary: NSColor(calibratedHue: 0.58, saturation: 0.72, brightness: 0.80, alpha: 1)
        )
    }

    @Published private(set) var player: Player?
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var artwork: NSImage? {
        didSet {
            if let artwork, let extracted = Self.extractPalette(from: artwork) {
                palette = extracted
            } else if hasTrack {
                palette = Self.seedPalette(for: "\(title)|\(artist)")
            } else {
                palette = nil
            }
            tint = palette?.primary
        }
    }
    /// Vibrant multi-color palette for the active track, used to drive the bar's ambient atmosphere.
    @Published private(set) var palette: Palette?
    /// Primary colour of the artwork, for tinting the notch glow.
    @Published private(set) var tint: NSColor?
    @Published private(set) var playing = false
    @Published private(set) var duration: Double = 0
    /// Position as of `positionAt`; use `elapsed(at:)` for a live value.
    @Published private(set) var position: Double = 0
    private var positionAt = Date()
    private var artworkKey = ""

    /// True whenever a track is loaded in the player (playing or paused).
    var hasTrack: Bool { player != nil && !title.isEmpty }

    /// Active palette whenever a track is loaded (falls back to a seeded vibrant palette while artwork is loading or missing).
    var activePalette: Palette? {
        guard hasTrack else { return nil }
        return palette ?? Self.seedPalette(for: "\(title)|\(artist)")
    }

    private init() {
        let center = DistributedNotificationCenter.default()
        for (name, player) in [("com.spotify.client.PlaybackStateChanged", Player.spotify),
                               ("com.apple.Music.playerInfo", .music)] {
            center.addObserver(forName: .init(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NowPlaying.shared.refresh(prefer: player) }
            }
        }
        refresh(prefer: nil)
    }

    func elapsed(at date: Date) -> Double {
        min(duration, position + (playing ? date.timeIntervalSince(positionAt) : 0))
    }

    func send(_ command: Command) {
        guard let player else { return }
        run("tell application \"\(player.rawValue)\" to \(command.rawValue)")
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        position = seconds
        positionAt = .now
        run("tell application \"\(player.rawValue)\" to set player position to \(seconds)")
    }

    /// Brings the active player (Spotify or Apple Music) to the front, or launches one if neither is running.
    func openPlayer() {
        let target = player
            ?? Player.allCases.first(where: \.isRunning)
            ?? (NSWorkspace.shared.urlForApplication(withBundleIdentifier: Player.spotify.bundleID) != nil ? .spotify : .music)
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func run(_ script: String) {
        DispatchQueue.global().async {
            _ = shell("/usr/bin/osascript", ["-e", script])
            DispatchQueue.main.async { NowPlaying.shared.refresh(prefer: nil) }
        }
    }

    /// Re-reads state from whichever running player is playing (the one that just broadcast wins ties).
    func refresh(prefer: Player?) {
        // Only talk to running apps; `tell application` would launch them.
        let candidates = ([prefer].compactMap { $0 } + Player.allCases.filter { $0 != prefer }).filter(\.isRunning)
        DispatchQueue.global().async {
            var best: (Player, [String])?
            for player in candidates {
                let fields = Self.query(player)
                guard fields.count >= 6 else { continue }
                if fields[0] == "playing" { best = (player, fields); break }
                if best == nil { best = (player, fields) }
            }
            DispatchQueue.main.async { NowPlaying.shared.apply(best) }
        }
    }

    private func apply(_ result: (Player, [String])?) {
        guard let (player, f) = result else {
            self.player = nil; title = ""; artist = ""; playing = false; artwork = nil; artworkKey = ""
            return
        }
        let number = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        self.player = player
        playing = f[0] == "playing"
        title = f[1]
        artist = f[2]
        duration = number(f[4])
        position = number(f[5])
        positionAt = .now

        let key = "\(player.rawValue)|\(f[1])|\(f[2])|\(f[3])"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil
        let artworkURL = f.count > 6 ? f[6] : ""
        DispatchQueue.global().async {
            let image = Self.fetchArtwork(player, url: artworkURL)
            DispatchQueue.main.async {
                if NowPlaying.shared.artworkKey == key { NowPlaying.shared.artwork = image }
            }
        }
    }

    /// Samples an album cover on a 16×16 grid and extracts up to three distinct, vibrancy-boosted colors.
    private static func extractPalette(from image: NSImage) -> Palette? {
        let side = 16
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        struct Bucket {
            var weight: CGFloat = 0
            var hSum: CGFloat = 0
            var sSum: CGFloat = 0
            var bSum: CGFloat = 0
        }

        let binCount = 12
        var bins = Array(repeating: Bucket(), count: binCount)
        var fallbackB: CGFloat = 0.5

        for y in 0..<side {
            for x in 0..<side {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let h = c.hueComponent
                let s = c.saturationComponent
                let b = c.brightnessComponent
                fallbackB = (fallbackB + b) * 0.5
                // Ignore near-black and washed-out white pixels when weighting vibrant hues.
                guard b > 0.10 else { continue }
                let vibrancy = max(0.05, s * s) * (1.0 - abs(b - 0.65) * 0.6)
                let idx = min(binCount - 1, max(0, Int(h * CGFloat(binCount))))
                bins[idx].weight += vibrancy
                bins[idx].hSum += h * vibrancy
                bins[idx].sSum += s * vibrancy
                bins[idx].bSum += b * vibrancy
            }
        }

        let ranked = bins.enumerated()
            .filter { $0.element.weight > 0 }
            .sorted { $0.element.weight > $1.element.weight }

        guard let first = ranked.first else {
            return .fallback
        }

        func makeVivid(_ bucket: Bucket, satFloor: CGFloat, brightFloor: CGFloat, brightCeil: CGFloat) -> (h: CGFloat, s: CGFloat, b: CGFloat, color: NSColor) {
            let h = (bucket.hSum / bucket.weight).truncatingRemainder(dividingBy: 1.0)
            let rawS = bucket.sSum / bucket.weight
            let rawB = bucket.bSum / bucket.weight
            // If cover is monochrome/greyscale, give it a subtle cool/warm tint rather than flat grey.
            let s = rawS < 0.08 ? 0.35 : min(0.96, max(satFloor, rawS * 1.25))
            let b = min(brightCeil, max(brightFloor, rawB * 1.15))
            return (h, s, b, NSColor(calibratedHue: h, saturation: s, brightness: b, alpha: 1.0))
        }

        func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let d = abs(a - b)
            return min(d, 1.0 - d)
        }

        let p1 = makeVivid(first.element, satFloor: 0.68, brightFloor: 0.76, brightCeil: 0.98)

        // Pick a second distinct hue bucket if available; otherwise shift hue for a rich duo-tone gradient.
        let secondBucket = ranked.dropFirst().first {
            let h = $0.element.hSum / $0.element.weight
            return hueDistance(h, p1.h) >= 0.11 && $0.element.weight >= first.element.weight * 0.14
        }?.element

        let p2: (h: CGFloat, s: CGFloat, b: CGFloat, color: NSColor)
        if let secondBucket {
            p2 = makeVivid(secondBucket, satFloor: 0.64, brightFloor: 0.72, brightCeil: 0.95)
        } else {
            let h2 = (p1.h + 0.12).truncatingRemainder(dividingBy: 1.0)
            let s2 = min(0.95, max(0.60, p1.s * 0.95))
            let b2 = min(0.92, max(0.68, p1.b * 0.92))
            p2 = (h2, s2, b2, NSColor(calibratedHue: h2, saturation: s2, brightness: b2, alpha: 1.0))
        }

        // Pick a third distinct bucket or shift in the opposite direction for atmospheric depth.
        let thirdBucket = ranked.dropFirst().first {
            let h = $0.element.hSum / $0.element.weight
            return hueDistance(h, p1.h) >= 0.14 && hueDistance(h, p2.h) >= 0.11 && $0.element.weight >= first.element.weight * 0.08
        }?.element

        let c3: NSColor
        if let thirdBucket {
            c3 = makeVivid(thirdBucket, satFloor: 0.58, brightFloor: 0.62, brightCeil: 0.88).color
        } else {
            let h3 = (p1.h + 0.86).truncatingRemainder(dividingBy: 1.0)
            c3 = NSColor(calibratedHue: h3, saturation: min(0.90, max(0.55, p1.s * 0.9)), brightness: 0.75, alpha: 1.0)
        }

        return Palette(primary: p1.color, secondary: p2.color, tertiary: c3)
    }

    /// Deterministic vibrant palette seeded from track metadata when artwork is unavailable.
    private static func seedPalette(for key: String) -> Palette {
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        let h1 = CGFloat(hash % 360) / 360.0
        let h2 = (h1 + 0.14).truncatingRemainder(dividingBy: 1.0)
        let h3 = (h1 + 0.82).truncatingRemainder(dividingBy: 1.0)
        return Palette(
            primary: NSColor(calibratedHue: h1, saturation: 0.78, brightness: 0.92, alpha: 1),
            secondary: NSColor(calibratedHue: h2, saturation: 0.74, brightness: 0.88, alpha: 1),
            tertiary: NSColor(calibratedHue: h3, saturation: 0.70, brightness: 0.78, alpha: 1)
        )
    }

    /// state, title, artist, album, duration (s), position (s), [artwork url] — one per line.
    nonisolated private static func query(_ player: Player) -> [String] {
        let durationSeconds = player == .spotify ? "((duration of t) / 1000)" : "(duration of t)"
        let artworkURL = player == .spotify ? " & linefeed & (artwork url of t)" : ""
        let script = """
        tell application "\(player.rawValue)"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & \(durationSeconds) & linefeed & player position\(artworkURL)
        end tell
        """
        return shell("/usr/bin/osascript", ["-e", script])
            .trimmingCharacters(in: .newlines)
            .components(separatedBy: "\n")
    }

    /// Spotify hands out an artwork URL; Music only gives raw image data, which we write to a temp file.
    nonisolated private static func fetchArtwork(_ player: Player, url: String) -> NSImage? {
        if player == .spotify {
            return URL(string: url).flatMap { try? Data(contentsOf: $0) }.flatMap(NSImage.init(data:))
        }
        let path = NSTemporaryDirectory() + "bullshitnotch-artwork"
        let script = """
        tell application "Music"
            try
                set d to raw data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        set f to open for access (POSIX file "\(path)") with write permission
        set eof f to 0
        write d to f
        close access f
        return "ok"
        """
        guard shell("/usr/bin/osascript", ["-e", script]).contains("ok") else { return nil }
        return NSImage(contentsOfFile: path)
    }
}
