import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Só uma Ampulhetinha por vez.
        if let id = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            if NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .contains(where: { $0.processIdentifier != me }) {
                NSApp.terminate(nil)
                return
            }
        }

        NotificationManager.shared.setup()
        let store = TimerStore.shared
        store.start()
        let status = StatusItemController(store: store)
        Coordinator.shared.status = status
        store.onChange = { [weak status] in status?.refresh() }
        RemindersSync.shared.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await NotificationManager.shared.refreshStatus() }
        RemindersSync.shared.refreshStatus()
    }
}

/// Ações globais (menus, notificações, ajustes).
@MainActor
final class Coordinator {
    static let shared = Coordinator()
    var status: StatusItemController?
    private var settingsWindow: NSWindow?

    func showList() {
        status?.showPopover()
    }

    func newTimer(minutes: Int) {
        status?.closePopover()
        TitlePrompt.shared.present(minutes: minutes, bubble: nil,
                                   screen: status?.promptAnchorScreen()) { title, minutes, start in
            TimerStore.shared.add(title: title, minutes: minutes, start: start)
        }
    }

    func openSettings() {
        status?.closePopover()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: host)
            w.title = "Ajustes da Ampulhetinha"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func openRemindersApp() {
        status?.closePopover()
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
    }

    func showAbout() {
        status?.closePopover()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
