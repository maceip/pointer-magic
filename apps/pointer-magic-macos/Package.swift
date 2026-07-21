// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PointerMagic",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PointerMagicCore", targets: ["PointerCore"]),
        .library(name: "PointerSceneContracts", targets: ["PointerSceneContracts"]),
        .library(name: "PointerSceneMemory", targets: ["PointerSceneMemory"]),
        .library(name: "PointerMacSceneDiscovery", targets: ["PointerMacSceneDiscovery"]),
        .library(name: "PointerAgentContracts", targets: ["PointerAgentContracts"]),
        .library(name: "PointerAgentMemory", targets: ["PointerAgentMemory"]),
        .library(name: "PointerMacAgentDiscovery", targets: ["PointerMacAgentDiscovery"]),
        .library(name: "PointerAgentHost", targets: ["PointerAgentHost"]),
        .library(name: "PointerAgentShelf", targets: ["PointerAgentShelf"]),
        .library(name: "PointerShelfContracts", targets: ["PointerShelfContracts"]),
        .library(name: "PointerShelfRuntime", targets: ["PointerShelfRuntime"]),
        .library(name: "PointerMacAgentFocus", targets: ["PointerMacAgentFocus"]),
        .library(name: "PointerMagicKit", targets: ["PointerMagicKit"]),
        .library(name: "PointerMacPerception", targets: ["PointerMacPerception"]),
        .executable(name: "PointerMagic", targets: ["PointerApp"]),
        .executable(name: "PointerMagicAgentProbe", targets: ["PointerAgentProbe"]),
        .executable(name: "PointerMagicBench", targets: ["PointerBench"]),
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
        .target(name: "PointerAgentContracts"),
        .target(
            name: "PointerAgentMemory",
            dependencies: ["PointerAgentContracts"]
        ),
        .target(
            name: "PointerMacAgentDiscovery",
            dependencies: ["PointerC"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "PointerAgentHost",
            dependencies: [
                "PointerAgentContracts",
                "PointerAgentMemory",
                "PointerMacAgentDiscovery",
            ]
        ),
        .target(
            name: "PointerShelfContracts",
            dependencies: ["PointerCore"]
        ),
        .target(
            name: "PointerShelfRuntime",
            dependencies: ["PointerCore", "PointerShelfContracts"]
        ),
        .target(
            name: "PointerAgentShelf",
            dependencies: ["PointerCore", "PointerShelfContracts"]
        ),
        .target(
            name: "PointerMacAgentFocus",
            dependencies: ["PointerAgentContracts", "PointerC"]
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
            name: "PointerMagicKit",
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
                "PointerMagicKit",
                "PointerCore",
                "PointerAgentContracts",
                "PointerAgentHost",
                "PointerAgentShelf",
                "PointerShelfContracts",
                "PointerShelfRuntime",
                "PointerMacAgentFocus",
                "PointerMacPerception",
                "PointerMacSceneDiscovery",
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "PointerBench",
            dependencies: ["PointerCore", "PointerTransport"]
        ),
        .executableTarget(
            name: "PointerAgentProbe",
            dependencies: [
                "PointerAgentContracts",
                "PointerAgentHost",
                "PointerMacAgentDiscovery",
            ]
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
            name: "PointerAgentContractsTests",
            dependencies: ["PointerAgentContracts"]
        ),
        .testTarget(
            name: "PointerShelfContractsTests",
            dependencies: ["PointerShelfContracts", "PointerCore"]
        ),
        .testTarget(
            name: "PointerShelfRuntimeTests",
            dependencies: ["PointerShelfRuntime", "PointerShelfContracts", "PointerCore"]
        ),
        .testTarget(
            name: "PointerAgentMemoryTests",
            dependencies: ["PointerAgentContracts", "PointerAgentMemory"]
        ),
        .testTarget(
            name: "PointerAgentHostTests",
            dependencies: ["PointerAgentContracts", "PointerAgentHost"]
        ),
        .testTarget(
            name: "PointerMacAgentDiscoveryTests",
            dependencies: ["PointerMacAgentDiscovery"]
        ),
        .testTarget(
            name: "PointerAgentShelfTests",
            dependencies: [
                "PointerAgentShelf",
                "PointerCore",
                "PointerShelfContracts",
            ]
        ),
        .testTarget(
            name: "PointerMacAgentFocusTests",
            dependencies: ["PointerMacAgentFocus"]
        ),
        .testTarget(
            name: "PointerTransportTests",
            dependencies: ["PointerCore", "PointerTransport"]
        ),
        .testTarget(
            name: "PointerMacEventsTests",
            dependencies: ["PointerCore", "PointerMacEvents"]
        ),
        .testTarget(
            name: "PointerMacSemanticsTests",
            dependencies: ["PointerCore", "PointerMacSemantics"]
        ),
        .testTarget(
            name: "PointerMagicKitTests",
            dependencies: ["PointerMagicKit", "PointerCore", "PointerMacOverlay"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
