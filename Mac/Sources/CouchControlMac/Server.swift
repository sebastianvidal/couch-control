import Foundation
import Network

/// TCP listener advertised over Bonjour. The first line from a phone must be
/// `hello <code-or-token>`; the Mac answers `ok <token> mac` or `nope`. After that each line
/// is one input command (see Injector.handle).
final class Server {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "couchctl.server")
    private let onChange: () -> Void
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var authenticated: Set<ObjectIdentifier> = []

    private(set) var status = "Starting…"

    init(port: UInt16, onChange: @escaping () -> Void) throws {
        self.onChange = onChange
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: "_couchctl._tcp")
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.report()
            case .failed(let error): self?.set(status: "Server failed: \(error.localizedDescription)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    /// Drops every phone; they will have to pair again.
    func disconnectAll() {
        queue.async {
            for connection in self.connections.values { self.drop(connection) }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        buffers[id] = Data()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(connection)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let id = ObjectIdentifier(connection)
            if let data, !data.isEmpty {
                var buffer = self.buffers[id] ?? Data()
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    self.handle(line, from: connection)
                }
                self.buffers[id] = buffer
            }
            if isComplete || error != nil {
                self.drop(connection)
            } else {
                self.receive(connection)
            }
        }
    }

    private func handle(_ line: String, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        if authenticated.contains(id) {
            Injector.shared.handle(line)
            return
        }
        // Input that arrives before the handshake (queued on the phone while its socket was
        // reconnecting) is dropped, not refused: "nope" is only for a bad hello, because the
        // phone treats it as "this host forgot me" and throws its token away.
        guard line.hasPrefix("hello ") else { return }
        let credential = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        if let token = Pairing.shared.authenticate(credential) {
            authenticated.insert(id)
            send("ok \(token) mac", to: connection)
            report()
        } else {
            send("nope", to: connection)
        }
    }

    private func send(_ line: String, to connection: NWConnection) {
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func drop(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard connections.removeValue(forKey: id) != nil else { return }
        buffers.removeValue(forKey: id)
        let wasAuthenticated = authenticated.remove(id) != nil
        connection.cancel()
        // Never leave a key or mouse button stuck down when the phone goes away.
        if wasAuthenticated { Injector.shared.releaseAll() }
        report()
    }

    private func report() {
        let n = authenticated.count
        set(status: n == 0 ? "Waiting for iPhone…" : (n == 1 ? "1 iPhone connected" : "\(n) iPhones connected"))
    }

    private func set(status: String) {
        self.status = status
        onChange()
    }
}
