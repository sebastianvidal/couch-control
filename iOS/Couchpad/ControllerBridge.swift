import Combine
import CoreGraphics
import Foundation
import GameController

/// Forwards a physical controller attached to the iPhone (Backbone, a Bluetooth PS/Xbox
/// pad, …) to the computer as keys and mouse, so any game that accepts keyboard + mouse
/// plays from the couch. The computer never sees a gamepad: macOS has no public way to
/// create one, so this is the honest version.
///
/// Default profile, FPS-shaped:
///   left stick / d-pad → W A S D / arrows      right stick → mouse look
///   A space · B ctrl · X r · Y f · L1 q · R1 e · L2 right-click · R2 left-click
///   L3 shift · R3 v · menu esc · options tab
@MainActor
final class ControllerBridge: ObservableObject {
    @Published private(set) var controllerName: String?

    weak var client: Client?
    weak var settings: AppSettings?

    private var controller: GCController?
    private var timer: Timer?
    private var heldKeys = Set<Int>()
    private var leftDown = false
    private var rightDown = false
    private var lookRemainder = CGPoint.zero
    private var observers: [NSObjectProtocol] = []

    // macOS virtual keycodes.
    private enum Key {
        static let w = 13, a = 0, s = 1, d = 2, q = 12, e = 14, r = 15, f = 3, v = 9
        static let space = 49, shift = 56, control = 59, esc = 53, tab = 48
        static let left = 123, right = 124, down = 125, up = 126
    }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                if let controller = note.object as? GCController { self?.attach(controller) }
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                if let controller = note.object as? GCController, controller === self?.controller { self?.detach() }
            }
        })
        if let existing = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            attach(existing)
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    private func attach(_ controller: GCController) {
        guard controller.extendedGamepad != nil else { return }
        self.controller = controller
        controllerName = controller.vendorName ?? "Controller"
        timer?.invalidate()
        // Poll at 60 Hz: simpler than per-element handlers and the sticks need a frame clock anyway.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func detach() {
        timer?.invalidate()
        timer = nil
        releaseAll()
        controller = nil
        controllerName = nil
    }

    /// Lets go of everything, e.g. when the app leaves the foreground.
    func releaseAll() {
        for code in heldKeys { client?.send("k \(code) 0") }
        heldKeys.removeAll()
        if leftDown { client?.send("b l 0"); leftDown = false }
        if rightDown { client?.send("b r 0"); rightDown = false }
    }

    private func tick() {
        guard let pad = controller?.extendedGamepad, let client, client.isConnected else {
            if !heldKeys.isEmpty || leftDown || rightDown { releaseAll() }
            return
        }

        // Digital keys: buttons plus the left stick quantised with hysteresis-free 0.5 threshold.
        var wanted = Set<Int>()
        let ls = pad.leftThumbstick
        if ls.yAxis.value > 0.5 { wanted.insert(Key.w) }
        if ls.yAxis.value < -0.5 { wanted.insert(Key.s) }
        if ls.xAxis.value < -0.5 { wanted.insert(Key.a) }
        if ls.xAxis.value > 0.5 { wanted.insert(Key.d) }
        if pad.dpad.up.isPressed { wanted.insert(Key.up) }
        if pad.dpad.down.isPressed { wanted.insert(Key.down) }
        if pad.dpad.left.isPressed { wanted.insert(Key.left) }
        if pad.dpad.right.isPressed { wanted.insert(Key.right) }
        if pad.buttonA.isPressed { wanted.insert(Key.space) }
        if pad.buttonB.isPressed { wanted.insert(Key.control) }
        if pad.buttonX.isPressed { wanted.insert(Key.r) }
        if pad.buttonY.isPressed { wanted.insert(Key.f) }
        if pad.leftShoulder.isPressed { wanted.insert(Key.q) }
        if pad.rightShoulder.isPressed { wanted.insert(Key.e) }
        if pad.leftThumbstickButton?.isPressed == true { wanted.insert(Key.shift) }
        if pad.rightThumbstickButton?.isPressed == true { wanted.insert(Key.v) }
        if pad.buttonMenu.isPressed { wanted.insert(Key.esc) }
        if pad.buttonOptions?.isPressed == true { wanted.insert(Key.tab) }

        for code in heldKeys.subtracting(wanted) { client.send("k \(code) 0") }
        for code in wanted.subtracting(heldKeys) { client.send("k \(code) 1") }
        heldKeys = wanted

        // Triggers as mouse buttons: R2 fires, L2 aims.
        let fire = pad.rightTrigger.isPressed
        let aim = pad.leftTrigger.isPressed
        if fire != leftDown { client.send("b l \(fire ? 1 : 0)"); leftDown = fire }
        if aim != rightDown { client.send("b r \(aim ? 1 : 0)"); rightDown = aim }

        // Right stick as mouse look: deadzone, then a squared curve so small deflections are fine.
        let rs = pad.rightThumbstick
        let speed = CGFloat(settings?.controllerLookSpeed ?? 10)
        let invert: CGFloat = settings?.controllerInvertY == true ? 1 : -1
        let dx = curve(CGFloat(rs.xAxis.value)) * speed + lookRemainder.x
        let dy = curve(CGFloat(rs.yAxis.value)) * speed * invert + lookRemainder.y
        let ix = Int(dx.rounded(.towardZero))
        let iy = Int(dy.rounded(.towardZero))
        lookRemainder = CGPoint(x: dx - CGFloat(ix), y: dy - CGFloat(iy))
        if ix != 0 || iy != 0 { client.send("m \(ix) \(iy)") }
    }

    private func curve(_ v: CGFloat) -> CGFloat {
        let dead: CGFloat = 0.15
        guard abs(v) > dead else { return 0 }
        let t = (abs(v) - dead) / (1 - dead)
        return (v < 0 ? -1 : 1) * t * t
    }
}
