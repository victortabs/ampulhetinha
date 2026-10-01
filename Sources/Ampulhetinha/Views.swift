import EventKit
import ServiceManagement
import SwiftUI

// MARK: - Lista (popover da barra de menus)

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct TimerListView: View {
    @ObservedObject var store: TimerStore
    @ObservedObject private var reminders = RemindersSync.shared
    @ObservedObject private var settings = Settings.shared
    @State private var contentHeight: CGFloat = 0

    private let presets = [5, 10, 15, 20, 25, 30, 45, 60, 90, 120]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if needsRemindersAccess { accessBanner }
            let active = store.allActive
            if active.isEmpty && store.recent.isEmpty {
                emptyState
            } else {
                ScrollView {
                    content(active)
                        .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
                }
                .frame(height: min(max(contentHeight, 1), 460))
                .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            }
            Divider()
            Text("Arraste a ampulheta para baixo · segure ⌥ para minuto a minuto")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
        }
        .frame(width: 320)
    }

    private var needsRemindersAccess: Bool {
        (settings.syncReminders || settings.showExternalReminders) && !reminders.isAuthorized
    }

    private var header: some View {
        HStack(spacing: 8) {
            HourglassBadge(size: 22)
            Text("Ampulhetinha").font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            Menu {
                Menu("Novo timer") {
                    ForEach(presets, id: \.self) { m in
                        Button(Fmt.longDuration(minutes: m)) { Coordinator.shared.newTimer(minutes: m) }
                    }
                }
                Divider()
                Button("Abrir Lembretes") { Coordinator.shared.openRemindersApp() }
                Button("Ajustes…") { Coordinator.shared.openSettings() }
                Button("Sobre a Ampulhetinha") { Coordinator.shared.showAbout() }
                Divider()
                Button("Sair da Ampulhetinha") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { Coordinator.shared.openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Ajustes")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var accessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist").foregroundStyle(.orange)
            Text("Sem acesso ao app Lembretes").font(.system(size: 12))
            Spacer()
            Button(reminders.status == .notDetermined ? "Permitir" : "Abrir Ajustes") {
                if reminders.status == .notDetermined {
                    Task {
                        await reminders.requestAccessIfNeeded()
                        store.reconcileWithReminders()
                    }
                } else {
                    reminders.openPrivacySettings()
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nenhum timer").font(.headline)
            Text("Clique na ampulheta da barra de menus e arraste para baixo. Quanto mais longe, mais tempo.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
    }

    @ViewBuilder
    private func content(_ active: [TimerItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !active.isEmpty {
                SectionTitle(text: "Lembretes atuais")
                ForEach(active) { item in
                    TimerRow(item: item, now: store.now, store: store)
                    if item.id != active.last?.id { Divider().padding(.horizontal, 16) }
                }
            }
            if !store.recent.isEmpty {
                HStack {
                    SectionTitle(text: "Recentes")
                    Spacer()
                    Button("Limpar") { store.clearRecent() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .padding(.trailing, 16)
                }
                ForEach(store.recent) { item in
                    RecentRow(item: item, store: store)
                }
                .padding(.bottom, 4)
            }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

private struct TimerRow: View {
    let item: TimerItem
    let now: Date
    let store: TimerStore

    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var remaining: TimeInterval { item.fireDate.timeIntervalSince(now) }
    private var progress: Double {
        let total = item.fireDate.timeIntervalSince(item.startDate)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(item.startDate) / total))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                if remaining > 0 {
                    bigLine("em", Fmt.shortRemaining(remaining))
                } else {
                    bigLine("há", Fmt.shortRemaining(-remaining)).foregroundStyle(.orange)
                }
                bigLine(Fmt.dayPrefix(item.fireDate, now: now), Fmt.time(item.fireDate))
                titleView.padding(.top, 5)
                if item.isExternal {
                    Label(item.listName ?? "Lembretes", systemImage: "checklist")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                } else if remaining > 0 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(Color(nsColor: Palette.coral))
                        .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
            if hovering && !editing {
                VStack(spacing: 6) {
                    RowButton(symbol: "goforward.5", help: "Adiar 5 minutos") { store.snooze(item.id, minutes: 5) }
                    RowButton(symbol: "checkmark", help: "Concluir") { store.complete(item.id) }
                    if !item.isExternal {
                        RowButton(symbol: "trash", help: "Excluir") { store.delete(item.id) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(hovering ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Adiar 5 minutos") { store.snooze(item.id, minutes: 5) }
            Button("Adiar 15 minutos") { store.snooze(item.id, minutes: 15) }
            Button("Adiar 1 hora") { store.snooze(item.id, minutes: 60) }
            Divider()
            if !item.isExternal { Button("Renomear…") { startEditing() } }
            Button("Concluir") { store.complete(item.id) }
            if !item.isExternal { Button("Excluir") { store.delete(item.id) } }
            if item.isExternal || item.reminderID != nil {
                Divider()
                Button("Abrir no app Lembretes") { Coordinator.shared.openRemindersApp() }
            }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if editing {
            TextField("Título", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit {
                    store.rename(item.id, to: draft)
                    editing = false
                }
                .onExitCommand { editing = false }
        } else {
            Text(item.displayTitle)
                .font(.system(size: 13))
                .lineLimit(2)
                .onTapGesture(count: 2) { if !item.isExternal { startEditing() } }
        }
    }

    private func startEditing() {
        draft = item.title
        editing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func bigLine(_ prefix: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(prefix)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .light))
                .monospacedDigit()
        }
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct RecentRow: View {
    let item: TimerItem
    let store: TimerStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle).font(.system(size: 13)).lineLimit(1)
                Text("\(Fmt.longDuration(minutes: item.durationMinutes)) · terminou \(Fmt.at(item.finishedAt ?? item.fireDate))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            RowButton(symbol: "arrow.clockwise", help: "Repetir com o mesmo tempo") { store.repeatTimer(item.id) }
            if hovering {
                RowButton(symbol: "xmark", help: "Remover da lista") { store.delete(item.id) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var reminders = RemindersSync.shared
    @ObservedObject private var notifications = NotificationManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Geral") {
                Toggle("Mostrar contagem regressiva na barra de menus", isOn: $settings.showCountdown)
                Toggle("Abrir ao iniciar sessão", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Quando o tempo acabar") {
                Picker("Avisar com", selection: $settings.alertStyle) {
                    ForEach(AlertStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Tocar som", isOn: $settings.playSound)
                Toggle("Concluir automaticamente", isOn: $settings.completeOnFire)
                Text(settings.completeOnFire
                     ? "O timer sai da lista (vai para Recentes) e o lembrete é marcado como concluído."
                     : "O timer fica na lista como atrasado até você concluir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !notifications.authorized {
                    HStack {
                        Label("Notificações desativadas — a janela de alerta será usada.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Abrir Ajustes") { notifications.openSettings() }
                    }
                }
            }

            Section("App Lembretes") {
                if !reminders.isAuthorized {
                    HStack {
                        Text(reminders.status == .notDetermined
                             ? "A Ampulhetinha ainda não pediu acesso aos Lembretes."
                             : "Acesso aos Lembretes negado.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(reminders.status == .notDetermined ? "Permitir acesso" : "Abrir Privacidade") {
                            if reminders.status == .notDetermined {
                                Task {
                                    await reminders.requestAccessIfNeeded()
                                    TimerStore.shared.reconcileWithReminders()
                                }
                            } else {
                                reminders.openPrivacySettings()
                            }
                        }
                    }
                }
                Toggle("Criar um lembrete para cada timer", isOn: $settings.syncReminders)
                Picker("Lista", selection: $settings.reminderListID) {
                    Text(reminders.defaultListName.isEmpty ? "Padrão" : "Padrão (\(reminders.defaultListName))").tag("")
                    ForEach(reminders.lists) { Text($0.title).tag($0.id) }
                }
                .disabled(!settings.syncReminders || !reminders.isAuthorized)
                Toggle("Alarme também no app Lembretes (avisa no iPhone/iPad)", isOn: $settings.alarmInReminders)
                    .disabled(!settings.syncReminders)
                Toggle("Mostrar lembretes com horário dos próximos 7 dias", isOn: $settings.showExternalReminders)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            reminders.refreshStatus()
            reminders.loadLists()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            Task { await notifications.refreshStatus() }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Não foi possível alterar: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
