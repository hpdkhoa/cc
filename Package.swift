// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Decanter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Decanter", targets: ["Decanter"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")],
    targets: [
        .executableTarget(name: "Decanter", dependencies: ["Yams"], path: "Sources/Decanter")
    ]
)
