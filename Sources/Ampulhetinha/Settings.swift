import Combine
import Foundation

enum AlertStyle: String, CaseIterable, Identifiable {
    case notification
    case notificationAndWindow

    var id: String { rawValue }
    var label: String {
        switch self {
        case .notification: return "Notificação"
        case .notificationAndWindow: return "Notificação + janela de alerta"
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var showCountdown: Bool { didSet { d.set(showCountdown, forKey: "showCountdown") } }
    /// Quanto tempo vale arrastar até o pé da tela.
    @Published var maxDragMinutes: Int { didSet { d.set(maxDragMinutes, forKey: "maxDragMinutes") } }
    @Published var alertStyle: AlertStyle { didSet { d.set(alertStyle.rawValue, forKey: "alertStyle") } }
    @Published var playSound: Bool {
        didSet { d.set(playSound, forKey: "playSound"); TimerStore.shared.rescheduleNotifications() }
    }
    @Published var completeOnFire: Bool { didSet { d.set(completeOnFire, forKey: "completeOnFire") } }

    @Published var syncReminders: Bool {
        didSet { d.set(syncReminders, forKey: "syncReminders"); remindersSettingsChanged() }
    }
    /// "" = lista padrão do app Lembretes.
    @Published var reminderListID: String { didSet { d.set(reminderListID, forKey: "reminderListID") } }
    @Published var alarmInReminders: Bool {
        didSet { d.set(alarmInReminders, forKey: "alarmInReminders"); TimerStore.shared.pushAllToReminders() }
    }
    @Published var showExternalReminders: Bool {
        didSet { d.set(showExternalReminders, forKey: "showExternalReminders"); remindersSettingsChanged() }
    }

    private init() {
        d.register(defaults: [
            "showCountdown": true,
            "maxDragMinutes": 720,
            "alertStyle": AlertStyle.notification.rawValue,
            "playSound": true,
            "completeOnFire": true,
            "syncReminders": true,
            "reminderListID": "",
            "alarmInReminders": false,
            "showExternalReminders": true,
        ])
        showCountdown = d.bool(forKey: "showCountdown")
        maxDragMinutes = d.integer(forKey: "maxDragMinutes")
        alertStyle = AlertStyle(rawValue: d.string(forKey: "alertStyle") ?? "") ?? .notification
        playSound = d.bool(forKey: "playSound")
        completeOnFire = d.bool(forKey: "completeOnFire")
        syncReminders = d.bool(forKey: "syncReminders")
        reminderListID = d.string(forKey: "reminderListID") ?? ""
        alarmInReminders = d.bool(forKey: "alarmInReminders")
        showExternalReminders = d.bool(forKey: "showExternalReminders")
    }

    private func remindersSettingsChanged() {
        Task {
            await RemindersSync.shared.requestAccessIfNeeded()
            TimerStore.shared.reconcileWithReminders()
        }
    }
}
