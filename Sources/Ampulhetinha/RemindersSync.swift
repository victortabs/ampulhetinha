import AppKit
import EventKit

struct ReminderList: Identifiable, Hashable {
    var id: String
    var title: String
}

/// Ponte com o app Lembretes da Apple.
@MainActor
final class RemindersSync: ObservableObject {
    static let shared = RemindersSync()

    let ek = EKEventStore()
    @Published private(set) var status = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var lists: [ReminderList] = []
    @Published private(set) var defaultListName = ""
    private var observer: NSObjectProtocol?

    var isAuthorized: Bool { status == .fullAccess }
    private var wanted: Bool { Settings.shared.syncReminders || Settings.shared.showExternalReminders }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: ek, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                RemindersSync.shared.loadLists()
                TimerStore.shared.reconcileWithReminders()
            }
        }
        Task {
            await requestAccessIfNeeded()
            TimerStore.shared.reconcileWithReminders()
        }
    }

    func requestAccessIfNeeded() async {
        refreshStatus()
        if wanted, status == .notDetermined {
            _ = try? await ek.requestFullAccessToReminders()
            refreshStatus()
        }
        loadLists()
    }

    func refreshStatus() {
        status = EKEventStore.authorizationStatus(for: .reminder)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }

    func loadLists() {
        guard isAuthorized else { lists = []; return }
        lists = ek.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        defaultListName = ek.defaultCalendarForNewReminders()?.title ?? ""
    }

    private func targetCalendar() -> EKCalendar? {
        let id = Settings.shared.reminderListID
        if !id.isEmpty, let c = ek.calendar(withIdentifier: id), c.allowsContentModifications { return c }
        return ek.defaultCalendarForNewReminders()
    }

    // MARK: - Escrita

    /// Cria o lembrete do timer. Devolve (id, idExterno).
    func create(for item: TimerItem) -> (String, String?)? {
        guard isAuthorized, Settings.shared.syncReminders, let cal = targetCalendar() else { return nil }
        let r = EKReminder(eventStore: ek)
        r.calendar = cal
        apply(item, to: r)
        do {
            try ek.save(r, commit: true)
            return (r.calendarItemIdentifier, r.calendarItemExternalIdentifier)
        } catch {
            NSLog("Ampulhetinha: falha ao criar lembrete: \(error)")
            return nil
        }
    }

    /// Atualiza título/horário e reabre o lembrete se estava concluído.
    @discardableResult
    func update(_ item: TimerItem) -> Bool {
        guard isAuthorized, let r = reminder(for: item) else { return false }
        r.isCompleted = false
        apply(item, to: r, keepTitle: item.isExternal)
        return save(r)
    }

    func complete(_ item: TimerItem) {
        guard isAuthorized, let r = reminder(for: item), !r.isCompleted else { return }
        r.isCompleted = true
        save(r)
    }

    func delete(_ item: TimerItem) {
        guard isAuthorized, let r = reminder(for: item) else { return }
        do { try ek.remove(r, commit: true) } catch { NSLog("Ampulhetinha: falha ao excluir lembrete: \(error)") }
    }

    @discardableResult
    private func save(_ r: EKReminder) -> Bool {
        do { try ek.save(r, commit: true); return true } catch {
            NSLog("Ampulhetinha: falha ao salvar lembrete: \(error)")
            return false
        }
    }

    private func apply(_ item: TimerItem, to r: EKReminder, keepTitle: Bool = false) {
        if !keepTitle { r.title = item.displayTitle }
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireDate)
        comps.timeZone = TimeZone.current
        r.dueDateComponents = comps
        // Alarmes: só mexemos nos lembretes criados pela Ampulhetinha.
        guard !item.isExternal else {
            if let alarms = r.alarms, !alarms.isEmpty {
                alarms.forEach { r.removeAlarm($0) }
                r.addAlarm(EKAlarm(absoluteDate: item.fireDate))
            }
            return
        }
        r.alarms?.forEach { r.removeAlarm($0) }
        if Settings.shared.alarmInReminders {
            r.addAlarm(EKAlarm(absoluteDate: item.fireDate))
        }
    }

    // MARK: - Leitura

    func reminder(for item: TimerItem) -> EKReminder? {
        if let id = item.reminderID, let r = ek.calendarItem(withIdentifier: id) as? EKReminder { return r }
        if let ext = item.reminderExternalID, !ext.isEmpty {
            return ek.calendarItems(withExternalIdentifier: ext).compactMap { $0 as? EKReminder }.first
        }
        return nil
    }

    /// Lembretes não concluídos, com horário, nos próximos 7 dias.
    func fetchUpcoming() async -> [ExternalReminder] {
        guard isAuthorized else { return [] }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
        let predicate = ek.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: nil)
        return await Self.fetch(ek, predicate)
    }

    nonisolated private static func fetch(_ ek: EKEventStore, _ predicate: NSPredicate) async -> [ExternalReminder] {
        await withCheckedContinuation { cont in
            ek.fetchReminders(matching: predicate) { reminders in
                let now = Date()
                let out: [ExternalReminder] = (reminders ?? []).compactMap { r in
                    guard let dc = r.dueDateComponents, dc.hour != nil,
                          let due = Calendar.current.date(from: dc), due > now else { return nil }
                    return ExternalReminder(
                        id: r.calendarItemIdentifier,
                        externalID: r.calendarItemExternalIdentifier,
                        title: r.title ?? "",
                        due: due,
                        listName: r.calendar?.title ?? "Lembretes"
                    )
                }
                cont.resume(returning: out)
            }
        }
    }

    /// Data de vencimento do lembrete, se tiver horário.
    static func dueDate(of r: EKReminder) -> Date? {
        guard let dc = r.dueDateComponents, dc.hour != nil else { return nil }
        return Calendar.current.date(from: dc)
    }
}
