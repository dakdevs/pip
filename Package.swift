// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pip",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Pip", targets: ["Pip"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(name: "Pip", dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), .product(name: "Sparkle", package: "Sparkle")], resources: [.process("Resources")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "PipTests", dependencies: ["Pip"])
    ],
    swiftLanguageModes: [.v5]
)
