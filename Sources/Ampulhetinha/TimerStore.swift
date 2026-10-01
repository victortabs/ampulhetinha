import AppKit
import Combine

@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()

    /// Timers criados aqui (correndo ou, se não concluem sozinhos, atrasados).
    @Published private(set) var items: [TimerItem] = []
    /// Lembretes com horário vindos do app Lembretes.
    @Published private(set) var external: [TimerItem] = []
    /// Últimos timers terminados, para "Repetir".
    @Published private(set) var recent: [TimerItem] = []
    @Published private(set) var now = Date()

    /// Chamado a cada segundo e a cada mudança (atualiza a barra de menus).
    var onChange: (() -> Void)?

    private var ticker: Timer?
    private var externalTask: Task<Void, Never>?
    private var lastExternalRefresh = Date.distantPast

    var allActive: [TimerItem] {
        (items + external).sorted { $0.fireDate < $1.fireDate }
    }

    var next: TimerItem? { allActive.first { $0.fireDate > now } }
    var hasOverdue: Bool { items.contains { $0.fireDate <= now } }

    // MARK: - Ciclo de vida

    func start() {
        load()
        processExpired(alert: false)
        rescheduleNotifications()

        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { TimerStore.shared.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let store = TimerStore.shared
                store.tick()
                store.rescheduleNotifications()
                store.reconcileWithReminders()
            }
        }
    }

    private func tick() {
        now = Date()
        processExpired(alert: true)
        if external.contains(where: { $0.fireDate <= now }) {
            external.removeAll { $0.fireDate <= now }
        }
        if now.timeIntervalSince(lastExternalRefresh) > 300 { refreshExternal() }
        onChange?()
    }

    private func processExpired(alert: Bool) {
        let due = items.filter { $0.finishedAt == nil && $0.fireDate <= now }
        guard !due.isEmpty else { return }
        for var item in due {
            item.finishedAt = now
            if Settings.shared.completeOnFire {
                items.removeAll { $0.id == item.id }
                addRecent(item)
                RemindersSync.shared.complete(item)
            } else {
                replace(item)
            }
            if alert { fired(item) }
        }
        save()
    }

    private func fired(_ item: TimerItem) {
        let wantsWindow = Settings.shared.alertStyle == .notificationAndWindow
        if wantsWindow || !NotificationManager.shared.authorized {
            AlertCenter.shared.show(item)
        }
    }

    // MARK: - Ações

    func add(title: String, minutes: Int, start: Date = Date()) {
        var item = TimerItem(title: title, start: start, fireDate: start.addingTimeInterval(TimeInterval(minutes * 60)))
        if let ids = RemindersSync.shared.create(for: item) {
            item.reminderID = ids.0
            item.reminderExternalID = ids.1
        }
        items.append(item)
        sortItems()
        NotificationManager.shared.schedule(item)
        save()
        onChange?()
    }

    /// Adia: soma ao horário (se ainda correndo) ou conta a partir de agora (se já terminou).
    func snooze(_ id: String, minutes: Int) {
        let delta = TimeInterval(minutes * 60)
        if let idx = items.firstIndex(where: { $0.id == id }) {
            var it = items[idx]
            if it.finishedAt != nil || it.fireDate <= now {
                it.startDate = now
                it.fireDate = now.addingTimeInterval(delta)
            } else {
                it.fireDate = it.fireDate.addingTimeInterval(delta)
            }
            it.finishedAt = nil
            items[idx] = it
            sortItems()
            NotificationManager.shared.cancel(it.id)
            NotificationManager.shared.schedule(it)
            RemindersSync.shared.update(it)
        } else if let idx = recent.firstIndex(where: { $0.id == id }) {
            var it = recent.remove(at: idx)
            it.finishedAt = nil
            it.startDate = now
            it.fireDate = now.addingTimeInterval(delta)
            if !RemindersSync.shared.update(it), let ids = RemindersSync.shared.create(for: it) {
                it.reminderID = ids.0
                it.reminderExternalID = ids.1
            }
            items.append(it)
            sortItems()
            NotificationManager.shared.cancel(it.id)
            NotificationManager.shared.schedule(it)
        } else if let idx = external.firstIndex(where: { $0.id == id }) {
            var it = external[idx]
            it.fireDate = max(it.fireDate, now).addingTimeInterval(delta)
            external[idx] = it
            RemindersSync.shared.update(it)
        }
        save()
        onChange?()
    }

    func complete(_ id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            var it = items.remove(at: idx)
            NotificationManager.shared.cancel(it.id)
            RemindersSync.shared.complete(it)
            it.finishedAt = it.finishedAt ?? now
            addRecent(it)
        } else if let idx = external.firstIndex(where: { $0.id == id }) {
            RemindersSync.shared.complete(external.remove(at: idx))
        } else if let idx = recent.firstIndex(where: { $0.id == id }) {
            NotificationManager.shared.cancel(id)
            recent.remove(at: idx)
        }
        save()
        onChange?()
    }

    func delete(_ id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let it = items.remove(at: idx)
            NotificationManager.shared.cancel(it.id)
            RemindersSync.shared.delete(it)
        } else if let idx = recent.firstIndex(where: { $0.id == id }) {
            recent.remove(at: idx)
        }
        save()
        onChange?()
    }

    func rename(_ id: String, to title: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].title = title
        NotificationManager.shared.cancel(id)
        NotificationManager.shared.schedule(items[idx])
        RemindersSync.shared.update(items[idx])
        save()
    }

    func repeatTimer(_ id: String) {
        guard let it = recent.first(where: { $0.id == id }) else { return }
        recent.removeAll { $0.id == id }
        add(title: it.title, minutes: it.durationMinutes)
    }

    func clearRecent() {
        recent.removeAll()
        save()
    }

    /// "OK" na janela de alerta ou "Concluir" na notificação: conclui se ainda estiver na lista.
    func acknowledge(_ id: String) {
        if items.contains(where: { $0.id == id }) { complete(id) }
    }

    func handleNotificationAction(_ action: String, id: String?) {
        switch action {
        case "snooze5": if let id { snooze(id, minutes: 5) }
        case "snooze15": if let id { snooze(id, minutes: 15) }
        case "snooze60": if let id { snooze(id, minutes: 60) }
        case "done": if let id { acknowledge(id) }
        default: Coordinator.shared.showList()
        }
    }

    // MARK: - Notificações e Lembretes

    func rescheduleNotifications() {
        NotificationManager.shared.cancelAllPending()
        items.forEach { NotificationManager.shared.schedule($0) }
    }

    /// Reescreve todos os lembretes (ex.: quando a opção de alarme muda).
    func pushAllToReminders() {
        items.filter { $0.finishedAt == nil }.forEach { RemindersSync.shared.update($0) }
    }

    /// Traz para cá o que mudou no app Lembretes (concluído, excluído, novo horário, novo título).
    func reconcileWithReminders() {
        let sync = RemindersSync.shared
        guard sync.isAuthorized else {
            if !external.isEmpty { external = [] }
            onChange?()
            return
        }
        var changed = false
        for item in items {
            guard item.reminderID != nil || item.reminderExternalID != nil else {
                // Criado enquanto não havia acesso: cria o lembrete agora.
                if Settings.shared.syncReminders, item.finishedAt == nil, let ids = sync.create(for: item),
                   let idx = items.firstIndex(where: { $0.id == item.id }) {
                    items[idx].reminderID = ids.0
                    items[idx].reminderExternalID = ids.1
                    changed = true
                }
                continue
            }
            guard let idx = items.firstIndex(where: { $0.id == item.id }) else { continue }
            guard let r = sync.reminder(for: item) else {
                // Excluído no app Lembretes.
                NotificationManager.shared.cancel(item.id)
                items.remove(at: idx)
                changed = true
                continue
            }
            if r.isCompleted {
                NotificationManager.shared.cancel(item.id)
                var done = items.remove(at: idx)
                done.finishedAt = done.finishedAt ?? now
                addRecent(done)
                changed = true
                continue
            }
            var it = items[idx]
            if it.reminderID != r.calendarItemIdentifier { it.reminderID = r.calendarItemIdentifier }
            if let t = r.title, !t.isEmpty, t != it.displayTitle { it.title = t }
            if let due = RemindersSync.dueDate(of: r), abs(due.timeIntervalSince(it.fireDate)) >= 60 {
                it.fireDate = due
                if due > now { it.finishedAt = nil }
                NotificationManager.shared.cancel(it.id)
                NotificationManager.shared.schedule(it)
            }
            if it != items[idx] {
                items[idx] = it
                changed = true
            }
        }
        if changed {
            sortItems()
            save()
        }
        refreshExternal()
        onChange?()
    }

    func refreshExternal() {
        lastExternalRefresh = Date()
        guard Settings.shared.showExternalReminders, RemindersSync.shared.isAuthorized else {
            if !external.isEmpty { external = [] }
            return
        }
        externalTask?.cancel()
        externalTask = Task {
            let list = await RemindersSync.shared.fetchUpcoming()
            guard !Task.isCancelled else { return }
            let ids = Set((items + recent).compactMap(\.reminderID))
            let extIDs = Set((items + recent).compactMap(\.reminderExternalID).filter { !$0.isEmpty })
            external = list
                .filter { !ids.contains($0.id) && !($0.externalID.map { extIDs.contains($0) } ?? false) }
                .map { TimerItem(external: $0) }
            onChange?()
        }
    }

    // MARK: - Auxiliares

    private func replace(_ item: TimerItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx] = item }
    }

    private func sortItems() {
        items.sort { $0.fireDate < $1.fireDate }
    }

    private func addRecent(_ item: TimerItem) {
        recent.removeAll { $0.id == item.id }
        recent.insert(item, at: 0)
        if recent.count > 5 { recent.removeLast(recent.count - 5) }
    }

    // MARK: - Persistência

    private struct Persisted: Codable {
        var items: [TimerItem]
        var recent: [TimerItem]
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ampulhetinha", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("timers.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        items = p.items
        recent = p.recent
        sortItems()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Persisted(items: items, recent: recent)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
