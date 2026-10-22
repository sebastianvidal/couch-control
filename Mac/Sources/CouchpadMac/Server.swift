import CryptoKit
import Foundation
import Network

/// TCP listener advertised over Bonjour, speaking protocol v2 (see SecureChannel.swift): a
/// plain-text key exchange, then every line encrypted. A phone must authenticate inside the
/// channel with a proof over the transcript before any input is accepted.
final class Server {
    private final class Session {
        let connection: NWConnection
        var buffer = FrameBuffer()
        let privateKey = P256.KeyAgreement.PrivateKey()
        var transcript = Data()
        var send: FrameCipher?
        var recv: FrameCipher?
        var authenticated = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private enum ProtocolError: Error { case badHandshake, badFrame }

    private var listener: NWListener?
    private let port: UInt16
    private let queue = DispatchQueue(label: "couchpad.server")
    private let onChange: () -> Void
    private var sessions: [ObjectIdentifier: Session] = [:]

    private(set) var status = "Starting…"

    init(port: UInt16, onChange: @escaping () -> Void) throws {
        self.port = port
        self.onChange = onChange
    }

    /// Starts listening; if the port is busy or the network isn't up yet, keeps retrying.
    func start() {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            set(status: "Could not create listener")
            return
        }
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: "_couchpad._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.report()
            case .failed(let error):
                self.set(status: "Server failed: \(error.localizedDescription) — retrying…")
                listener.cancel()
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Drops every phone; they will have to pair again.
    func disconnectAll() {
        queue.async {
            for session in self.sessions.values { self.drop(session) }
        }
    }

    private func accept(_ connection: NWConnection) {
        let session = Session(connection)
        sessions[ObjectIdentifier(connection)] = session
        connection.stateUpdateHandler = { [weak self, weak session] state in
            switch state {
            case .failed, .cancelled: if let session { self?.drop(session) }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(session)
    }

    private func receive(_ session: Session) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak session] data, _, isComplete, error in
            guard let self, let session else { return }
            if let data, !data.isEmpty {
                do {
                    try self.handleBytes(data, session: session)
                } catch {
                    // Not a Couchpad peer, or tampering: hang up.
                    self.drop(session)
                    return
                }
            }
            if isComplete || error != nil {
                self.drop(session)
            } else {
                self.receive(session)
            }
        }
    }

    private func handleBytes(_ data: Data, session: Session) throws {
        session.buffer.append(data)

        if session.send == nil {
            // Plain-text handshake: exactly one line, "v2 <client public key>".
            guard let line = session.buffer.nextLine() else { return }
            let parts = line.split(separator: " ")
            guard parts.count == 2, parts[0] == "v2",
                  let clientKey = Data(base64Encoded: String(parts[1])), clientKey.count == 64 else {
                throw ProtocolError.badHandshake
            }
            var nonceBytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else {
                throw ProtocolError.badHandshake
            }
            let nonce = Data(nonceBytes)
            let hostKey = session.privateKey.publicKey.rawRepresentation
            let key = try SecureChannel.sessionKey(privateKey: session.privateKey, peerPublicKey: clientKey, nonce: nonce)
            session.transcript = SecureChannel.transcript(clientKey: clientKey, hostKey: hostKey, nonce: nonce)
            session.send = FrameCipher(key: key, direction: 1)
            session.recv = FrameCipher(key: key, direction: 0)
            let reply = "v2 \(hostKey.base64EncodedString()) \(nonce.base64EncodedString())\n"
            session.connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
        }

        guard let recv = session.recv else { return }
        while let body = try session.buffer.next() {
            let line = try recv.open(body)
            try handleLine(line, session: session)
        }
    }

    private func handleLine(_ line: String, session: Session) throws {
        if session.authenticated {
            Injector.shared.handle(line)
            return
        }
        // Anything before "auth" is dropped, never refused: a refusal makes the phone discard its token.
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "auth", let proof = Data(base64Encoded: String(parts[2])) else { return }
        let transcript = session.transcript
        let matches: (String) -> Bool = {
            SecureChannel.proofMatches(proof, secret: $0, transcript: transcript, side: SecureChannel.clientTag)
        }
        let token: String?
        switch parts[1] {
        case "token": token = Pairing.shared.token(where: matches)
        case "code": token = Pairing.shared.pair(codeMatches: matches)
        default: token = nil
        }
        if let token {
            session.authenticated = true
            let hostProof = SecureChannel.proof(secret: token, transcript: transcript, side: SecureChannel.hostTag)
            try send("ok \(token) mac \(hostProof.base64EncodedString())", to: session)
            report()
        } else {
            // One guess per connection: say no, then hang up.
            let frame = try session.send!.seal("nope")
            session.connection.send(content: frame, completion: .contentProcessed { [weak self, weak session] _ in
                if let session { self?.queue.async { self?.drop(session) } }
            })
        }
    }

    private func send(_ line: String, to session: Session) throws {
        guard let cipher = session.send else { throw ProtocolError.badFrame }
        let frame = try cipher.seal(line)
        session.connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func drop(_ session: Session) {
        guard sessions.removeValue(forKey: ObjectIdentifier(session.connection)) != nil else { return }
        session.connection.cancel()
        // Never leave a key or mouse button stuck down when the phone goes away.
        if session.authenticated { Injector.shared.releaseAll() }
        report()
    }

    private func report() {
        let n = sessions.values.filter { $0.authenticated }.count
        set(status: n == 0 ? "Waiting for iPhone…" : (n == 1 ? "1 iPhone connected" : "\(n) iPhones connected"))
    }

    private func set(status: String) {
        self.status = status
        onChange()
    }
}
