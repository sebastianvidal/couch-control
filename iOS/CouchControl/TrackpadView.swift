import SwiftUI
import UIKit

/// One finger moves, tap clicks, two-finger tap right-clicks, two fingers scroll,
/// tap-then-touch-and-hold drags.
struct TrackpadView: UIViewRepresentable {
    let client: Client
    let settings: AppSettings

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.client = client
        view.settings = settings
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {}
}

final class TrackpadUIView: UIView {
    weak var client: Client?
    weak var settings: AppSettings?

    private var active: [UITouch: CGPoint] = [:]
    private var startTime: TimeInterval = 0
    private var maxTouches = 0
    private var travel: CGFloat = 0
    private var lastTapTime: TimeInterval = 0
    private var dragging = false
    private var moveRemainder = CGPoint.zero
    private var scrollRemainder = CGPoint.zero
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = Date().timeIntervalSince1970
        if active.isEmpty {
            startTime = now
            maxTouches = 0
            travel = 0
            if settings?.tapToDrag == true, now - lastTapTime < 0.3 {
                dragging = true
                client?.send("b l 1")
                haptic.impactOccurred()
            }
        }
        for touch in touches { active[touch] = touch.location(in: self) }
        maxTouches = max(maxTouches, active.count)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var delta = CGPoint.zero
        var moved = 0
        for touch in touches {
            guard let previous = active[touch] else { continue }
            let point = touch.location(in: self)
            delta.x += point.x - previous.x
            delta.y += point.y - previous.y
            active[touch] = point
            moved += 1
        }
        guard moved > 0 else { return }
        delta.x /= CGFloat(moved)
        delta.y /= CGFloat(moved)
        travel += hypot(delta.x, delta.y)

        if active.count == 1 {
            sendMove(delta)
        } else if active.count >= 2 {
            sendScroll(delta)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches { active.removeValue(forKey: touch) }
        guard active.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let duration = now - startTime
        if dragging {
            dragging = false
            client?.send("b l 0")
        } else if duration < 0.25, travel < 12 {
            if maxTouches == 1 {
                client?.send("c l")
                lastTapTime = now
                haptic.impactOccurred()
            } else if maxTouches == 2 {
                client?.send("c r")
                haptic.impactOccurred()
            }
        }
    }

    private func sendMove(_ delta: CGPoint) {
        let scale = CGFloat(settings?.sensitivity ?? 2.5)
        let fx = delta.x * scale + moveRemainder.x
        let fy = delta.y * scale + moveRemainder.y
        let ix = Int(fx.rounded(.towardZero))
        let iy = Int(fy.rounded(.towardZero))
        moveRemainder = CGPoint(x: fx - CGFloat(ix), y: fy - CGFloat(iy))
        if ix != 0 || iy != 0 { client?.send("m \(ix) \(iy)") }
    }

    private func sendScroll(_ delta: CGPoint) {
        let scale = CGFloat(settings?.scrollSpeed ?? 1.5)
        let direction: CGFloat = settings?.naturalScroll == false ? -1 : 1
        let fx = delta.x * scale * direction + scrollRemainder.x
        let fy = delta.y * scale * direction + scrollRemainder.y
        let ix = Int(fx.rounded(.towardZero))
        let iy = Int(fy.rounded(.towardZero))
        scrollRemainder = CGPoint(x: fx - CGFloat(ix), y: fy - CGFloat(iy))
        if ix != 0 || iy != 0 { client?.send("s \(ix) \(iy)") }
    }
}
