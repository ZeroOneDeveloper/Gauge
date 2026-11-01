// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gauge",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Gauge", targets: ["Gauge"])],
    targets: [
        .target(name: "GaugeCore"),
        .executableTarget(name: "Gauge", dependencies: ["GaugeCore"], resources: [.copy("Resources/ProviderIcons")]),
        .testTarget(name: "GaugeCoreTests", dependencies: ["GaugeCore"]),
        .testTarget(name: "GaugeTests", dependencies: ["Gauge", "GaugeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
