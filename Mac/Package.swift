// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CouchpadMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CouchpadMac",
            path: "Sources/CouchpadMac"
        )
    ]
)
