import AppKit
import ApplicationServices
import ServiceManagement

let servicePort: UInt16 = 48123

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let codeLine = NSMenuItem(title: "", action: #selector(showPairingCode), keyEquivalent: "")
    private let addressLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let axLine = NSMenuItem(title: "", action: #selector(requestAccessibility), keyEquivalent: "")
    private let loginLine = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let forgetLine = NSMenuItem(title: "Forget Paired iPhones…", action: #selector(forgetPhones), keyEquivalent: "")
    private var server: Server?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Couch Control")

        menu.delegate = self
        menu.addItem(statusLine)
        menu.addItem(codeLine)
        menu.addItem(addressLine)
        menu.addItem(axLine)
        menu.addItem(.separator())
        menu.addItem(loginLine)
        menu.addItem(forgetLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Couch Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in [codeLine, axLine, loginLine, forgetLine] { item.target = self }
        statusItem.menu = menu

        refreshAccessibility(prompt: true)

        do {
            let server = try Server(port: servicePort) { [weak self] in
                DispatchQueue.main.async { self?.refresh() }
            }
            server.start()
            self.server = server
        } catch {
            statusLine.title = "Could not start: \(error.localizedDescription)"
        }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshAccessibility(prompt: false)
        refresh()
    }

    private func refresh() {
        statusLine.title = server?.status ?? statusLine.title
        codeLine.title = "Pairing code: \(Pairing.shared.code)"
        addressLine.title = "Address: \(localIPv4() ?? "?"):\(servicePort)"
        loginLine.state = SMAppService.mainApp.status == .enabled ? .on : .off
        forgetLine.isEnabled = Pairing.shared.pairedCount > 0
    }

    private func refreshAccessibility(prompt: Bool) {
        let trusted: Bool
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrusted()
        }
        axLine.title = trusted ? "Accessibility: granted" : "Accessibility: not granted — click to fix"
        axLine.isEnabled = !trusted
    }

    @objc private func showPairingCode() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = Pairing.shared.code
        alert.informativeText = "Enter this code in Couch Control on your iPhone. It changes after each pairing."
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    @objc private func requestAccessibility() {
        refreshAccessibility(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
        refresh()
    }

    @objc private func forgetPhones() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Forget all paired iPhones?"
        alert.informativeText = "Every phone will need the pairing code again."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Pairing.shared.forgetAll()
        server?.disconnectAll()
        refresh()
    }

    private func localIPv4() -> String? {
        Host.current().addresses.first { $0.contains(".") && !$0.hasPrefix("127.") && !$0.hasPrefix("169.254.") }
    }
}
