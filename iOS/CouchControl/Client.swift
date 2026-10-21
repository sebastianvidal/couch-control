import Foundation
import Network
import Combine

let servicePort: UInt16 = 48123

/// Finds computers running Couch Control over Bonjour, keeps one TCP connection open, and
/// handles pairing: the host wants `hello <code-or-token>` first and answers
/// `ok <token> <platform>` or `nope`. Tokens are kept per host so the code is only needed once.
///
/// Session rules:
/// - Leaving the app closes the connection cleanly (the host then releases any held keys).
/// - Returning reconnects at once with the stored token; discovery is restarted too, since
///   Bonjour results go stale while the app is suspended.
/// - Transient failures retry with backoff and never touch the token. The pairing prompt only
///   appears when the host explicitly refuses the token or there is none.
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
    private var receiving = false
    private var receiveBuffer = Data()
    private var sentCredential: Credential?
    private var retryTask: Task<Void, Never>?
    private var failures = 0
    private var inBackground = false
    private var preferredName: String?
    private var manualHost: String?
    private let queue = DispatchQueue(label: "couchctl.client")
    private let defaults = UserDefaults.standard

    private enum Credential { case token, code }

    // MARK: Lifecycle

    func startBrowsing() {
        guard browser == nil else { return }
        preferredName = defaults.string(forKey: "preferredHost")
        restartBrowser()
    }

    func appDidEnterBackground() {
        inBackground = true
        retryTask?.cancel()
        // A clean close: the host sees the FIN right away instead of a dead socket later.
        if let connection {
            connection.cancel()
            self.connection = nil
        }
        phase = .disconnected
        status = "Paused"
    }

    func appDidBecomeActive() {
        guard inBackground else { return }
        inBackground = false
        failures = 0
        restartBrowser()
        if let manualHost {
            connect(host: manualHost)
        } else {
            autoConnect()
        }
    }

    private func restartBrowser() {
        browser?.cancel()
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

    // MARK: Connecting

    private func autoConnect() {
        guard connection == nil, !inBackground, manualHost == nil, !services.isEmpty else { return }
        // The host we used last, then any host we have paired with, then whatever is there.
        let service = services.first { $0.name == preferredName }
            ?? services.first { token(for: $0.name) != nil }
            ?? services[0]
        connect(to: service)
    }

    func connect(to service: Service) {
        manualHost = nil
        connect(endpoint: service.endpoint, name: service.name)
    }

    func connect(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        manualHost = trimmed
        connect(endpoint: .hostPort(host: NWEndpoint.Host(trimmed), port: NWEndpoint.Port(rawValue: servicePort)!), name: trimmed)
    }

    private func connect(endpoint: NWEndpoint, name: String) {
        retryTask?.cancel()
        connection?.cancel()
        receiving = false
        receiveBuffer = Data()
        sentCredential = nil
        macName = name
        phase = .connecting
        status = failures == 0 ? "Connecting to \(name)…" : "Reconnecting to \(name)…"

        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.connectionTimeout = 5
        let connection = NWConnection(to: endpoint, using: params)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.failures = 0
                    guard !self.receiving else { return } // the path recovered; the session is already set up
                    self.receiving = true
                    self.receive(on: connection)
                    if let token = self.token(for: name) {
                        self.sentCredential = .token
                        self.sendRaw("hello \(token)")
                    } else {
                        self.phase = .needsCode
                        self.status = "Enter the code shown on \(name)"
                    }
                case .waiting(let error):
                    // No route yet (Wi-Fi coming back, host restarting). Give it a moment, then retry fresh.
                    // Not paired while waiting: anything sent now would be queued and arrive before hello.
                    self.phase = .connecting
                    self.status = "Can't reach \(name): \(error.localizedDescription)"
                    self.scheduleRetry(after: 3)
                case .failed, .cancelled:
                    self.connection = nil
                    self.receiving = false
                    if !self.inBackground {
                        self.phase = .disconnected
                        self.status = "Disconnected from \(name)"
                        self.failures += 1
                        self.scheduleRetry(after: min(Double(self.failures), 5))
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        self.connection = connection
    }

    private func scheduleRetry(after seconds: Double) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.inBackground else { return }
            if let connection = self.connection, connection.state == .ready { return }
            self.connection?.cancel()
            self.connection = nil
            if let manualHost = self.manualHost {
                self.connect(host: manualHost)
            } else {
                self.autoConnect()
            }
        }
    }

    // MARK: Pairing

    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, connection != nil else { return }
        phase = .connecting
        status = "Pairing with \(macName)…"
        sentCredential = .code
        sendRaw("hello \(trimmed)")
    }

    func forgetMac() {
        defaults.removeObject(forKey: tokenKey(macName))
        if preferredName == macName {
            preferredName = nil
            defaults.removeObject(forKey: "preferredHost")
        }
        connection?.cancel()
    }

    private func handle(_ line: String) {
        if line.hasPrefix("ok ") {
            // "ok <token> [mac|windows]"; older Mac builds send no platform.
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return }
            defaults.set(String(parts[1]), forKey: tokenKey(macName))
            preferredName = macName
            defaults.set(macName, forKey: "preferredHost")
            hostPlatform = parts.count >= 3 && parts[2] == "windows" ? .windows : .mac
            phase = .paired
            status = "Connected to \(macName)"
        } else if line == "nope" {
            switch sentCredential {
            case .token:
                // The host forgot this phone; the token is genuinely dead.
                defaults.removeObject(forKey: tokenKey(macName))
                phase = .needsCode
                status = "\(macName) no longer recognizes this phone"
            case .code:
                phase = .wrongCode
                status = "Wrong code. Check the code on \(macName)"
            case nil:
                break
            }
            sentCredential = nil
        }
    }

    // MARK: I/O

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                if let data { self.receiveBuffer.append(data) }
                while let newline = self.receiveBuffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: self.receiveBuffer[self.receiveBuffer.startIndex..<newline], as: UTF8.self)
                    self.receiveBuffer.removeSubrange(self.receiveBuffer.startIndex...newline)
                    self.handle(line)
                }
                if isComplete || error != nil {
                    // The host closed the socket; treat it like a failure so we reconnect.
                    connection.cancel()
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    /// Input commands; dropped until pairing has succeeded.
    func send(_ line: String) {
        guard isConnected, let connection, connection.state == .ready else { return }
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func sendRaw(_ line: String) {
        connection?.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func tokenKey(_ name: String) -> String { "token.\(name)" }
    private func token(for name: String) -> String? { defaults.string(forKey: tokenKey(name)) }
}
