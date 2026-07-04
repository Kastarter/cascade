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
        // GovernanceKit is deliberately ProviderKit-free: it speaks PerceptionCore's
        // ActionDescriptor, never CUAction, so MacContextKit/AppShell can link it
        // without a dependency cycle.
        .target(name: "GovernanceKit", dependencies: ["CascadeMemory", "PerceptionCore"]),
        .target(name: "MacContextKit", dependencies: ["CascadeMemory", "GovernanceKit"]),
        .target(
            name: "ComputerUseKit",
            dependencies: ["CascadeMemory", "MacContextKit", "PerceptionCore"],
            resources: [.copy("Skills")]
        ),
        .target(name: "PerceptionCore"),
        .target(name: "ProviderKit", dependencies: ["CascadeMemory", "PerceptionCore"]),
        .target(name: "SandboxKit", dependencies: ["ProviderKit", "CascadeMemory", "AgentOrchestrator"]),
        .target(name: "WasteDetection", dependencies: ["CascadeMemory"]),
        .target(
            name: "AgentOrchestrator",
            dependencies: ["CascadeMemory", "ComputerUseKit", "PerceptionCore", "ProviderKit", "WasteDetection"]
        ),
        .target(name: "GroundingBench", dependencies: ["CascadeMemory", "ProviderKit"]),
        .target(
            name: "AppShell",
            dependencies: [
                "AgentOrchestrator",
                "CascadeDesignSystem",
                "CascadeMemory",
                "ComputerUseKit",
                "GovernanceKit",
                "MacContextKit",
                "PerceptionCore",
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
        .testTarget(name: "PerceptionCoreTests", dependencies: ["PerceptionCore"]),
        .testTarget(name: "CascadeMemoryTests", dependencies: ["CascadeMemory"]),
        .testTarget(
            name: "WasteDetectionTests",
            dependencies: ["CascadeMemory", "WasteDetection"]
        ),
        .testTarget(
            name: "AgentOrchestratorTests",
            dependencies: ["AgentOrchestrator", "AppShell", "CascadeMemory", "ComputerUseKit", "ProviderKit", "WasteDetection"]
        ),
        .testTarget(name: "ComputerUseKitTests", dependencies: ["ComputerUseKit", "CascadeMemory", "PerceptionCore"]),
        .testTarget(name: "GovernanceKitTests", dependencies: ["GovernanceKit", "CascadeMemory", "PerceptionCore"]),
        .testTarget(name: "MacContextKitTests", dependencies: ["MacContextKit", "CascadeMemory", "GovernanceKit"]),
        .testTarget(
            name: "ProviderKitTests",
            dependencies: ["ProviderKit", "CascadeMemory"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SandboxKitTests", dependencies: ["ProviderKit", "SandboxKit", "AgentOrchestrator"]),
        .testTarget(
            name: "AppShellTests",
            dependencies: ["AppShell", "AgentOrchestrator", "CascadeMemory", "ComputerUseKit", "GovernanceKit", "PerceptionCore", "ProviderKit", "WasteDetection", "SandboxKit", "MacContextKit"]
        ),
        .testTarget(
            name: "ReliabilityEvalTests",
            dependencies: ["AgentOrchestrator", "CascadeMemory"]
        ),
        .testTarget(
            name: "GroundingBenchTests",
            dependencies: ["GroundingBench", "ProviderKit"]
        )
    ]
)
