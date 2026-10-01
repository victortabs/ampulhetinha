import AppKit
import SwiftUI

/// A ampulheta na barra de menus: clique abre a lista, arrastar para baixo cria um timer.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: TimerStore
    private let popover = NSPopover()
    private let overlay = DragOverlayController()
    private var monitor: Any?

    private var mouseDownAt: NSPoint?
    private var pressPoller: Timer?
    private var dragging = false
    private var anchor = NSPoint.zero
    private var dragMinutes = 0
    private var dragStart = Date()
    private var lastDrag: (point: NSPoint, fine: Bool, at: Date) = (.zero, false, .distantPast)
    private var hapticBucket = 0
    private var lastPopoverClose = Date.distantPast

    private var currentSymbol = ""
    private var currentTitle = "-"

    init(store: TimerStore) {
        self.store = store
        super.init()
        statusItem.autosaveName = "AmpulhetinhaStatusItem"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.setAccessibilityLabel("Ampulhetinha")

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: TimerListView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        refresh()
    }

    // MARK: Aparência

    func refresh() {
        guard let button = statusItem.button else { return }
        let next = store.next
        let symbol = store.hasOverdue ? "hourglass.bottomhalf.filled"
            : (next != nil ? "hourglass.tophalf.filled" : "hourglass")
        if symbol != currentSymbol {
            currentSymbol = symbol
            let img = NSImage.symbol(symbol, size: 14, weight: .medium)
            img.isTemplate = true
            button.image = img
        }

        var title = ""
        if Settings.shared.showCountdown, let n = next {
            let left = n.fireDate.timeIntervalSince(store.now)
            if left < 86_400 { title = Fmt.compact(left) }
        }
        if title != currentTitle {
            currentTitle = title
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            button.attributedTitle = NSAttributedString(string: title.isEmpty ? "" : " " + title,
                                                        attributes: [.font: font])
        }
        button.toolTip = next.map { "\($0.displayTitle) — \(Fmt.at($0.fireDate))" }
            ?? "Arraste para baixo para criar um timer"
    }

    // MARK: Eventos

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let button = statusItem.button, let win = button.window else { return event }
        switch event.type {
        case .leftMouseDown:
            guard event.window === win else { return event }
            if event.modifierFlags.contains(.control) { togglePopover(); return nil }
            mouseDownAt = NSEvent.mouseLocation
            dragging = false
            button.highlight(true)
            startPolling()
            return nil

        case .rightMouseDown:
            guard event.window === win else { return event }
            togglePopover()
            return nil

        case .leftMouseDragged:
            // O acompanhamento é feito por `pollPress()`; aqui só engolimos o evento.
            return mouseDownAt == nil ? event : nil

        case .leftMouseUp:
            guard mouseDownAt != nil else { return event }
            // No macOS 26+ o sistema manda um mouseUp sintético logo após o mouseDown,
            // com o botão ainda apertado. Só vale o "soltou" de verdade.
            if NSEvent.pressedMouseButtons & 1 != 0 { return nil }
            finishPress()
            return nil

        default:
            return event
        }
    }

    // MARK: Arrastar

    /// Os itens da barra de menus não recebem mais eventos de arrasto (o sistema
    /// converte o toque num clique), então lemos mouse e botão diretamente.
    private func startPolling() {
        pressPoller?.invalidate()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPress() }
        }
        RunLoop.main.add(t, forMode: .common)
        pressPoller = t
    }

    private func pollPress() {
        guard let start = mouseDownAt else { finishPress(); return }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            finishPress()
            return
        }
        let p = NSEvent.mouseLocation
        if !dragging, hypot(p.x - start.x, p.y - start.y) > 3 { beginDrag() }
        if dragging { updateDrag(to: p, fine: NSEvent.modifierFlags.contains(.option)) }
    }

    private func finishPress() {
        pressPoller?.invalidate()
        pressPoller = nil
        guard mouseDownAt != nil else { return }
        mouseDownAt = nil
        statusItem.button?.highlight(false)
        if dragging {
            dragging = false
            endDrag()
        } else {
            togglePopover()
        }
    }

    private func iconAnchor() -> (NSPoint, NSScreen)? {
        guard let button = statusItem.button, let win = button.window,
              let screen = win.screen ?? NSScreen.main else { return nil }
        let rect = win.convertToScreen(button.convert(button.bounds, to: nil))
        let x: CGFloat
        if currentTitle.isEmpty {
            x = rect.midX
        } else {
            x = rect.minX + 6 + (button.image?.size.width ?? 16) / 2
        }
        // O cordão nasce logo abaixo da barra de menus, não por cima dela.
        return (NSPoint(x: x, y: min(rect.minY, screen.visibleFrame.maxY) - 2), screen)
    }

    private func beginDrag() {
        guard let (a, screen) = iconAnchor() else { return }
        dragging = true
        anchor = a
        dragMinutes = 0
        hapticBucket = 0
        lastDrag.at = .distantPast
        if popover.isShown { popover.performClose(nil) }
        overlay.show(on: screen, anchor: a)
    }

    private func updateDrag(to point: NSPoint, fine: Bool) {
        guard let screen = overlay.screen else { return }
        let f = screen.frame
        let p = NSPoint(x: min(max(point.x, f.minX + 2), f.maxX - 2), y: min(max(point.y, f.minY + 2), f.maxY - 2))
        // O poller roda a 120 Hz: com o mouse parado só refaz 1×/s (para o horário do balão andar).
        let now = Date()
        let moved = p != lastDrag.point || fine != lastDrag.fine
        guard moved || now.timeIntervalSince(lastDrag.at) >= 1 else { return }
        lastDrag = (p, fine, now)
        let distance = hypot(p.x - anchor.x, p.y - anchor.y)
        let (minutes, start) = DurationMapper.choice(distance: distance, fine: fine)

        // Toque leve no trackpad a cada opção nova (só se foi o mouse que mudou, não o relógio).
        if minutes != hapticBucket {
            hapticBucket = minutes
            if moved { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        dragMinutes = minutes
        dragStart = start
        overlay.update(cursor: p, minutes: minutes, fireDate: start.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    private func endDrag() {
        let minutes = dragMinutes
        let bubble = overlay.bubbleScreenFrame
        let screen = overlay.screen
        overlay.hide()
        guard minutes > 0 else { return }
        let start = dragStart
        TitlePrompt.shared.present(minutes: minutes, start: start, bubble: bubble,
                                   screen: screen) { [store] title, minutes, start in
            store.add(title: title, minutes: minutes, start: start)
        }
    }

    // MARK: Popover

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if Date().timeIntervalSince(lastPopoverClose) > 0.25 {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        store.refreshExternal()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
    }

    /// Ponto logo abaixo da ampulheta, para abrir o campo de título a partir do menu.
    func promptAnchorScreen() -> NSScreen? {
        iconAnchor()?.1
    }
}

