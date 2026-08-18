// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "XIVLauncherCNMac",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "XIVLauncherCNMac", targets: ["XIVLauncherCNMac"])
    ],
    targets: [
        .executableTarget(
            name: "XIVLauncherCNMac",
            path: "Sources/XIVLauncherCNMac"
        ),
        .testTarget(name: "XIVLauncherCNMacTests", dependencies: ["XIVLauncherCNMac"], path: "Tests/XIVLauncherCNMacTests")
    ],
    swiftLanguageModes: [.v5]
)
