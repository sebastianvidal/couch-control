import Combine
import CoreGraphics
import Foundation
import GameController

/// Forwards a physical controller attached to the iPhone (Backbone, a Bluetooth PS/Xbox
/// pad, …) to the computer as keys and mouse, so any game that accepts keyboard + mouse
/// plays from the couch. The computer never sees a gamepad: macOS has no public way to
/// create one, so this is the honest version.
///
/// What each control does comes from the user's ControllerProfile (presets: FPS, MapleStory,
/// Arrows), edited in Settings → Controller bindings.
@MainActor
final class ControllerBridge: ObservableObject {
    @Published private(set) var controllerName: String?
    @Published var profile = ControllerProfile.load() {
        didSet {
            profile.save()
            releaseAll()   // old bindings may be held; start clean under the new ones
        }
    }

    weak var client: Client?
    weak var settings: AppSettings?

    private var controller: GCController?
    private var timer: Timer?
    private var heldKeys = Set<Int>()
    private var leftDown = false
    private var rightDown = false
    private var lookRemainder = CGPoint.zero
    private var observers: [NSObjectProtocol] = []

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

        var keys = Set<Int>()
        var left = false, right = false
        var look = CGPoint.zero

        func apply(_ control: Control, _ pressed: Bool) {
            guard pressed else { return }
            switch profile[control] {
            case .none, .mouseLook: break
            case .key(let code): keys.insert(code)
            case .mouseLeft: left = true
            case .mouseRight: right = true
            }
        }

        let ls = pad.leftThumbstick
        apply(.leftStickUp, ls.yAxis.value > 0.5)
        apply(.leftStickDown, ls.yAxis.value < -0.5)
        apply(.leftStickLeft, ls.xAxis.value < -0.5)
        apply(.leftStickRight, ls.xAxis.value > 0.5)
        apply(.dpadUp, pad.dpad.up.isPressed)
        apply(.dpadDown, pad.dpad.down.isPressed)
        apply(.dpadLeft, pad.dpad.left.isPressed)
        apply(.dpadRight, pad.dpad.right.isPressed)
        apply(.a, pad.buttonA.isPressed)
        apply(.b, pad.buttonB.isPressed)
        apply(.x, pad.buttonX.isPressed)
        apply(.y, pad.buttonY.isPressed)
        apply(.l1, pad.leftShoulder.isPressed)
        apply(.r1, pad.rightShoulder.isPressed)
        apply(.l2, pad.leftTrigger.isPressed)
        apply(.r2, pad.rightTrigger.isPressed)
        apply(.l3, pad.leftThumbstickButton?.isPressed == true)
        apply(.r3, pad.rightThumbstickButton?.isPressed == true)
        apply(.menu, pad.buttonMenu.isPressed)
        apply(.options, pad.buttonOptions?.isPressed == true)

        // The right stick is either mouse look or nothing (bind it to a key to use it as a button).
        let rs = pad.rightThumbstick
        switch profile[.rightStick] {
        case .mouseLook:
            let speed = CGFloat(settings?.controllerLookSpeed ?? 10)
            let invert: CGFloat = settings?.controllerInvertY == true ? 1 : -1
            look = CGPoint(x: curve(CGFloat(rs.xAxis.value)) * speed, y: curve(CGFloat(rs.yAxis.value)) * speed * invert)
        case .key(let code):
            if abs(rs.xAxis.value) > 0.5 || abs(rs.yAxis.value) > 0.5 { keys.insert(code) }
        case .mouseLeft:
            if abs(rs.xAxis.value) > 0.5 || abs(rs.yAxis.value) > 0.5 { left = true }
        case .mouseRight:
            if abs(rs.xAxis.value) > 0.5 || abs(rs.yAxis.value) > 0.5 { right = true }
        case .none:
            break
        }

        for code in heldKeys.subtracting(keys) { client.send("k \(code) 0") }
        for code in keys.subtracting(heldKeys) { client.send("k \(code) 1") }
        heldKeys = keys
        if left != leftDown { client.send("b l \(left ? 1 : 0)"); leftDown = left }
        if right != rightDown { client.send("b r \(right ? 1 : 0)"); rightDown = right }

        let dx = look.x + lookRemainder.x
        let dy = look.y + lookRemainder.y
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
