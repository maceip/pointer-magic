// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MagicPointer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MagicPointerCore", targets: ["PointerCore"]),
        .library(name: "PointerSceneContracts", targets: ["PointerSceneContracts"]),
        .library(name: "PointerSceneMemory", targets: ["PointerSceneMemory"]),
        .library(name: "PointerMacSceneDiscovery", targets: ["PointerMacSceneDiscovery"]),
        .library(name: "MagicPointerKit", targets: ["MagicPointerKit"]),
        .library(name: "PointerMacPerception", targets: ["PointerMacPerception"]),
        .executable(name: "MagicPointer", targets: ["PointerApp"]),
        .executable(name: "MagicPointerBench", targets: ["PointerBench"]),
    ],
    targets: [
        .target(
            name: "PointerC",
            publicHeadersPath: "include",
            cSettings: [
                .define("_DARWIN_C_SOURCE"),
            ]
        ),
        .target(name: "PointerCore"),
        .target(name: "PointerSceneContracts"),
        .target(
            name: "PointerSceneMemory",
            dependencies: ["PointerSceneContracts"]
        ),
        .target(
            name: "PointerMacSceneDiscovery",
            dependencies: ["PointerSceneContracts", "PointerSceneMemory"]
        ),
        .target(
            name: "PointerTransport",
            dependencies: ["PointerC", "PointerCore"]
        ),
        .target(
            name: "PointerMacEvents",
            dependencies: ["PointerCore", "PointerTransport"]
        ),
        .target(
            name: "PointerMacSemantics",
            dependencies: ["PointerCore"]
        ),
        .target(
            name: "PointerMacPerception",
            dependencies: ["PointerCore"]
        ),
        .target(
            name: "PointerMacOverlay",
            dependencies: ["PointerCore", "PointerTransport"]
        ),
        .target(
            name: "MagicPointerKit",
            dependencies: [
                "PointerCore",
                "PointerTransport",
                "PointerMacEvents",
                "PointerMacSemantics",
                "PointerMacOverlay",
            ]
        ),
        .executableTarget(
            name: "PointerApp",
            dependencies: [
                "MagicPointerKit",
                "PointerCore",
                "PointerMacPerception",
                "PointerMacSceneDiscovery",
            ]
        ),
        .executableTarget(
            name: "PointerBench",
            dependencies: ["PointerCore", "PointerTransport"]
        ),
        .testTarget(
            name: "PointerCoreTests",
            dependencies: ["PointerCore"]
        ),
        .testTarget(
            name: "PointerSceneContractsTests",
            dependencies: ["PointerSceneContracts"]
        ),
        .testTarget(
            name: "PointerSceneMemoryTests",
            dependencies: ["PointerSceneContracts", "PointerSceneMemory"]
        ),
        .testTarget(
            name: "PointerMacSceneDiscoveryTests",
            dependencies: [
                "PointerMacSceneDiscovery",
                "PointerSceneContracts",
                "PointerSceneMemory",
            ]
        ),
        .testTarget(
            name: "PointerTransportTests",
            dependencies: ["PointerCore", "PointerTransport"]
        ),
        .testTarget(
            name: "PointerMacSemanticsTests",
            dependencies: ["PointerCore", "PointerMacSemantics"]
        ),
        .testTarget(
            name: "MagicPointerKitTests",
            dependencies: ["MagicPointerKit", "PointerCore", "PointerMacOverlay"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
