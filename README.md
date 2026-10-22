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

Everything is on your local network, so the question is who else is on it. Today the
pairing code is well protected against guessing (see above), but the connection itself is
plain TCP: on an untrusted network, someone sniffing traffic could capture a phone's token
and replay it, or impersonate a host by name. Encrypted, mutually authenticated sessions are
the next planned change. Until then, treat the host like any other service you wouldn't run
on café Wi‑Fi: quit it there, or "Forget Paired iPhones" afterwards.

## Protocol

Newline-terminated text lines over TCP. The phone must authenticate first:

```
hello <code-or-token>   → host answers  ok <token> mac|windows   or   nope (and hangs up)
```

Then, one command per line:

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
