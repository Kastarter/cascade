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
        routineProfiles: [RoutineProfile] = [],
        dismissedSignatures: Set<String> = [],
        browserWorkflowsAllowed: Bool = true,
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil,
        now: Date = Date()
    ) -> ProactiveOffer? {
        candidates(
            prediction: prediction,
            liveRepetition: liveRepetition,
            struggle: struggle,
            recentEvents: recentEvents,
            agents: agents,
            appSkills: appSkills,
            preferenceModel: preferenceModel,
            routineProfiles: routineProfiles,
            dismissedSignatures: dismissedSignatures,
            browserWorkflowsAllowed: browserWorkflowsAllowed,
            webAppIdentity: webAppIdentity,
            now: now
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
        routineProfiles: [RoutineProfile] = [],
        dismissedSignatures: Set<String> = [],
        browserWorkflowsAllowed: Bool = true,
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil,
        now: Date = Date()
    ) -> [ProactiveHelpCandidate] {
        let ordered = recentEvents.sorted {
            if $0.capturedAt == $1.capturedAt { return $0.id < $1.id }
            return $0.capturedAt < $1.capturedAt
        }
        let active = ordered.last
        let activeApp = active?.appName
        let activeBundle = active?.bundleIdentifier
        let activeSurface = active.flatMap { webAppIdentity?($0) }
        let liveLabels = ordered.suffix(4).map(Self.normalizedLabel)
        let evidence = ordered.suffix(3).map(NextActionPredictor.humanLabel)
        var output: [ProactiveHelpCandidate] = []

        for agent in agents where agent.enabled {
            guard let prefixConfidence = Self.prefixConfidence(agent: agent, liveLabels: liveLabels) else { continue }
            let signature = "agent:\(agent.signature)"
            let context = PreferenceContext(
                appName: agent.apps.first ?? activeApp,
                surface: activeSurface ?? "savedAgent",
                candidateType: "savedAgent",
                hourBucket: Calendar.current.component(.hour, from: now),
                backgroundCapable: Self.browserNames.isSuperset(of: Set(agent.apps.map { $0.lowercased() })),
                privacyRiskBucket: "low"
            )
            let routineAdjustment = Self.routineAdjustment(
                signature: agent.signature,
                appName: activeApp ?? agent.apps.first,
                surface: activeSurface,
                now: now,
                profiles: routineProfiles
            )
            let score = score(
                predictedBenefit: min(1, Double(max(agent.estimatedSecondsPerRun, agent.estimatedSeconds)) / 90.0),
                confidence: max(prefixConfidence, prediction?.confidence ?? 0.6),
                userAcceptancePrior: preferenceModel.preference(for: agent.signature, context: context),
                surfaceRelevance: Self.surfaceRelevance(apps: agent.apps, activeApp: activeApp, activeSurface: activeSurface),
                interruptionCost: 0.08,
                recentDismissalPenalty: dismissedSignatures.contains(signature) ? 0.45 : 0,
                privacyRiskPenalty: 0
            ) + routineAdjustment
            guard score > 0 else { continue }
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
            let context = PreferenceContext(
                appName: activeApp,
                surface: activeSurface ?? "appSkill",
                candidateType: "appSkill",
                hourBucket: Calendar.current.component(.hour, from: now),
                backgroundCapable: false,
                privacyRiskBucket: skill.explicitAskOnly ? "medium" : "low"
            )
            let routineAdjustment = Self.routineAdjustment(signature: signature, appName: activeApp, surface: activeSurface, now: now, profiles: routineProfiles)
            let offerScore = score(
                predictedBenefit: 0.58,
                confidence: confidence,
                userAcceptancePrior: preferenceModel.preference(for: signature, context: context),
                surfaceRelevance: 1,
                interruptionCost: 0.14,
                recentDismissalPenalty: dismissedSignatures.contains(signature) ? 0.35 : 0,
                privacyRiskPenalty: skill.explicitAskOnly ? 0.16 : 0
            ) + routineAdjustment
            if offerScore > 0 {
                let offer = ProactiveOffer(
                    source: .appSkill,
                    level: confidence >= 0.72 ? .action : .passive,
                    title: skill.name,
                    detail: skill.useWhen,
                    actionTitle: "Show",
                    signature: signature,
                    confidence: confidence,
                    score: offerScore,
                    evidence: evidence,
                    prediction: prediction,
                    skillName: skill.name
                )
                output.append(ProactiveHelpCandidate(kind: .appSkill, offer: offer))
            }
        }

        if let liveRepetition {
            let signature = "repetition:\(liveRepetition.signature)"
            let confidence = liveRepetition.stage == .actionable ? 0.82 : 0.58
            let context = PreferenceContext(
                appName: activeApp,
                surface: activeSurface ?? "liveRepetition",
                candidateType: "liveRepetition",
                hourBucket: Calendar.current.component(.hour, from: now),
                backgroundCapable: false,
                privacyRiskBucket: "low"
            )
            let routineAdjustment = Self.routineAdjustment(signature: liveRepetition.signature, appName: activeApp, surface: activeSurface, now: now, profiles: routineProfiles)
            let offerScore = score(
                predictedBenefit: min(1, Double(liveRepetition.eventIDs.count) / 6),
                confidence: confidence,
                userAcceptancePrior: preferenceModel.preference(for: signature, context: context),
                surfaceRelevance: 0.9,
                interruptionCost: liveRepetition.stage == .actionable ? 0.10 : 0.02,
                recentDismissalPenalty: dismissedSignatures.contains(signature) ? 0.35 : 0,
                privacyRiskPenalty: 0
            ) + routineAdjustment
            if offerScore > 0 {
            let offer = ProactiveOffer(
                source: .liveRepetition,
                level: liveRepetition.stage == .actionable ? .action : .ambient,
                title: liveRepetition.stage == .actionable ? "This looks repeatable" : "Pattern noticed",
                detail: "\(liveRepetition.occurrences) matching runs in this session.",
                actionTitle: liveRepetition.stage == .actionable ? "Teach" : nil,
                signature: signature,
                confidence: confidence,
                score: offerScore,
                evidence: liveRepetition.evidenceLabels,
                prediction: prediction,
                rangeStart: liveRepetition.startAt,
                rangeEnd: liveRepetition.endAt
            )
            output.append(ProactiveHelpCandidate(kind: .liveRepetition, offer: offer))
            }
        }

        if let struggle {
            let signature = "struggle:\(struggle.kind.rawValue):\(activeApp?.lowercased() ?? "unknown")"
            let context = PreferenceContext(
                appName: activeApp,
                surface: activeSurface ?? "struggle",
                candidateType: "struggle",
                hourBucket: Calendar.current.component(.hour, from: now),
                backgroundCapable: false,
                privacyRiskBucket: "low"
            )
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
                    userAcceptancePrior: preferenceModel.preference(for: signature, context: context),
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
            let context = PreferenceContext(
                appName: activeApp,
                surface: activeSurface ?? "backgroundWeb",
                candidateType: "backgroundWebAgent",
                hourBucket: Calendar.current.component(.hour, from: now),
                backgroundCapable: true,
                privacyRiskBucket: "medium"
            )
            let routineAdjustment = Self.routineAdjustment(signature: signature, appName: activeApp, surface: activeSurface, now: now, profiles: routineProfiles)
            let offerScore = score(
                predictedBenefit: 0.62,
                confidence: confidence,
                userAcceptancePrior: preferenceModel.preference(for: signature, context: context),
                surfaceRelevance: 0.75,
                interruptionCost: 0.18,
                recentDismissalPenalty: dismissedSignatures.contains(signature) ? 0.35 : 0,
                privacyRiskPenalty: 0.04
            ) + routineAdjustment
            if offerScore > 0 {
            let offer = ProactiveOffer(
                source: .backgroundWebAgent,
                level: .passive,
                title: "Run this web flow in the background",
                detail: "Keep your screen free while Cascade works in a sandbox.",
                actionTitle: "Run",
                signature: signature,
                confidence: confidence,
                score: offerScore,
                evidence: evidence,
                prediction: prediction,
                task: "Continue the current browser workflow."
            )
            output.append(ProactiveHelpCandidate(kind: .backgroundWebAgent, offer: offer))
            }
        }

        if let prediction {
            let signature = "next-action:\(prediction.token)"
            let context = PreferenceContext(
                appName: activeApp,
                surface: activeSurface ?? "nextAction",
                candidateType: "nextAction",
                hourBucket: Calendar.current.component(.hour, from: now),
                backgroundCapable: false,
                privacyRiskBucket: "low"
            )
            let routineAdjustment = Self.routineAdjustment(signature: signature, appName: activeApp, surface: activeSurface, now: now, profiles: routineProfiles)
            let offerScore = score(
                predictedBenefit: 0.35,
                confidence: prediction.confidence,
                userAcceptancePrior: preferenceModel.preference(for: signature, context: context),
                surfaceRelevance: 0.7,
                interruptionCost: 0.08,
                recentDismissalPenalty: dismissedSignatures.contains(signature) ? 0.3 : 0,
                privacyRiskPenalty: 0
            ) + routineAdjustment
            if offerScore > 0 {
            let offer = ProactiveOffer(
                source: .nextAction,
                level: prediction.confidence >= 0.8 ? .passive : .ambient,
                title: "Likely next action",
                detail: prediction.humanLabel,
                actionTitle: nil,
                signature: signature,
                confidence: prediction.confidence,
                score: offerScore,
                evidence: evidence,
                prediction: prediction
            )
            output.append(ProactiveHelpCandidate(kind: .nextAction, offer: offer))
            }
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
        return browserNames.contains(app)
    }

    private static func routineAdjustment(
        signature: String,
        appName: String?,
        surface: String?,
        now: Date,
        profiles: [RoutineProfile]
    ) -> Double {
        guard !profiles.isEmpty else { return 0 }
        let weekday = Calendar.current.component(.weekday, from: now)
        let hour = Calendar.current.component(.hour, from: now)
        let signatureHash = AuditIdentity.hash(signature)
        let appKey = appName.map { AuditIdentity.safeToken($0.lowercased()) }
        let surfaceKey = surface.map { AuditIdentity.safeToken($0.lowercased()) }
        let matches = profiles.filter { profile in
            profile.weekday == weekday
                && profile.hourBucket == hour
                && (profile.workflowSignature == signatureHash || profile.workflowSignature == nil)
                && (appKey == nil || profile.appName == appKey)
                && (surfaceKey == nil || profile.surface == surfaceKey || profile.surface == "unknown")
        }
        guard !matches.isEmpty else { return 0 }
        let positive = matches.reduce(0) { $0 + $1.accepted + $1.completed + $1.scheduled }
        let negative = matches.reduce(0) { $0 + $1.dismissedSnoozed + $1.disabledDeleted }
        if negative >= 2, negative > positive { return -0.45 }
        if positive >= 2, positive > negative { return 0.18 }
        return 0
    }

    private static let browserNames: Set<String> = [
        "safari", "google chrome", "chrome", "arc", "firefox", "microsoft edge", "brave browser"
    ]
}
