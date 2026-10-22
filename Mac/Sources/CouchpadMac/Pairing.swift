import Foundation

/// Phones pair once with a 6-digit code and are handed a random token for every later
/// connection. The code is only live for one minute after the user opens the pairing
/// window, each connection gets a single guess, three wrong guesses rotate the code and lock
/// pairing for a few seconds. That keeps online guessing far below the one-in-a-million odds.
final class Pairing {
    static let shared = Pairing()

    static let window: TimeInterval = 60
    static let maxWrongGuesses = 3
    static let lockout: TimeInterval = 3

    enum Event { case codeChanged, expired, paired }
    /// Called on the pairing queue; hop to main before touching UI.
    var onEvent: ((Event) -> Void)?

    private let defaults = UserDefaults.standard
    private let tokensKey = "pairedTokens"
    private let lock = NSLock()

    private(set) var code = Pairing.makeCode()
    private var codeExpires = Date.distantPast
    private var wrongGuesses = 0
    private var lockedUntil = Date.distantPast
    private var expiryTimer: DispatchSourceTimer?

    var isCodeActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date() < codeExpires
    }

    var secondsRemaining: Int {
        lock.lock(); defer { lock.unlock() }
        return max(0, Int(codeExpires.timeIntervalSinceNow.rounded(.up)))
    }

    var pairedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tokens.count
    }

    private var tokens: Set<String> {
        get { Set(defaults.stringArray(forKey: tokensKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: tokensKey) }
    }

    /// The user opened the pairing window: fresh code, one-minute window.
    func beginPairing() {
        lock.lock()
        code = Pairing.makeCode()
        codeExpires = Date().addingTimeInterval(Pairing.window)
        wrongGuesses = 0
        scheduleExpiry()
        lock.unlock()
        onEvent?(.codeChanged)
    }

    /// The user closed the pairing window: the code stops working right away.
    func endPairing() {
        lock.lock()
        codeExpires = .distantPast
        expiryTimer?.cancel(); expiryTimer = nil
        lock.unlock()
    }

    /// The stored token (if any) for which `matches` is true. The caller checks a transcript
    /// proof against each candidate; the token itself never travels.
    func token(where matches: (String) -> Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        return tokens.first(where: matches)
    }

    /// A pairing attempt: `matches` checks the client's proof against the live code. Issues
    /// and stores a new token on success. Enforces the window, single guess, rotation, lockout.
    func pair(codeMatches matches: (String) -> Bool) -> String? {
        lock.lock()
        guard Date() < codeExpires, Date() >= lockedUntil else { lock.unlock(); return nil }
        if matches(code) {
            let token = UUID().uuidString
            tokens.insert(token)
            codeExpires = .distantPast   // one pairing per window
            expiryTimer?.cancel(); expiryTimer = nil
            lock.unlock()
            onEvent?(.paired)
            return token
        }
        wrongGuesses += 1
        var rotated = false
        if wrongGuesses >= Pairing.maxWrongGuesses {
            code = Pairing.makeCode()
            wrongGuesses = 0
            lockedUntil = Date().addingTimeInterval(Pairing.lockout)
            rotated = true
        }
        lock.unlock()
        if rotated { onEvent?(.codeChanged) }
        return nil
    }

    func forgetAll() {
        lock.lock()
        tokens = []
        lock.unlock()
    }

    private func scheduleExpiry() {
        expiryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + Pairing.window)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillActive = Date() < self.codeExpires
            self.lock.unlock()
            if !stillActive { self.onEvent?(.expired) }
        }
        timer.resume()
        expiryTimer = timer
    }

    private static func makeCode() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        NSLog("Pairing code: " + code)  // whole message as the format so the log doesn't redact it
        return code
    }
}
