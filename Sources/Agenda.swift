import AppKit
import EventKit

/// The selected day's calendar events, plus reminders due by then (incl. overdue), via EventKit.
@MainActor
final class Agenda: ObservableObject {
    static let shared = Agenda()

    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var reminders: [EKReminder] = []
    @Published private(set) var calendarAccess = false
    @Published private(set) var remindersAccess = false
    @Published var day = Calendar.current.startOfDay(for: .now) { didSet { reload() } }

    private let store = EKEventStore()
    private var started = false
    private var isDemo = false
    private var lastKnownToday = Calendar.current.startOfDay(for: .now)

    private init() {
        if CommandLine.arguments.contains("--demo") {
            loadDemoData()
        }
    }

    func loadDemoData() {
        isDemo = true
        started = true
        calendarAccess = true
        remindersAccess = true

        let cal1 = EKCalendar(for: .event, eventStore: store)
        cal1.title = "Work"
        cal1.color = .systemOrange
        let cal2 = EKCalendar(for: .event, eventStore: store)
        cal2.title = "Engineering"
        cal2.color = .systemCyan
        let cal3 = EKCalendar(for: .event, eventStore: store)
        cal3.title = "Personal"
        cal3.color = .systemPurple

        let ev1 = EKEvent(eventStore: store)
        ev1.title = "Explain why 1 line took 4 days"
        ev1.startDate = Calendar.current.date(bySettingHour: 10, minute: 30, second: 0, of: .now) ?? .now
        ev1.endDate = Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: .now) ?? .now
        ev1.calendar = cal1

        let ev2 = EKEvent(eventStore: store)
        ev2.title = "Deploy to Prod on Friday (YOLO)"
        ev2.startDate = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: .now) ?? .now
        ev2.endDate = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: .now) ?? .now
        ev2.location = "https://meet.google.com/yolo-prod-friday"
        ev2.calendar = cal2

        events = [ev1, ev2]
        nextMeeting = ev2
        nextMeetingLink = URL(string: "https://meet.google.com/yolo-prod-friday")

        let rem1 = EKReminder(eventStore: store)
        rem1.title = "rm -rf node_modules & pray"
        reminders = [rem1]
    }

    /// Asks for access the first time the agenda is shown, and refreshes every subsequent time it appears.
    func start() {
        if isDemo { return }
        if started {
            checkAuthorizationAndReload(resetCache: true)
            return
        }
        started = true
        requestAccessIfNeeded()

        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Agenda.shared.store.reset()
                Agenda.shared.reload()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Agenda.shared.checkAuthorizationAndReload(resetCache: true)
            }
        }
        if meetingTimer == nil {
            meetingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                Task { @MainActor in
                    Agenda.shared.checkAuthorizationAndReload(resetCache: true)
                }
            }
        }
    }

    private func requestAccessIfNeeded() {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                self.calendarAccess = granted
                if granted {
                    self.store.reset()
                    self.store.refreshSourcesIfNecessary()
                }
                self.reload()
            }
        }
        store.requestFullAccessToReminders { granted, _ in
            DispatchQueue.main.async {
                self.remindersAccess = granted
                if granted {
                    self.store.reset()
                    self.store.refreshSourcesIfNecessary()
                }
                self.reload()
            }
        }
    }

    /// Re-checks TCC status (in case permissions were toggled in System Settings), resets stale EventKit caches,
    /// rolls the selected day forward across midnight, and reloads events + reminders.
    func checkAuthorizationAndReload(resetCache: Bool = false) {
        if isDemo { return }
        let evStatus = EKEventStore.authorizationStatus(for: .event)
        let remStatus = EKEventStore.authorizationStatus(for: .reminder)
        let newCalAccess = (evStatus == .fullAccess)
        let newRemAccess = (remStatus == .fullAccess)

        if !calendarAccess && newCalAccess || !remindersAccess && newRemAccess {
            calendarAccess = newCalAccess
            remindersAccess = newRemAccess
            store.reset()
            store.refreshSourcesIfNecessary()
        } else {
            calendarAccess = newCalAccess
            remindersAccess = newRemAccess
            if resetCache && (calendarAccess || remindersAccess) {
                store.reset()
                store.refreshSourcesIfNecessary()
            }
        }

        let currentToday = Calendar.current.startOfDay(for: .now)
        if currentToday != lastKnownToday {
            if day == lastKnownToday {
                lastKnownToday = currentToday
                day = currentToday
                return
            }
            lastKnownToday = currentToday
        }

        reload()
    }

    func reload() {
        if isDemo { return }
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return }
        if calendarAccess {
            events = store.events(matching: store.predicateForEvents(withStart: day, end: end, calendars: nil))
                .filter { $0.status != .canceled }
                .sorted { $0.startDate < $1.startDate }
            reloadNextMeeting()
        }
        if remindersAccess {
            let due = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
            store.fetchReminders(matching: due) { found in
                let sorted = (found ?? []).sorted {
                    ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
                }
                DispatchQueue.main.async { self.reminders = sorted }
            }
        }
    }

    func complete(_ reminder: EKReminder) {
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        reload()
    }

    // MARK: Next meeting

    /// The next timed event that hasn't ended yet (within a week), and its video-call link if it has one.
    @Published private(set) var nextMeeting: EKEvent?
    @Published private(set) var nextMeetingLink: URL?
    private var meetingTimer: Timer?

    /// Recomputed on every reload and periodically, so it moves on when a meeting ends or a new one appears.
    func reloadNextMeeting() {
        guard calendarAccess, let end = Calendar.current.date(byAdding: .day, value: 7, to: .now) else { return }
        let now = Date.now
        let upcoming = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        // Prefer the first one that actually has a call link; fall back to the first event.
        let withLink = upcoming.first { Self.meetingLink(for: $0) != nil }
        let event = withLink ?? upcoming.first
        nextMeeting = event
        nextMeetingLink = event.flatMap(Self.meetingLink(for:))
    }

    /// ponytail: known call hosts only, so a random link in the notes isn't mistaken for the meeting.
    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                       "webex.com", "whereby.com", "around.co", "facetime.apple.com",
                                       "chime.aws", "gotomeeting.com", "meet.jit.si", "slack.com/huddle"]

    static func meetingLink(for event: EKEvent) -> URL? {
        let candidates = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in candidates {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url else { continue }
                if meetingHosts.contains(where: { url.absoluteString.contains($0) }) { return url }
            }
        }
        return nil
    }

    static func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Shows the event in Calendar; falls back to just opening the app.
    static func open(_ event: EKEvent) {
        if let id = event.calendarItemExternalIdentifier?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(id)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            return
        }
        openCalendarApp()
    }
}
