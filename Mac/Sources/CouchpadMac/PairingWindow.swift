import AppKit
import CoreImage

/// Pairing payload shared by every host: the phone scans it, or opens it as a URL.
///   couchpad://pair?name=<host name>&addr=<ip>&port=48123&code=<6 digits>
enum PairingURL {
    static func make(name: String, address: String?, port: UInt16, code: String) -> String {
        var components = URLComponents()
        components.scheme = "couchpad"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "addr", value: address),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code", value: code),
        ]
        return components.string ?? ""
    }
}

/// Small floating window with the QR code and the digits under it.
final class PairingWindow {
    private let window: NSWindow
    private let imageView = NSImageView()
    private let codeLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair with Couchpad"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 30, y: 140, width: 240, height: 240)

        codeLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        codeLabel.alignment = .center
        codeLabel.frame = NSRect(x: 20, y: 88, width: 260, height: 44)

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.stringValue = "Scan with Couchpad on your iPhone (or with the Camera app), or type the code. It changes after each pairing."
        hintLabel.frame = NSRect(x: 24, y: 20, width: 252, height: 60)

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.addSubview(imageView)
        content.addSubview(codeLabel)
        content.addSubview(hintLabel)
        window.contentView = content
    }

    var isVisible: Bool { window.isVisible }

    func show(payload: String, code: String) {
        update(payload: payload, code: code)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func update(payload: String, code: String) {
        codeLabel.stringValue = code
        imageView.image = PairingWindow.qrImage(for: payload, size: 240)
    }

    private static func qrImage(for text: String, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
