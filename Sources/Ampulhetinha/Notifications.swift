import AppKit
import UserNotifications

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    static let category = "AMPULHETINHA_TIMER"

    @Published private(set) var authorized = false
    private var center: UNUserNotificationCenter { .current() }

    func setup() {
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: "snooze5", title: "Adiar 5 min"),
            UNNotificationAction(identifier: "snooze15", title: "Adiar 15 min"),
            UNNotificationAction(identifier: "snooze60", title: "Adiar 1 hora"),
            UNNotificationAction(identifier: "done", title: "Concluir"),
        ]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: actions, intentIdentifiers: [])
        ])
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await refreshStatus()
        }
    }

    func refreshStatus() async {
        let s = await center.notificationSettings()
        authorized = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func schedule(_ item: TimerItem) {
        guard !item.isExternal, item.finishedAt == nil, item.fireDate > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = item.displayTitle
        content.body = "Tempo esgotado · \(Fmt.longDuration(minutes: item.durationMinutes)) desde as \(Fmt.time(item.startDate))"
        content.sound = Settings.shared.playSound ? .default : nil
        content.categoryIdentifier = Self.category
        content.userInfo = ["id": item.id]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
    }

    func cancel(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func cancelAllPending() {
        center.removeAllPendingNotificationRequests()
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.content.userInfo["id"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            TimerStore.shared.handleNotificationAction(action, id: id)
        }
    }
}
