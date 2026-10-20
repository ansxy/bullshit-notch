import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Network
import ScreenCaptureKit
import SwiftUI

// MARK: - Data Models

enum QATargetMode: String, CaseIterable, Identifiable {
    case window = "App Window"
    case screen = "Full Screen"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .window: return "macwindow"
        case .screen: return "display"
        }
    }
}

struct QAWindowTarget: Identifiable, Hashable {
    let id: CGWindowID
    let appName: String
    let bundleID: String
    let title: String
    let frame: CGRect

    var displayLabel: String {
        if title.isEmpty { return appName }
        return "\(appName) — \(title)"
    }
}

enum QAEventKind: String, Codable {
    case click = "click"
    case input = "input"
    case navigation = "navigation"
    case consoleError = "console.error"
    case consoleWarn = "console.warn"
    case consoleLog = "console.log"
    case pageError = "page.error"
    case fetch = "fetch"
    case flag = "flag"

    var icon: String {
        switch self {
        case .click:        return "cursorarrow.click"
        case .input:        return "keyboard"
        case .navigation:   return "globe"
        case .consoleError: return "exclamationmark.octagon.fill"
        case .consoleWarn:  return "exclamationmark.triangle.fill"
        case .consoleLog:   return "text.alignleft"
        case .pageError:    return "xmark.octagon.fill"
        case .fetch:        return "arrow.left.arrow.right"
        case .flag:         return "flag.fill"
        }
    }

    var isError: Bool {
        self == .consoleError || self == .pageError
    }
}

struct QATelemetryEvent: Identifiable, Codable {
    var id = UUID()
    let timestamp: TimeInterval // seconds since recording started
    let kind: QAEventKind
    let summary: String
    var detail: String? = nil
    var method: String? = nil
    var status: Int? = nil
    var url: String? = nil
    var requestBody: String? = nil
    var responseBody: String? = nil
    var screenshotFilename: String? = nil

    var isFailure: Bool {
        if kind.isError { return true }
        if kind == .fetch, let s = status, s >= 400 { return true }
        return false
    }

    var formattedTime: String {
        let mins = Int(timestamp) / 60
        let secs = Int(timestamp) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

struct QASessionSummary: Identifiable {
    let id = UUID()
    let startedAt: Date
    let duration: TimeInterval
    let folderURL: URL
    let videoURL: URL?
    let reportURL: URL
    let targetName: String
    let events: [QATelemetryEvent]

    var errorCount: Int {
        events.filter(\.isFailure).count
    }

    var fetchCount: Int {
        events.filter { $0.kind == .fetch }.count
    }

    var screenshotCount: Int {
        events.compactMap(\.screenshotFilename).count
    }
}

// MARK: - QA Recorder Store

@MainActor
final class QARecorderStore: NSObject, ObservableObject {
    static let shared = QARecorderStore()

    @Published var targetMode: QATargetMode = .window
    @Published private(set) var availableWindows: [QAWindowTarget] = []
    @Published var selectedWindowID: CGWindowID?
    @Published var attachBrowser: Bool = true
    @Published private(set) var browserClientCount: Int = 0
    @Published private(set) var lastBrowserPage: String = ""

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var liveEvents: [QATelemetryEvent] = []
    @Published var lastSummary: QASessionSummary?
    @Published private(set) var statusMessage: String?

    var liveErrorCount: Int {
        liveEvents.filter(\.isFailure).count
    }

    var liveFetchCount: Int {
        liveEvents.filter { $0.kind == .fetch }.count
    }

    static let bridgePort: UInt16 = 47821

    private var timer: Timer?
    private var recordingStartDate: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var pauseStartedAt: Date?
    private var sessionFolder: URL?

    // ScreenCaptureKit + AVAssetWriter state
    private var scStream: SCStream?
    private var streamOutput: VideoStreamOutput?
    private var currentSCContentFilter: SCContentFilter?
    private var currentCaptureSize: CGSize = CGSize(width: 1440, height: 900)

    // Local HTTP + SSE / POST Telemetry Bridge Server (127.0.0.1:47821)
    private var listener: NWListener?

    private override init() {
        super.init()
        startBridgeServer()
        refreshWindows()
    }

    // MARK: - Window Discovery

    func refreshWindows() {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var targets: [QAWindowTarget] = []

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != myPID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let winID = info[kCGWindowNumber as String] as? CGWindowID,
                  let appName = info[kCGWindowOwnerName as String] as? String,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width >= 240, frame.height >= 160 else {
                continue
            }
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let runningApp = NSRunningApplication(processIdentifier: ownerPID)
            let bundleID = runningApp?.bundleIdentifier ?? ""
            targets.append(QAWindowTarget(id: winID, appName: appName, bundleID: bundleID, title: title, frame: frame))
        }

        // Prioritize Firefox / browsers at the top
        targets.sort { a, b in
            let aBrowser = Self.isBrowser(a.appName, a.bundleID)
            let bBrowser = Self.isBrowser(b.appName, b.bundleID)
            if aBrowser != bBrowser { return aBrowser }
            return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
        }

        availableWindows = targets
        if selectedWindowID == nil || !targets.contains(where: { $0.id == selectedWindowID }) {
            selectedWindowID = targets.first?.id
        }
    }

    private static func isBrowser(_ name: String, _ bundle: String) -> Bool {
        let lower = (name + " " + bundle).lowercased()
        return lower.contains("firefox") || lower.contains("zen") || lower.contains("chrome") || lower.contains("safari") || lower.contains("arc") || lower.contains("brave")
    }

    // MARK: - Start / Pause / Flag / Stop Recording

    func startRecording() {
        guard !isRecording else { return }
        statusMessage = nil
        lastSummary = nil
        liveEvents.removeAll()

        let stamp = Self.folderTimestampFormatter.string(from: Date())
        let baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/BullshitNotch-QA", isDirectory: true)
            .appendingPathComponent("qa-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir.appendingPathComponent("screenshots", isDirectory: true), withIntermediateDirectories: true)
        sessionFolder = baseDir

        isRecording = true
        isPaused = false
        elapsedSeconds = 0
        pausedAccumulated = 0
        pauseStartedAt = nil
        recordingStartDate = Date()

        // Collapse the notch and show the floating pill controller
        NotchModel.shared?.setExpanded(false)
        QAFloatingPillController.shared.show()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, !self.isPaused, let start = self.recordingStartDate else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start) - self.pausedAccumulated
            }
        }

        Task {
            await startScreenCapture(in: baseDir)
        }
    }

    func togglePause() {
        guard isRecording else { return }
        if isPaused {
            if let pauseStartedAt {
                pausedAccumulated += Date().timeIntervalSince(pauseStartedAt)
            }
            self.pauseStartedAt = nil
            isPaused = false
            streamOutput?.isPaused = false
        } else {
            pauseStartedAt = Date()
            isPaused = true
            streamOutput?.isPaused = true
        }
    }

    func flagMoment(note: String = "Manual QA Flag / Keyframe") {
        guard isRecording else { return }
        var ev = QATelemetryEvent(timestamp: elapsedSeconds, kind: .flag, summary: note)
        if let file = captureKeyframeScreenshot(prefix: "flag") {
            ev.screenshotFilename = file
        }
        liveEvents.append(ev)
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isPaused = false
        timer?.invalidate()
        timer = nil

        QAFloatingPillController.shared.hide()

        let finalDuration = elapsedSeconds
        let folder = sessionFolder ?? FileManager.default.temporaryDirectory
        let eventsSnapshot = liveEvents
        let targetLabel: String = {
            if targetMode == .window, let win = availableWindows.first(where: { $0.id == selectedWindowID }) {
                return win.displayLabel
            }
            return "Full Screen"
        }()

        let activeStream = scStream
        let activeOutput = streamOutput
        scStream = nil
        streamOutput = nil

        Task {
            if let activeStream {
                try? await activeStream.stopCapture()
            }
            let videoURL = await activeOutput?.finishWriting()
            let reportURL = folder.appendingPathComponent("qa-report.md")
            let md = Self.buildMarkdownReport(
                targetName: targetLabel,
                duration: finalDuration,
                folderURL: folder,
                videoURL: videoURL,
                events: eventsSnapshot
            )
            try? md.write(to: reportURL, atomically: true, encoding: .utf8)

            // Save raw JSON telemetry log as well
            if let jsonData = try? JSONEncoder().encode(eventsSnapshot) {
                try? jsonData.write(to: folder.appendingPathComponent("telemetry.json"))
            }

            let summary = QASessionSummary(
                startedAt: Date().addingTimeInterval(-finalDuration),
                duration: finalDuration,
                folderURL: folder,
                videoURL: videoURL,
                reportURL: reportURL,
                targetName: targetLabel,
                events: eventsSnapshot
            )

            await MainActor.run {
                self.lastSummary = summary
                // Pop open the Notch to the QA tab as chosen in Option C + 1!
                if let model = NotchModel.shared {
                    model.tab = .topbar
                    model.setExpanded(true)
                }
                NotificationCenter.default.post(name: Notification.Name("DemoSwitchSection"), object: AppSection.qa)
            }
        }
    }

    // MARK: - ScreenCaptureKit + Keyframe Snapshots

    private func startScreenCapture(in folder: URL) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let myBundleID = Bundle.main.bundleIdentifier ?? "com.ansxy.bullshitnotch"
            let excludedApps = content.applications.filter { $0.bundleIdentifier == myBundleID }

            let filter: SCContentFilter
            let width: Int
            let height: Int

            if targetMode == .window,
               let targetID = selectedWindowID,
               let scWin = content.windows.first(where: { $0.windowID == targetID }) {
                filter = SCContentFilter(desktopIndependentWindow: scWin)
                width = max(320, Int(scWin.frame.width) & ~1)
                height = max(240, Int(scWin.frame.height) & ~1)
            } else if let display = content.displays.first {
                filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                width = max(640, Int(display.width) & ~1)
                height = max(360, Int(display.height) & ~1)
            } else {
                await MainActor.run {
                    self.statusMessage = "No capture display found."
                }
                return
            }

            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30 fps smooth & lightweight
            config.showsCursor = true
            config.queueDepth = 4

            let videoURL = folder.appendingPathComponent("recording.mp4")
            let output = try VideoStreamOutput(outputURL: videoURL, width: width, height: height)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.ansxy.bullshitnotch.qavideo", qos: .userInitiated))
            try await stream.startCapture()

            await MainActor.run {
                self.scStream = stream
                self.streamOutput = output
                self.currentSCContentFilter = filter
                self.currentCaptureSize = CGSize(width: width, height: height)
            }
        } catch {
            await MainActor.run {
                self.statusMessage = "Screen Recording permission required in System Settings › Privacy & Security."
            }
        }
    }

    private func captureKeyframeScreenshot(prefix: String) -> String? {
        guard let folder = sessionFolder, let latestImage = streamOutput?.latestCGImage() else {
            return nil
        }
        let filename = "\(prefix)-\(Int(elapsedSeconds * 10)).png"
        let url = folder.appendingPathComponent("screenshots").appendingPathComponent(filename)
        let rep = NSBitmapImageRep(cgImage: latestImage)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            return "screenshots/\(filename)"
        }
        return nil
    }

    // MARK: - Firefox / Browser Telemetry Local Bridge (127.0.0.1:47821)

    /// Listens on http://127.0.0.1:47821 for telemetry POSTs from the bundled Firefox extension or injected snippet.
    private func startBridgeServer() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let port = NWEndpoint.Port(rawValue: Self.bridgePort)!
            let l = try NWListener(using: params, on: port)
            l.newConnectionHandler = { [weak self] conn in
                self?.handleBridgeConnection(conn)
            }
            l.start(queue: DispatchQueue(label: "com.ansxy.bullshitnotch.qabridge", qos: .utility))
            listener = l
        } catch {
            // Port busy or unavailable
        }
    }

    nonisolated private func handleBridgeConnection(_ conn: NWConnection) {
        conn.start(queue: DispatchQueue(label: "com.ansxy.bullshitnotch.qaconn", qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            defer { conn.cancel() }
            guard let self, let data, !data.isEmpty,
                  let raw = String(data: data, encoding: .utf8) else { return }

            // Handle CORS preflight
            if raw.hasPrefix("OPTIONS ") {
                let resp = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, GET, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n"
                conn.send(content: resp.data(using: .utf8), completion: .contentProcessed({ _ in }))
                return
            }

            // Serve live injector script on GET /qa.js so any page or bookmarklet can load it
            if raw.hasPrefix("GET /qa.js") {
                let js = Self.browserHookScript
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(js.utf8.count)\r\nConnection: close\r\n\r\n\(js)"
                conn.send(content: resp.data(using: .utf8), completion: .contentProcessed({ _ in }))
                return
            }

            // Parse JSON body from POST /event
            if let bodyRange = raw.range(of: "\r\n\r\n") {
                let bodyStr = String(raw[bodyRange.upperBound...])
                if let bodyData = bodyStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                    Task { @MainActor in
                        self.ingestBrowserPayload(json)
                    }
                }
            }

            let ok = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
            conn.send(content: ok.data(using: .utf8), completion: .contentProcessed({ _ in }))
        }
    }

    private func ingestBrowserPayload(_ json: [String: Any]) {
        browserClientCount = max(1, browserClientCount)
        if let page = json["page"] as? String, !page.isEmpty {
            lastBrowserPage = page
        }
        guard isRecording, !isPaused, attachBrowser else { return }

        let kindRaw = (json["kind"] as? String) ?? "console.log"
        let kind = QAEventKind(rawValue: kindRaw) ?? .consoleLog
        let summary = (json["summary"] as? String) ?? kindRaw
        var ev = QATelemetryEvent(
            timestamp: elapsedSeconds,
            kind: kind,
            summary: summary,
            detail: json["detail"] as? String,
            method: json["method"] as? String,
            status: json["status"] as? Int,
            url: json["url"] as? String,
            requestBody: json["requestBody"] as? String,
            responseBody: json["responseBody"] as? String
        )

        // Automatically snap a keyframe screenshot on click, console error, or failed fetch!
        if ev.isFailure || kind == .click {
            let prefix = ev.isFailure ? "err" : "click"
            ev.screenshotFilename = captureKeyframeScreenshot(prefix: prefix)
        }

        liveEvents.append(ev)
        if liveEvents.count > 400 {
            liveEvents.removeFirst(liveEvents.count - 400)
        }
    }

    // MARK: - Firefox Extension Export & 1-Click Actions

    /// Writes the ready-to-load Firefox WebExtension (manifest.json + content.js) into ~/Movies/BullshitNotch-QA/firefox-extension/
    /// and opens Firefox's `about:debugging#/runtime/this-firefox` (or reveals the folder) so the user can attach it in 1 click.
    func installOrRevealFirefoxExtension() {
        let extDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/BullshitNotch-QA/firefox-extension", isDirectory: true)
        try? FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "manifest_version": 2,
          "name": "BullshitNotch QA Telemetry Bridge",
          "version": "1.0",
          "description": "Streams console logs, uncaught errors, DOM clicks, and fetch/XHR payloads to BullshitNotch during QA recording.",
          "permissions": ["<all_urls>"],
          "content_scripts": [
            {
              "matches": ["<all_urls>"],
              "js": ["content.js"],
              "run_at": "document_start",
              "all_frames": true
            }
          ]
        }
        """

        let contentJS = """
        (function() {
          const script = document.createElement('script');
          script.textContent = \(Self.jsStringLiteral(Self.browserHookScript));
          (document.head || document.documentElement).appendChild(script);
          script.remove();
        })();
        """

        let manifestURL = extDir.appendingPathComponent("manifest.json")
        try? manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        try? contentJS.write(to: extDir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        // Copy the 1-line console snippet to clipboard as well for instant paste if preferred
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("fetch('http://127.0.0.1:\(Self.bridgePort)/qa.js').then(r=>r.text()).then(eval)", forType: .string)

        NSWorkspace.shared.activateFileViewerSelecting([manifestURL])
        statusMessage = "Firefox extension saved & console hook copied to clipboard!"
    }

    func sendSummaryToAgent(_ summary: QASessionSummary) {
        let project = ProjectStore.shared.projects.first
        let dir = project?.expandedPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        let agentCmd = project?.agentCommand ?? (UserDefaults.standard.string(forKey: Pref.defaultAgentCommand) ?? "claude")
        let prompt = "Please investigate and fix the bug captured in this QA session report: \(summary.reportURL.path)"
        let escapedPrompt = prompt.replacingOccurrences(of: "\"", with: "\\\"")
        ProjectStore.shared.launchInTerminal(directory: dir, command: "\(agentCmd) \"\(escapedPrompt)\"")
    }

    func addSummaryToShelf(_ summary: QASessionSummary) {
        var urls: [URL] = [summary.reportURL]
        if let v = summary.videoURL, FileManager.default.fileExists(atPath: v.path) {
            urls.append(v)
        }
        Shelf.shared.add(urls)
        if let model = NotchModel.shared {
            model.tab = .shelf
        }
    }

    func copyReportMarkdown(_ summary: QASessionSummary) {
        if let md = try? String(contentsOf: summary.reportURL, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(md, forType: .string)
            statusMessage = "Copied QA Markdown report to clipboard!"
        }
    }

    // MARK: - Markdown Report Builder & JS Hook

    private static func buildMarkdownReport(
        targetName: String,
        duration: TimeInterval,
        folderURL: URL,
        videoURL: URL?,
        events: [QATelemetryEvent]
    ) -> String {
        var lines: [String] = []
        lines.append("# QA Session Report — \(targetName)")
        lines.append("")
        lines.append("- **Duration:** \(Int(duration))s")
        lines.append("- **Bundle Folder:** `\(folderURL.path)`")
        if let videoURL {
            lines.append("- **Screen Recording:** `\(videoURL.path)`")
        }
        lines.append("- **Errors / Failed Requests:** \(events.filter(\.isFailure).count)")
        lines.append("- **Total Network Requests:** \(events.filter { $0.kind == .fetch }.count)")
        lines.append("")
        lines.append("## Event & Telemetry Timeline")
        lines.append("")

        if events.isEmpty {
            lines.append("_No browser telemetry events recorded during this session._")
        } else {
            for ev in events {
                let badge = ev.isFailure ? "❌" : (ev.kind == .flag ? "🚩" : "•")
                var header = "- `[\(ev.formattedTime)]` \(badge) **\(ev.kind.rawValue)**: \(ev.summary)"
                if let shot = ev.screenshotFilename {
                    header += " ([Keyframe](\(folderURL.appendingPathComponent(shot).path)))"
                }
                lines.append(header)
                if let detail = ev.detail, !detail.isEmpty {
                    lines.append("  ```text\n  \(detail)\n  ```")
                }
                if let req = ev.requestBody, !req.isEmpty {
                    lines.append("  - **Request Payload:** `\(req.prefix(600))`")
                }
                if let resp = ev.responseBody, !resp.isEmpty, ev.isFailure {
                    lines.append("  - **Response Body:** `\(resp.prefix(800))`")
                }
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static let folderTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private static func jsStringLiteral(_ s: String) -> String {
        let data = try? JSONEncoder().encode(s)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    /// Injected into Firefox/Chrome pages to stream clicks, console errors/logs, and fetch/XHR payloads to 127.0.0.1:47821.
    nonisolated static let browserHookScript = """
    (function() {
      if (window.__bullshitNotchQAHooked) return;
      window.__bullshitNotchQAHooked = true;
      const ENDPOINT = 'http://127.0.0.1:47821/event';
      function send(payload) {
        payload.page = location.host + location.pathname;
        fetch(ENDPOINT, {
          method: 'POST',
          mode: 'cors',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
          keepalive: true
        }).catch(() => {});
      }
      send({ kind: 'navigation', summary: 'Connected ' + location.href, url: location.href });

      document.addEventListener('click', function(e) {
        const el = e.target && e.target.closest ? (e.target.closest('button,a,input,[role="button"]') || e.target) : e.target;
        if (!el) return;
        const tag = (el.tagName || '').toLowerCase();
        const id = el.id ? '#' + el.id : '';
        const text = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 48);
        send({ kind: 'click', summary: 'Click <' + tag + id + '> ' + (text ? '"' + text + '"' : '') });
      }, true);

      window.addEventListener('error', function(e) {
        send({
          kind: 'page.error',
          summary: e.message || 'Uncaught Error',
          detail: (e.filename || '') + ':' + (e.lineno || 0) + (e.error && e.error.stack ? '\\n' + e.error.stack : '')
        });
      });

      window.addEventListener('unhandledrejection', function(e) {
        const reason = e.reason ? (e.reason.stack || e.reason.message || String(e.reason)) : 'Unhandled Promise Rejection';
        send({ kind: 'page.error', summary: 'Unhandled Rejection', detail: String(reason).slice(0, 1000) });
      });

      ['error', 'warn', 'log'].forEach(function(level) {
        const orig = console[level];
        console[level] = function() {
          const msg = Array.from(arguments).map(a => {
            try { return typeof a === 'object' ? JSON.stringify(a) : String(a); } catch (_) { return String(a); }
          }).join(' ');
          if (level !== 'log' || msg.length < 300) {
            send({ kind: 'console.' + level, summary: msg.slice(0, 200), detail: msg.length > 200 ? msg.slice(0, 1200) : undefined });
          }
          return orig.apply(this, arguments);
        };
      });

      const origFetch = window.fetch;
      window.fetch = async function(input, init) {
        const url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
        if (url.includes('127.0.0.1:47821')) return origFetch.apply(this, arguments);
        const method = (init && init.method) || (input && input.method) || 'GET';
        let reqBody = undefined;
        if (init && typeof init.body === 'string') reqBody = init.body.slice(0, 800);
        try {
          const resp = await origFetch.apply(this, arguments);
          const clone = resp.clone();
          let respBody = undefined;
          if (!resp.ok) {
            try { respBody = (await clone.text()).slice(0, 1000); } catch (_) {}
          }
          send({
            kind: 'fetch',
            method: method,
            status: resp.status,
            url: url,
            summary: method + ' ' + url.replace(location.origin, '') + ' → ' + resp.status,
            requestBody: reqBody,
            responseBody: respBody
          });
          return resp;
        } catch (err) {
          send({
            kind: 'fetch',
            method: method,
            status: 0,
            url: url,
            summary: method + ' ' + url + ' → NETWORK ERROR',
            detail: String(err),
            requestBody: reqBody
          });
          throw err;
        }
      };
    })();
    """
}

// MARK: - Hardware-Accelerated H.264 Stream Output

private final class VideoStreamOutput: NSObject, SCStreamOutput {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private var startedSession = false
    private var latestSampleBuffer: CMSampleBuffer?
    var isPaused = false

    init(outputURL: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: outputURL)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_500_000,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) {
            writer.add(input)
        }
        super.init()
        writer.startWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }

        lock.lock()
        latestSampleBuffer = sampleBuffer
        let paused = isPaused
        if !startedSession {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            startedSession = true
        }
        if !paused, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
        lock.unlock()
    }

    func latestCGImage() -> CGImage? {
        lock.lock()
        let buf = latestSampleBuffer
        lock.unlock()
        guard let buf, let pixelBuffer = CMSampleBufferGetImageBuffer(buf) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    func finishWriting() async -> URL? {
        let wasStarted = lock.withLock { startedSession }
        guard wasStarted else { return nil }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.outputURL
    }
}

// MARK: - Option C: Minimal Draggable Floating Media Control Pill

@MainActor
final class QAFloatingPillController {
    static let shared = QAFloatingPillController()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 42),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: QAFloatingPillView())
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: frame.midX - 160, y: frame.minY + 36))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct QAFloatingPillView: View {
    @ObservedObject private var store = QARecorderStore.shared

    private var formattedElapsed: String {
        let mins = Int(store.elapsedSeconds) / 60
        let secs = Int(store.elapsedSeconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Recording pulse + timer
            HStack(spacing: 5) {
                Circle()
                    .fill(store.isPaused ? Color.yellow : Color.red)
                    .frame(width: 8, height: 8)
                Text(formattedElapsed)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }

            Divider().frame(height: 16)

            // Firefox / Browser live badge
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("\(store.liveErrorCount) err · \(store.liveFetchCount) req")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(store.liveErrorCount > 0 ? Color.orange : Color.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.14), in: Capsule())

            Divider().frame(height: 16)

            // Pause / Resume
            Button {
                store.togglePause()
            } label: {
                Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help(store.isPaused ? "Resume QA recording" : "Pause QA recording")

            // Flag Bug + Keyframe Screenshot
            Button {
                store.flagMoment()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 10))
                    Text("Flag")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Snap a keyframe screenshot and mark a bug in the timeline")

            // Stop Recording -> Opens Notch Summary
            Button {
                store.stopRecording()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9))
                    Text("Stop")
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.red, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Finish recording and open QA Summary in the Notch")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color.black.opacity(0.65)))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Notch QA Recorder View (Setup + Post-Recording Timeline)

struct QARecorderView: View {
    @ObservedObject private var store = QARecorderStore.shared
    @ObservedObject private var music = NowPlaying.shared
    @AppStorage(Pref.musicAmbient) private var musicAmbient = true

    private var accentColor: Color {
        (musicAmbient ? music.activePalette?.primaryColor : nil) ?? .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = store.lastSummary, !store.isRecording {
                summaryView(summary)
            } else {
                setupView
            }
        }
        .onAppear {
            store.refreshWindows()
        }
    }

    // MARK: 1. Setup View inside the Notch

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.isRecording ? Color.red : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(store.isRecording ? "QA Session Recording…" : "Start QA Session")
                        .font(.headline)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(store.browserClientCount > 0 ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(store.browserClientCount > 0
                         ? "Firefox Connected (\(store.lastBrowserPage.isEmpty ? "live" : store.lastBrowserPage))"
                         : "Bridge ready on 127.0.0.1:\(QARecorderStore.bridgePort)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button {
                    store.installOrRevealFirefoxExtension()
                } label: {
                    Label("Firefox Hook", systemImage: "puzzlepiece.extension.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.22), in: Capsule())
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Export Firefox WebExtension & copy 1-line console hook to clipboard")
            }

            // Target Mode + Window Picker + Browser Telemetry Toggle
            HStack(spacing: 8) {
                ForEach(QATargetMode.allCases) { mode in
                    Button {
                        store.targetMode = mode
                        if mode == .window { store.refreshWindows() }
                    } label: {
                        Label(mode.rawValue, systemImage: mode.icon)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                store.targetMode == mode
                                    ? Color.white.opacity(0.18)
                                    : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    store.attachBrowser.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: store.attachBrowser ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(store.attachBrowser ? .orange : .secondary)
                        Text("Attach Firefox Logs + Fetch")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        store.attachBrowser ? Color.orange.opacity(0.20) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(store.attachBrowser ? Color.orange.opacity(0.5) : .clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()
            }

            if store.targetMode == .window {
                HStack(spacing: 6) {
                    Text("Window:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $store.selectedWindowID) {
                        ForEach(store.availableWindows) { win in
                            Text(win.displayLabel).tag(Optional(win.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    Button {
                        store.refreshWindows()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .padding(5)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Refresh open windows")
                }
            }

            if let msg = store.statusMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Big Start / Stop Action Button
            if store.isRecording {
                HStack(spacing: 8) {
                    Button {
                        store.flagMoment()
                    } label: {
                        Label("Flag Bug + Snap Keyframe", systemImage: "camera.fill")
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.stopRecording()
                    } label: {
                        Label("Stop Recording (\(Int(store.elapsedSeconds))s)", systemImage: "stop.fill")
                            .font(.callout.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    store.startRecording()
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(.white).frame(width: 8, height: 8)
                        Text("Start Recording (Spawns Floating Control Pill)")
                            .font(.callout.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.red.opacity(0.88), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 2. Post-Recording Summary View inside the Notch (Option 1)

    private func summaryView(_ summary: QASessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("QA Session Saved (\(Int(summary.duration))s)")
                        .font(.callout.weight(.bold))
                    Text("· \(summary.targetName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(summary.errorCount) Errors · \(summary.fetchCount) Fetch · \(summary.screenshotCount) Shots")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background((summary.errorCount > 0 ? Color.red : Color.green).opacity(0.22), in: Capsule())
                    .foregroundStyle(summary.errorCount > 0 ? .red : .green)

                Button {
                    store.lastSummary = nil
                } label: {
                    Text("New QA")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // Timeline list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if summary.events.isEmpty {
                        Text("Screen video recorded to \(summary.folderURL.lastPathComponent). Click 'Firefox Hook' before recording to include console logs & fetch payloads.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ForEach(summary.events) { ev in
                            HStack(alignment: .top, spacing: 6) {
                                Text("[\(ev.formattedTime)]")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Image(systemName: ev.kind.icon)
                                    .font(.system(size: 10))
                                    .foregroundStyle(ev.isFailure ? .red : (ev.kind == .flag ? .yellow : .cyan))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(ev.summary)
                                        .font(.system(size: 11, weight: ev.isFailure ? .semibold : .regular, design: .monospaced))
                                        .foregroundStyle(ev.isFailure ? Color.red : Color.primary)
                                        .lineLimit(1)
                                    if let detail = ev.detail ?? ev.responseBody, !detail.isEmpty {
                                        Text(detail)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                if let shot = ev.screenshotFilename {
                                    Button {
                                        NSWorkspace.shared.open(summary.folderURL.appendingPathComponent(shot))
                                    } label: {
                                        Text("📸 shot")
                                            .font(.system(size: 9, design: .monospaced))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.blue.opacity(0.22), in: Capsule())
                                            .foregroundStyle(.cyan)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(ev.isFailure ? Color.red.opacity(0.10) : Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))

            // 1-Click Hand-Off Actions
            HStack(spacing: 8) {
                Button {
                    store.sendSummaryToAgent(summary)
                } label: {
                    Label("Send Report + Video to Agent", systemImage: "sparkles")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(accentColor.opacity(0.32), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(accentColor.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    store.addSummaryToShelf(summary)
                } label: {
                    Label("Add Bundle to Shelf", systemImage: "tray.and.arrow.down.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.blue.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.blue.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    store.copyReportMarkdown(summary)
                } label: {
                    Label("Copy MD", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    NSWorkspace.shared.open(summary.folderURL)
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                        .padding(7)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open QA bundle folder in Finder")
            }
        }
    }
}
