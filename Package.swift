// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CascadeNative",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Cascade", targets: ["CascadeApp"]),
        .library(name: "CascadeMemory", targets: ["CascadeMemory"]),
        .library(name: "MacContextKit", targets: ["MacContextKit"]),
        .library(name: "ComputerUseKit", targets: ["ComputerUseKit"]),
        .library(name: "AgentOrchestrator", targets: ["AgentOrchestrator"]),
        .library(name: "GroundingBench", targets: ["GroundingBench"]),
        .executable(name: "grounding-bench", targets: ["GroundingBenchCLI"])
    ],
    targets: [
        .target(name: "CascadeDesignSystem"),
        .target(name: "CascadeMemory"),
        .target(name: "MacContextKit", dependencies: ["CascadeMemory"]),
        .target(
            name: "ComputerUseKit",
            dependencies: ["CascadeMemory", "MacContextKit"],
            resources: [.copy("Skills")]
        ),
        .target(name: "ProviderKit", dependencies: ["CascadeMemory", "ComputerUseKit"]),
        .target(name: "SandboxKit", dependencies: ["ProviderKit", "CascadeMemory", "AgentOrchestrator"]),
        .target(name: "WasteDetection", dependencies: ["CascadeMemory"]),
        .target(
            name: "AgentOrchestrator",
            dependencies: ["CascadeMemory", "ComputerUseKit", "ProviderKit", "WasteDetection"]
        ),
        .target(name: "GroundingBench", dependencies: ["CascadeMemory", "ComputerUseKit", "MacContextKit", "ProviderKit"]),
        .target(
            name: "AppShell",
            dependencies: [
                "AgentOrchestrator",
                "CascadeDesignSystem",
                "CascadeMemory",
                "ComputerUseKit",
                "MacContextKit",
                "ProviderKit",
                "SandboxKit",
                "WasteDetection"
            ]
        ),
        .executableTarget(
            name: "CascadeApp",
            dependencies: ["AppShell"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "GroundingBenchCLI",
            dependencies: ["GroundingBench", "ProviderKit"]
        ),
        .testTarget(name: "CascadeMemoryTests", dependencies: ["CascadeMemory"]),
        .testTarget(
            name: "WasteDetectionTests",
            dependencies: ["CascadeMemory", "WasteDetection"]
        ),
        .testTarget(
            name: "AgentOrchestratorTests",
            dependencies: ["AgentOrchestrator", "CascadeMemory", "ComputerUseKit", "ProviderKit", "WasteDetection"]
        ),
        .testTarget(name: "ComputerUseKitTests", dependencies: ["ComputerUseKit", "CascadeMemory"]),
        .testTarget(name: "MacContextKitTests", dependencies: ["MacContextKit", "CascadeMemory"]),
        .testTarget(
            name: "ProviderKitTests",
            dependencies: ["ProviderKit", "CascadeMemory"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SandboxKitTests", dependencies: ["ProviderKit", "SandboxKit", "AgentOrchestrator"]),
        .testTarget(
            name: "AppShellTests",
            dependencies: ["AppShell", "AgentOrchestrator", "CascadeMemory", "ComputerUseKit", "ProviderKit", "WasteDetection", "SandboxKit", "MacContextKit"]
        ),
        .testTarget(
            name: "ReliabilityEvalTests",
            dependencies: ["AgentOrchestrator", "CascadeMemory"]
        ),
        .testTarget(
            name: "GroundingBenchTests",
            dependencies: ["GroundingBench", "ComputerUseKit", "ProviderKit"]
        )
    ]
)
