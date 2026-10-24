// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LightReader",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LightReader", targets: ["LightReader"])],
    targets: [
        .target(name: "LightReaderKit"),
        .executableTarget(name: "LightReader", dependencies: ["LightReaderKit"]),
        .executableTarget(name: "LightReaderChecks", dependencies: ["LightReaderKit"], path: "Tests/LightReaderKitTests")
    ]
)
