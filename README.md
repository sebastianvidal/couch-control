# Couchpad

Your iPhone as a trackpad and keyboard for your Mac or Windows PC, over local Wi-Fi. Made
for gaming on a computer plugged into the TV without a mouse and keyboard on the couch.

No accounts, no cloud: the phone finds the computer with Bonjour, pairs once with a 6-digit
code, and talks to it over one TCP socket on your network.

**Status (October 2026):** the iPhone app is in **TestFlight beta** ahead of a free App Store
release; the Mac companion **1.0 is released** (signed and notarized, under
[Releases](https://github.com/sebastianvidal/couchpad/releases/latest)); the Windows companion compiles
but has not yet been run on a real Windows machine. Site: https://sebastianvidal.github.io/couchpad/

```
Mac/       SwiftPM menu-bar app. Advertises _couchpad._tcp on port 48123, injects CGEvents.
Windows/   .NET 8 tray app. Same protocol and port, injects via SendInput.
iOS/       Xcode project. Trackpad on top, the iOS keyboard below, plus the keys it lacks.
Tools/     make-icons.swift renders the app icons.
```

## Mac app

Download the notarized build from [Releases](https://github.com/sebastianvidal/couchpad/releases/latest),
or build it yourself:

```bash
Mac/build.sh
open "Mac/build/Couchpad.app"
```

A cursor icon appears in the menu bar. The first launch asks for **Accessibility** access
(System Settings → Privacy & Security → Accessibility); that permission is what lets it move
the pointer and type. Local builds are ad-hoc signed, so macOS may ask again after a rebuild.

Menu: connection status · pairing code · address · Accessibility state · Launch at Login ·
Forget Paired iPhones.

## Build the Windows app

Needs the [.NET 8 SDK](https://dotnet.microsoft.com/download). On Windows:

```bash
dotnet publish Windows -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
```

Run `Windows/bin/Release/net8.0-windows/win-x64/publish/Couchpad.exe`. It lives in the
system tray; right-click for the pairing code, address and "Start with Windows". The first
run asks to allow it through Windows Firewall — allow it on **private** networks, or the phone
can't reach it. No other permission is needed: `SendInput` works for any app, including games
that read raw input (DirectInput / XInput games see the scan codes it sends).

The project also compiles on macOS/Linux (`dotnet build Windows`) for checking changes, but
only runs on Windows.

**Honest note:** the Windows app was written and compile-checked on a Mac, not yet run on a
real Windows machine. If something misbehaves, open an issue.

## Build the iPhone app

1. `cp iOS/Config/Local.xcconfig.example iOS/Config/Local.xcconfig` and put your Team ID in it.
2. Open `iOS/Couchpad.xcodeproj`, pick your iPhone, Run.
3. Allow **Local Network** when asked, otherwise the app can't find the Mac.

Both devices need to be on the same Wi-Fi. If Bonjour is blocked on your network, type the
Mac's IP (shown in the menu-bar menu) into Settings → Connection on the phone.

## Pairing

The first time a phone connects, it asks for a 6-digit code. Click "Pair an iPhone…" in the
host's menu-bar or tray icon to get a window with a **QR code** and the digits: scan it with
the Scan button in the app (or with the iPhone's Camera app, which opens Couchpad), or type
the digits. The host then gives the phone a token it keeps, so the code is never needed again
for that phone. Only phones with a token can send input.

The code is only live while that window is open, for at most one minute, and for one pairing.
Each connection gets a single guess; three wrong guesses rotate the code and pause pairing for
a few seconds. Pairing is the only way in: without a token, the host ignores everything.

The QR carries the host's address (`couchpad://pair?name=…&addr=…&port=…&code=…`), so a QR
pairing also works on networks that block Bonjour; the phone remembers the address and falls
back to it when discovery finds nothing.

## Gestures

| Phone                      | Mac                                      |
| -------------------------- | ---------------------------------------- |
| One finger                 | Move pointer                             |
| Tap                        | Left click                               |
| Two-finger tap             | Right click                              |
| Two fingers                | Scroll                                   |
| Tap, then touch and hold   | Drag (release to drop)                   |
| Three-finger swipe         | Up: Mission Control · Down: App Exposé · Left/right: switch Spaces (Windows: Task View / desktop / virtual desktops) |
| Left / Right buttons       | Hold the mouse button                    |
| iOS keyboard               | Typing, backspace, return as real key presses |
| esc, tab, arrows, F-keys, WASD strip | Key down while touched, up on release |
| ⇧ ⌃ ⌥ ⌘ fn                 | Toggle: held until tapped again; typed letters become shortcuts (⌘C etc.) |
| On a Windows host          | The same keys show as Ctrl / Alt / Win; fn is hidden |
| Keyboard button            | Hide / show the iOS keyboard to enlarge the trackpad |

Pointer speed, scroll speed, natural scrolling and tap-to-drag are in the gear menu.

## Security

Everything stays on your local network; the design assumes other people may be on it too.

- **Encrypted sessions.** Every connection starts with an ephemeral P-256 key exchange; the
  session key comes from HKDF and every line after that is AES-256-GCM. An eavesdropper sees
  two public keys and a nonce, then ciphertext.
- **Nothing secret is ever sent.** The phone proves it holds its token (or the pairing code)
  with an HMAC over the handshake transcript, and the host proves it holds the same token
  back. Captured traffic can't be replayed (fresh keys each time) and an impostor advertising
  your computer's name can neither learn the token nor relay, because the transcript binds
  both sides' keys.
- **Pairing codes are hard to guess.** Live only while the pairing window is open (at most a
  minute, one pairing), one guess per connection, three misses rotate the code and pause
  pairing. Because a new token travels inside the encrypted channel, recording a pairing and
  cracking the 6-digit code afterwards yields nothing; only an attacker active during that
  minute who already knows the code could interpose.
- **What's left:** a paired phone or host that is itself compromised. "Forget Paired
  iPhones" on the host and "Forget this computer" on the phone revoke access.

## Protocol

Protocol v2 (see `Shared/SecureChannel.swift` and `Windows/SecureChannel.cs`):

```
phone → host   v2 <P-256 public key, base64>                      (plain text line)
host  → phone  v2 <P-256 public key, base64> <16-byte nonce, base64>
                → both derive sessionKey = HKDF-SHA256(ECDH, salt: nonce, info: "couchpad v2 session")
                → every message from here is a frame: 4-byte length ‖ AES-256-GCM(line)
phone → host   auth token|code <HMAC-SHA256(secret, transcript ‖ "client")>
host  → phone  ok <token> mac|windows <HMAC-SHA256(token, transcript ‖ "host")>   or   nope (then hangs up)
```

Inside the channel, one command per line:

```
m dx dy      move (dx/dy also sent as raw mouse deltas, which is what games read)
s dx dy      scroll in pixels
b l|r 1|0    mouse button down / up
c l|r        click
k code 1|0   key down / up, macOS virtual keycode
g up|down|left|right   three-finger swipe; the host maps it to its own shortcut
t text       type text (each character is pressed as its key; shift added as needed)
r            release everything
```

The Mac releases every held key and button when a phone disconnects.

## Releasing

- **iPhone → App Store.** Needs the Apple Developer Program. The project already carries the
  Local Network and Bonjour usage strings, `ITSAppUsesNonExemptEncryption = NO`, an icon and a
  first-run setup screen. The in-app links point at the project site
  (https://sebastianvidal.github.io/couchpad/, served from `docs/`) and its privacy
  policy page, which is also the privacy policy URL for the App Store listing.
  In App Review notes, explain that the Mac app is a free direct download (the Mac App Store
  sandbox forbids input injection), link to it, and mention App Store Review Guideline 4.2.7
  and existing apps in this category (Remote Mouse, Mobile Mouse).
- **Mac → direct download.** The Mac App Store sandbox blocks the event injection this app
  needs, so it ships as a notarized DMG attached to a GitHub Release:
  `SIGN_IDENTITY="Developer ID Application: …" Mac/release.sh` (see the script for the
  one-time `notarytool` credential setup), then `gh release create v1.0 Mac/build/Couchpad-1.0.dmg`.
- **Windows → direct download.** Zip the `publish` folder from the command above and attach
  it to the same release. Unsigned builds trigger SmartScreen's "unknown publisher" warning;
  an Authenticode certificate removes it but isn't required.

## License

MIT. See `LICENSE`.
