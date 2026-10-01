import AppKit
import SwiftUI

/// Painel que recebe teclado sem ativar o app (como o Spotlight).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Botões funcionam no primeiro clique mesmo com o painel inativo.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
func makeFloatingPanel<Content: View>(_ root: Content) -> KeyPanel {
    let host = FirstMouseHostingView(rootView: root)
    let size = host.fittingSize
    let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.maskImage = roundedMask(radius: 14)
    host.frame = effect.bounds
    host.autoresizingMask = [.width, .height]
    effect.addSubview(host)
    panel.contentView = effect
    return panel
}

@MainActor
private func roundedMask(radius r: CGFloat) -> NSImage {
    let edge = 2 * r + 1
    let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    img.resizingMode = .stretch
    return img
}

// MARK: - Título do timer (aparece ao soltar)

@MainActor
final class PromptModel: ObservableObject {
    @Published var title = ""
    @Published var minutes = 25
    var start = Date()
    var fireDate: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }
}

/// Selo da Ampulhetinha: círculo em degradê com a ampulheta branca.
struct HourglassBadge: View {
    var size: CGFloat = 26
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: [Color(nsColor: Palette.peach), Color(nsColor: Palette.coral), Color(nsColor: Palette.lilac)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "hourglass")
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

private struct KeyHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

struct PromptView: View {
    @ObservedObject var model: PromptModel
    var commit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HourglassBadge(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Fmt.longDuration(minutes: model.minutes))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(Fmt.at(model.fireDate))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            TextField("Do que devo te lembrar?", text: $model.title)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color(nsColor: Palette.coral).opacity(focused ? 0.7 : 0.15), lineWidth: 1.5))
                )
                .focused($focused)
                .onSubmit(commit)
            HStack(spacing: 12) {
                KeyHint(key: "↩", label: "criar")
                KeyHint(key: "↑↓", label: "ajustar")
                KeyHint(key: "esc", label: "cancelar")
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }
}

@MainActor
final class TitlePrompt: NSObject, NSWindowDelegate {
    static let shared = TitlePrompt()

    private var panel: KeyPanel?
    private let model = PromptModel()
    private var keyMonitor: Any?
    private var onCommit: ((String, Int, Date) -> Void)?
    private var finished = true
    /// App que estava em uso antes do campo aparecer (recebe o foco de volta).
    private var previousApp: NSRunningApplication?

    /// `bubble`: onde estava a bolha do arrasto (o campo aparece no mesmo lugar).
    func present(minutes: Int, start: Date = Date(), bubble: NSRect?, alignRight: Bool, screen: NSScreen?,
                 commit: @escaping (String, Int, Date) -> Void) {
        if !finished { commitNow() }
        finished = false
        model.title = ""
        model.minutes = minutes
        model.start = start
        onCommit = commit

        let p = makeFloatingPanel(PromptView(model: model) { [weak self] in self?.commitNow() })
        p.delegate = self
        panel = p

        let size = p.frame.size
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin: NSPoint
        if let b = bubble {
            origin = NSPoint(x: alignRight ? b.maxX - size.width : b.minX, y: b.midY - size.height / 2)
        } else {
            origin = NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 8)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        p.setFrameOrigin(origin)
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let panel = self.panel, e.window === panel else { return e }
            let step = e.modifierFlags.contains(.shift) ? 5 : 1
            switch e.keyCode {
            case 53: self.cancel(); return nil                       // esc
            case 126: self.adjust(step); return nil                  // ↑
            case 125: self.adjust(-step); return nil                 // ↓
            default: return e
            }
        }
    }

    private func adjust(_ delta: Int) {
        model.minutes = min(max(1, model.minutes + delta), 60 * 24 * 7)
    }

    private func commitNow(restoreFocus: Bool = true) {
        guard !finished else { return }
        let (title, minutes, start) = (model.title, model.minutes, model.start)
        let action = onCommit
        close(restoreFocus: restoreFocus)
        action?(title, minutes, start)
    }

    private func cancel() {
        guard !finished else { return }
        close(restoreFocus: true)
    }

    private func close(restoreFocus: Bool) {
        if restoreFocus { previousApp?.activate() }
        previousApp = nil
        finished = true
        onCommit = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Clicou fora: cria o timer com o que foi digitado.
    func windowDidResignKey(_ notification: Notification) {
        commitNow(restoreFocus: false)
    }
}

// MARK: - Janela de alerta (quando o tempo acaba)

struct AlertView: View {
    let item: TimerItem
    var snooze: (Int) -> Void
    var ok: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HourglassBadge(size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Text("Tempo esgotado · \(Fmt.longDuration(minutes: item.durationMinutes))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button("+5 min") { snooze(5) }
                    Button("+15 min") { snooze(15) }
                    Button("+1 h") { snooze(60) }
                    Spacer(minLength: 8)
                    Button("OK", action: ok).keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
                .padding(.top, 6)
            }
        }
        .padding(14)
        .frame(width: 330)
    }
}

@MainActor
final class AlertCenter {
    static let shared = AlertCenter()
    private var panels: [(id: String, panel: KeyPanel)] = []

    func show(_ item: TimerItem) {
        if Settings.shared.playSound { NSSound(named: "Glass")?.play() }
        dismiss(item.id)
        let id = item.id
        let view = AlertView(
            item: item,
            snooze: { [weak self] m in TimerStore.shared.snooze(id, minutes: m); self?.dismiss(id) },
            ok: { [weak self] in TimerStore.shared.acknowledge(id); self?.dismiss(id) }
        )
        let panel = makeFloatingPanel(view)
        panels.append((id, panel))
        layout()
        panel.orderFrontRegardless()
    }

    func dismiss(_ id: String) {
        panels.filter { $0.id == id }.forEach { $0.panel.orderOut(nil) }
        panels.removeAll { $0.id == id }
        layout()
    }

    private func layout() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        var y = visible.maxY - 12
        for entry in panels {
            let size = entry.panel.frame.size
            y -= size.height
            entry.panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 12, y: y))
            y -= 10
        }
    }
}
