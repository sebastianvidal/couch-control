import Foundation
import Combine

final class AppSettings: ObservableObject {
    @Published var sensitivity: Double { didSet { save("sensitivity", sensitivity) } }
    @Published var scrollSpeed: Double { didSet { save("scrollSpeed", scrollSpeed) } }
    @Published var naturalScroll: Bool { didSet { save("naturalScroll", naturalScroll) } }
    @Published var tapToDrag: Bool { didSet { save("tapToDrag", tapToDrag) } }
    @Published var threeFingerSwipes: Bool { didSet { save("threeFingerSwipes", threeFingerSwipes) } }
    @Published var manualHost: String { didSet { save("manualHost", manualHost) } }

    init() {
        let d = UserDefaults.standard
        sensitivity = d.object(forKey: "sensitivity") as? Double ?? 2.5
        scrollSpeed = d.object(forKey: "scrollSpeed") as? Double ?? 1.5
        naturalScroll = d.object(forKey: "naturalScroll") as? Bool ?? true
        tapToDrag = d.object(forKey: "tapToDrag") as? Bool ?? true
        threeFingerSwipes = d.object(forKey: "threeFingerSwipes") as? Bool ?? true
        manualHost = d.string(forKey: "manualHost") ?? ""
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
