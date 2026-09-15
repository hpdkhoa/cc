// swift-tools-version:5.9
import PackageDescription

// Yams is vendored under Vendor/Yams so `swift build` works with no network access.
// The SwiftUI app target only exists on macOS; on Linux only the UI-free
// DecanterCore library (and its tests) are built, which is what CI / headless checks use.

var products: [Product] = [
    .library(name: "DecanterCore", targets: ["DecanterCore"]),
]
var targets: [Target] = [
    .target(
        name: "DecanterCore",
        dependencies: ["Yams"],
        path: "Sources/DecanterCore"
    ),
    .testTarget(
        name: "DecanterCoreTests",
        dependencies: ["DecanterCore"],
        path: "Tests/DecanterCoreTests"
    ),
]

#if os(macOS)
products.append(.executable(name: "Decanter", targets: ["Decanter"]))
targets.append(
    .executableTarget(
        name: "Decanter",
        dependencies: ["DecanterCore"],
        path: "Sources/Decanter"
    )
)
#endif

let package = Package(
    name: "Decanter",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [.package(path: "Vendor/Yams")],
    targets: targets
)
