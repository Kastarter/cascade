import CascadeMemory
import Foundation

/// What Cascade detected the user repeating — a candidate to turn into an agent.
/// The `recipe` is built from the user's *actual* recorded actions, so a deployed
/// agent reproduces the task the way the user does it.
public struct DetectedWaste: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let apps: [String]
    public let occurrences: Int
    public let estimatedSecondsPerRun: Int
    public let estimatedTotalSeconds: Int
    public let recipe: AgentRecipe
    public let evidence: [Int64]
    public let confidence: Double
    /// Stable key (the action-token sequence) used to dedupe an agent built from
    /// this workflow.
    public let signature: String

    public init(
        id: UUID = UUID(),
        title: String,
        apps: [String],
        occurrences: Int,
        estimatedSecondsPerRun: Int,
        estimatedTotalSeconds: Int,
        recipe: AgentRecipe,
        evidence: [Int64],
        confidence: Double,
        signature: String
    ) {
        self.id = id
        self.title = title
        self.apps = apps
        self.occurrences = occurrences
        self.estimatedSecondsPerRun = estimatedSecondsPerRun
        self.estimatedTotalSeconds = estimatedTotalSeconds
        self.recipe = recipe
        self.evidence = evidence
        self.confidence = confidence
        self.signature = signature
    }
}

/// Mines recorded input events (anchored to the screen Rewind) for **repeated
/// action sequences** — the workflows the user does over and over — and turns the
/// most valuable ones into agent recipes built from the real actions.
public struct WasteDetector: Sendable {
    private let minRunLength: Int
    private let maxRunLength: Int

    public init(minRunLength: Int = 2, maxRunLength: Int = 8) {
        self.minRunLength = minRunLength
        self.maxRunLength = maxRunLength
    }

    public func detect(
        contexts: [RecordedContext],
        inputEvents: [InputEvent],
        maxResults: Int = 5
    ) -> [DetectedWaste] {
        // Oldest → newest; ignore anything in a sensitive app defensively.
        let events = inputEvents
            .filter { !PrivacyRules.isSensitive(appName: $0.appName, bundleIdentifier: $0.bundleIdentifier, windowTitle: $0.windowTitle) }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard events.count >= minRunLength * 2 else { return [] }

        let tokens = events.map(Self.token)
        let n = events.count
        var consumed = Set<Int>()
        var results: [DetectedWaste] = []

        // Longest repeats first; mark their indices consumed so shorter
        // sub-sequences inside them don't double-count.
        let topLength = min(maxRunLength, n / 2)
        guard topLength >= minRunLength else { return [] }
        for length in stride(from: topLength, through: minRunLength, by: -1) {
            var starts: [String: [Int]] = [:]
            var i = 0
            while i + length <= n {
                if (i..<i + length).contains(where: { consumed.contains($0) }) { i += 1; continue }
                let key = tokens[i..<i + length].joined(separator: "|")
                starts[key, default: []].append(i)
                i += 1
            }
            for (_, indices) in starts {
                let nonOverlapping = Self.nonOverlapping(indices.sorted(), length: length)
                guard nonOverlapping.count >= 2 else { continue }
                let representativeStart = nonOverlapping.max()!
                let instance = Array(events[representativeStart..<representativeStart + length])
                results.append(makeWaste(instance: instance, occurrences: nonOverlapping.count, contexts: contexts))
                for start in nonOverlapping {
                    for index in start..<start + length { consumed.insert(index) }
                }
            }
        }

        return results
            .sorted { lhs, rhs in
                if lhs.estimatedTotalSeconds != rhs.estimatedTotalSeconds {
                    return lhs.estimatedTotalSeconds > rhs.estimatedTotalSeconds
                }
                return lhs.signature < rhs.signature
            }
            .prefix(maxResults)
            .map { $0 }
    }

    // MARK: - Recipe construction

    private func makeWaste(instance: [InputEvent], occurrences: Int, contexts: [RecordedContext]) -> DetectedWaste {
        var steps: [RecipeStep] = []
        var order = 0
        var lastApp: String?
        for event in instance {
            if event.appName != lastApp {
                steps.append(RecipeStep(order: order, kind: .activateApp, appName: event.appName, bundleIdentifier: event.bundleIdentifier))
                order += 1
                lastApp = event.appName
            }
            steps.append(RecipeStep(
                order: order,
                kind: Self.recipeKind(event.kind),
                x: event.x,
                y: event.y,
                text: event.text,
                key: event.key,
                modifiers: event.modifiers,
                appName: event.appName,
                bundleIdentifier: event.bundleIdentifier,
                windowTitleHint: event.windowTitle,
                ocrAnchor: Self.ocrAnchor(for: event, contexts: contexts)
            ))
            order += 1
        }

        let apps = Self.orderedDistinct(instance.map(\.appName))
        let span = instance.last!.capturedAt.timeIntervalSince(instance.first!.capturedAt)
        let perRun = max(instance.count, Int(span.rounded()))
        let title = apps.count <= 1
            ? "Repeated steps in \(apps.first ?? "an app")"
            : "Workflow: " + apps.joined(separator: " → ")
        return DetectedWaste(
            title: title,
            apps: apps,
            occurrences: occurrences,
            estimatedSecondsPerRun: perRun,
            estimatedTotalSeconds: perRun * occurrences,
            recipe: AgentRecipe(steps: steps),
            evidence: instance.map(\.id),
            confidence: min(0.95, 0.5 + Double(occurrences) * 0.12),
            signature: instance.map(Self.token).joined(separator: "|")
        )
    }

    // MARK: - Helpers

    /// The token used to compare actions for repetition. Coordinates and typed
    /// content are intentionally ignored — what repeats is the *shape* (kind +
    /// app + shortcut), not the exact pixels or text.
    private static func token(_ event: InputEvent) -> String {
        switch event.kind {
        case .key:
            let mods = event.modifiers.sorted().joined(separator: "+")
            return "key:\(mods)+\(event.key ?? "")@\(event.appName)"
        case .type:
            return "type@\(event.appName)"
        default:
            return "\(event.kind.rawValue)@\(event.appName)"
        }
    }

    private static func recipeKind(_ kind: InputEventKind) -> RecipeStepKind {
        switch kind {
        case .click: .click
        case .doubleClick: .doubleClick
        case .rightClick: .rightClick
        case .type: .type
        case .key: .key
        case .scroll: .scroll
        }
    }

    /// Greedily selects non-overlapping occurrences (each at least `length` apart).
    private static func nonOverlapping(_ starts: [Int], length: Int) -> [Int] {
        var chosen: [Int] = []
        var lastEnd = -1
        for start in starts where start > lastEnd {
            chosen.append(start)
            lastEnd = start + length - 1
        }
        return chosen
    }

    /// The clicked element's own AX label is the strongest anchor; the recorded
    /// screen context is the fallback. Contexts must come from the SAME app as the
    /// event and pass the privacy gate — an anchor from an unrelated (or sensitive)
    /// frame would re-target the replayed click at the wrong thing.
    private static func ocrAnchor(for event: InputEvent, contexts: [RecordedContext]) -> String? {
        if let label = event.text, !label.trimmingCharacters(in: .whitespaces).isEmpty,
           !PrivacyRules.isSensitiveText(label),
           event.kind == .click || event.kind == .doubleClick || event.kind == .rightClick {
            return String(label.prefix(60))
        }
        let nearest = contexts
            .filter {
                $0.capturedAt <= event.capturedAt
                    && !PrivacyRules.isSensitive(appName: $0.appName, bundleIdentifier: $0.bundleIdentifier, windowTitle: $0.windowTitle)
                    && ($0.bundleIdentifier == event.bundleIdentifier || $0.appName == event.appName)
            }
            .max(by: { $0.capturedAt < $1.capturedAt })
        if let title = nearest?.windowTitle, !title.isEmpty { return String(title.prefix(60)) }
        if let ocr = nearest?.ocrText,
           let line = ocr.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(line.prefix(60))
        }
        return event.windowTitle
    }

    private static func orderedDistinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}
