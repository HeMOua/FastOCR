// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FastOCR", platforms: [.macOS(.v14)], products: [
    .executable(name: "FastOCR", targets: ["FastOCR"])
], targets: [
    .target(name: "OCRCore"),
    .executableTarget(name: "FastOCR", dependencies: ["OCRCore"]),
    .testTarget(name: "OCRCoreTests", dependencies: ["OCRCore"])
])
