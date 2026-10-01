import AppKit

/// Cores da Ampulhetinha (as mesmas do ícone).
enum Palette {
    static let peach = NSColor(srgbRed: 0.99, green: 0.70, blue: 0.55, alpha: 1)
    static let coral = NSColor(srgbRed: 0.95, green: 0.49, blue: 0.50, alpha: 1)
    static let lilac = NSColor(srgbRed: 0.72, green: 0.49, blue: 0.80, alpha: 1)
    static let gradient = NSGradient(colors: [peach, coral, lilac])!
    static let muted = NSGradient(colors: [NSColor(white: 0.62, alpha: 1), NSColor(white: 0.45, alpha: 1)])!
}

/// Janela transparente em tela cheia que desenha o gesto de arrastar:
/// o cordão saindo da ampulheta, a bolinha no cursor e o balão com o tempo.
@MainActor
final class DragOverlayController {
    private var window: NSWindow?
    private let lineView = DragLineView()
    private let bubble = NSVisualEffectView()
    private let bubbleContent = BubbleContentView()
    private var maskKey = ""

    private(set) var screen: NSScreen?
    private(set) var bubbleScreenFrame: NSRect = .zero
    private(set) var bubbleOnLeft = true

    func show(on screen: NSScreen, anchor: NSPoint) {
        let w = window ?? makeWindow()
        window = w
        self.screen = screen
        w.setFrame(screen.frame, display: false)
        let local = NSPoint(x: anchor.x - screen.frame.minX, y: anchor.y - screen.frame.minY)
        lineView.reset(anchor: local)
        bubble.isHidden = true
        w.orderFrontRegardless()
    }

    func update(cursor: NSPoint, minutes: Int, fireDate: Date) {
        guard let screen else { return }
        let local = NSPoint(x: cursor.x - screen.frame.minX, y: cursor.y - screen.frame.minY)
        bubbleContent.minutes = minutes
        bubbleContent.fireDate = fireDate
        layoutBubble(knob: local, screen: screen)
        lineView.move(knob: local, active: minutes > 0, bubble: bubble.frame,
                      pointerOnRight: bubbleOnLeft, pointerY: bubbleContent.pointerY)
        bubble.isHidden = false
    }

    func hide() {
        window?.orderOut(nil)
        screen = nil
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .popUpMenu
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = NSView()
        w.contentView = root
        lineView.frame = root.bounds
        lineView.autoresizingMask = [.width, .height]
        root.addSubview(lineView)

        bubble.material = .hudWindow
        bubble.blendingMode = .behindWindow
        bubble.state = .active
        bubble.appearance = NSAppearance(named: .vibrantDark)
        bubble.addSubview(bubbleContent)
        root.addSubview(bubble)
        return w
    }

    private func layoutBubble(knob: NSPoint, screen: NSScreen) {
        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let body = bubbleContent.bodySize()
        let size = NSSize(width: body.width + BubbleShape.pointerWidth, height: body.height)
        let gap = DragLineView.knobRadius + 8

        var onLeft = true
        var x = knob.x - gap - size.width
        if x < bounds.minX + 8 {
            onLeft = false
            x = knob.x + gap
        }
        var y = knob.y - size.height / 2
        y = min(max(y, bounds.minY + 8), bounds.maxY - menuBar - size.height - 4)
        let pointerY = min(max(knob.y - y, 20), size.height - 20).rounded()

        let frame = NSRect(x: x, y: y, width: size.width, height: size.height).integral
        bubble.frame = frame
        bubbleContent.frame = bubble.bounds
        bubbleContent.pointerOnRight = onLeft
        bubbleContent.pointerY = pointerY
        bubbleContent.needsDisplay = true

        let key = "\(Int(frame.width))x\(Int(frame.height))-\(onLeft)-\(Int(pointerY))"
        if key != maskKey {
            maskKey = key
            bubble.maskImage = BubbleShape.mask(size: frame.size, pointerOnRight: onLeft, pointerY: pointerY)
        }
        bubbleOnLeft = onLeft
        bubbleScreenFrame = frame.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }
}

// MARK: - Cordão + bolinha

final class DragLineView: NSView {
    static let knobRadius: CGFloat = 15

    private var anchor = NSPoint.zero
    private var knob = NSPoint.zero
    private var active = false
    private var bubbleFrame = NSRect.zero
    private var pointerOnRight = true
    private var pointerY: CGFloat = 0

    private lazy var knobIcon = NSImage.symbol("hourglass", size: 13, weight: .bold).tinted(.white)
    private lazy var cancelIcon = NSImage.symbol("xmark", size: 11, weight: .heavy).tinted(.white)

    func reset(anchor a: NSPoint) {
        anchor = a
        knob = a
        active = false
        bubbleFrame = .zero
        needsDisplay = true
    }

    func move(knob new: NSPoint, active: Bool, bubble: NSRect, pointerOnRight: Bool, pointerY: CGFloat) {
        let old = dirtyBounds()
        knob = new
        self.active = active
        bubbleFrame = bubble
        self.pointerOnRight = pointerOnRight
        self.pointerY = pointerY
        setNeedsDisplay(old.union(dirtyBounds()))
    }

    private func dirtyBounds() -> NSRect {
        let c = control
        let minX = min(anchor.x, knob.x, c.x), maxX = max(anchor.x, knob.x, c.x)
        let minY = min(anchor.y, knob.y, c.y), maxY = max(anchor.y, knob.y, c.y)
        var r = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -(Self.knobRadius + 26), dy: -(Self.knobRadius + 26))
        if !bubbleFrame.isEmpty { r = r.union(bubbleFrame.insetBy(dx: -30, dy: -30)) }
        return r
    }

    /// Ponto de controle: o cordão sai da ampulheta caindo reto e curva até o cursor.
    private var control: NSPoint {
        NSPoint(x: anchor.x, y: anchor.y - (anchor.y - knob.y) * 0.6)
    }

    private func point(_ t: CGFloat) -> NSPoint {
        let c = control, u = 1 - t
        return NSPoint(x: u * u * anchor.x + 2 * u * t * c.x + t * t * knob.x,
                       y: u * u * anchor.y + 2 * u * t * c.y + t * t * knob.y)
    }

    private func tangent(_ t: CGFloat) -> CGVector {
        let c = control, u = 1 - t
        var dx = 2 * u * (c.x - anchor.x) + 2 * t * (knob.x - c.x)
        var dy = 2 * u * (c.y - anchor.y) + 2 * t * (knob.y - c.y)
        let len = hypot(dx, dy)
        if len < 0.001 { return CGVector(dx: 0, dy: -1) }
        dx /= len; dy /= len
        return CGVector(dx: dx, dy: dy)
    }

    /// Cordão afinando do topo (mais grosso) até a ponta.
    private func cordPath(extra: CGFloat) -> NSBezierPath {
        let steps = 48
        let top: CGFloat = 6 + extra, end: CGFloat = 3.2 + extra
        var left: [NSPoint] = [], right: [NSPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = point(t), d = tangent(t)
            let w = (top + (end - top) * t) / 2
            left.append(NSPoint(x: p.x - d.dy * w, y: p.y + d.dx * w))
            right.append(NSPoint(x: p.x + d.dy * w, y: p.y - d.dx * w))
        }
        let path = NSBezierPath()
        path.move(to: left[0])
        left.dropFirst().forEach { path.line(to: $0) }
        right.reversed().forEach { path.line(to: $0) }
        path.close()
        let r = top / 2
        path.append(NSBezierPath(ovalIn: NSRect(x: anchor.x - r, y: anchor.y - r, width: r * 2, height: r * 2)))
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        guard hypot(knob.x - anchor.x, knob.y - anchor.y) > 1 else { return }

        drawBubbleShadow()

        let gradient = active ? Palette.gradient : Palette.muted

        // Contorno branco + sombra: o cordão aparece em qualquer papel de parede.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.white.withAlphaComponent(0.9).setFill()
        cordPath(extra: 1.8).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Cordão em degradê, do topo até a bolinha.
        NSGraphicsContext.saveGraphicsState()
        cordPath(extra: 0).addClip()
        gradient.draw(from: anchor, to: knob, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        NSGraphicsContext.restoreGraphicsState()

        drawKnob(gradient: gradient)
    }

    private func drawKnob(gradient: NSGradient) {
        let r = active ? Self.knobRadius : Self.knobRadius - 3
        let outer = NSRect(x: knob.x - r - 2.5, y: knob.y - r - 2.5, width: (r + 2.5) * 2, height: (r + 2.5) * 2)
        let inner = NSRect(x: knob.x - r, y: knob.y - r, width: r * 2, height: r * 2)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: outer).fill()
        NSGraphicsContext.restoreGraphicsState()

        let disc = NSBezierPath(ovalIn: inner)
        gradient.draw(in: disc, angle: -60)

        // Brilho sutil na metade de cima.
        NSGraphicsContext.saveGraphicsState()
        disc.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: inner.minX, y: inner.midY - 2, width: inner.width, height: inner.height / 2 + 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        let icon = active ? knobIcon : cancelIcon
        icon.draw(in: NSRect(x: (knob.x - icon.size.width / 2).rounded(), y: (knob.y - icon.size.height / 2).rounded(),
                             width: icon.size.width, height: icon.size.height))
    }

    /// Sombra do balão (só por fora dele; o balão é desenhado por cima, translúcido).
    private func drawBubbleShadow() {
        guard !bubbleFrame.isEmpty else { return }
        let shape = BubbleShape.path(in: bubbleFrame, pointerOnRight: pointerOnRight, pointerY: pointerY)
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: bubbleFrame.insetBy(dx: -40, dy: -40))
        clip.append(shape)
        clip.windingRule = .evenOdd
        clip.addClip()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Balão

enum BubbleShape {
    static let radius: CGFloat = 18
    static let pointerWidth: CGFloat = 11
    static let pointerHalf: CGFloat = 10

    /// Retângulo arredondado + biquinho apontando para a bolinha, num contorno só.
    static func path(in rect: NSRect, pointerOnRight: Bool, pointerY: CGFloat) -> NSBezierPath {
        let r = radius, h = pointerHalf
        let b = pointerOnRight
            ? NSRect(x: rect.minX, y: rect.minY, width: rect.width - pointerWidth, height: rect.height)
            : NSRect(x: rect.minX + pointerWidth, y: rect.minY, width: rect.width - pointerWidth, height: rect.height)
        let py = rect.minY + pointerY
        let p = NSBezierPath()
        p.move(to: NSPoint(x: b.minX + r, y: b.minY))
        p.line(to: NSPoint(x: b.maxX - r, y: b.minY))
        p.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.minY + r), radius: r, startAngle: 270, endAngle: 360)
        if pointerOnRight {
            p.line(to: NSPoint(x: b.maxX, y: py - h))
            p.line(to: NSPoint(x: rect.maxX, y: py))
            p.line(to: NSPoint(x: b.maxX, y: py + h))
        }
        p.line(to: NSPoint(x: b.maxX, y: b.maxY - r))
        p.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.maxY - r), radius: r, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: b.minX + r, y: b.maxY))
        p.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.maxY - r), radius: r, startAngle: 90, endAngle: 180)
        if !pointerOnRight {
            p.line(to: NSPoint(x: b.minX, y: py + h))
            p.line(to: NSPoint(x: rect.minX, y: py))
            p.line(to: NSPoint(x: b.minX, y: py - h))
        }
        p.line(to: NSPoint(x: b.minX, y: b.minY + r))
        p.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.minY + r), radius: r, startAngle: 180, endAngle: 270)
        p.close()
        return p
    }

    static func mask(size: NSSize, pointerOnRight: Bool, pointerY: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            path(in: rect, pointerOnRight: pointerOnRight, pointerY: pointerY).fill()
            return true
        }
    }
}

final class BubbleContentView: NSView {
    var minutes = 0
    var fireDate = Date()
    var pointerOnRight = true
    var pointerY: CGFloat = 36

    private let height: CGFloat = 72
    private let pad: CGFloat = 9
    private let font1 = NSFont.rounded(20, .semibold)
    private let font2 = NSFont.rounded(15, .medium)

    private var line1: String { minutes > 0 ? Fmt.longDuration(minutes: minutes) : "Cancelar" }
    private var line2: String { minutes > 0 ? Fmt.at(fireDate) : "solte aqui para desistir" }

    private var attrs1: [NSAttributedString.Key: Any] { [.font: font1, .foregroundColor: NSColor.white] }
    private var attrs2: [NSAttributedString.Key: Any] {
        [.font: font2, .foregroundColor: NSColor.white.withAlphaComponent(0.72)]
    }

    func bodySize() -> NSSize {
        let w = max((line1 as NSString).size(withAttributes: attrs1).width,
                    (line2 as NSString).size(withAttributes: attrs2).width)
        let clock = height - pad * 2
        return NSSize(width: (pad + clock + 12 + w + 20).rounded(.up), height: height)
    }

    private var bodyRect: NSRect {
        pointerOnRight
            ? NSRect(x: 0, y: 0, width: bounds.width - BubbleShape.pointerWidth, height: bounds.height)
            : NSRect(x: BubbleShape.pointerWidth, y: 0, width: bounds.width - BubbleShape.pointerWidth, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = BubbleShape.path(in: bounds.insetBy(dx: 0.5, dy: 0.5), pointerOnRight: pointerOnRight, pointerY: pointerY - 0.5)
        NSColor(white: 0.05, alpha: 0.2).setFill()
        outline.fill()
        NSColor(white: 1, alpha: 0.18).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let body = bodyRect
        let d = body.height - pad * 2
        drawClock(in: NSRect(x: body.minX + pad, y: body.minY + pad, width: d, height: d))

        let x = body.minX + pad + d + 12
        let s2 = line2 as NSString
        let h2 = s2.size(withAttributes: attrs2).height
        (line1 as NSString).draw(at: NSPoint(x: x, y: body.midY - 1), withAttributes: attrs1)
        s2.draw(at: NSPoint(x: x, y: body.midY - h2 - 1), withAttributes: attrs2)
    }

    private func fill(_ path: NSBezierPath, with gradient: NSGradient) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        gradient.draw(in: path.bounds, angle: -60)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawClock(in r: NSRect) {
        let c = NSPoint(x: r.midX, y: r.midY)
        let radius = r.width / 2
        NSColor(white: 1, alpha: 0.13).setFill()
        NSBezierPath(ovalIn: r).fill()

        guard minutes > 0 else {
            let x = NSBezierPath()
            let k = radius * 0.28
            x.move(to: NSPoint(x: c.x - k, y: c.y - k)); x.line(to: NSPoint(x: c.x + k, y: c.y + k))
            x.move(to: NSPoint(x: c.x - k, y: c.y + k)); x.line(to: NSPoint(x: c.x + k, y: c.y - k))
            x.lineWidth = 3; x.lineCapStyle = .round
            NSColor.white.withAlphaComponent(0.8).setStroke()
            x.stroke()
            return
        }

        let cal = Calendar.current
        let n = cal.dateComponents([.minute, .second], from: Date())
        let f = cal.dateComponents([.hour, .minute, .second], from: fireDate)
        let nowMin = Double(n.minute ?? 0) + Double(n.second ?? 0) / 60
        let fireMin = Double(f.minute ?? 0) + Double(f.second ?? 0) / 60
        func angle(_ minute: Double) -> CGFloat { CGFloat(90 - minute * 6) }

        // Mais de uma hora: anel completo no degradê.
        if minutes >= 60 {
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            ring.append(NSBezierPath(ovalIn: r.insetBy(dx: 3.5, dy: 3.5)))
            ring.windingRule = .evenOdd
            fill(ring, with: Palette.gradient)
        }
        // Fatia do tempo que vai passar dentro da hora.
        let span = Double(minutes % 60 == 0 && minutes >= 60 ? 0 : minutes % 60)
        if span > 0 {
            let sector = NSBezierPath()
            sector.move(to: c)
            sector.appendArc(withCenter: c, radius: radius - (minutes >= 60 ? 4.5 : 1.5),
                             startAngle: angle(nowMin), endAngle: angle(nowMin + span), clockwise: true)
            sector.close()
            fill(sector, with: Palette.gradient)
        }

        for i in 0..<12 {
            let a = CGFloat(i) * .pi / 6
            let dist = radius - 7
            let dot: CGFloat = i % 3 == 0 ? 1.6 : 1.0
            let p = NSPoint(x: c.x + dist * sin(a), y: c.y + dist * cos(a))
            NSColor.white.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2)).fill()
        }

        func hand(_ degrees: CGFloat, _ length: CGFloat, _ width: CGFloat) {
            let rad = degrees * .pi / 180
            let p = NSBezierPath()
            p.move(to: c)
            p.line(to: NSPoint(x: c.x + length * cos(rad), y: c.y + length * sin(rad)))
            p.lineWidth = width
            p.lineCapStyle = .round
            NSColor.white.setStroke()
            p.stroke()
        }
        let hour = Double((f.hour ?? 0) % 12) + fireMin / 60
        hand(CGFloat(90 - hour * 30), radius * 0.46, 3.2)
        hand(angle(fireMin), radius * 0.72, 2.2)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill()
        Palette.coral.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 1.3, y: c.y - 1.3, width: 2.6, height: 2.6)).fill()
    }
}

// MARK: - Utilitários

extension NSFont {
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }
}

extension NSImage {
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return base.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? base
    }

    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}
