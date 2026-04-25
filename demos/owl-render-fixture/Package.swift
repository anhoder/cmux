// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OwlRenderFixture",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "OwlLayerHostVerifier",
            targets: ["OwlLayerHostVerifier"]
        ),
        .executable(
            name: "OwlMojoBindingsGenerator",
            targets: ["OwlMojoBindingsGenerator"]
        ),
        .executable(
            name: "OwlLayerHostSelfTest",
            targets: ["OwlLayerHostSelfTest"]
        )
    ],
    targets: [
        .target(
            name: "OwlMojoBindingsGeneratorCore",
            path: "Sources/OwlMojoBindingsGeneratorCore"
        ),
        .executableTarget(
            name: "OwlMojoBindingsGenerator",
            dependencies: ["OwlMojoBindingsGeneratorCore"],
            path: "Sources/OwlMojoBindingsGenerator"
        ),
        .executableTarget(
            name: "OwlLayerHostVerifier",
            path: "Sources/OwlLayerHostVerifier"
        ),
        .executableTarget(
            name: "OwlLayerHostSelfTest",
            path: "Sources/OwlLayerHostSelfTest"
        ),
        .testTarget(
            name: "OwlMojoBindingsGeneratorTests",
            dependencies: ["OwlMojoBindingsGeneratorCore"],
            path: "Tests/OwlMojoBindingsGeneratorTests"
        )
    ]
)
