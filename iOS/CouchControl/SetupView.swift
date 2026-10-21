import SwiftUI

enum Links {
    
    static let macDownload = URL(string: "https://github.com/sebastianvidal/couch-control/releases/latest")!
    static let privacy = URL(string: "https://github.com/sebastianvidal/couch-control/blob/main/PRIVACY.md")!
}

/// First-run walkthrough. Also what App Review sees before a Mac is paired, so it has to
/// explain the companion app clearly and be useful on its own.
struct SetupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your iPhone becomes a trackpad and keyboard for your Mac.")
                            .font(.headline)
                        Text("Made for the couch: the Mac is plugged into the TV, you're across the room, and you don't want a mouse and keyboard on your lap.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Set up in three steps") {
                    step(1, "Install the free Mac app",
                         "Download Couch Control for Mac and open it. It lives in the menu bar as a cursor icon.",
                         link: Links.macDownload, linkTitle: "Download for Mac")
                    step(2, "Allow Accessibility",
                         "macOS asks once. This is what lets the Mac app move the pointer and type for you.")
                    step(3, "Pair",
                         "Put both devices on the same Wi-Fi. This app finds the Mac by itself; enter the 6-digit code from the Mac's menu-bar icon the first time.")
                }

                Section("Gestures") {
                    row("hand.point.up.left", "One finger", "Move the pointer")
                    row("hand.tap", "Tap", "Click")
                    row("hand.tap", "Two-finger tap", "Right-click")
                    row("hand.draw", "Two fingers", "Scroll")
                    row("hand.point.up.left.and.text", "Tap, then touch and hold", "Drag")
                    row("keyboard", "Keyboard", "Types on the Mac. esc, tab, arrows and ⌘⌥⌃⇧ are in the strip above it")
                    row("gamecontroller", "Hold keys", "Expand the strip for WASD, space and F-keys that stay down while touched")
                }

                Section("Privacy") {
                    Text("Everything stays on your Wi-Fi. Nothing is sent to a server, there are no accounts, and the app collects no data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Couch Control")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String, link: URL? = nil, linkTitle: String = "") -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                if let link {
                    Link(linkTitle, destination: link).font(.subheadline)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ symbol: String, _ gesture: String, _ effect: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading) {
                Text(gesture).font(.subheadline.weight(.medium))
                Text(effect).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
