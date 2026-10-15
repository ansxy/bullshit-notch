import AppKit

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

    @Published private(set) var player: Player?
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var artwork: NSImage? { didSet { tint = artwork.flatMap(Self.averageColor) } }
    /// Average colour of the artwork, for tinting the notch glow.
    @Published private(set) var tint: NSColor?
    @Published private(set) var playing = false
    @Published private(set) var duration: Double = 0
    /// Position as of `positionAt`; use `elapsed(at:)` for a live value.
    @Published private(set) var position: Double = 0
    private var positionAt = Date()
    private var artworkKey = ""

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
            self.player = nil; playing = false; artwork = nil; artworkKey = ""
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

    /// Draws the image into a single pixel and reads it back.
    private static func averageColor(_ image: NSImage) -> NSColor? {
        guard let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixel)
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        return pixel.colorAt(x: 0, y: 0)
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
        let path = NSTemporaryDirectory() + "topbar-artwork"
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
