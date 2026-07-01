import CascadeMemory
import Foundation

/// A compact, prompt-ready summary of a successful demonstration trajectory.
/// It is deliberately inert: callers may rank or render sketches, but nothing is
/// injected into a runtime prompt until an explicit integration path opts in.
public struct TrajectorySketch: Identifiable, Sendable, Equatable {
    public let id: String
    public let appName: String
    public let windowTitle: String?
    public let normalizedGoalTokens: [String]
    public let firstActions: [TrajectoryAction]
    public let safeAnchors: [String]
    public let expectedChecks: [TrajectoryCheck]
    public let failureCorrections: [TrajectoryCorrection]

    public init(
        id: String,
        appName: String,
        windowTitle: String?,
        normalizedGoalTokens: [String],
        firstActions: [TrajectoryAction],
        safeAnchors: [String],
        expectedChecks: [TrajectoryCheck],
        failureCorrections: [TrajectoryCorrection]
    ) {
        self.id = id
        self.appName = appName
        self.windowTitle = windowTitle
        self.normalizedGoalTokens = normalizedGoalTokens
        self.firstActions = firstActions
        self.safeAnchors = safeAnchors
        self.expectedChecks = expectedChecks
        self.failureCorrections = failureCorrections
    }

    public var promptText: String {
        var lines = ["TRAJECTORY SKETCH"]
        lines.append("app: \(appName)")
        if let windowTitle { lines.append("window: \(windowTitle)") }
        if !normalizedGoalTokens.isEmpty {
            lines.append("goal_tokens: \(normalizedGoalTokens.joined(separator: ", "))")
        }
        if !firstActions.isEmpty {
            lines.append("first_actions:")
            for action in firstActions {
                let repeats = action.repeatCount > 1 ? " x\(action.repeatCount)" : ""
                lines.append("\(action.index). \(action.label)\(repeats)")
            }
        }
        if !safeAnchors.isEmpty {
            lines.append("safe_anchors: \(safeAnchors.joined(separator: " | "))")
        }
        if !expectedChecks.isEmpty {
            lines.append("expected_checks:")
            for check in expectedChecks {
                lines.append("- \(check.label)")
            }
        }
        if !failureCorrections.isEmpty {
            lines.append("verified_corrections:")
            for correction in failureCorrections {
                lines.append("- \(correction.failureKind): \(correction.correction)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func relevanceScore(appName queryAppName: String?, goal queryGoal: String) -> Double {
        var score = 0.0
        let queryApp = queryAppName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let queryApp, !queryApp.isEmpty {
            let sketchApp = appName.lowercased()
            if sketchApp == queryApp {
                score += 2.0
            } else if sketchApp.contains(queryApp) || queryApp.contains(sketchApp) {
                score += 1.0
            }
        }

        let queryTokens = Set(Self.normalizedGoalTokens(from: queryGoal))
        if !queryTokens.isEmpty {
            let sketchTokens = Set(normalizedGoalTokens)
            let overlap = sketchTokens.intersection(queryTokens).count
            let union = sketchTokens.union(queryTokens).count
            if union > 0 {
                score += Double(overlap) / Double(union)
            }
            score += Double(overlap) * 0.05
        }
        return score
    }

    public static func normalizedGoalTokens(from goal: String) -> [String] {
        let parts = goal
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 1 && !Self.goalStopWords.contains($0) }

        var seen = Set<String>()
        var ordered: [String] = []
        for part in parts where seen.insert(part).inserted {
            ordered.append(part)
        }
        return ordered
    }

    private static let goalStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in",
        "into", "is", "it", "latest", "of", "on", "or", "out", "the", "then",
        "this", "to", "with"
    ]
}

public struct TrajectoryAction: Sendable, Equatable {
    public let index: Int
    public let kind: RecipeStepKind
    public let label: String
    public let appName: String
    public let anchor: String?
    public let sourceOrders: [Int]
    public let repeatCount: Int

    public init(
        index: Int,
        kind: RecipeStepKind,
        label: String,
        appName: String,
        anchor: String?,
        sourceOrders: [Int],
        repeatCount: Int
    ) {
        self.index = index
        self.kind = kind
        self.label = label
        self.appName = appName
        self.anchor = anchor
        self.sourceOrders = sourceOrders
        self.repeatCount = repeatCount
    }
}

public struct TrajectoryCheck: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case auditEvent
        case traceSpan
        case agentExperience
    }

    public let source: Source
    public let label: String
    public let requiredTerms: [String]
    public let evidenceID: String?

    public init(source: Source, label: String, requiredTerms: [String], evidenceID: String? = nil) {
        self.source = source
        self.label = label
        self.requiredTerms = requiredTerms
        self.evidenceID = evidenceID
    }

    public func matches(audit event: AuditEvent) -> Bool {
        guard source == .auditEvent else { return false }
        return Self.containsTerms(requiredTerms, in: "\(event.action) \(event.detail)")
    }

    public func matches(traceSpan span: TraceSpan) -> Bool {
        guard source == .traceSpan else { return false }
        let attributes = span.attributes
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " ")
        return span.status == .ok && Self.containsTerms(requiredTerms, in: "\(span.name) \(attributes)")
    }

    public func matches(experience: AgentExperienceCase) -> Bool {
        guard source == .agentExperience else { return false }
        guard experience.outcome == .success, experience.verificationSignal != nil else { return false }
        return Self.containsTerms(requiredTerms, in: "\(experience.appName) \(experience.goalPattern) \(experience.recipeSignature)")
    }

    private static func containsTerms(_ terms: [String], in text: String) -> Bool {
        let normalized = text.lowercased()
        return terms.allSatisfy { normalized.contains($0) }
    }
}

public struct TrajectoryCorrection: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case auditEvent
        case traceSpan
    }

    public let source: Source
    public let failureKind: String
    public let correction: String
    public let evidenceID: String?

    public init(source: Source, failureKind: String, correction: String, evidenceID: String? = nil) {
        self.source = source
        self.failureKind = failureKind
        self.correction = correction
        self.evidenceID = evidenceID
    }
}

public struct TrajectorySketchBuilder: Sendable {
    public let maxActions: Int
    public let maxAnchors: Int
    public let maxChecks: Int
    public let maxCorrections: Int

    public init(maxActions: Int = 8, maxAnchors: Int = 6, maxChecks: Int = 5, maxCorrections: Int = 3) {
        self.maxActions = max(1, maxActions)
        self.maxAnchors = max(0, maxAnchors)
        self.maxChecks = max(0, maxChecks)
        self.maxCorrections = max(0, maxCorrections)
    }

    public func build(
        goal: String,
        recipe: AgentRecipe,
        auditEvents: [AuditEvent] = [],
        experiences: [AgentExperienceCase] = [],
        traces: [AgentTrace] = []
    ) -> TrajectorySketch {
        let sortedSteps = recipe.steps.sorted { $0.order < $1.order }
        let primaryApp = Self.primaryApp(from: sortedSteps)
        let windowTitle = sortedSteps.lazy.compactMap { Self.safeLabel($0.windowTitleHint) }.first
        let actions = Self.collapsedActions(from: sortedSteps).prefix(maxActions)
        let anchors = Self.safeAnchors(from: sortedSteps, limit: maxAnchors)
        let checks = Self.expectedChecks(
            auditEvents: auditEvents,
            experiences: experiences,
            traces: traces,
            limit: maxChecks
        )
        let corrections = Self.failureCorrections(
            auditEvents: auditEvents,
            traces: traces,
            limit: maxCorrections
        )

        return TrajectorySketch(
            id: Self.sketchID(appName: primaryApp, goal: goal, actions: Array(actions)),
            appName: primaryApp,
            windowTitle: windowTitle,
            normalizedGoalTokens: TrajectorySketch.normalizedGoalTokens(from: goal),
            firstActions: Array(actions),
            safeAnchors: anchors,
            expectedChecks: checks,
            failureCorrections: corrections
        )
    }

    public func rank(_ sketches: [TrajectorySketch], appName: String?, goal: String) -> [TrajectorySketch] {
        sketches.sorted {
            let left = $0.relevanceScore(appName: appName, goal: goal)
            let right = $1.relevanceScore(appName: appName, goal: goal)
            if left == right { return $0.id < $1.id }
            return left > right
        }
    }

    private static func collapsedActions(from steps: [RecipeStep]) -> [TrajectoryAction] {
        var collapsed: [TrajectoryAction] = []
        for step in steps {
            let action = action(from: step, index: collapsed.count + 1)
            if let last = collapsed.last, equivalent(last, action) {
                collapsed[collapsed.count - 1] = TrajectoryAction(
                    index: last.index,
                    kind: last.kind,
                    label: last.label,
                    appName: last.appName,
                    anchor: last.anchor,
                    sourceOrders: last.sourceOrders + action.sourceOrders,
                    repeatCount: last.repeatCount + action.repeatCount
                )
            } else {
                collapsed.append(action)
            }
        }
        return collapsed.enumerated().map { offset, action in
            TrajectoryAction(
                index: offset + 1,
                kind: action.kind,
                label: action.label,
                appName: action.appName,
                anchor: action.anchor,
                sourceOrders: action.sourceOrders,
                repeatCount: action.repeatCount
            )
        }
    }

    private static func action(from step: RecipeStep, index: Int) -> TrajectoryAction {
        let anchor = safeLabel(step.ocrAnchor) ?? safeNonTypedText(step)
        let appName = safeLabel(step.appName) ?? "app"
        let label: String
        switch step.kind {
        case .activateApp:
            label = "switch to \(appName)"
        case .click:
            label = anchored("click", anchor: anchor)
        case .doubleClick:
            label = anchored("double-click", anchor: anchor)
        case .rightClick:
            label = anchored("right-click", anchor: anchor)
        case .type:
            label = step.isParameter ? "type current value" : "type"
        case .key:
            label = shortcutLabel(key: step.key, modifiers: step.modifiers)
        case .scroll:
            label = "scroll"
        }

        return TrajectoryAction(
            index: index,
            kind: step.kind,
            label: label,
            appName: appName,
            anchor: anchor,
            sourceOrders: [step.order],
            repeatCount: 1
        )
    }

    private static func equivalent(_ left: TrajectoryAction, _ right: TrajectoryAction) -> Bool {
        left.kind == right.kind
            && left.label == right.label
            && left.appName == right.appName
            && left.anchor == right.anchor
    }

    private static func safeAnchors(from steps: [RecipeStep], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var anchors: [String] = []
        for step in steps {
            let candidates: [String?] = [step.ocrAnchor, step.kind == .type ? nil : step.text, step.windowTitleHint]
            for candidate in candidates {
                guard let label = safeLabel(candidate), seen.insert(label.lowercased()).inserted else { continue }
                anchors.append(label)
                if anchors.count == limit { return anchors }
            }
        }
        return anchors
    }

    private static func expectedChecks(
        auditEvents: [AuditEvent],
        experiences: [AgentExperienceCase],
        traces: [AgentTrace],
        limit: Int
    ) -> [TrajectoryCheck] {
        guard limit > 0 else { return [] }
        var checks: [TrajectoryCheck] = []
        var seen = Set<String>()

        for event in auditEvents.sorted(by: auditSort) where isPositiveCheck("\(event.action) \(event.detail)") {
            guard let label = safeLabel("\(event.action): \(event.detail)") else { continue }
            let terms = checkTerms(from: "\(event.action) \(event.detail)")
            guard !terms.isEmpty else { continue }
            appendUnique(
                TrajectoryCheck(source: .auditEvent, label: label, requiredTerms: terms, evidenceID: "\(event.id)"),
                to: &checks,
                seen: &seen,
                limit: limit
            )
        }

        for trace in traces {
            for span in trace.spans.sorted(by: { $0.startMs < $1.startMs }) where isPositiveTraceCheck(span) {
                let attributes = span.attributes
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                guard let label = safeLabel("\(span.name): \(attributes)") else { continue }
                let terms = checkTerms(from: "\(span.name) \(attributes)")
                guard !terms.isEmpty else { continue }
                appendUnique(
                    TrajectoryCheck(source: .traceSpan, label: label, requiredTerms: terms, evidenceID: span.id),
                    to: &checks,
                    seen: &seen,
                    limit: limit
                )
            }
        }

        for experience in experiences where experience.outcome == .success && experience.verificationSignal != nil {
            let raw = "\(experience.verificationSignal?.rawValue ?? "verified") \(experience.appName) \(experience.goalPattern)"
            guard let label = safeLabel(raw) else { continue }
            let terms = checkTerms(from: "\(experience.appName) \(experience.goalPattern) \(experience.recipeSignature)")
            guard !terms.isEmpty else { continue }
            appendUnique(
                TrajectoryCheck(source: .agentExperience, label: label, requiredTerms: terms, evidenceID: "\(experience.id)"),
                to: &checks,
                seen: &seen,
                limit: limit
            )
        }

        return checks
    }

    private static func failureCorrections(
        auditEvents: [AuditEvent],
        traces: [AgentTrace],
        limit: Int
    ) -> [TrajectoryCorrection] {
        guard limit > 0 else { return [] }
        var corrections: [TrajectoryCorrection] = []
        var seen = Set<String>()

        for event in auditEvents.sorted(by: auditSort) where isVerifiedRecovery("\(event.action) \(event.detail)") {
            let raw = "\(event.action) \(event.detail)"
            guard let correction = recoveryValue(named: "correction", in: raw)
                ?? recoveryValue(named: "recovery", in: raw)
                ?? recoveryValue(named: "action", in: raw)
                ?? safeLabel(event.detail)
            else { continue }
            let failureKind = recoveryValue(named: "failure", in: raw)
                ?? recoveryValue(named: "failure_kind", in: raw)
                ?? "unknown"
            appendUnique(
                TrajectoryCorrection(source: .auditEvent, failureKind: failureKind, correction: correction, evidenceID: "\(event.id)"),
                to: &corrections,
                seen: &seen,
                limit: limit
            )
        }

        for trace in traces {
            for span in trace.spans.sorted(by: { $0.startMs < $1.startMs }) where isVerifiedRecovery(span) {
                let correction = safeLabel(
                    span.attributes["recovery.action"]
                        ?? span.attributes["recovery"]
                        ?? span.attributes["correction"]
                        ?? span.name
                )
                guard let correction else { continue }
                let failureKind = span.failureKind?.rawValue
                    ?? span.attributes["failure.kind"]
                    ?? span.attributes["failure"]
                    ?? "unknown"
                appendUnique(
                    TrajectoryCorrection(source: .traceSpan, failureKind: failureKind, correction: correction, evidenceID: span.id),
                    to: &corrections,
                    seen: &seen,
                    limit: limit
                )
            }
        }

        return corrections
    }

    private static func isPositiveCheck(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("unverified") || lowered.contains("incomplete") || lowered.contains("failed") || lowered.contains("error") {
            return false
        }
        return lowered.contains("verified")
            || lowered.contains("completed")
            || lowered.contains("expected")
            || lowered.contains("check")
            || lowered.contains("complete")
    }

    private static func isPositiveTraceCheck(_ span: TraceSpan) -> Bool {
        guard span.status == .ok else { return false }
        if span.kind == .eval { return true }
        let raw = "\(span.name) \(span.attributes.values.joined(separator: " "))"
        return isPositiveCheck(raw)
    }

    private static func isVerifiedRecovery(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard lowered.contains("recovery") || lowered.contains("correction") || lowered.contains("retry") else { return false }
        return lowered.contains("verified=true")
            || lowered.contains("verified: true")
            || lowered.contains("verified recovery")
            || (lowered.contains("verified") && !lowered.contains("unverified"))
    }

    private static func isVerifiedRecovery(_ span: TraceSpan) -> Bool {
        guard span.status == .ok else { return false }
        let verified = span.attributes["recovery.verified"]
            ?? span.attributes["verified"]
            ?? span.attributes["check.verified"]
        guard verified?.lowercased() == "true" else { return false }
        return span.attributes["recovery.action"] != nil
            || span.attributes["recovery"] != nil
            || span.attributes["correction"] != nil
            || span.name.lowercased().contains("recovery")
    }

    private static func checkTerms(from text: String) -> [String] {
        Array(TrajectorySketch.normalizedGoalTokens(from: text).prefix(6))
    }

    private static func appendUnique<T>(
        _ value: T,
        to values: inout [T],
        seen: inout Set<String>,
        limit: Int
    ) where T: CustomKeyConvertible {
        guard values.count < limit, seen.insert(value.uniqueKey).inserted else { return }
        values.append(value)
    }

    private static func auditSort(_ left: AuditEvent, _ right: AuditEvent) -> Bool {
        if left.createdAt == right.createdAt { return left.id < right.id }
        return left.createdAt < right.createdAt
    }

    private static func primaryApp(from steps: [RecipeStep]) -> String {
        steps.lazy.compactMap { safeLabel($0.appName) }.first ?? "app"
    }

    private static func sketchID(appName: String, goal: String, actions: [TrajectoryAction]) -> String {
        let actionKey = actions.map(\.label).joined(separator: "|")
        return "\(appName.lowercased())|\(TrajectorySketch.normalizedGoalTokens(from: goal).joined(separator: "-"))|\(actionKey)"
    }

    private static func anchored(_ verb: String, anchor: String?) -> String {
        guard let anchor, !anchor.isEmpty else { return verb }
        return "\(verb) \"\(anchor)\""
    }

    private static func shortcutLabel(key: String?, modifiers: [String]) -> String {
        let normalized = modifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let modifierText = normalized.map { modifier -> String in
            switch modifier {
            case "command", "cmd": "Command"
            case "shift": "Shift"
            case "option", "alt": "Option"
            case "control", "ctrl": "Control"
            case "fn", "function": "Fn"
            default: modifier.capitalized
            }
        }.joined(separator: "+")
        let keyText = (key ?? "").count == 1 ? (key ?? "").uppercased() : (key ?? "key").capitalized
        return modifierText.isEmpty ? keyText : "\(modifierText)+\(keyText)"
    }

    private static func safeNonTypedText(_ step: RecipeStep) -> String? {
        guard step.kind != .type else { return nil }
        return safeLabel(step.text)
    }

    private static func safeLabel(_ text: String?) -> String? {
        guard var label = text?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        guard !PrivacyRules.isSensitiveText(label), !PIIDetector.containsHighConfidencePII(label) else { return nil }
        label = PIIDetector.redact(label, includeNames: false, highConfidenceOnly: false).redacted
        label = label.replacingOccurrences(of: #"\b[A-Za-z0-9_\-]{24,}\b"#, with: "<TOKEN>", options: .regularExpression)
        label = label.replacingOccurrences(of: #"\b\d{7,}\b"#, with: "<NUMBER>", options: .regularExpression)
        label = label.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !looksLikeOpaqueSecret(label) else { return nil }
        if label.count > 72 {
            label = String(label.prefix(69)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }
        return label
    }

    private static func looksLikeOpaqueSecret(_ label: String) -> Bool {
        let stripped = label.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard stripped.count >= 20 else { return false }
        let scalarSet = CharacterSet(charactersIn: stripped)
        let tokenSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return tokenSet.isSuperset(of: scalarSet) && !stripped.contains(" ")
    }

    private static func recoveryValue(named key: String, in text: String) -> String? {
        let pattern = #"(?i)\b"# + NSRegularExpression.escapedPattern(for: key) + #"\s*[:=]\s*(.+?)(?=\s+[A-Za-z_][A-Za-z0-9_.-]*\s*[:=]|[,;|]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        return safeLabel(ns.substring(with: match.range(at: 1)))
    }
}

private protocol CustomKeyConvertible {
    var uniqueKey: String { get }
}

extension TrajectoryCheck: CustomKeyConvertible {
    fileprivate var uniqueKey: String { "\(source.rawValue)|\(label.lowercased())|\(requiredTerms.joined(separator: ","))" }
}

extension TrajectoryCorrection: CustomKeyConvertible {
    fileprivate var uniqueKey: String { "\(source.rawValue)|\(failureKind.lowercased())|\(correction.lowercased())" }
}
