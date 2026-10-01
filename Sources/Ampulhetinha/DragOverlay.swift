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
        lineView.move(knob: local, minutes: minutes, bubble: bubble.frame,
                      pointerUp: bubbleContent.pointerUp, pointerX: bubbleContent.pointerX)
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

    /// Balão centralizado embaixo da ampulheta, com o biquinho para cima;
    /// sobe para cima dela só quando não cabe no pé da tela.
    private func layoutBubble(knob: NSPoint, screen: NSScreen) {
        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        let body = bubbleContent.bodySize()
        let size = NSSize(width: body.width, height: body.height + BubbleShape.pointerWidth)
        let gap = DragLineView.knobRadius + 4

        var up = true
        var y = knob.y - gap - size.height
        if y < bounds.minY + 8 {
            up = false
            y = knob.y + gap
        }
        // Origem arredondada (não .integral): o tamanho não oscila 1 pt e a máscara não é refeita.
        let x = min(max(knob.x - size.width / 2, bounds.minX + 8), bounds.maxX - size.width - 8).rounded()
        y = y.rounded()
        let inset = BubbleShape.radius + BubbleShape.pointerHalf
        let pointerX = min(max(knob.x - x, inset), size.width - inset).rounded()

        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        bubble.frame = frame
        bubbleContent.frame = bubble.bounds
        bubbleContent.pointerUp = up
        bubbleContent.pointerX = pointerX
        bubbleContent.needsDisplay = true

        let key = "\(Int(frame.width))x\(Int(frame.height))-\(up)-\(Int(pointerX))"
        if key != maskKey {
            maskKey = key
            bubble.maskImage = BubbleShape.mask(size: frame.size, pointerUp: up, pointerX: pointerX)
        }
        bubbleScreenFrame = frame.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }
}

// MARK: - Cordão + bolinha

final class DragLineView: NSView {
    static let knobRadius: CGFloat = 20

    private var anchor = NSPoint.zero
    private var knob = NSPoint.zero
    private var active = false
    private var bubbleFrame = NSRect.zero
    private var pointerUp = true
    private var pointerX: CGFloat = 0
    /// A ampulheta da bolinha gira 22,5° a cada 5 min (horário ao aumentar), com a virada suavizada.
    private var iconAngle: CGFloat = 0
    private var targetAngle: CGFloat = 0
    private var spin: Timer?

    private lazy var knobSymbol = NSImage.symbol("hourglass", size: 32, weight: .bold)
    private lazy var cancelSymbol = NSImage.symbol("xmark", size: 18, weight: .heavy)
    private lazy var knobIcon = knobSymbol.tinted(Palette.gradient)
    private lazy var knobHalo = knobSymbol.tinted(.white)
    private lazy var cancelIcon = cancelSymbol.tinted(Palette.muted)
    private lazy var cancelHalo = cancelSymbol.tinted(.white)

    func reset(anchor a: NSPoint) {
        anchor = a
        knob = a
        active = false
        bubbleFrame = .zero
        iconAngle = 0
        targetAngle = 0
        spin?.invalidate()
        spin = nil
        needsDisplay = true
    }

    func move(knob new: NSPoint, minutes: Int, bubble: NSRect, pointerUp: Bool, pointerX: CGFloat) {
        let old = dirtyBounds()
        knob = new
        active = minutes > 0
        targetAngle = -CGFloat(minutes) * 22.5 / 5
        if spin == nil && iconAngle != targetAngle {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.stepSpin() }
            }
            RunLoop.main.add(t, forMode: .common)
            spin = t
        }
        bubbleFrame = bubble
        self.pointerUp = pointerUp
        self.pointerX = pointerX
        setNeedsDisplay(old.union(dirtyBounds()))
    }

    private func stepSpin() {
        iconAngle += (targetAngle - iconAngle) * 0.25
        if abs(targetAngle - iconAngle) < 0.3 {
            iconAngle = targetAngle
            spin?.invalidate()
            spin = nil
        }
        let r = Self.knobRadius + 12
        setNeedsDisplay(NSRect(x: knob.x - r, y: knob.y - r, width: r * 2, height: r * 2))
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
        let top: CGFloat = 4 + extra, end: CGFloat = 2.2 + extra
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
        // Ponta redonda no mesmo contorno: um círculo à parte, girando ao contrário, abria um buraco.
        let d = tangent(0)
        let start = atan2(-d.dx, d.dy) * 180 / .pi
        path.appendArc(withCenter: anchor, radius: top / 2, startAngle: start, endAngle: start - 180, clockwise: true)
        path.close()
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
        cordPath(extra: 1.4).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Cordão em degradê, do topo até a bolinha.
        NSGraphicsContext.saveGraphicsState()
        cordPath(extra: 0).addClip()
        gradient.draw(from: anchor, to: knob, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        NSGraphicsContext.restoreGraphicsState()

        drawKnob()
    }

    /// Só a ampulheta (sem disco), no degradê do cordão e com o mesmo contorno branco + sombra.
    private func drawKnob() {
        let (icon, halo) = active ? (knobIcon, knobHalo) : (cancelIcon, cancelHalo)
        NSGraphicsContext.saveGraphicsState()
        let rotation = NSAffineTransform()
        rotation.translateX(by: knob.x, yBy: knob.y)
        rotation.rotate(byDegrees: active ? iconAngle : 0)
        rotation.concat()
        let rect = NSRect(x: -icon.size.width / 2, y: -icon.size.height / 2, width: icon.size.width, height: icon.size.height)

        // Contorno: a silhueta branca carimbada em volta, numa camada só para a sombra sair uma vez.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            halo.draw(in: rect.offsetBy(dx: 1.6 * cos(a), dy: 1.6 * sin(a)))
        }
        NSGraphicsContext.current?.cgContext.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        rotation.concat()
        icon.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Sombra do balão (só por fora dele; o balão é desenhado por cima, translúcido).
    private func drawBubbleShadow() {
        guard !bubbleFrame.isEmpty else { return }
        let shape = BubbleShape.path(in: bubbleFrame, pointerUp: pointerUp, pointerX: pointerX)
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

    /// Retângulo arredondado + biquinho (em cima ou embaixo) apontando para a ampulheta, num contorno só.
    static func path(in rect: NSRect, pointerUp: Bool, pointerX: CGFloat) -> NSBezierPath {
        let r = radius, h = pointerHalf
        let b = pointerUp
            ? NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - pointerWidth)
            : NSRect(x: rect.minX, y: rect.minY + pointerWidth, width: rect.width, height: rect.height - pointerWidth)
        let px = rect.minX + pointerX
        let p = NSBezierPath()
        p.move(to: NSPoint(x: b.minX + r, y: b.minY))
        if !pointerUp {
            p.line(to: NSPoint(x: px - h, y: b.minY))
            p.line(to: NSPoint(x: px, y: rect.minY))
            p.line(to: NSPoint(x: px + h, y: b.minY))
        }
        p.line(to: NSPoint(x: b.maxX - r, y: b.minY))
        p.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.minY + r), radius: r, startAngle: 270, endAngle: 360)
        p.line(to: NSPoint(x: b.maxX, y: b.maxY - r))
        p.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.maxY - r), radius: r, startAngle: 0, endAngle: 90)
        if pointerUp {
            p.line(to: NSPoint(x: px + h, y: b.maxY))
            p.line(to: NSPoint(x: px, y: rect.maxY))
            p.line(to: NSPoint(x: px - h, y: b.maxY))
        }
        p.line(to: NSPoint(x: b.minX + r, y: b.maxY))
        p.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.maxY - r), radius: r, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: b.minX, y: b.minY + r))
        p.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.minY + r), radius: r, startAngle: 180, endAngle: 270)
        p.close()
        return p
    }

    static func mask(size: NSSize, pointerUp: Bool, pointerX: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            path(in: rect, pointerUp: pointerUp, pointerX: pointerX).fill()
            return true
        }
    }
}

final class BubbleContentView: NSView {
    var minutes = 0
    var fireDate = Date()
    var pointerUp = true
    var pointerX: CGFloat = 36

    private let height: CGFloat = 72
    private let pad: CGFloat = 9
    private let font1 = NSFont.rounded(20, .semibold)
    private let font2 = NSFont.rounded(15, .semibold)

    private var line1: String { minutes > 0 ? Fmt.shortRemaining(TimeInterval(minutes * 60)) : "Cancelar" }
    private var line2: String { minutes > 0 ? Fmt.at(fireDate) : "solte aqui para desistir" }

    private var attrs1: [NSAttributedString.Key: Any] { [.font: font1, .foregroundColor: NSColor.white] }
    private var attrs2: [NSAttributedString.Key: Any] {
        [.font: font2, .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
    }

    /// Largura fixa enquanto há tempo: não pula entre "45 min" e "1 h 15 min"
    /// (só cresce se precisar, como "amanhã às…"; mudar a largura refaz a máscara do balão e engasga o arrasto).
    func bodySize() -> NSSize {
        let (l1, l2) = minutes > 0 ? ("8 h 88 min", "às 88:88") : ("", "")
        let w = max((l1 as NSString).size(withAttributes: attrs1).width, (line1 as NSString).size(withAttributes: attrs1).width,
                    (l2 as NSString).size(withAttributes: attrs2).width, (line2 as NSString).size(withAttributes: attrs2).width)
        let clock = height - pad * 2
        return NSSize(width: (pad + clock + 12 + w + 20).rounded(.up), height: height)
    }

    private var bodyRect: NSRect {
        pointerUp
            ? NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - BubbleShape.pointerWidth)
            : NSRect(x: 0, y: BubbleShape.pointerWidth, width: bounds.width, height: bounds.height - BubbleShape.pointerWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = BubbleShape.path(in: bounds.insetBy(dx: 0.5, dy: 0.5), pointerUp: pointerUp, pointerX: pointerX - 0.5)
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

    func tinted(_ gradient: NSGradient) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            NSGraphicsContext.current?.compositingOperation = .sourceAtop
            gradient.draw(in: rect, angle: -60)
            return true
        }
        img.isTemplate = false
        return img
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
