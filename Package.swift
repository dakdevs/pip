// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pip",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Pip", targets: ["Pip"])],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7")],
    targets: [
        .executableTarget(name: "Pip", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], resources: [.process("Resources")]),
        .testTarget(name: "PipTests", dependencies: ["Pip"])
    ],
    swiftLanguageModes: [.v5]
)
