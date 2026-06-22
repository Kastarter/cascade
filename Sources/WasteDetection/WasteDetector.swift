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
    /// When the workflow was last observed — lets the UI date the card and pick
    /// a nearby rewind frame as visual evidence.
    public let lastSeenAt: Date

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
        signature: String,
        lastSeenAt: Date = Date()
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
        self.lastSeenAt = lastSeenAt
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
        maxResults: Int = 5,
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil
    ) -> [DetectedWaste] {
        // Oldest → newest; ignore anything in a sensitive app defensively. Scroll
        // BURSTS collapse to one gesture first — eight wheel ticks while reading
        // are one movement, not eight automatable steps (they were inflating both
        // the detected "workflows" and the minutes-saved math).
        let events = Self.collapsingScrollBursts(
            inputEvents
                .filter { !PrivacyRules.isSensitive(appName: $0.appName, bundleIdentifier: $0.bundleIdentifier, windowTitle: $0.windowTitle) }
                .sorted { $0.capturedAt < $1.capturedAt }
        )
        guard events.count >= minRunLength * 2 else { return [] }

        // The "surface" an event happened on: the web app inside the browser when one
        // is identifiable (Gmail, Notion…), else the macOS app. Detecting by surface
        // is what makes two web apps in the SAME browser distinct workflows instead of
        // both collapsing into "Chrome". Default (nil resolver) = the app itself.
        let surface: (InputEvent) -> String = { webAppIdentity?($0) ?? $0.appName }
        let tokens = events.map { Self.token($0, surface: surface($0)) }
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
            // Process candidates in a STABLE order — Swift dictionary iteration is
            // per-process random, which made both the chosen set and the output
            // flaky run to run. Strongest first: most occurrences, then earliest,
            // then lexicographic, so the result is fully deterministic.
            let ordered = starts.sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                let lo = lhs.value.min() ?? 0, ro = rhs.value.min() ?? 0
                if lo != ro { return lo < ro }
                return lhs.key < rhs.key
            }
            for (_, indices) in ordered {
                // Re-check `consumed` as we go, not just when `starts` was built: a
                // longer pass OR an earlier candidate THIS pass may already own some
                // of these events. Without this, two overlapping shapes both emit and
                // the same activity is counted into two cards.
                let free = indices.sorted().filter { start in
                    !(start..<start + length).contains(where: { consumed.contains($0) })
                }
                let nonOverlapping = Self.nonOverlapping(free, length: length)
                guard nonOverlapping.count >= 2 else { continue }
                let representativeStart = nonOverlapping.max()!
                let instance = Array(events[representativeStart..<representativeStart + length])
                // A workflow is something an agent can DO for you, and that
                // means STRUCTURE: clicks on UI elements and command shortcuts.
                // Plain typing, bare editing keys (Delete, Return, arrows), and
                // scrolling are content editing — "Delete · Delete · type" is
                // someone fixing a sentence, and nobody wants an agent that
                // re-presses Delete for them. The same bar gates the intentional
                // `waste(fromInstance:)` path — one rule, one place.
                guard Self.isAutomatableInstance(instance) else { continue }
                let allOccurrences = nonOverlapping.map { Array(events[$0..<$0 + length]) }
                results.append(makeWaste(instance: instance, occurrences: nonOverlapping.count, contexts: contexts, surface: surface, allOccurrences: allOccurrences))
                for start in nonOverlapping {
                    for index in start..<start + length { consumed.insert(index) }
                }
            }
        }

        // Rank by a composite score, not raw total-seconds: a frequent, time-saving,
        // long-and-cohesive, recent routine beats a loose or stale one. `now` is read
        // once so the ordering is internally consistent.
        let now = Date()
        return results
            .sorted { lhs, rhs in
                let l = Self.rankingScore(lhs, now: now), r = Self.rankingScore(rhs, now: now)
                if l != r { return l > r }
                return lhs.signature < rhs.signature
            }
            .prefix(maxResults)
            .map { $0 }
    }

    /// Orders detected workflows by genuine worth, replacing a raw total-seconds sort
    /// (which ignored length, recency, and routine quality). Combines the signals the
    /// RPM/task-mining literature converges on:
    ///   • ROI        = occurrences × seconds-per-run  (frequency × time saved)
    ///   • cohesion   = meaningful-step count          (Leno: the best single ranker;
    ///                  with contiguous mining this is length — it sharpens once
    ///                  gap-tolerant mining lands and the gap term becomes non-zero)
    ///   • recency    = hyperbolic decay on `lastSeenAt` (this morning > last week;
    ///                  hyperbolic, not exponential, so an old routine fades without
    ///                  underflowing to an unordered zero)
    ///   • data-transfer boost: a copy in one app pasted into another is the canonical
    ///                  automatable routine (Leno) — nudge it up.
    /// Pure + unit-pinned (asserts the ordering properties, not magic numbers).
    static func rankingScore(_ waste: DetectedWaste, now: Date) -> Double {
        let roi = Double(waste.occurrences) * Double(max(1, waste.estimatedSecondsPerRun))
        let cohesion = Double(waste.recipe.steps.count { $0.kind != .activateApp && $0.kind != .scroll })
        let lengthBoost = 1.0 + 0.15 * cohesion
        let ageDays = max(0, now.timeIntervalSince(waste.lastSeenAt) / 86_400)
        let recency = 1.0 / (1.0 + ageDays / 7.0)            // ~half weight at one week
        let transferBoost = hasCrossAppCopyPaste(waste.recipe.steps) ? 1.5 : 1.0
        return roi * lengthBoost * recency * transferBoost
    }

    /// True when the recipe copies in one app and pastes in another — the strongest
    /// "this is a real, automatable routine" signal in the literature.
    static func hasCrossAppCopyPaste(_ steps: [RecipeStep]) -> Bool {
        guard let copy = steps.first(where: { $0.kind == .key && $0.key?.lowercased() == "c" && ($0.modifiers.contains("command") || $0.modifiers.contains("control")) }),
              let paste = steps.first(where: { $0.kind == .key && $0.key?.lowercased() == "v" && ($0.modifiers.contains("command") || $0.modifiers.contains("control")) })
        else { return false }
        return copy.order < paste.order && copy.appName != paste.appName
    }

    /// Turns ONE recorded instance — an arbitrary bracketed time range — into a
    /// `DetectedWaste`, the reusable entry point behind every *intentional*
    /// agent-creation front door (Teach-once, a Reel selection). It filters
    /// sensitive apps, collapses scroll bursts, and applies the SAME
    /// intent/structural guard `detect` uses, so a range that is only scrolling or
    /// typing returns `nil` ("nothing repeatable here yet") instead of a junk
    /// recipe. `occurrences` is 1 for a single demonstration; `surface` defaults to
    /// the app itself (pass a web-identity resolver to name by web app).
    public func waste(
        fromInstance events: [InputEvent],
        contexts: [RecordedContext],
        occurrences: Int = 1,
        surface: (@Sendable (InputEvent) -> String?)? = nil
    ) -> DetectedWaste? {
        let instance = Self.collapsingScrollBursts(
            events
                .filter { !PrivacyRules.isSensitive(appName: $0.appName, bundleIdentifier: $0.bundleIdentifier, windowTitle: $0.windowTitle) }
                .sorted { $0.capturedAt < $1.capturedAt }
        )
        guard Self.isAutomatableInstance(instance) else { return nil }
        let resolve: (InputEvent) -> String = { surface?($0) ?? $0.appName }
        return makeWaste(instance: instance, occurrences: max(1, occurrences), contexts: contexts, surface: resolve)
    }

    /// The instance-array positions whose `.type` value VARIES across a workflow's
    /// recorded occurrences — its parameters (AWM placeholder abstraction). A position
    /// qualifies only when EVERY occurrence has a `.type` event there (same shape) and
    /// at least two of the recorded values differ. Pure + unit-pinned. Empty for fewer
    /// than two occurrences (a single demo can't reveal what changes).
    static func variableTypePositions(_ occurrences: [[InputEvent]]) -> Set<Int> {
        guard occurrences.count >= 2, let length = occurrences.first?.count else { return [] }
        var variable = Set<Int>()
        for position in 0..<length {
            let cells = occurrences.compactMap { $0.indices.contains(position) ? $0[position] : nil }
            guard cells.count == occurrences.count, cells.allSatisfy({ $0.kind == .type }) else { continue }
            let values = Set(cells.map { ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) })
            if values.count >= 2 { variable.insert(position) }
        }
        return variable
    }

    // MARK: - Recipe construction

    private func makeWaste(instance: [InputEvent], occurrences: Int, contexts: [RecordedContext], surface: (InputEvent) -> String, allOccurrences: [[InputEvent]] = []) -> DetectedWaste {
        // Which positions hold a typed value that CHANGES across the recorded
        // occurrences — those are parameters, not fixed content (B5/AWM). Empty for
        // the single-demonstration (Teach-once) path, which has no occurrences to diff.
        let variablePositions = Self.variableTypePositions(allOccurrences)
        var steps: [RecipeStep] = []
        var order = 0
        var lastApp: String?
        for (position, event) in instance.enumerated() {
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
                ocrAnchor: Self.ocrAnchor(for: event, contexts: contexts),
                targetDescriptor: event.targetDescriptor,
                isParameter: variablePositions.contains(position)
            ))
            order += 1
        }

        // Real macOS apps drive routing (browser → background sandbox) and replay
        // (activateApp opens the browser). The SURFACE — the web app when there is one
        // — names the card and keys the signature, so the user sees "Gmail", not
        // "Chrome", and two web apps in one browser are two distinct agents.
        let apps = Self.orderedDistinct(instance.map(\.appName))
        let surfaces = Self.orderedDistinct(instance.map(surface))
        let span = instance.last!.capturedAt.timeIntervalSince(instance.first!.capturedAt)
        let perRun = max(instance.count, Int(span.rounded()))
        return DetectedWaste(
            title: Self.title(apps: surfaces, steps: steps),
            apps: apps,
            occurrences: occurrences,
            estimatedSecondsPerRun: perRun,
            estimatedTotalSeconds: perRun * occurrences,
            recipe: AgentRecipe(steps: steps),
            evidence: instance.map(\.id),
            confidence: min(0.95, 0.5 + Double(occurrences) * 0.12),
            signature: instance.map { Self.token($0, surface: surface($0)) }.joined(separator: "|"),
            lastSeenAt: instance.last!.capturedAt
        )
    }

    /// A title that says what the workflow IS, not just where it happened: the
    /// recorded anchors and shortcuts become the story ("Mail: click “Send
    /// Message” → ⌘C"), and the classic copy-into-another-app shape is named
    /// outright. Falls back to the app flow only when the steps carry no story.
    static func title(apps: [String], steps: [RecipeStep]) -> String {
        // ⌘C in one app followed by ⌘V in another is the single most common
        // detected workflow — name it like a person would.
        if let copy = steps.first(where: { $0.kind == .key && $0.key?.lowercased() == "c" && $0.modifiers.contains("command") }),
           let paste = steps.first(where: { $0.kind == .key && $0.key?.lowercased() == "v" && $0.modifiers.contains("command") }),
           copy.order < paste.order, copy.appName != paste.appName {
            return "Copy from \(copy.appName) into \(paste.appName)"
        }
        // Lead with the most telling steps: anchored clicks and shortcuts.
        let meaningful = steps.filter { $0.kind != .activateApp && $0.kind != .scroll }
        let story = meaningful.prefix(3).map(\.humanLabel).joined(separator: " → ")
        if apps.count <= 1 {
            let app = apps.first ?? "an app"
            return story.isEmpty ? "Repeated steps in \(app)" : "\(app): \(String(story.prefix(64)))"
        }
        return "\(apps.joined(separator: " → ")): \(String(story.prefix(48)))"
    }

    // MARK: - Helpers

    /// The token used to compare actions for repetition. Coordinates and typed
    /// content are intentionally ignored, but a click now carries the clicked
    /// element's IDENTITY (its AX label) — clicking the same "Reply All" button
    /// across runs shares a token; clicking different buttons doesn't. This is
    /// Leno's normalized-UI model: keep CONTEXT params (element identity), drop DATA
    /// params (typed text). Before, every click in an app was the same token, so the
    /// detector couldn't tell one routine from another in that app. The label is
    /// already recorded in `InputEvent.text`; an unlabeled click degrades to the old
    /// coarse `click@app` token.
    static func token(_ event: InputEvent, surface: String) -> String {
        switch event.kind {
        case .key:
            let mods = event.modifiers.sorted().joined(separator: "+")
            return "key:\(mods)+\(event.key ?? "")@\(surface)"
        case .type:
            return "type@\(surface)"
        case .click, .doubleClick, .rightClick:
            let label = normalizedLabel(event.text)
            return label.isEmpty
                ? "\(event.kind.rawValue)@\(surface)"
                : "\(event.kind.rawValue):\(label)@\(surface)"
        case .scroll:
            return "scroll@\(surface)"
        }
    }

    /// Lowercased, whitespace-collapsed, bounded element label — so trivial casing or
    /// spacing differences don't fork the token, but distinct controls stay distinct.
    static func normalizedLabel(_ text: String?) -> String {
        guard let text else { return "" }
        return String(
            text.lowercased()
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(40)
        )
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

    /// The bar a recorded instance must clear to become an automatable workflow:
    /// ≥2 structural actions (clicks / command shortcuts) AND one intent marker —
    /// a click on a *named* element, a real shortcut, or a cross-app flow. Two
    /// anonymous clicks in a browser are reading, not a workflow. `detect` and the
    /// intentional `waste(fromInstance:)` path both gate on this — one rule, one
    /// place — so the "what's worth automating" definition can never drift between
    /// the automatic and the demonstrated routes.
    static func isAutomatableInstance(_ instance: [InputEvent]) -> Bool {
        let structuralCount = instance.count(where: isStructural)
        let hasIntentMarker = instance.contains(where: isIntentMarker)
            || Set(instance.map(\.appName)).count >= 2
        return structuralCount >= 2 && hasIntentMarker
    }

    /// Clicks and modifier shortcuts give a repetition automatable structure.
    /// Bare keys (Delete, Return, arrows, characters) and typing are content
    /// editing — they ride along in a recipe but never justify one.
    private static func isStructural(_ event: InputEvent) -> Bool {
        switch event.kind {
        case .click, .doubleClick, .rightClick:
            return true
        case .key:
            return event.modifiers.contains("command") || event.modifiers.contains("control")
        case .type, .scroll:
            return false
        }
    }

    /// Evidence the repetition is deliberate: a click on an element the recorder
    /// could NAME (its AX label), or a command shortcut. Anonymous same-app
    /// clicking is how people read.
    private static func isIntentMarker(_ event: InputEvent) -> Bool {
        switch event.kind {
        case .click, .doubleClick, .rightClick:
            return !(event.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .key:
            return event.modifiers.contains("command") || event.modifiers.contains("control")
        case .type, .scroll:
            return false
        }
    }

    /// Consecutive scrolls in the same app merge into the first one of the burst —
    /// a wheel gesture emits many events, but it is ONE user action. The chain is
    /// judged between NEIGHBORING scrolls, so a long continuous burst stays one
    /// action no matter how many seconds it lasts.
    static func collapsingScrollBursts(_ events: [InputEvent]) -> [InputEvent] {
        var out: [InputEvent] = []
        var previous: InputEvent?
        for event in events {
            defer { previous = event }
            if event.kind == .scroll,
               let previous, previous.kind == .scroll,
               previous.appName == event.appName,
               event.capturedAt.timeIntervalSince(previous.capturedAt) < 3 {
                continue
            }
            out.append(event)
        }
        return out
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
