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

    private init() {}

    /// Asks for access the first time the agenda is shown, not at launch.
    func start() {
        guard !started else { return }
        started = true
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { self.calendarAccess = granted; self.reload() }
        }
        store.requestFullAccessToReminders { granted, _ in
            DispatchQueue.main.async { self.remindersAccess = granted; self.reload() }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { Agenda.shared.reload() }
        }
    }

    func reload() {
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return }
        if calendarAccess {
            events = store.events(matching: store.predicateForEvents(withStart: day, end: end, calendars: nil))
                .sorted { $0.startDate < $1.startDate }
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
}
