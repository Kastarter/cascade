import AgentOrchestrator
import CascadeMemory
import ComputerUseKit
import Foundation
import WasteDetection

public struct ProactiveHelpCandidate: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case savedAgent
        case appSkill
        case rewindQuestion
        case backgroundWebAgent
        case liveRepetition
        case nextAction
        case struggle
    }

    public let id: String
    public let kind: Kind
    public let offer: ProactiveOffer

    public init(kind: Kind, offer: ProactiveOffer) {
        self.kind = kind
        self.offer = offer
        self.id = "\(kind.rawValue):\(offer.signature)"
    }
}

public struct ProactiveHelpSelector: Sendable {
    public init() {}

    public func select(
        prediction: NextActionPredictor.Prediction?,
        liveRepetition: LiveRepetitionCandidate?,
        struggle: StruggleSignal?,
        recentEvents: [InputEvent],
        agents: [CascadeAgent],
        appSkills: AppSkillRegistry,
        preferenceModel: PreferenceModel,
        dismissedSignatures: Set<String> = [],
        browserWorkflowsAllowed: Bool = true,
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil
    ) -> ProactiveOffer? {
        candidates(
            prediction: prediction,
            liveRepetition: liveRepetition,
            struggle: struggle,
            recentEvents: recentEvents,
            agents: agents,
            appSkills: appSkills,
            preferenceModel: preferenceModel,
            dismissedSignatures: dismissedSignatures,
            browserWorkflowsAllowed: browserWorkflowsAllowed,
            webAppIdentity: webAppIdentity
        ).first?.offer
    }

    public func candidates(
        prediction: NextActionPredictor.Prediction?,
        liveRepetition: LiveRepetitionCandidate?,
        struggle: StruggleSignal?,
        recentEvents: [InputEvent],
        agents: [CascadeAgent],
        appSkills: AppSkillRegistry,
        preferenceModel: PreferenceModel,
        dismissedSignatures: Set<String> = [],
        browserWorkflowsAllowed: Bool = true,
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil
    ) -> [ProactiveHelpCandidate] {
        let ordered = recentEvents.sorted {
            if $0.capturedAt == $1.capturedAt { return $0.id < $1.id }
            return $0.capturedAt < $1.capturedAt
        }
        let active = ordered.last
        let activeApp = active?.appName
        let activeBundle = active?.bundleIdentifier
        let liveLabels = ordered.suffix(4).map(Self.normalizedLabel)
        let evidence = ordered.suffix(3).map(NextActionPredictor.humanLabel)
        var output: [ProactiveHelpCandidate] = []

        for agent in agents where agent.enabled {
            guard let prefixConfidence = Self.prefixConfidence(agent: agent, liveLabels: liveLabels) else { continue }
            let signature = "agent:\(agent.signature)"
            let score = score(
                predictedBenefit: min(1, Double(max(agent.estimatedSecondsPerRun, agent.estimatedSeconds)) / 90.0),
                confidence: max(prefixConfidence, prediction?.confidence ?? 0.6),
                userAcceptancePrior: preferenceModel.preference(agent.signature),
                surfaceRelevance: Self.surfaceRelevance(apps: agent.apps, activeApp: activeApp, activeSurface: active.flatMap { webAppIdentity?($0) }),
                interruptionCost: 0.08,
                recentDismissalPenalty: dismissedSignatures.contains(signature) ? 0.45 : 0,
                privacyRiskPenalty: 0
            )
            let offer = ProactiveOffer(
                source: .savedAgent,
                level: .action,
                title: agent.name,
                detail: "Matches the steps you just started.",
                actionTitle: "Run",
                signature: signature,
                confidence: max(prefixConfidence, prediction?.confidence ?? 0.6),
                score: score,
                evidence: evidence,
                prediction: prediction,
                relatedAgentID: agent.id,
                task: agent.goal
            )
            output.append(ProactiveHelpCandidate(kind: .savedAgent, offer: offer))
        }

        if let skill = appSkills.skill(appName: activeApp, bundleIdentifier: activeBundle) {
            let signature = "skill:\(skill.name.lowercased())"
            let confidence = skill.relevance(appName: activeApp, bundleIdentifier: activeBundle, actionLabels: liveLabels)
            let offer = ProactiveOffer(
                source: .appSkill,
                level: confidence >= 0.72 ? .action : .passive,
                title: skill.name,
                detail: skill.useWhen,
                actionTitle: "Show",
                signature: signature,
                confidence: confidence,
                score: score(
                    predictedBenefit: 0.58,
                    confidence: confidence,
                    userAcceptancePrior: preferenceModel.preference(signature),
                    surfaceRelevance: 1,
                    interruptionCost: 0.14,
                    recentDismissalPenalty: dismissedSignatures.contains(signature) ? 0.35 : 0,
                    privacyRiskPenalty: skill.explicitAskOnly ? 0.16 : 0
                ),
                evidence: evidence,
                prediction: prediction,
                skillName: skill.name
            )
            output.append(ProactiveHelpCandidate(kind: .appSkill, offer: offer))
        }

        if let liveRepetition {
            let signature = "repetition:\(liveRepetition.signature)"
            let confidence = liveRepetition.stage == .actionable ? 0.82 : 0.58
            let offer = ProactiveOffer(
                source: .liveRepetition,
                level: liveRepetition.stage == .actionable ? .action : .ambient,
                title: liveRepetition.stage == .actionable ? "This looks repeatable" : "Pattern noticed",
                detail: "\(liveRepetition.occurrences) matching runs in this session.",
                actionTitle: liveRepetition.stage == .actionable ? "Teach" : nil,
                signature: signature,
                confidence: confidence,
                score: score(
                    predictedBenefit: min(1, Double(liveRepetition.eventIDs.count) / 6),
                    confidence: confidence,
                    userAcceptancePrior: preferenceModel.preference(signature),
                    surfaceRelevance: 0.9,
                    interruptionCost: liveRepetition.stage == .actionable ? 0.10 : 0.02,
                    recentDismissalPenalty: dismissedSignatures.contains(signature) ? 0.35 : 0,
                    privacyRiskPenalty: 0
                ),
                evidence: liveRepetition.evidenceLabels,
                prediction: prediction,
                rangeStart: liveRepetition.startAt,
                rangeEnd: liveRepetition.endAt
            )
            output.append(ProactiveHelpCandidate(kind: .liveRepetition, offer: offer))
        }

        if let struggle {
            let signature = "struggle:\(struggle.kind.rawValue):\(activeApp?.lowercased() ?? "unknown")"
            let offer = ProactiveOffer(
                source: .struggle,
                level: struggle.confidence >= 0.75 ? .passive : .ambient,
                title: "Want Cascade to look?",
                detail: struggle.reason,
                actionTitle: "Look",
                signature: signature,
                confidence: struggle.confidence,
                score: score(
                    predictedBenefit: 0.74,
                    confidence: struggle.confidence,
                    userAcceptancePrior: preferenceModel.preference(signature),
                    surfaceRelevance: 0.85,
                    interruptionCost: 0.12,
                    recentDismissalPenalty: dismissedSignatures.contains(signature) ? 0.35 : 0,
                    privacyRiskPenalty: 0
                ),
                evidence: evidence
            )
            output.append(ProactiveHelpCandidate(kind: .struggle, offer: offer))

            let rewind = ProactiveOffer(
                source: .rewindQuestion,
                level: .passive,
                title: "Check the record",
                detail: "Cascade can search recent context around this issue.",
                actionTitle: "Ask",
                signature: "rewind:\(signature)",
                confidence: min(0.82, struggle.confidence),
                score: 0.43,
                evidence: evidence
            )
            output.append(ProactiveHelpCandidate(kind: .rewindQuestion, offer: rewind))
        }

        if browserWorkflowsAllowed,
           let active,
           Self.isBrowserWorkflow(active, webAppIdentity: webAppIdentity) {
            let signature = "background-web:\(Self.normalized(active.windowTitle ?? active.appName))"
            let confidence = max(0.55, prediction?.confidence ?? 0.55)
            let offer = ProactiveOffer(
                source: .backgroundWebAgent,
                level: .passive,
                title: "Run this web flow in the background",
                detail: "Keep your screen free while Cascade works in a sandbox.",
                actionTitle: "Run",
                signature: signature,
                confidence: confidence,
                score: score(
                    predictedBenefit: 0.62,
                    confidence: confidence,
                    userAcceptancePrior: preferenceModel.preference(signature),
                    surfaceRelevance: 0.75,
                    interruptionCost: 0.18,
                    recentDismissalPenalty: dismissedSignatures.contains(signature) ? 0.35 : 0,
                    privacyRiskPenalty: 0.04
                ),
                evidence: evidence,
                prediction: prediction,
                task: "Continue the current browser workflow."
            )
            output.append(ProactiveHelpCandidate(kind: .backgroundWebAgent, offer: offer))
        }

        if let prediction {
            let signature = "next-action:\(prediction.token)"
            let offer = ProactiveOffer(
                source: .nextAction,
                level: prediction.confidence >= 0.8 ? .passive : .ambient,
                title: "Likely next action",
                detail: prediction.humanLabel,
                actionTitle: nil,
                signature: signature,
                confidence: prediction.confidence,
                score: score(
                    predictedBenefit: 0.35,
                    confidence: prediction.confidence,
                    userAcceptancePrior: preferenceModel.preference(signature),
                    surfaceRelevance: 0.7,
                    interruptionCost: 0.08,
                    recentDismissalPenalty: dismissedSignatures.contains(signature) ? 0.3 : 0,
                    privacyRiskPenalty: 0
                ),
                evidence: evidence,
                prediction: prediction
            )
            output.append(ProactiveHelpCandidate(kind: .nextAction, offer: offer))
        }

        return output.sorted { lhs, rhs in
            if lhs.offer.score != rhs.offer.score { return lhs.offer.score > rhs.offer.score }
            if lhs.offer.level != rhs.offer.level { return lhs.offer.level > rhs.offer.level }
            return lhs.id < rhs.id
        }
    }

    public func score(
        predictedBenefit: Double,
        confidence: Double,
        userAcceptancePrior: Double,
        surfaceRelevance: Double,
        interruptionCost: Double,
        recentDismissalPenalty: Double,
        privacyRiskPenalty: Double
    ) -> Double {
        predictedBenefit
            * confidence
            * userAcceptancePrior
            * surfaceRelevance
            - interruptionCost
            - recentDismissalPenalty
            - privacyRiskPenalty
    }

    private static func prefixConfidence(agent: CascadeAgent, liveLabels: [String]) -> Double? {
        let steps = agent.recipe.humanSteps.prefix(3).map(normalized)
        guard !steps.isEmpty, !liveLabels.isEmpty else { return nil }
        let suffix = Array(liveLabels.suffix(min(liveLabels.count, steps.count)))
        var matches = 0
        for (index, live) in suffix.enumerated() {
            guard steps.indices.contains(index) else { continue }
            if compatible(live, steps[index]) { matches += 1 }
        }
        guard matches > 0 else { return nil }
        return min(1, 0.48 + Double(matches) / Double(max(2, steps.count)) * 0.44)
    }

    private static func surfaceRelevance(apps: [String], activeApp: String?, activeSurface: String?) -> Double {
        guard !apps.isEmpty else { return 0.65 }
        let normalizedApps = Set(apps.map(normalized))
        if let activeApp, normalizedApps.contains(normalized(activeApp)) { return 1.0 }
        if let activeSurface, normalizedApps.contains(normalized(activeSurface)) { return 0.95 }
        return 0.45
    }

    private static func normalizedLabel(for event: InputEvent) -> String {
        normalized(NextActionPredictor.humanLabel(for: event))
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compatible(_ live: String, _ step: String) -> Bool {
        guard !live.isEmpty, !step.isEmpty else { return false }
        if live == step || live.contains(step) || step.contains(live) { return true }
        let liveWords = Set(live.split(separator: " ").filter { $0.count >= 3 })
        let stepWords = Set(step.split(separator: " ").filter { $0.count >= 3 })
        return !liveWords.isDisjoint(with: stepWords)
    }

    private static func isBrowserWorkflow(
        _ event: InputEvent,
        webAppIdentity: (@Sendable (InputEvent) -> String?)?
    ) -> Bool {
        if webAppIdentity?(event) != nil { return true }
        let app = normalized(event.appName)
        return ["safari", "google chrome", "chrome", "arc", "firefox", "microsoft edge", "brave browser"].contains(app)
    }
}
