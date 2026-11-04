// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pina",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Pina", path: "Sources/Pina")
    ]
)
