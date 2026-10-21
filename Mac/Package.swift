// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CouchControlMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CouchControlMac",
            path: "Sources/CouchControlMac"
        )
    ]
)
