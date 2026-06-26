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
        .library(name: "AgentOrchestrator", targets: ["AgentOrchestrator"])
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
        .target(name: "ProviderKit", dependencies: ["CascadeMemory"]),
        .target(name: "SandboxKit", dependencies: ["ProviderKit", "CascadeMemory"]),
        .target(name: "WasteDetection", dependencies: ["CascadeMemory"]),
        .target(
            name: "AgentOrchestrator",
            dependencies: ["CascadeMemory", "ComputerUseKit", "ProviderKit", "WasteDetection"]
        ),
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
        .testTarget(name: "CascadeMemoryTests", dependencies: ["CascadeMemory"]),
        .testTarget(
            name: "WasteDetectionTests",
            dependencies: ["CascadeMemory", "WasteDetection"]
        ),
        .testTarget(
            name: "AgentOrchestratorTests",
            dependencies: ["AgentOrchestrator", "CascadeMemory", "ComputerUseKit", "ProviderKit", "WasteDetection"]
        ),
        .testTarget(name: "ComputerUseKitTests", dependencies: ["ComputerUseKit"]),
        .testTarget(name: "MacContextKitTests", dependencies: ["MacContextKit"]),
        .testTarget(name: "ProviderKitTests", dependencies: ["ProviderKit", "CascadeMemory"]),
        .testTarget(name: "SandboxKitTests", dependencies: ["ProviderKit", "SandboxKit"]),
        .testTarget(
            name: "AppShellTests",
            dependencies: ["AppShell", "AgentOrchestrator", "CascadeMemory", "ProviderKit", "WasteDetection", "SandboxKit"]
        ),
        .testTarget(
            name: "ReliabilityEvalTests",
            dependencies: ["AgentOrchestrator"]
        )
    ]
)
