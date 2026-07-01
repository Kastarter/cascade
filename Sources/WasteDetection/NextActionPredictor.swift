import CascadeMemory
import Foundation

/// Predicts the user's next action from their recent action stream so Cascade can
/// help *just in time* — "you've done A then B; you usually do C next — automate
/// it?" — instead of only surfacing repeated work in a daily digest (SEQ-18).
///
/// An online, back-off n-gram model: simple, fast, on-device, and (per the
/// next-activity-prediction literature) a strong baseline before any LSTM/LLM.
/// Tokens are opaque action labels (e.g. "click:Reply", "key:cmd+c", "app:Mail").
public struct NextActionPredictor: Sendable {
    public struct Prediction: Sendable, Codable, Equatable {
        public let token: String
        public let confidence: Double   // P(next = token | current context), 0…1
        public let support: Int         // how many times the context was seen
        public let evidenceCount: Int
        public let sourceWindow: String?
        public let humanLabel: String

        public init(
            token: String,
            confidence: Double,
            support: Int,
            evidenceCount: Int? = nil,
            sourceWindow: String? = nil,
            humanLabel: String? = nil
        ) {
            self.token = token
            self.confidence = min(1, max(0, confidence))
            self.support = support
            self.evidenceCount = evidenceCount ?? support
            self.sourceWindow = sourceWindow
            self.humanLabel = humanLabel ?? Self.humanLabel(from: token)
        }

        public static func humanLabel(from token: String) -> String {
            String(token.split(separator: "|", maxSplits: 1).first ?? Substring(token))
        }
    }

    /// Longest context (n-1) the model conditions on before backing off.
    public let maxOrder: Int
    /// A context must have been seen at least this many times to predict from it.
    public let minSupport: Int
    /// Half-life for event-backed evidence. A recent repeat is more predictive than a
    /// stale one, while the string-token compatibility API remains flat-counted.
    public let recencyHalfLife: TimeInterval

    public init(maxOrder: Int = 3, minSupport: Int = 2, recencyHalfLife: TimeInterval = 15 * 60) {
        self.maxOrder = max(2, maxOrder)
        self.minSupport = max(2, minSupport)
        self.recencyHalfLife = max(30, recencyHalfLife)
    }

    /// Predict the most likely next token given the action `history`, conditioning
    /// on the longest recent suffix that has enough support and backing off to
    /// shorter contexts. Returns nil when nothing recurs strongly enough.
    public func predict(history: [String]) -> Prediction? {
        predict(observations: history.enumerated().map {
            Observation(token: $0.element, capturedAt: nil, sourceWindow: nil)
        })
    }

    /// Event-backed prediction path for SEQ-18. It tokenizes privacy-safe
    /// `InputEvent`s with action shape, app/surface, window/source context, AX label,
    /// target identity, key combo, and a coarse inter-event gap bucket, then runs the
    /// same n-gram backoff with recency-weighted evidence.
    public func predict(
        events: [InputEvent],
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil,
        activeContext: RecordedContext? = nil
    ) -> Prediction? {
        let ordered = Self.orderedPrivacySafe(events)
        let observations = Self.observations(
            for: ordered,
            webAppIdentity: webAppIdentity,
            activeContext: activeContext
        )
        return predict(observations: observations)
    }

    public func proactiveOffer(
        events: [InputEvent],
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil,
        activeContext: RecordedContext? = nil,
        gateContext: InterruptibilityContext,
        gate: InterruptibilityGate = InterruptibilityGate()
    ) -> Prediction? {
        guard let prediction = predict(events: events, webAppIdentity: webAppIdentity, activeContext: activeContext) else {
            return nil
        }
        var context = gateContext
        context.confidence = prediction.confidence
        guard gate.shouldOffer(context) else { return nil }
        return prediction
    }

    public static func tokens(
        for events: [InputEvent],
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil,
        activeContext: RecordedContext? = nil
    ) -> [String] {
        observations(for: orderedPrivacySafe(events), webAppIdentity: webAppIdentity, activeContext: activeContext)
            .map(\.token)
    }

    public static func token(
        for event: InputEvent,
        previousEvent: InputEvent? = nil,
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil,
        activeContext: RecordedContext? = nil
    ) -> String {
        let surface = webAppIdentity?(event) ?? event.appName
        let action = actionPrefix(for: event, surface: surface)
        let app = tokenField("app", event.appName)
        let surfaceField = tokenField("surface", surface)
        let bundle = event.bundleIdentifier.map { tokenField("bundle", $0) }
        let window = sourceWindow(for: event, activeContext: activeContext)
            .map { "windowHash=\(AuditIdentity.hash($0))" }
        let target = targetIdentity(for: event).map { "targetHash=\(AuditIdentity.hash($0))" }
        let gap = gapBucket(from: previousEvent, to: event)
        let metadata = ([app, surfaceField, bundle, window, target, "gap=\(gap)"] as [String?])
            .compactMap { $0 }
            .joined(separator: "|")
        return metadata.isEmpty ? action : "\(action)|\(metadata)"
    }

    public static func humanLabel(for event: InputEvent) -> String {
        switch event.kind {
        case .key:
            let combo = keyCombo(for: event)
            return combo.isEmpty ? "press key" : "press \(combo)"
        case .type:
            return "type"
        case .click, .doubleClick, .rightClick:
            let label = clickLabel(for: event)
            let verb: String
            switch event.kind {
            case .click: verb = "click"
            case .doubleClick: verb = "double-click"
            case .rightClick: verb = "right-click"
            default: verb = "click"
            }
            return label.isEmpty || label == "unlabeled" ? "\(verb) the next control" : "\(verb) \(label)"
        case .scroll:
            return "scroll"
        }
    }

    private func predict(observations: [Observation]) -> Prediction? {
        let n = observations.count
        guard n >= 2 else { return nil }
        let maxK = min(maxOrder - 1, n - 1)
        let newest = observations.compactMap(\.capturedAt).max()
        for k in stride(from: maxK, through: 1, by: -1) {
            let context = observations.suffix(k).map(\.token)
            var following: [String: WeightedEvidence] = [:]
            var total = 0
            var totalWeight = 0.0
            var i = 0
            // Count tokens that historically followed this context, excluding the
            // trailing occurrence (that's the one we're predicting FOR).
            while i + k < n {
                if observations[i..<i + k].map(\.token) == context {
                    let next = observations[i + k]
                    let weight = Self.recencyWeight(for: next.capturedAt, newest: newest, halfLife: recencyHalfLife)
                    following[next.token, default: WeightedEvidence()].add(weight: weight, sourceWindow: next.sourceWindow)
                    total += 1
                    totalWeight += weight
                }
                i += 1
            }
            if total >= minSupport, totalWeight > 0,
               let best = following.max(by: { lhs, rhs in
                   if lhs.value.weight != rhs.value.weight { return lhs.value.weight < rhs.value.weight }
                   return lhs.key > rhs.key
               }) {
                return Prediction(
                    token: best.key,
                    confidence: best.value.weight / totalWeight,
                    support: total,
                    evidenceCount: best.value.count,
                    sourceWindow: best.value.sourceWindow,
                    humanLabel: Prediction.humanLabel(from: best.key)
                )
            }
        }
        return nil
    }

    /// Predict and gate a proactive next-action offer in one pure step. The predictor
    /// may see a pattern, but the gate decides whether surfacing it is welcome now.
    public func proactiveOffer(
        history: [String],
        secondsSinceLastOffer: TimeInterval,
        recentDismissals: Int,
        userIsActivelyTyping: Bool,
        gate: InterruptibilityGate = InterruptibilityGate()
    ) -> Prediction? {
        guard let prediction = predict(history: history),
              gate.shouldOffer(
                  confidence: prediction.confidence,
                  secondsSinceLastOffer: secondsSinceLastOffer,
                  recentDismissals: recentDismissals,
                  userIsActivelyTyping: userIsActivelyTyping
              ) else { return nil }
        return prediction
    }

    private static func observations(
        for events: [InputEvent],
        webAppIdentity: (@Sendable (InputEvent) -> String?)?,
        activeContext: RecordedContext?
    ) -> [Observation] {
        var previous: InputEvent?
        return events.map { event in
            defer { previous = event }
            return Observation(
                token: token(for: event, previousEvent: previous, webAppIdentity: webAppIdentity, activeContext: activeContext),
                capturedAt: event.capturedAt,
                sourceWindow: sourceWindow(for: event, activeContext: activeContext)
            )
        }
    }

    private static func orderedPrivacySafe(_ events: [InputEvent]) -> [InputEvent] {
        events
            .filter {
                !PrivacyRules.isSensitive(
                    appName: $0.appName,
                    bundleIdentifier: $0.bundleIdentifier,
                    windowTitle: $0.windowTitle
                )
            }
            .sorted {
                if $0.capturedAt == $1.capturedAt { return $0.id < $1.id }
                return $0.capturedAt < $1.capturedAt
            }
    }

    private static func actionPrefix(for event: InputEvent, surface: String) -> String {
        let surfaceLabel = cleaned(surface, fallback: "unknown")
        switch event.kind {
        case .key:
            let combo = keyCombo(for: event)
            return combo.isEmpty ? "key:unknown@\(surfaceLabel)" : "key:\(combo)@\(surfaceLabel)"
        case .type:
            return "type@\(surfaceLabel)"
        case .click, .doubleClick, .rightClick:
            return "\(event.kind.rawValue):\(clickLabel(for: event))@\(surfaceLabel)"
        case .scroll:
            return "scroll@\(surfaceLabel)"
        }
    }

    private static func keyCombo(for event: InputEvent) -> String {
        let modifiers = event.modifiers.map { $0.lowercased() }.sorted()
        let key = cleaned(event.key ?? "", fallback: "unknown")
        return (modifiers + [key]).filter { !$0.isEmpty }.joined(separator: "+")
    }

    private static func clickLabel(for event: InputEvent) -> String {
        if let text = InputEventSanitizer.sanitize(text: event.text, kind: event.kind),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        }
        if let descriptor = AXTargetDescriptorV2.decode(event.targetDescriptor),
           !descriptor.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(descriptor.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        }
        return "unlabeled"
    }

    private static func targetIdentity(for event: InputEvent) -> String? {
        guard let descriptor = event.targetDescriptor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !descriptor.isEmpty else { return nil }
        if let decoded = AXTargetDescriptorV2.decode(descriptor) {
            let parts = [decoded.role, decoded.identifier, decoded.container, decoded.label]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        return descriptor
    }

    private static func sourceWindow(for event: InputEvent, activeContext: RecordedContext?) -> String? {
        let candidate = event.windowTitle ?? activeContext?.windowTitle
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              !PrivacyRules.isSensitiveText(candidate) else { return nil }
        return String(candidate.prefix(100))
    }

    private static func gapBucket(from previous: InputEvent?, to event: InputEvent) -> String {
        guard let previous else { return "start" }
        let gap = max(0, event.capturedAt.timeIntervalSince(previous.capturedAt))
        switch gap {
        case 0..<1: return "sub1s"
        case 1..<5: return "1-5s"
        case 5..<15: return "5-15s"
        case 15..<60: return "15-60s"
        case 60..<180: return "1-3m"
        default: return "3m+"
        }
    }

    private static func recencyWeight(for date: Date?, newest: Date?, halfLife: TimeInterval) -> Double {
        guard let date, let newest else { return 1 }
        let age = max(0, newest.timeIntervalSince(date))
        return pow(0.5, age / halfLife)
    }

    private static func tokenField(_ key: String, _ value: String) -> String {
        "\(key)=\(AuditIdentity.safeToken(cleaned(value, fallback: "unknown").lowercased()))"
    }

    private static func cleaned(_ value: String, fallback: String) -> String {
        let trimmed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(80))
    }

    private struct Observation: Sendable {
        let token: String
        let capturedAt: Date?
        let sourceWindow: String?
    }

    private struct WeightedEvidence: Sendable {
        var weight: Double = 0
        var count: Int = 0
        var sourceWindow: String?

        mutating func add(weight: Double, sourceWindow: String?) {
            self.weight += weight
            count += 1
            if let sourceWindow { self.sourceWindow = sourceWindow }
        }
    }
}

public enum ProactiveOfferLevel: Int, Codable, Sendable, Equatable, Comparable {
    case auditOnly = 0
    case ambient = 1
    case passive = 2
    case action = 3

    public static func < (lhs: ProactiveOfferLevel, rhs: ProactiveOfferLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ProactiveSignal: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case prediction
        case repetition
        case struggle
        case suppression
    }

    public let kind: Kind
    public let reason: String
    public let confidence: Double
    public let signature: String
    public let featureSummary: [String]
    public let appName: String?
    public let windowHash: String?

    public init(
        kind: Kind,
        reason: String,
        confidence: Double,
        signature: String,
        featureSummary: [String] = [],
        appName: String? = nil,
        windowHash: String? = nil
    ) {
        self.kind = kind
        self.reason = reason
        self.confidence = min(1, max(0, confidence))
        self.signature = signature
        self.featureSummary = featureSummary
        self.appName = appName
        self.windowHash = windowHash
    }
}

public struct ProactiveOffer: Identifiable, Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable, Equatable {
        case nextAction
        case liveRepetition
        case savedAgent
        case appSkill
        case rewindQuestion
        case backgroundWebAgent
        case struggle
    }

    public let id: UUID
    public let source: Source
    public let level: ProactiveOfferLevel
    public let title: String
    public let detail: String
    public let actionTitle: String?
    public let signature: String
    public let confidence: Double
    public let score: Double
    public let evidence: [String]
    public let prediction: NextActionPredictor.Prediction?
    public let relatedAgentID: Int64?
    public let skillName: String?
    public let task: String?
    public let rangeStart: Date?
    public let rangeEnd: Date?

    public init(
        id: UUID = UUID(),
        source: Source,
        level: ProactiveOfferLevel,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        signature: String,
        confidence: Double,
        score: Double,
        evidence: [String] = [],
        prediction: NextActionPredictor.Prediction? = nil,
        relatedAgentID: Int64? = nil,
        skillName: String? = nil,
        task: String? = nil,
        rangeStart: Date? = nil,
        rangeEnd: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.level = level
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.signature = signature
        self.confidence = min(1, max(0, confidence))
        self.score = score
        self.evidence = evidence
        self.prediction = prediction
        self.relatedAgentID = relatedAgentID
        self.skillName = skillName
        self.task = task
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }
}

/// Decides WHETHER to surface a proactive offer — the hard part of proactivity is
/// not predicting, it's not being annoying. A false interruption costs trust, so
/// the gate is conservative: high confidence, off the active-typing path, past a
/// cooldown, and it mutes itself once the user has dismissed enough (learned
/// interruptibility — SEQ-18).
public struct InterruptibilityContext: Sendable, Equatable {
    public enum Boundary: String, Sendable, Equatable {
        case idleAfterAction
        case completionControl
        case appOrWindowSwitch
        case noEffectOrErrorPlateau
        case userOpenedCascade
    }

    public var confidence: Double
    public var secondsSinceLastOffer: TimeInterval
    public var recentDismissals: Int
    public var userIsActivelyTyping: Bool
    public var isPrivacySensitive: Bool
    public var secureInputActive: Bool
    public var modifierHeavyKeySequence: Bool
    public var draggingOrSelecting: Bool
    public var agentRunning: Bool
    public var assistTaskRunning: Bool
    public var stopRequested: Bool
    public var permissionsHealthy: Bool
    public var noisySurface: Bool
    public var meetingOrFullscreenOrPrivateSurface: Bool
    public var perAppSnoozed: Bool
    public var perSignatureSnoozed: Bool
    public var recentlyDismissedSignature: Bool
    public var boundary: Boundary?
    public var repeatedNoEffectOrErrorPlateau: Bool
    public var requiresBoundary: Bool

    public init(
        confidence: Double = 0,
        secondsSinceLastOffer: TimeInterval = .greatestFiniteMagnitude,
        recentDismissals: Int = 0,
        userIsActivelyTyping: Bool = false,
        isPrivacySensitive: Bool = false,
        secureInputActive: Bool = false,
        modifierHeavyKeySequence: Bool = false,
        draggingOrSelecting: Bool = false,
        agentRunning: Bool = false,
        assistTaskRunning: Bool = false,
        stopRequested: Bool = false,
        permissionsHealthy: Bool = true,
        noisySurface: Bool = false,
        meetingOrFullscreenOrPrivateSurface: Bool = false,
        perAppSnoozed: Bool = false,
        perSignatureSnoozed: Bool = false,
        recentlyDismissedSignature: Bool = false,
        boundary: Boundary? = nil,
        repeatedNoEffectOrErrorPlateau: Bool = false,
        requiresBoundary: Bool = false
    ) {
        self.confidence = confidence
        self.secondsSinceLastOffer = secondsSinceLastOffer
        self.recentDismissals = recentDismissals
        self.userIsActivelyTyping = userIsActivelyTyping
        self.isPrivacySensitive = isPrivacySensitive
        self.secureInputActive = secureInputActive
        self.modifierHeavyKeySequence = modifierHeavyKeySequence
        self.draggingOrSelecting = draggingOrSelecting
        self.agentRunning = agentRunning
        self.assistTaskRunning = assistTaskRunning
        self.stopRequested = stopRequested
        self.permissionsHealthy = permissionsHealthy
        self.noisySurface = noisySurface
        self.meetingOrFullscreenOrPrivateSurface = meetingOrFullscreenOrPrivateSurface
        self.perAppSnoozed = perAppSnoozed
        self.perSignatureSnoozed = perSignatureSnoozed
        self.recentlyDismissedSignature = recentlyDismissedSignature
        self.boundary = boundary
        self.repeatedNoEffectOrErrorPlateau = repeatedNoEffectOrErrorPlateau
        self.requiresBoundary = requiresBoundary
    }
}

public struct InterruptibilityGate: Sendable {
    public var minConfidence: Double
    public var cooldownSeconds: TimeInterval
    public var maxRecentDismissalsBeforeMute: Int

    public init(minConfidence: Double = 0.6, cooldownSeconds: TimeInterval = 120, maxRecentDismissalsBeforeMute: Int = 3) {
        self.minConfidence = minConfidence
        self.cooldownSeconds = cooldownSeconds
        self.maxRecentDismissalsBeforeMute = maxRecentDismissalsBeforeMute
    }

    public enum Decision: Sendable, Equatable {
        case offer
        case suppress(reason: String)
    }

    public func decide(_ context: InterruptibilityContext) -> Decision {
        if context.isPrivacySensitive { return .suppress(reason: "privacy.sensitive") }
        if context.secureInputActive { return .suppress(reason: "input.secure") }
        if context.agentRunning { return .suppress(reason: "agent.running") }
        if context.assistTaskRunning { return .suppress(reason: "assist.running") }
        if context.stopRequested { return .suppress(reason: "stop.requested") }
        if !context.permissionsHealthy { return .suppress(reason: "permissions.unhealthy") }
        if context.noisySurface { return .suppress(reason: "surface.noisy") }
        if context.meetingOrFullscreenOrPrivateSurface { return .suppress(reason: "surface.private_or_meeting") }
        if context.perAppSnoozed { return .suppress(reason: "snooze.app") }
        if context.perSignatureSnoozed { return .suppress(reason: "snooze.signature") }
        if context.recentlyDismissedSignature { return .suppress(reason: "dismissal.signature_recent") }
        if context.userIsActivelyTyping { return .suppress(reason: "typing.active") }
        if context.modifierHeavyKeySequence { return .suppress(reason: "input.modifier_sequence") }
        if context.draggingOrSelecting { return .suppress(reason: "input.drag_or_selection") }
        if context.confidence < minConfidence { return .suppress(reason: "confidence.low") }
        if context.secondsSinceLastOffer < cooldownSeconds { return .suppress(reason: "cooldown.active") }
        if context.recentDismissals >= maxRecentDismissalsBeforeMute { return .suppress(reason: "dismissal.muted") }
        if context.requiresBoundary,
           context.boundary == nil,
           !context.repeatedNoEffectOrErrorPlateau {
            return .suppress(reason: "boundary.missing")
        }
        return .offer
    }

    public func decide(
        confidence: Double,
        secondsSinceLastOffer: TimeInterval,
        recentDismissals: Int,
        userIsActivelyTyping: Bool
    ) -> Decision {
        decide(InterruptibilityContext(
            confidence: confidence,
            secondsSinceLastOffer: secondsSinceLastOffer,
            recentDismissals: recentDismissals,
            userIsActivelyTyping: userIsActivelyTyping
        ))
    }

    public func shouldOffer(_ context: InterruptibilityContext) -> Bool {
        decide(context) == .offer
    }

    public func shouldOffer(
        confidence: Double, secondsSinceLastOffer: TimeInterval,
        recentDismissals: Int, userIsActivelyTyping: Bool
    ) -> Bool {
        decide(
            confidence: confidence, secondsSinceLastOffer: secondsSinceLastOffer,
            recentDismissals: recentDismissals, userIsActivelyTyping: userIsActivelyTyping
        ) == .offer
    }
}

public struct StruggleSignal: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case repeatedClick
        case undoCancelLoop
        case repeatedError
        case searchRewrite
        case scrollOscillation
        case flailingAfterIdle
    }

    public let kind: Kind
    public let confidence: Double
    public let reason: String
    public let eventIDs: [Int64]

    public init(kind: Kind, confidence: Double, reason: String, eventIDs: [Int64]) {
        self.kind = kind
        self.confidence = min(1, max(0, confidence))
        self.reason = reason
        self.eventIDs = eventIDs
    }
}

public struct StruggleDetector: Sendable {
    public let window: TimeInterval

    public init(window: TimeInterval = 90) {
        self.window = max(15, window)
    }

    public func detect(events: [InputEvent], contexts: [RecordedContext] = []) -> StruggleSignal? {
        let ordered = events
            .filter { !PrivacyRules.isSensitive(appName: $0.appName, bundleIdentifier: $0.bundleIdentifier, windowTitle: $0.windowTitle) }
            .sorted {
                if $0.capturedAt == $1.capturedAt { return $0.id < $1.id }
                return $0.capturedAt < $1.capturedAt
            }
        guard let end = ordered.last?.capturedAt else {
            return repeatedError(in: contexts)
        }
        let recent = ordered.filter { end.timeIntervalSince($0.capturedAt) <= window }
        let candidates = [
            repeatedClick(in: recent),
            undoCancelLoop(in: recent),
            searchRewrite(in: recent),
            scrollOscillation(in: recent),
            flailingAfterIdle(in: ordered),
            repeatedError(in: contexts)
        ].compactMap { $0 }
        return candidates.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }.first
    }

    private func repeatedClick(in events: [InputEvent]) -> StruggleSignal? {
        let clicks = events.filter { [.click, .doubleClick, .rightClick].contains($0.kind) }
        guard clicks.count >= 3 else { return nil }
        let grouped = Dictionary(grouping: clicks, by: clickIdentity)
        guard let group = grouped.values.first(where: { group in
            guard group.count >= 3,
                  let first = group.first,
                  let last = group.last else { return false }
            return last.capturedAt.timeIntervalSince(first.capturedAt) <= 8
        }) else { return nil }
        return StruggleSignal(
            kind: .repeatedClick,
            confidence: group.count >= 4 ? 0.9 : 0.72,
            reason: "rapid same-target clicks",
            eventIDs: group.map(\.id)
        )
    }

    private func undoCancelLoop(in events: [InputEvent]) -> StruggleSignal? {
        let loopKeys: Set<String> = ["escape", "delete", "backspace", "cancel", "z", "w"]
        let keys = events.filter { event in
            guard event.kind == .key else { return false }
            let key = event.key?.lowercased() ?? ""
            if key == "z" || key == "w" {
                return event.modifiers.map { $0.lowercased() }.contains("command")
            }
            return loopKeys.contains(key)
        }
        guard keys.count >= 3 else { return nil }
        return StruggleSignal(kind: .undoCancelLoop, confidence: 0.74, reason: "undo/cancel key loop", eventIDs: keys.map(\.id))
    }

    private func searchRewrite(in events: [InputEvent]) -> StruggleSignal? {
        let typed = events.filter { $0.kind == .type }
        guard typed.count >= 3 else { return nil }
        let searchTyped = typed.filter { event in
            let haystack = [event.windowTitle, event.targetDescriptor, event.text]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return haystack.contains("search") || haystack.contains("find") || haystack.contains("filter")
        }
        let distinctShapes = Set(searchTyped.map { ($0.text ?? "").lowercased() })
        guard searchTyped.count >= 3, distinctShapes.count >= 2 else { return nil }
        return StruggleSignal(kind: .searchRewrite, confidence: 0.68, reason: "search/query rewrite loop", eventIDs: searchTyped.map(\.id))
    }

    private func scrollOscillation(in events: [InputEvent]) -> StruggleSignal? {
        let scrolls = events.filter { $0.kind == .scroll }
        guard scrolls.count >= 5 else { return nil }
        let directions = scrolls.compactMap(scrollDirection)
        guard directions.count >= 5 else { return nil }
        var flips = 0
        for index in 1..<directions.count where directions[index] != directions[index - 1] {
            flips += 1
        }
        guard flips >= 4 else { return nil }
        return StruggleSignal(kind: .scrollOscillation, confidence: 0.66, reason: "scroll direction oscillation", eventIDs: scrolls.map(\.id))
    }

    private func flailingAfterIdle(in events: [InputEvent]) -> StruggleSignal? {
        guard events.count >= 7 else { return nil }
        for index in 1..<events.count {
            let gap = events[index].capturedAt.timeIntervalSince(events[index - 1].capturedAt)
            guard gap >= 60 else { continue }
            let burst = events[index...].prefix { $0.capturedAt.timeIntervalSince(events[index].capturedAt) <= 25 }
            guard burst.count >= 6 else { continue }
            let distinct = Set(burst.map(actionEntropyKey))
            let typingRatio = Double(burst.count { $0.kind == .type }) / Double(burst.count)
            guard distinct.count >= 5, typingRatio < 0.5 else { continue }
            return StruggleSignal(kind: .flailingAfterIdle, confidence: 0.64, reason: "high-entropy actions after idle", eventIDs: burst.map(\.id))
        }
        return nil
    }

    private func repeatedError(in contexts: [RecordedContext]) -> StruggleSignal? {
        let recent = contexts
            .filter { !PrivacyRules.isSensitive($0) }
            .sorted { $0.capturedAt < $1.capturedAt }
            .suffix(12)
        var counts: [String: Int] = [:]
        for context in recent {
            let text = [context.windowTitle, context.ocrText]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            guard text.contains("error") || text.contains("failed") || text.contains("alert") || text.contains("try again") else {
                continue
            }
            let key = String(text.prefix(80))
            counts[key, default: 0] += 1
        }
        guard counts.values.contains(where: { $0 >= 2 }) else { return nil }
        return StruggleSignal(kind: .repeatedError, confidence: 0.78, reason: "repeated alert/error text", eventIDs: [])
    }

    private func clickIdentity(_ event: InputEvent) -> String {
        if let descriptor = event.targetDescriptor, !descriptor.isEmpty {
            return "descriptor:\(AuditIdentity.hash(descriptor))"
        }
        if let label = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return "label:\(label.lowercased())"
        }
        let x = Int((event.x ?? 0) / 8)
        let y = Int((event.y ?? 0) / 8)
        return "point:\(event.appName.lowercased()):\(x):\(y)"
    }

    private func scrollDirection(_ event: InputEvent) -> Int? {
        guard let dyText = event.modifiers.dropFirst().first,
              let dy = Int(dyText),
              dy != 0 else { return nil }
        return dy > 0 ? 1 : -1
    }

    private func actionEntropyKey(_ event: InputEvent) -> String {
        switch event.kind {
        case .key:
            return "key:\(event.modifiers.sorted().joined(separator: "+")):\(event.key ?? "")"
        case .click, .doubleClick, .rightClick:
            return clickIdentity(event)
        case .type:
            return "type"
        case .scroll:
            return "scroll:\(scrollDirection(event) ?? 0)"
        }
    }
}
