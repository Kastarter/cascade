import CascadeMemory
import Foundation

public enum AgentSpeedLane: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case directAppLaunch = "direct_app_launch"
    case localHarness = "local_harness"
    case recordRecall = "record_recall"
    case backgroundWeb = "background_web"
    case accessibilitySnapshot = "accessibility_snapshot"
    case localOCR = "local_ocr"
    case visualComputerUse = "visual_computer_use"
}

public struct AgentSpeedCapabilities: Sendable, Equatable {
    public var harnessTier: HarnessTier
    public var recallEnabled: Bool
    public var backgroundWebAvailable: Bool
    public var accessibilityAvailable: Bool
    public var localOCRAvailable: Bool
    public var directAppLaunchAvailable: Bool

    public init(
        harnessTier: HarnessTier = .readOnly,
        recallEnabled: Bool = true,
        backgroundWebAvailable: Bool = true,
        accessibilityAvailable: Bool = true,
        localOCRAvailable: Bool = true,
        directAppLaunchAvailable: Bool = true
    ) {
        self.harnessTier = harnessTier
        self.recallEnabled = recallEnabled
        self.backgroundWebAvailable = backgroundWebAvailable
        self.accessibilityAvailable = accessibilityAvailable
        self.localOCRAvailable = localOCRAvailable
        self.directAppLaunchAvailable = directAppLaunchAvailable
    }
}

public struct AgentSpeedRouteOption: Sendable, Equatable, Codable {
    public let lane: AgentSpeedLane
    public let priority: Int
    public let estimatedLatencyMilliseconds: Int
    public let requiresModelVision: Bool
    public let requiresScreenCapture: Bool
    public let available: Bool
    public let reason: String

    public init(
        lane: AgentSpeedLane,
        priority: Int,
        estimatedLatencyMilliseconds: Int,
        requiresModelVision: Bool,
        requiresScreenCapture: Bool,
        available: Bool,
        reason: String
    ) {
        self.lane = lane
        self.priority = priority
        self.estimatedLatencyMilliseconds = max(0, estimatedLatencyMilliseconds)
        self.requiresModelVision = requiresModelVision
        self.requiresScreenCapture = requiresScreenCapture
        self.available = available
        self.reason = reason
    }
}

public struct AgentSpeedRoutePlan: Sendable, Equatable, Codable {
    public let sourcePlan: SourcePlan
    public let options: [AgentSpeedRouteOption]

    public init(sourcePlan: SourcePlan, options: [AgentSpeedRouteOption]) {
        self.sourcePlan = sourcePlan
        self.options = options.sorted { lhs, rhs in
            if lhs.available != rhs.available { return lhs.available && !rhs.available }
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if lhs.estimatedLatencyMilliseconds != rhs.estimatedLatencyMilliseconds {
                return lhs.estimatedLatencyMilliseconds < rhs.estimatedLatencyMilliseconds
            }
            return lhs.lane.rawValue < rhs.lane.rawValue
        }
    }

    public var primary: AgentSpeedRouteOption? {
        options.first(where: \.available)
    }

    public var fallbackVisual: AgentSpeedRouteOption? {
        options.first { $0.lane == .visualComputerUse }
    }

    public var avoidsVisualComputerUseFirst: Bool {
        primary?.lane != nil && primary?.lane != .visualComputerUse
    }

    public func auditDescriptor(goal: String) -> String {
        let lanes = options.map { option in
            [
                option.lane.rawValue,
                option.available ? "available" : "unavailable",
                "p\(option.priority)",
                "\(option.estimatedLatencyMilliseconds)ms",
                option.requiresModelVision ? "vision" : "no_vision",
                option.requiresScreenCapture ? "capture" : "no_capture",
            ].joined(separator: ":")
        }.joined(separator: ",")
        return [
            "goalHash=\(AuditIdentity.hash(goal))",
            "intent=\(sourcePlan.routingIntent.rawValue)",
            "sources=\(sourcePlan.candidateSources.map(\.rawValue).joined(separator: ","))",
            "primary=\(primary?.lane.rawValue ?? "none")",
            "lanes=\(lanes)",
        ].joined(separator: " ")
    }
}

public struct AgentSpeedRouter: Sendable {
    public init() {}

    public func route(
        goal: String,
        sourcePlan: SourcePlan,
        environment: SourceRouter.Environment = .onScreen,
        capabilities: AgentSpeedCapabilities = AgentSpeedCapabilities()
    ) -> AgentSpeedRoutePlan {
        var options: [AgentSpeedRouteOption] = []
        let normalizedGoal = Self.normalized(goal)
        let requiredSource = sourcePlan.requiredSource

        if sourcePlan.candidateSources.contains(.recordedMemory) || sourcePlan.routingIntent == .answerRecord {
            options.append(option(
                .recordRecall,
                priority: Self.priority(for: .recordedMemory, defaultPriority: 10, requiredSource: requiredSource),
                latency: 120,
                available: capabilities.recallEnabled,
                reason: "recorded_memory_source"
            ))
        }

        if sourcePlan.candidateSources.contains(.localFiles) || sourcePlan.routingIntent == .findFile {
            options.append(option(
                .localHarness,
                priority: Self.priority(for: .localFiles, defaultPriority: 12, requiredSource: requiredSource),
                latency: 140,
                available: capabilities.harnessTier != .off,
                reason: "local_file_source"
            ))
        }

        if sourcePlan.candidateSources.contains(.web) || sourcePlan.routingIntent == .webFact || environment == .webSandbox {
            options.append(option(
                .backgroundWeb,
                priority: Self.priority(for: .web, defaultPriority: 20, requiredSource: requiredSource),
                latency: 650,
                available: capabilities.backgroundWebAvailable,
                reason: "web_source"
            ))
        }

        if sourcePlan.routingIntent == .locateVisible || sourcePlan.candidateSources.contains(.onScreen) {
            options.append(option(
                .accessibilitySnapshot,
                priority: Self.priority(for: .onScreen, defaultPriority: 30, requiredSource: requiredSource),
                latency: 90,
                available: capabilities.accessibilityAvailable,
                reason: "visible_ui_semantics"
            ))
            options.append(option(
                .localOCR,
                priority: Self.priority(for: .onScreen, defaultPriority: 35, requiredSource: requiredSource),
                latency: 220,
                requiresScreenCapture: true,
                available: capabilities.localOCRAvailable,
                reason: "visible_text_local_ocr"
            ))
        }

        if sourcePlan.routingIntent == .action, Self.hasDirectOpenIntent(normalizedGoal) {
            options.append(option(
                .directAppLaunch,
                priority: 5,
                latency: 80,
                available: capabilities.directAppLaunchAvailable,
                reason: "open_app_or_url"
            ))
        }

        if sourcePlan.routingIntent == .action || sourcePlan.candidateSources.contains(.action) {
            options.append(option(
                .accessibilitySnapshot,
                priority: 32,
                latency: 110,
                available: capabilities.accessibilityAvailable,
                reason: "action_semantic_ui"
            ))
        }

        options.append(option(
            .visualComputerUse,
            priority: 90,
            latency: 1_900,
            requiresModelVision: true,
            requiresScreenCapture: true,
            available: true,
            reason: "universal_fallback"
        ))

        return AgentSpeedRoutePlan(sourcePlan: sourcePlan, options: Self.deduplicated(options))
    }

    public static func plan(
        goal: String,
        sourcePlan: SourcePlan,
        environment: SourceRouter.Environment = .onScreen,
        capabilities: AgentSpeedCapabilities = AgentSpeedCapabilities()
    ) -> AgentSpeedRoutePlan {
        AgentSpeedRouter().route(
            goal: goal,
            sourcePlan: sourcePlan,
            environment: environment,
            capabilities: capabilities
        )
    }

    private func option(
        _ lane: AgentSpeedLane,
        priority: Int,
        latency: Int,
        requiresModelVision: Bool = false,
        requiresScreenCapture: Bool = false,
        available: Bool,
        reason: String
    ) -> AgentSpeedRouteOption {
        AgentSpeedRouteOption(
            lane: lane,
            priority: priority,
            estimatedLatencyMilliseconds: latency,
            requiresModelVision: requiresModelVision,
            requiresScreenCapture: requiresScreenCapture,
            available: available,
            reason: reason
        )
    }

    private static func deduplicated(_ options: [AgentSpeedRouteOption]) -> [AgentSpeedRouteOption] {
        var bestByLane: [AgentSpeedLane: AgentSpeedRouteOption] = [:]
        for option in options {
            guard let current = bestByLane[option.lane] else {
                bestByLane[option.lane] = option
                continue
            }
            if option.available != current.available {
                if option.available { bestByLane[option.lane] = option }
            } else if option.priority < current.priority {
                bestByLane[option.lane] = option
            } else if option.priority == current.priority,
                      option.estimatedLatencyMilliseconds < current.estimatedLatencyMilliseconds {
                bestByLane[option.lane] = option
            }
        }
        return Array(bestByLane.values)
    }

    private static func priority(
        for source: SourceID,
        defaultPriority: Int,
        requiredSource: SourceID?
    ) -> Int {
        guard let requiredSource else { return defaultPriority }
        return source == requiredSource ? 1 : defaultPriority + 40
    }

    private static func normalized(_ goal: String) -> String {
        " " + goal.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) + " "
    }

    private static func hasDirectOpenIntent(_ normalizedGoal: String) -> Bool {
        [" open ", " launch ", " go to ", " visit "].contains { normalizedGoal.contains($0) }
    }
}
