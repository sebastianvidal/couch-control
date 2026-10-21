import SwiftUI
import UIKit
import Combine

/// Modifier keys toggled on in the key strip. While any is held, typed characters
/// are sent as real keycodes so shortcuts like ⌘C reach the Mac.
final class InputState: ObservableObject {
    @Published var heldModifiers = Set<Int>()
    @Published var keyboardShown = true
}

/// Invisible view that owns the iOS keyboard and forwards what is typed.
struct KeyInputView: UIViewRepresentable {
    let client: Client
    @ObservedObject var state: InputState

    func makeUIView(context: Context) -> KeyInputUIView {
        let view = KeyInputUIView()
        view.client = client
        view.state = state
        return view
    }

    func updateUIView(_ uiView: KeyInputUIView, context: Context) {
        DispatchQueue.main.async {
            if state.keyboardShown {
                if !uiView.isFirstResponder { uiView.becomeFirstResponder() }
            } else if uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }
}

final class KeyInputUIView: UIView, UIKeyInput {
    weak var client: Client?
    weak var state: InputState?

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, state?.keyboardShown != false else { return }
        DispatchQueue.main.async { self.becomeFirstResponder() }
    }

    func insertText(_ text: String) {
        if text == "\n" {
            tap(36)
            return
        }
        if let state, !state.heldModifiers.isEmpty {
            for ch in text {
                if let code = Keycodes.code(for: ch) { tap(code) }
            }
            return
        }
        client?.send("t \(text)")
    }

    func deleteBackward() {
        tap(51)
    }

    private func tap(_ code: Int) {
        client?.send("k \(code) 1")
        client?.send("k \(code) 0")
    }
}

enum Keycodes {
    private static let map: [Character: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]

    static func code(for ch: Character) -> Int? {
        map[Character(ch.lowercased())]
    }
}
