import Foundation
import Network
import Combine

let servicePort: UInt16 = 48123

/// Finds Macs running Couch Control over Bonjour, keeps one TCP connection open, and
/// handles pairing: the Mac wants `hello <code-or-token>` first and answers `ok <token>`
/// or `nope`. Tokens are kept per Mac so the code is only needed once.
@MainActor
final class Client: ObservableObject {
    struct Service: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    enum Phase: Equatable {
        case searching, connecting, needsCode, wrongCode, paired, disconnected
    }

    enum HostPlatform { case mac, windows }

    @Published private(set) var services: [Service] = []
    @Published private(set) var status = "Looking for your computer…"
    @Published private(set) var phase: Phase = .searching
    @Published private(set) var macName = ""
    @Published private(set) var hostPlatform: HostPlatform = .mac

    /// "Mac" or "PC", for UI text about the paired computer.
    var hostNoun: String { hostPlatform == .windows ? "PC" : "Mac" }

    var isConnected: Bool { phase == .paired }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "couchctl.client")
    private let defaults = UserDefaults.standard

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_couchctl._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { result -> Service? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Service(id: name, name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in
                self?.services = list
                self?.autoConnect()
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func autoConnect() {
        guard connection == nil, !services.isEmpty else { return }
        // Prefer a Mac we have paired with before.
        let service = services.first { token(for: $0.name) != nil } ?? services[0]
        connect(to: service)
    }

    func connect(to service: Service) {
        connect(endpoint: service.endpoint, name: service.name)
    }

    func connect(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        connect(endpoint: .hostPort(host: NWEndpoint.Host(trimmed), port: NWEndpoint.Port(rawValue: servicePort)!), name: trimmed)
    }

    private func connect(endpoint: NWEndpoint, name: String) {
        connection?.cancel()
        macName = name
        phase = .connecting
        status = "Connecting to \(name)…"
        receiveBuffer = Data()

        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        let connection = NWConnection(to: endpoint, using: params)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.receive(on: connection)
                    if let token = self.token(for: name) {
                        self.sendRaw("hello \(token)")
                    } else {
                        self.phase = .needsCode
                        self.status = "Enter the code shown on \(name)"
                    }
                case .waiting(let error):
                    self.status = "Can't reach \(name): \(error.localizedDescription)"
                case .failed, .cancelled:
                    self.phase = .disconnected
                    self.status = "Disconnected from \(name)"
                    self.connection = nil
                    // Retry a little later; the Mac may just be restarting.
                    try? await Task.sleep(for: .seconds(2))
                    self.autoConnect()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        self.connection = connection
    }

    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, connection != nil else { return }
        phase = .connecting
        status = "Pairing with \(macName)…"
        sendRaw("hello \(trimmed)")
    }

    func forgetMac() {
        defaults.removeObject(forKey: tokenKey(macName))
        connection?.cancel()
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                if let data { self.receiveBuffer.append(data) }
                while let newline = self.receiveBuffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: self.receiveBuffer[self.receiveBuffer.startIndex..<newline], as: UTF8.self)
                    self.receiveBuffer.removeSubrange(self.receiveBuffer.startIndex...newline)
                    self.handle(line)
                }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("ok ") {
            // "ok <token> [mac|windows]"; older Mac builds send no platform.
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return }
            defaults.set(String(parts[1]), forKey: tokenKey(macName))
            hostPlatform = parts.count >= 3 && parts[2] == "windows" ? .windows : .mac
            phase = .paired
            status = "Connected to \(macName)"
        } else if line == "nope" {
            defaults.removeObject(forKey: tokenKey(macName))
            phase = .wrongCode
            status = "Wrong code. Check the menu bar on \(macName)"
        }
    }

    /// Input commands; dropped until pairing has succeeded.
    func send(_ line: String) {
        guard isConnected else { return }
        sendRaw(line)
    }

    private func sendRaw(_ line: String) {
        connection?.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func tokenKey(_ name: String) -> String { "token.\(name)" }
    private func token(for name: String) -> String? { defaults.string(forKey: tokenKey(name)) }
}
