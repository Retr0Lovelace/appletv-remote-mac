import SwiftUI
import AppKit

enum PadDirection: Sendable { case up, down, left, right }
enum PadZone: Sendable, Equatable { case center, arrow(PadDirection) }

/// Rapport inner/outer du clickpad (cercle intérieur = select).
let clickpadInnerRatio: CGFloat = 0.55

/// Surface tactile façon Siri Remote : glisser = swipe, clic au centre = select,
/// clic sur le bord = flèche (clickwheel), défilement à deux doigts = swipe.
final class ClickpadNSView: NSView {
    var onSwipe: ((Int, Int, Int, Int) -> Void)?   // coordonnées 0...1000
    var onClick: (() -> Void)?
    var onArrow: ((PadDirection) -> Void)?
    var onLongPress: (() -> Void)?
    var onPressZone: ((PadZone?) -> Void)?

    private var downPoint = CGPoint.zero
    private var dragged = false
    private var accX = 0.0, accY = 0.0
    private var scrollAcc = CGPoint.zero
    private var longTimer: Timer?
    private var longFired = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        dragged = false; longFired = false; accX = 0; accY = 0
        onPressZone?(zone(at: downPoint))
        longTimer?.invalidate()
        longTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.dragged else { return }
                self.longFired = true
                self.onLongPress?()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !dragged && hypot(p.x - downPoint.x, p.y - downPoint.y) < 6 { return }
        dragged = true
        onPressZone?(nil)
        longTimer?.invalidate()
        accX += event.deltaX
        accY += event.deltaY
        emitSwipe(threshold: 28)
    }

    override func mouseUp(with event: NSEvent) {
        longTimer?.invalidate()
        onPressZone?(nil)
        guard !dragged, !longFired else { return }
        switch zone(at: convert(event.locationInWindow, from: nil)) {
        case .arrow(let d): onArrow?(d)
        case .center: onClick?()
        }
    }

    private func zone(at p: CGPoint) -> PadZone {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        let r = min(bounds.width, bounds.height) / 2
        guard hypot(dx, dy) > r * clickpadInnerRatio else { return .center }
        if abs(dx) > abs(dy) { return .arrow(dx > 0 ? .right : .left) }
        return .arrow(dy > 0 ? .down : .up)
    }

    override func scrollWheel(with event: NSEvent) {
        let k = event.hasPreciseScrollingDeltas ? 1.0 : 8.0
        scrollAcc.x += event.scrollingDeltaX * k
        scrollAcc.y += event.scrollingDeltaY * k
        accX = scrollAcc.x; accY = scrollAcc.y
        emitSwipe(threshold: 30)
        scrollAcc = CGPoint(x: accX, y: accY)
    }

    private func emitSwipe(threshold: Double) {
        guard abs(accX) >= threshold || abs(accY) >= threshold else { return }
        let len = 280
        if abs(accX) > abs(accY) {
            let s = accX > 0 ? 1 : -1
            onSwipe?(500 - s * len / 2, 500, 500 + s * len / 2, 500)
        } else {
            let s = accY > 0 ? 1 : -1
            onSwipe?(500, 500 - s * len / 2, 500, 500 + s * len / 2)
        }
        accX = 0; accY = 0
    }
}

struct ClickpadView: NSViewRepresentable {
    let onSwipe: (Int, Int, Int, Int) -> Void
    let onClick: () -> Void
    let onArrow: (PadDirection) -> Void
    let onLongPress: () -> Void
    var onPressZone: (PadZone?) -> Void = { _ in }

    func makeNSView(context: Context) -> ClickpadNSView {
        let v = ClickpadNSView()
        apply(v)
        return v
    }
    func updateNSView(_ v: ClickpadNSView, context: Context) { apply(v) }
    private func apply(_ v: ClickpadNSView) {
        v.onSwipe = onSwipe; v.onClick = onClick; v.onArrow = onArrow; v.onLongPress = onLongPress; v.onPressZone = onPressZone
    }
}
