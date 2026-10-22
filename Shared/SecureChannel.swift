import CryptoKit
import Foundation

/// Couchpad wire protocol v2. Shared verbatim by the iPhone and Mac apps (symlinked into
/// both); Windows/SecureChannel.cs implements the same thing in .NET.
///
/// Handshake (plain text lines, base64 fields):
///   client → host   v2 <client P-256 public key>
///   host   → client v2 <host P-256 public key> <16-byte host nonce>
/// Both sides derive  shared = ECDH(P-256)
///                    transcript = clientKey ‖ hostKey ‖ nonce
///                    sessionKey = HKDF-SHA256(shared, salt: nonce, info: "couchpad v2 session")
/// From here every message is one frame: 4-byte big-endian length, then AES-256-GCM
/// ciphertext (12-byte nonce = direction byte ‖ 3 zero bytes ‖ 64-bit counter, 16-byte tag),
/// with the direction byte as additional authenticated data. The plaintext is a UTF-8 line
/// without the newline.
///
/// Authentication inside the channel (so secrets never travel, and a relay in the middle fails
/// because the transcript binds both sides' ephemeral keys):
///   client → host   auth token|code <base64 HMAC-SHA256(key: secret, transcript ‖ "client")>
///   host   → client ok <token> <platform> <base64 HMAC-SHA256(key: token, transcript ‖ "host")>
///                 or nope
/// A new token issued at pairing is only ever seen inside the encrypted channel.
enum SecureChannel {
    static let sessionInfo = Data("couchpad v2 session".utf8)
    static let clientTag = Data("client".utf8)
    static let hostTag = Data("host".utf8)
    /// Cap on a single frame, generous for any line we send.
    static let maxFrame = 64 * 1024

    static func sessionKey(privateKey: P256.KeyAgreement.PrivateKey, peerPublicKey: Data, nonce: Data) throws -> SymmetricKey {
        let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nonce, sharedInfo: sessionInfo, outputByteCount: 32)
    }

    static func transcript(clientKey: Data, hostKey: Data, nonce: Data) -> Data {
        clientKey + hostKey + nonce
    }

    /// HMAC proving knowledge of `secret` (a token or pairing code) over the transcript.
    static func proof(secret: String, transcript: Data, side: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: transcript + side, using: SymmetricKey(data: Data(secret.utf8)))
        return Data(mac)
    }

    static func proofMatches(_ proof: Data, secret: String, transcript: Data, side: Data) -> Bool {
        let expected = self.proof(secret: secret, transcript: transcript, side: side)
        // Constant-time comparison.
        guard expected.count == proof.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(expected, proof) { diff |= a ^ b }
        return diff == 0
    }
}

/// Encrypts and decrypts frames for one direction of one session.
final class FrameCipher {
    private let key: SymmetricKey
    private let direction: UInt8
    private var counter: UInt64 = 0

    /// `direction` is 0 for client→host, 1 for host→client. Each side makes one cipher for
    /// sending and one for receiving, with opposite directions.
    init(key: SymmetricKey, direction: UInt8) {
        self.key = key
        self.direction = direction
    }

    private func nonce(for counter: UInt64) -> AES.GCM.Nonce {
        var bytes = Data([direction, 0, 0, 0])
        var be = counter.bigEndian
        bytes.append(Data(bytes: &be, count: 8))
        return try! AES.GCM.Nonce(data: bytes)
    }

    /// Returns a full frame: 4-byte length prefix + sealed box (ciphertext ‖ tag).
    func seal(_ line: String) throws -> Data {
        let box = try AES.GCM.seal(Data(line.utf8), using: key, nonce: nonce(for: counter), authenticating: Data([direction]))
        counter += 1
        let body = box.ciphertext + box.tag
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Decrypts one frame body (without the length prefix). Throws on tampering or reordering.
    func open(_ body: Data) throws -> String {
        guard body.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let box = try AES.GCM.SealedBox(nonce: nonce(for: counter), ciphertext: body.prefix(body.count - 16), tag: body.suffix(16))
        let plain = try AES.GCM.open(box, using: key, authenticating: Data([direction]))
        counter += 1
        return String(decoding: plain, as: UTF8.self)
    }
}

/// Accumulates bytes and yields complete frame bodies.
struct FrameBuffer {
    private var data = Data()

    mutating func append(_ bytes: Data) { data.append(bytes) }

    /// Pops the next complete frame body, or nil if more bytes are needed. Throws if a frame
    /// claims to be absurdly large (not a Couchpad peer).
    mutating func next() throws -> Data? {
        guard data.count >= 4 else { return nil }
        let length = Int(data.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) })
        guard length <= SecureChannel.maxFrame else { throw CryptoKitError.incorrectParameterSize }
        guard data.count >= 4 + length else { return nil }
        let body = data.subdata(in: 4..<(4 + length))
        data.removeSubrange(0..<(4 + length))
        return body
    }

    /// For the plain-text handshake lines before the channel exists.
    mutating func nextLine() -> String? {
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        let line = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
        data.removeSubrange(data.startIndex...newline)
        return line
    }
}
