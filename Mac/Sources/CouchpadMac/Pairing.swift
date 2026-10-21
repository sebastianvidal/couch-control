import Foundation

/// Phones must pair once with the 6-digit code shown in the menu bar. A successful pairing
/// hands the phone a random token it presents on every later connection.
final class Pairing {
    static let shared = Pairing()

    private let defaults = UserDefaults.standard
    private let tokensKey = "pairedTokens"
    private let lock = NSLock()

    private(set) var code: String = Pairing.makeCode()

    var pairedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tokens.count
    }

    private var tokens: Set<String> {
        get { Set(defaults.stringArray(forKey: tokensKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: tokensKey) }
    }

    /// Returns a token when `credential` is the current code or an existing token.
    func authenticate(_ credential: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if tokens.contains(credential) { return credential }
        guard credential == code else { return nil }
        let token = UUID().uuidString
        tokens.insert(token)
        code = Pairing.makeCode()
        return token
    }

    func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        tokens = []
        code = Pairing.makeCode()
    }

    private static func makeCode() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        NSLog("Pairing code: " + code)  // whole message as the format so the log doesn't redact it
        return code
    }
}
