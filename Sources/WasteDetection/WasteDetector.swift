import CascadeMemory
import Foundation

public struct RoutineQuality: Sendable, Equatable {
    public let supportScore: Double
    public let compactnessScore: Double
    public let determinismScore: Double
    public let parameterScore: Double
    public let replayabilityScore: Double
    public let privacyPenalty: Double
    public let interruptionPenalty: Double
    public let utilityScore: Double
    public let score: Double

    public init(
        supportScore: Double,
        compactnessScore: Double,
        determinismScore: Double,
        parameterScore: Double,
        replayabilityScore: Double,
        privacyPenalty: Double,
        interruptionPenalty: Double,
        utilityScore: Double,
        score: Double? = nil
    ) {
        self.supportScore = supportScore
        self.compactnessScore = compactnessScore
        self.determinismScore = determinismScore
        self.parameterScore = parameterScore
        self.replayabilityScore = replayabilityScore
        self.privacyPenalty = privacyPenalty
        self.interruptionPenalty = interruptionPenalty
        self.utilityScore = utilityScore
        self.score = score ?? (
            utilityScore
            * compactnessScore
            * determinismScore
            * replayabilityScore
            * (1.0 + 0.25 * parameterScore)
            * (1.0 - privacyPenalty)
            * (1.0 - interruptionPenalty)
        )
    }
}

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
    /// Precision/utility signals computed before LLM curation. Manual/test values
    /// may leave this nil and use the legacy score/gates.
    public let quality: RoutineQuality?

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
        lastSeenAt: Date = Date(),
        quality: RoutineQuality? = nil
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
        self.quality = quality
    }
}

/// Mines recorded input events (anchored to the screen Rewind) for **repeated
/// action sequences** — the workflows the user does over and over — and turns the
/// most valuable ones into agent recipes built from the real actions.
public struct WasteDetector: Sendable {
    private let minRunLength: Int
    private let maxRunLength: Int

    private struct RoutineCandidate: Sendable {
        let patternTokens: [String]
        let occurrences: [[InputEvent]]
        let support: Int
        let coverage: Double
        let medianGap: TimeInterval
        let surfaces: Set<String>

        init(patternTokens: [String], occurrences: [[InputEvent]], surface: (InputEvent) -> String) {
            self.patternTokens = patternTokens
            self.occurrences = occurrences
            self.support = occurrences.count
            self.coverage = Double(Set(occurrences.flatMap { $0.map(\.id) }).count)
            self.medianGap = Self.medianInterStepGap(occurrences)
            self.surfaces = Set(occurrences.flatMap { occurrence in occurrence.map(surface) })
        }

        private static func medianInterStepGap(_ occurrences: [[InputEvent]]) -> TimeInterval {
            var gaps: [TimeInterval] = []
            for occurrence in occurrences {
                guard occurrence.count >= 2 else { continue }
                for index in 1..<occurrence.count {
                    let gap = occurrence[index].capturedAt.timeIntervalSince(occurrence[index - 1].capturedAt)
                    if gap >= 0 { gaps.append(gap) }
                }
            }
            return WasteDetector.median(gaps) ?? 0
        }
    }

    public init(minRunLength: Int = 2, maxRunLength: Int = 8) {
        self.minRunLength = minRunLength
        self.maxRunLength = maxRunLength
    }

    public func detect(
        contexts: [RecordedContext],
        inputEvents: [InputEvent],
        maxResults: Int = 5,
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil,
        useEpisodeMining: Bool = true
    ) -> [DetectedWaste] {
        if useEpisodeMining {
            return detectWithEpisodeMining(
                contexts: contexts,
                inputEvents: inputEvents,
                maxResults: maxResults,
                webAppIdentity: webAppIdentity
            )
        }
        return detectContiguous(
            contexts: contexts,
            inputEvents: inputEvents,
            maxResults: maxResults,
            webAppIdentity: webAppIdentity
        )
    }

    private func detectContiguous(
        contexts: [RecordedContext],
        inputEvents: [InputEvent],
        maxResults: Int,
        webAppIdentity: (@Sendable (InputEvent) -> String?)?
    ) -> [DetectedWaste] {
        // Oldest → newest; ignore anything in a sensitive app defensively. Scroll
        // BURSTS collapse to one gesture first — eight wheel ticks while reading
        // are one movement, not eight automatable steps (they were inflating both
        // the detected "workflows" and the minutes-saved math).
        let collapsed = Self.collapsingScrollBursts(
            inputEvents
                .filter { !PrivacyRules.isSensitive(appName: $0.appName, bundleIdentifier: $0.bundleIdentifier, windowTitle: $0.windowTitle) }
                // H6: video-meeting apps are inherently noisy (mute, camera, reactions,
                // chat scrolling) and almost never hold a real automatable routine —
                // exclude them so meeting fidgeting can't fabricate "workflows".
                .filter { !Self.isNoisyApp(appName: $0.appName, bundleIdentifier: $0.bundleIdentifier) }
                .sorted { $0.capturedAt < $1.capturedAt }
        )
        guard collapsed.count >= minRunLength * 2 else { return [] }

        // The "surface" an event happened on: the web app inside the browser when one
        // is identifiable (Gmail, Notion…), else the macOS app. Detecting by surface
        // is what makes two web apps in the SAME browser distinct workflows instead of
        // both collapsing into "Chrome". Default (nil resolver) = the app itself.
        let surface: (InputEvent) -> String = { webAppIdentity?($0) ?? $0.appName }
        // H3 noise pre-filter: drop events whose token appears too few times to be part
        // of ANY repeated routine. A token seen < minSupport times can't belong to a
        // pattern with support ≥ minSupport, so this is LOSSLESS for repetition — but it
        // removes one-off strays (a misclick, an interruption) that sit BETWEEN real
        // steps, turning an interrupted routine back into a contiguous one the miner can
        // catch. (van Zelst infrequent-behavior / Tax chaotic-activity filtering.)
        let events = Self.keepingRepeatableTokens(collapsed, surface: surface, minSupport: 2)
        guard events.count >= minRunLength * 2 else { return [] }
        let tokens = events.map { Self.token($0, surface: surface($0)) }
        let n = events.count
        var consumed = Set<Int>()
        var candidates: [RoutineCandidate] = []

        // Longest repeats first; mark their indices consumed so shorter
        // sub-sequences inside them don't double-count.
        let topLength = min(maxRunLength, n / 2)
        guard topLength >= minRunLength else { return [] }
        for length in stride(from: topLength, through: minRunLength, by: -1) {
            var starts: [String: [Int]] = [:]
            var i = 0
            while i + length <= n {
                if (i..<i + length).contains(where: { consumed.contains($0) }) { i += 1; continue }
                // H4 session boundary: a real routine happens within one sitting — reject
                // a window that straddles a long idle gap (the user stepped away / moved
                // to a different task), so two unrelated stretches can't fuse into one
                // "pattern" just because they share an action shape.
                if !Self.isWithinOneSession(events, start: i, length: length) { i += 1; continue }
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
                candidates.append(RoutineCandidate(
                    patternTokens: Array(tokens[representativeStart..<representativeStart + length]),
                    occurrences: allOccurrences,
                    surface: surface
                ))
                for start in nonOverlapping {
                    for index in start..<start + length { consumed.insert(index) }
                }
            }
        }

        let results = promoteCandidates(candidates, contexts: contexts, surface: surface)
        // H5: merge near-duplicate VARIANTS of the same routine (done slightly
        // differently across runs) into one process — summing their occurrences. This
        // both rescues a real routine whose runs split across variants (neither variant
        // reaching the bar alone) and stops the feed showing the same task several times.
        let deduped = Self.mergeVariants(results)

        // Rank by a composite score, not raw total-seconds: a frequent, time-saving,
        // long-and-cohesive, recent routine beats a loose or stale one. `now` is read
        // once so the ordering is internally consistent.
        let now = Date()
        return deduped
            .sorted { lhs, rhs in
                let l = Self.rankingScore(lhs, now: now), r = Self.rankingScore(rhs, now: now)
                if l != r { return l > r }
                return lhs.signature < rhs.signature
            }
            .prefix(maxResults)
            .map { $0 }
    }

    private func detectWithEpisodeMining(
        contexts: [RecordedContext],
        inputEvents: [InputEvent],
        maxResults: Int,
        webAppIdentity: (@Sendable (InputEvent) -> String?)?
    ) -> [DetectedWaste] {
        let surface: (InputEvent) -> String = { webAppIdentity?($0) ?? $0.appName }
        let collapsed = Self.collapsingScrollBursts(
            inputEvents.sorted {
                if $0.capturedAt == $1.capturedAt { return $0.id < $1.id }
                return $0.capturedAt < $1.capturedAt
            }
        )
        let eventsByID = Dictionary(collapsed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let episodeEvents = ActionEpisodeSegmenter(maxIdleGap: Self.maxIdleGap)
            .segment(collapsed, surface: webAppIdentity)
            .map { episode in episode.eventIDs.compactMap { eventsByID[$0] } }
            .filter { $0.count >= minRunLength }
        guard episodeEvents.count >= 2 else { return [] }

        let minedEpisodes = episodeEvents.map { episode in
            episode.map { event in
                PrefixSpanMiner.Event(
                    Self.token(event, surface: surface(event)),
                    timestamp: event.capturedAt.timeIntervalSince1970
                )
            }
        }
        let miner = PrefixSpanMiner(
            minSupport: 1,
            maxPatternLength: maxRunLength,
            maxGapEvents: 3,
            maxGapSeconds: 90,
            maxSpanSeconds: Self.maxIdleGap,
            closedOnly: true
        )
        let patterns = miner.mine(episodes: minedEpisodes)
            .filter { $0.tokens.count >= minRunLength }
            .sorted { lhs, rhs in
                if lhs.tokens.count != rhs.tokens.count { return lhs.tokens.count > rhs.tokens.count }
                if lhs.support != rhs.support { return lhs.support > rhs.support }
                let lFirst = lhs.occurrenceSpans.first
                let rFirst = rhs.occurrenceSpans.first
                if lFirst?.episodeIndex != rFirst?.episodeIndex {
                    return (lFirst?.episodeIndex ?? Int.max) < (rFirst?.episodeIndex ?? Int.max)
                }
                if lFirst?.startEventIndex != rFirst?.startEventIndex {
                    return (lFirst?.startEventIndex ?? Int.max) < (rFirst?.startEventIndex ?? Int.max)
                }
                return lhs.tokens.lexicographicallyPrecedes(rhs.tokens)
            }

        var consumed = Set<EpisodeEventKey>()
        var candidates: [RoutineCandidate] = []
        for pattern in patterns {
            var localConsumed = Set<EpisodeEventKey>()
            var occurrences: [[InputEvent]] = []
            var occurrenceKeys: [[EpisodeEventKey]] = []
            for span in pattern.occurrenceSpans.sorted(by: Self.episodeSpanSort) {
                let indices = Self.matchedIndices(for: span)
                let keys = indices.map { EpisodeEventKey(episodeIndex: span.episodeIndex, eventIndex: $0) }
                guard keys.allSatisfy({ !consumed.contains($0) && !localConsumed.contains($0) }),
                      let events = Self.events(for: span, matchedIndices: indices, episodeEvents: episodeEvents),
                      events.count == pattern.tokens.count
                else { continue }
                occurrences.append(events)
                occurrenceKeys.append(keys)
                localConsumed.formUnion(keys)
            }
            guard !occurrences.isEmpty else { continue }
            let representative = occurrences.sorted(by: Self.newestOccurrenceFirst).first!
            guard Self.isAutomatableInstance(representative) else { continue }

            candidates.append(RoutineCandidate(
                patternTokens: pattern.tokens,
                occurrences: occurrences,
                surface: surface
            ))
            if occurrences.count >= 2 {
                for keys in occurrenceKeys {
                    consumed.formUnion(keys)
                }
            }
        }

        let results = promoteCandidates(candidates, contexts: contexts, surface: surface)
        let deduped = Self.mergeVariants(results)
        let now = Date()
        return deduped
            .sorted { lhs, rhs in
                let l = Self.rankingScore(lhs, now: now), r = Self.rankingScore(rhs, now: now)
                if l != r { return l > r }
                return lhs.signature < rhs.signature
            }
            .prefix(maxResults)
            .map { $0 }
    }

    private func promoteCandidates(
        _ candidates: [RoutineCandidate],
        contexts: [RecordedContext],
        surface: (InputEvent) -> String
    ) -> [DetectedWaste] {
        Self.clusterRoutineCandidates(candidates).compactMap { cluster in
            let merged = Self.mergeRoutineCandidateCluster(cluster)
            guard merged.support >= 2,
                  let representative = Self.representativeOccurrence(in: merged),
                  Self.isAutomatableInstance(representative)
            else { return nil }
            return makeWaste(
                instance: representative,
                occurrences: merged.support,
                contexts: contexts,
                surface: surface,
                allOccurrences: merged.occurrences
            )
        }
    }

    private static func clusterRoutineCandidates(
        _ candidates: [RoutineCandidate],
        threshold: Double = 0.72
    ) -> [[RoutineCandidate]] {
        var clusters: [[RoutineCandidate]] = []
        for candidate in candidates {
            if let index = clusters.firstIndex(where: { cluster in
                cluster.contains { routineCandidateSimilarity($0.patternTokens, candidate.patternTokens) >= threshold }
            }) {
                clusters[index].append(candidate)
            } else {
                clusters.append([candidate])
            }
        }
        return clusters
    }

    private static func mergeRoutineCandidateCluster(_ cluster: [RoutineCandidate]) -> RoutineCandidate {
        guard let representative = representativeCandidate(in: cluster) else {
            return RoutineCandidate(patternTokens: [], occurrences: [], surface: { $0.appName })
        }
        var seen = Set<String>()
        var seenEventIDs = Set<Int64>()
        var occurrences: [[InputEvent]] = []
        for candidate in cluster.sorted(by: routineCandidateSort) {
            for occurrence in candidate.occurrences.sorted(by: episodeOccurrenceSort) {
                let key = occurrenceIdentity(occurrence)
                let ids = Set(occurrence.map(\.id))
                guard !seen.contains(key), ids.isDisjoint(with: seenEventIDs) else { continue }
                seen.insert(key)
                seenEventIDs.formUnion(ids)
                occurrences.append(occurrence)
            }
        }
        return RoutineCandidate(
            patternTokens: representative.patternTokens,
            occurrences: occurrences,
            surface: { event in
                representative.surfaces.first(where: { $0 == event.appName }) ?? event.appName
            }
        )
    }

    private static func representativeCandidate(in cluster: [RoutineCandidate]) -> RoutineCandidate? {
        cluster.max { lhs, rhs in
            let lScore = medoidScore(lhs, in: cluster)
            let rScore = medoidScore(rhs, in: cluster)
            if lScore != rScore { return lScore < rScore }
            if lhs.patternTokens.count != rhs.patternTokens.count {
                return lhs.patternTokens.count < rhs.patternTokens.count
            }
            if lhs.support != rhs.support { return lhs.support < rhs.support }
            if lhs.medianGap != rhs.medianGap { return lhs.medianGap > rhs.medianGap }
            return lhs.patternTokens.lexicographicallyPrecedes(rhs.patternTokens)
        }
    }

    private static func representativeOccurrence(in candidate: RoutineCandidate) -> [InputEvent]? {
        candidate.occurrences.sorted(by: newestOccurrenceFirst).first
    }

    private static func medoidScore(_ candidate: RoutineCandidate, in cluster: [RoutineCandidate]) -> Double {
        guard !cluster.isEmpty else { return 0 }
        let total = cluster.reduce(0.0) { partial, other in
            partial + routineCandidateSimilarity(candidate.patternTokens, other.patternTokens)
        }
        return total / Double(cluster.count)
    }

    private static func routineCandidateSort(_ lhs: RoutineCandidate, _ rhs: RoutineCandidate) -> Bool {
        if lhs.support != rhs.support { return lhs.support > rhs.support }
        if lhs.patternTokens.count != rhs.patternTokens.count { return lhs.patternTokens.count > rhs.patternTokens.count }
        return lhs.patternTokens.lexicographicallyPrecedes(rhs.patternTokens)
    }

    private static func episodeOccurrenceSort(_ lhs: [InputEvent], _ rhs: [InputEvent]) -> Bool {
        let lFirst = lhs.first?.capturedAt ?? .distantPast
        let rFirst = rhs.first?.capturedAt ?? .distantPast
        if lFirst != rFirst { return lFirst < rFirst }
        return lhs.map(\.id).lexicographicallyPrecedes(rhs.map(\.id))
    }

    private static func occurrenceIdentity(_ occurrence: [InputEvent]) -> String {
        occurrence.map { event in
            if event.id != 0 { return "id:\(event.id)" }
            return [
                "t:\(event.capturedAt.timeIntervalSince1970)",
                "k:\(event.kind.rawValue)",
                "a:\(event.appName)",
                "x:\(event.text ?? "")",
                "key:\(event.key ?? "")"
            ].joined(separator: ";")
        }.joined(separator: "|")
    }

    private static func routineCandidateSimilarity(_ a: [String], _ b: [String]) -> Double {
        max(
            sequenceSimilarity(a, b),
            weightedTokenJaccard(a, b),
            subsequenceSimilarity(a, b)
        )
    }

    private static func weightedTokenJaccard(_ a: [String], _ b: [String]) -> Double {
        var aCounts: [String: Int] = [:]
        var bCounts: [String: Int] = [:]
        for token in a { aCounts[token, default: 0] += 1 }
        for token in b { bCounts[token, default: 0] += 1 }
        let keys = Set(aCounts.keys).union(bCounts.keys)
        let intersection = keys.reduce(0) { $0 + min(aCounts[$1] ?? 0, bCounts[$1] ?? 0) }
        let union = keys.reduce(0) { $0 + max(aCounts[$1] ?? 0, bCounts[$1] ?? 0) }
        guard union > 0 else { return 1 }
        return Double(intersection) / Double(union)
    }

    private static func subsequenceSimilarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return a.isEmpty && b.isEmpty ? 1 : 0 }
        if a.isSubsequence(of: b) || b.isSubsequence(of: a) {
            return Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        }
        return 0
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
        if let quality = waste.quality {
            return quality.score
        }
        let roi = Double(waste.occurrences) * Double(max(1, waste.estimatedSecondsPerRun))
        let cohesion = Double(waste.recipe.steps.count { $0.kind != .activateApp && $0.kind != .scroll })
        let lengthBoost = 1.0 + 0.15 * cohesion
        let ageDays = max(0, now.timeIntervalSince(waste.lastSeenAt) / 86_400)
        let recency = 1.0 / (1.0 + ageDays / 7.0)            // ~half weight at one week
        let transferBoost = hasCrossAppCopyPaste(waste.recipe.steps) ? 1.5 : 1.0
        return roi * lengthBoost * recency * transferBoost
    }

    /// Single-link clusters detected workflows whose signatures are near-duplicates
    /// (token-sequence similarity ≥ `threshold`) and collapses each cluster to ONE
    /// process: the most-complete variant as the representative, with the cluster's
    /// occurrences SUMMED (the task happened that many times, in variant forms) and
    /// evidence/last-seen combined. Fixes both the "same task surfaces as several
    /// cards" and the "real routine missed because its runs split across variants that
    /// each fell short of the bar" failures. Pure; order-stable input → stable output.
    static func mergeVariants(_ wastes: [DetectedWaste], threshold: Double = 0.8) -> [DetectedWaste] {
        var clusters: [[DetectedWaste]] = []
        for waste in wastes {
            let tokens = waste.signature.components(separatedBy: "|")
            if let index = clusters.firstIndex(where: { cluster in
                cluster.contains { sequenceSimilarity($0.signature.components(separatedBy: "|"), tokens) >= threshold }
            }) {
                clusters[index].append(waste)
            } else {
                clusters.append([waste])
            }
        }
        return clusters.map(mergeCluster)
    }

    /// Collapses a variant cluster into one `DetectedWaste`: representative = the
    /// longest signature (most complete), ties to most occurrences; occurrences summed.
    private static func mergeCluster(_ cluster: [DetectedWaste]) -> DetectedWaste {
        guard cluster.count > 1 else { return cluster[0] }
        let representative = cluster.max { lhs, rhs in
            let l = lhs.signature.components(separatedBy: "|").count
            let r = rhs.signature.components(separatedBy: "|").count
            return l != r ? l < r : lhs.occurrences < rhs.occurrences
        }!
        let totalOccurrences = cluster.reduce(0) { $0 + $1.occurrences }
        return DetectedWaste(
            id: representative.id,
            title: representative.title,
            apps: representative.apps,
            occurrences: totalOccurrences,
            estimatedSecondsPerRun: representative.estimatedSecondsPerRun,
            estimatedTotalSeconds: representative.estimatedSecondsPerRun * totalOccurrences,
            recipe: representative.recipe,
            evidence: cluster.flatMap(\.evidence),
            confidence: min(0.95, 0.5 + Double(totalOccurrences) * 0.12),
            signature: representative.signature,
            lastSeenAt: cluster.map(\.lastSeenAt).max() ?? representative.lastSeenAt,
            quality: representative.quality
        )
    }

    /// 1 − normalized Levenshtein over two token sequences: 1 = identical, 0 = fully
    /// different. The variant-merge similarity metric.
    static func sequenceSimilarity(_ a: [String], _ b: [String]) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1.0 - Double(levenshtein(a, b)) / Double(longest)
    }

    /// Classic edit-distance DP over token arrays (insert/delete/substitute = 1).
    static func levenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// True when the recipe copies in one app and pastes in another — the strongest
    /// "this is a real, automatable routine" signal in the literature. Public: the
    /// curator reads it to favour and name data-transfer routines.
    public static func hasCrossAppCopyPaste(_ steps: [RecipeStep]) -> Bool {
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

    private struct InferredParameter: Sendable {
        let position: Int
        let parameterKey: String
        let parameterKind: RecipeParameterKind
        let valueExamples: [String]
        let valueHashes: [String]
        let sourceEventIndices: [Int]
        let transform: String?
    }

    private struct TypeCell {
        let position: Int
        let identity: String
        let label: String
        let value: String
        let sourceEventIndices: [Int]
    }

    private struct TargetIdentity {
        let key: String
        let label: String
    }

    /// The instance-array positions whose `.type` value VARIES across a workflow's
    /// recorded occurrences — its parameters (AWM placeholder abstraction). Target
    /// identity wins over position: a field with a stable AX descriptor/label still
    /// matches when one occurrence has an extra click before typing. Same-index typing
    /// remains the fallback for legacy tests and unlabeled fields.
    static func variableTypePositions(_ occurrences: [[InputEvent]]) -> Set<Int> {
        Set(inferredParameters(occurrences).keys)
    }

    private static func inferredParameters(_ occurrences: [[InputEvent]]) -> [Int: InferredParameter] {
        guard occurrences.count >= 2, let representative = occurrences.first else { return [:] }
        let cellsByOccurrence = occurrences.map(typeCells)
        guard let representativeCells = cellsByOccurrence.first else { return [:] }
        var inferred: [Int: InferredParameter] = [:]

        for representativeCell in representativeCells {
            var matched: [TypeCell] = []
            for (occurrenceIndex, cells) in cellsByOccurrence.enumerated() {
                if let identityMatch = cells.first(where: { $0.identity == representativeCell.identity }) {
                    matched.append(identityMatch)
                    continue
                }
                if occurrences[occurrenceIndex].indices.contains(representativeCell.position) {
                    let event = occurrences[occurrenceIndex][representativeCell.position]
                    if event.kind == .type {
                        let fallback = TypeCell(
                            position: representativeCell.position,
                            identity: "index:\(representativeCell.position)",
                            label: representativeCell.label,
                            value: event.text ?? "",
                            sourceEventIndices: sourceEventIndices(for: representativeCell.position, in: occurrences[occurrenceIndex], value: event.text)
                        )
                        matched.append(fallback)
                    }
                }
            }

            guard matched.count == occurrences.count else { continue }
            let values = matched.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            let normalizedValues = Set(values.map(normalizedParameterValue).filter { !$0.isEmpty })
            guard normalizedValues.count >= 2 else { continue }

            let kind = classifyParameter(values)
            let key = parameterKey(from: representativeCell.label, fallbackPosition: representativeCell.position)
            inferred[representativeCell.position] = InferredParameter(
                position: representativeCell.position,
                parameterKey: key,
                parameterKind: kind,
                valueExamples: Array(Set(values.map { valueShape($0, kind: kind) })).sorted().prefix(3).map { $0 },
                valueHashes: Array(Set(values.map { AuditIdentity.hash(normalizedParameterValue($0)) })).sorted().prefix(5).map { $0 },
                sourceEventIndices: Array(Set(matched.flatMap(\.sourceEventIndices))).sorted(),
                transform: values.allSatisfy { $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) } ? nil : "trim"
            )
        }

        _ = representative
        return inferred
    }

    private static func typeCells(in occurrence: [InputEvent]) -> [TypeCell] {
        occurrence.indices.compactMap { index in
            let event = occurrence[index]
            guard event.kind == .type else { return nil }
            let identity = targetIdentity(forTypeAt: index, in: occurrence)
            return TypeCell(
                position: index,
                identity: identity.key,
                label: identity.label,
                value: event.text ?? "",
                sourceEventIndices: sourceEventIndices(for: index, in: occurrence, value: event.text)
            )
        }
    }

    private static func targetIdentity(forTypeAt index: Int, in occurrence: [InputEvent]) -> TargetIdentity {
        let event = occurrence[index]
        if let identity = targetIdentity(for: event) {
            return identity
        }
        if let priorIndex = stride(from: index - 1, through: max(0, index - 4), by: -1)
            .first(where: { occurrence.indices.contains($0) && isTargetingEvent(occurrence[$0]) }),
           let identity = targetIdentity(for: occurrence[priorIndex]) {
            return identity
        }
        if let window = event.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !window.isEmpty {
            let label = String(window.prefix(48))
            return TargetIdentity(key: "window:\(normalizedParameterValue(label))@\(event.appName.lowercased())", label: label)
        }
        return TargetIdentity(key: "index:\(index)", label: "field \(index + 1)")
    }

    private static func targetIdentity(for event: InputEvent) -> TargetIdentity? {
        if let descriptor = event.targetDescriptor?.trimmingCharacters(in: .whitespacesAndNewlines), !descriptor.isEmpty {
            if let decoded = AXTargetDescriptorV2.decode(descriptor) {
                let label = decoded.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = [decoded.role, decoded.identifier, decoded.container, label.isEmpty ? nil : label]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !parts.isEmpty {
                    return TargetIdentity(key: "target:\(normalizedParameterValue(parts.joined(separator: " ")))", label: label.isEmpty ? "field" : label)
                }
            }
            return TargetIdentity(key: "target:\(normalizedParameterValue(descriptor))", label: "field")
        }
        guard isTargetingEvent(event) else { return nil }
        let label = normalizedLabel(event.text)
        if !label.isEmpty {
            return TargetIdentity(key: "label:\(label)@\(event.appName.lowercased())", label: label)
        }
        return nil
    }

    private static func isTargetingEvent(_ event: InputEvent) -> Bool {
        switch event.kind {
        case .click, .doubleClick, .rightClick:
            return event.targetDescriptor?.isEmpty == false || normalizedLabel(event.text).isEmpty == false
        case .type, .key, .scroll:
            return false
        }
    }

    private static func sourceEventIndices(for position: Int, in occurrence: [InputEvent], value: String?) -> [Int] {
        guard position > 0 else { return [] }
        let normalizedValue = normalizedParameterValue(value ?? "")
        var sourceIndices: [Int] = []
        for index in 0..<position {
            let event = occurrence[index]
            if isCopyShortcut(event) || isTargetingEvent(event) {
                sourceIndices.append(index)
                continue
            }
            if !normalizedValue.isEmpty,
               let text = event.text,
               normalizedParameterValue(text) == normalizedValue {
                sourceIndices.append(index)
            }
        }
        return Array(sourceIndices.suffix(4))
    }

    private static func isCopyShortcut(_ event: InputEvent) -> Bool {
        guard event.kind == .key, ["c", "x"].contains(event.key?.lowercased() ?? "") else { return false }
        let modifiers = event.modifiers.map { $0.lowercased() }
        return modifiers.contains("command") || modifiers.contains("control")
    }

    private static func isPasteShortcut(_ event: InputEvent) -> Bool {
        guard event.kind == .key, event.key?.lowercased() == "v" else { return false }
        let modifiers = event.modifiers.map { $0.lowercased() }
        return modifiers.contains("command") || modifiers.contains("control")
    }

    private static func dataflowParameters(in occurrence: [InputEvent]) -> [Int: InferredParameter] {
        var inferred: [Int: InferredParameter] = [:]
        var latestCopyIndex: Int?
        for index in occurrence.indices {
            let event = occurrence[index]
            if isCopyShortcut(event) {
                latestCopyIndex = index
                continue
            }
            guard isPasteShortcut(event),
                  let copyIndex = latestCopyIndex,
                  copyIndex < index
            else { continue }
            let copyEvent = occurrence[copyIndex]
            guard copyEvent.appName != event.appName || copyEvent.bundleIdentifier != event.bundleIdentifier else { continue }
            inferred[index] = InferredParameter(
                position: index,
                parameterKey: dataflowParameterKey(copyIndex: copyIndex, pasteIndex: index, in: occurrence),
                parameterKind: .freeText,
                valueExamples: ["freeText:clipboard"],
                valueHashes: [],
                sourceEventIndices: [copyIndex],
                transform: nil
            )
        }
        return inferred
    }

    private static func dataflowParameterKey(copyIndex: Int, pasteIndex: Int, in occurrence: [InputEvent]) -> String {
        if let destination = nearbyTargetIdentity(before: pasteIndex, in: occurrence, matchingAppOf: occurrence[pasteIndex]) {
            return parameterKey(from: destination.label, fallbackPosition: pasteIndex)
        }
        if let source = nearbyTargetIdentity(before: copyIndex, in: occurrence, matchingAppOf: occurrence[copyIndex]) {
            return parameterKey(from: source.label, fallbackPosition: pasteIndex)
        }
        return "copied_value"
    }

    private static func nearbyTargetIdentity(before index: Int, in occurrence: [InputEvent], matchingAppOf event: InputEvent) -> TargetIdentity? {
        guard index > 0 else { return nil }
        for candidateIndex in stride(from: index - 1, through: max(0, index - 4), by: -1) {
            guard occurrence.indices.contains(candidateIndex) else { continue }
            let candidate = occurrence[candidateIndex]
            guard candidate.appName == event.appName, isTargetingEvent(candidate) else { continue }
            if let identity = targetIdentity(for: candidate) {
                return identity
            }
        }
        return nil
    }

    private static func parameterKey(from label: String, fallbackPosition: Int) -> String {
        let cleaned = label
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? "field_\(fallbackPosition + 1)" : String(cleaned.prefix(48))
    }

    private static func classifyParameter(_ values: [String]) -> RecipeParameterKind {
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return .freeText }
        if cleaned.allSatisfy({ matches($0, #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, caseInsensitive: true) }) { return .email }
        if cleaned.allSatisfy({ matches($0, #"^(https?://|www\.)\S+$"#, caseInsensitive: true) }) { return .url }
        if cleaned.allSatisfy({ matches($0, #"^(\~|/|[A-Za-z]:\\|\.{1,2}/).+"#) }) { return .filePath }
        if cleaned.allSatisfy({ matches($0, #"(\$|€|£|¥)\s*\d|\d[\d,]*(\.\d{2})?\s*(usd|cad|eur|gbp)"#, caseInsensitive: true) }) { return .currency }
        if cleaned.allSatisfy({ matches($0, #"^\d{4}-\d{1,2}-\d{1,2}$|^\d{1,2}/\d{1,2}/\d{2,4}$|^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"#, caseInsensitive: true) }) { return .date }
        if cleaned.allSatisfy({ matches($0, #"^[A-Z]*[-_ ]?\d[\dA-Z._ -]*$"#, caseInsensitive: true) }) { return .number }
        if cleaned.allSatisfy({ matches($0, #"^[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3}$"#) }) { return .personName }
        return .freeText
    }

    private static func matches(_ value: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
        let options: String.CompareOptions = caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]
        return value.range(of: pattern, options: options) != nil
    }

    private static func valueShape(_ value: String, kind: RecipeParameterKind) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .freeText || PrivacyRules.isSensitiveText(trimmed) {
            return "\(kind.rawValue):\(InputEventSanitizer.typedShape(for: trimmed))"
        }
        let shape = trimmed.map { character -> Character in
            if character.isNumber { return "0" }
            if character.isLetter { return "A" }
            if character.isWhitespace { return " " }
            return character
        }
        return "\(kind.rawValue):\(String(shape).prefix(48))"
    }

    private static func normalizedParameterValue(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Recipe construction

    private func makeWaste(instance: [InputEvent], occurrences: Int, contexts: [RecordedContext], surface: (InputEvent) -> String, allOccurrences: [[InputEvent]] = []) -> DetectedWaste {
        // Which positions hold a typed value that CHANGES across the recorded
        // occurrences — those are parameters, not fixed content (B5/AWM). Empty for
        // the single-demonstration (Teach-once) path, which has no occurrences to diff.
        var parameterMetadata = Self.inferredParameters(allOccurrences)
        for (position, parameter) in Self.dataflowParameters(in: instance) where parameterMetadata[position] == nil {
            parameterMetadata[position] = parameter
        }
        var steps: [RecipeStep] = []
        var eventPositionToStepOrder: [Int: Int] = [:]
        var order = 0
        var lastApp: String?
        for (position, event) in instance.enumerated() {
            if event.appName != lastApp {
                steps.append(RecipeStep(order: order, kind: .activateApp, appName: event.appName, bundleIdentifier: event.bundleIdentifier))
                order += 1
                lastApp = event.appName
            }
            let parameter = parameterMetadata[position]
            let sourceStepIDs = parameter?.sourceEventIndices.compactMap { eventPositionToStepOrder[$0] } ?? []
            eventPositionToStepOrder[position] = order
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
                isParameter: parameter != nil,
                parameterKey: parameter?.parameterKey,
                parameterKind: parameter?.parameterKind,
                valueExamples: parameter?.valueExamples ?? [],
                valueHashes: parameter?.valueHashes ?? [],
                sourceStepIDs: sourceStepIDs,
                transform: parameter?.transform
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
        let qualityOccurrences = allOccurrences.isEmpty ? [instance] : allOccurrences
        let quality = Self.routineQuality(
            instance: instance,
            occurrences: qualityOccurrences,
            steps: steps,
            support: occurrences,
            estimatedSecondsPerRun: perRun
        )
        return DetectedWaste(
            title: Self.title(apps: surfaces, steps: steps),
            apps: apps,
            occurrences: occurrences,
            estimatedSecondsPerRun: perRun,
            estimatedTotalSeconds: perRun * occurrences,
            recipe: AgentRecipe(steps: steps),
            evidence: Self.evidenceIDs(instance: instance, allOccurrences: allOccurrences),
            confidence: min(0.95, 0.5 + Double(occurrences) * 0.12),
            signature: instance.map { Self.token($0, surface: surface($0)) }.joined(separator: "|"),
            lastSeenAt: instance.last!.capturedAt,
            quality: quality
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

    private static func routineQuality(
        instance: [InputEvent],
        occurrences: [[InputEvent]],
        steps: [RecipeStep],
        support: Int,
        estimatedSecondsPerRun: Int
    ) -> RoutineQuality {
        let spans = occurrences.compactMap { occurrence -> TimeInterval? in
            guard let first = occurrence.first?.capturedAt, let last = occurrence.last?.capturedAt else { return nil }
            return max(0, last.timeIntervalSince(first))
        }
        let gaps = occurrences.flatMap { occurrence -> [TimeInterval] in
            guard occurrence.count >= 2 else { return [] }
            return (1..<occurrence.count).map {
                max(0, occurrence[$0].capturedAt.timeIntervalSince(occurrence[$0 - 1].capturedAt))
            }
        }
        let medianGap = median(gaps) ?? 0
        let medianSpan = median(spans) ?? 0
        let compactness = clamp(1.0 / (1.0 + medianGap / 30.0 + medianSpan / 300.0))
        let supportScore = clamp(Double(support) / 5.0)

        let meaningfulEvents = instance.filter { $0.kind != .scroll }
        let deterministic = meaningfulEvents.map(determinismContribution).reduce(0, +)
        let determinism = meaningfulEvents.isEmpty ? 0 : clamp(deterministic / Double(meaningfulEvents.count))

        let parameterSteps = steps.filter(\.isParameter)
        let typeSteps = steps.filter { $0.kind == .type }
        let typedParameterRatio = typeSteps.isEmpty ? 0 : Double(parameterSteps.count) / Double(typeSteps.count)
        let kindBonus = parameterSteps.map { parameterKindScore($0.parameterKind) }.reduce(0, +)
        let parameterScore = parameterSteps.isEmpty ? 0 : clamp((typedParameterRatio + kindBonus / Double(parameterSteps.count)) / 2)

        let replayability = clamp(0.45 + 0.45 * determinism + (hasCrossAppCopyPaste(steps) ? 0.10 : 0))
        let privacyPenalty = routinePrivacyPenalty(instance: instance, steps: steps)
        let interruptionPenalty = routineInterruptionPenalty(gaps: gaps, occurrenceCount: occurrences.count, instance: instance)
        let activePerRunCap = max(instance.count, instance.count * 8)
        let observedSeconds = Double(max(1, support * min(estimatedSecondsPerRun, activePerRunCap)))
        let transferBoost = hasCrossAppCopyPaste(steps) ? 1.25 : 1.0
        let utility = min(2.0, max(0.20, observedSeconds / 90.0)) * transferBoost * (1.0 + 0.25 * supportScore)

        return RoutineQuality(
            supportScore: supportScore,
            compactnessScore: compactness,
            determinismScore: determinism,
            parameterScore: parameterScore,
            replayabilityScore: replayability,
            privacyPenalty: privacyPenalty,
            interruptionPenalty: interruptionPenalty,
            utilityScore: utility
        )
    }

    private static func determinismContribution(_ event: InputEvent) -> Double {
        switch event.kind {
        case .key:
            return (event.modifiers.contains("command") || event.modifiers.contains("control")) ? 1.0 : 0.20
        case .click, .doubleClick, .rightClick:
            if event.targetDescriptor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return 1.0 }
            if normalizedLabel(event.text).isEmpty == false { return 0.85 }
            return 0.35
        case .type:
            return 0.50
        case .scroll:
            return 0.10
        }
    }

    private static func parameterKindScore(_ kind: RecipeParameterKind?) -> Double {
        switch kind {
        case .date, .currency, .number, .email, .url, .filePath:
            return 1.0
        case .personName:
            return 0.75
        case .freeText:
            return 0.30
        case nil:
            return 0
        }
    }

    private static func routinePrivacyPenalty(instance: [InputEvent], steps: [RecipeStep]) -> Double {
        var penalty = 0.0
        for event in instance {
            if PrivacyRules.isSensitive(appName: event.appName, bundleIdentifier: event.bundleIdentifier, windowTitle: event.windowTitle) {
                penalty += 0.45
            }
            if let text = event.text, PrivacyRules.isSensitiveText(text) {
                penalty += 0.30
            }
        }
        for step in steps where step.isParameter {
            if step.parameterKind == .freeText { penalty += 0.20 }
            if let key = step.parameterKey, PrivacyRules.isSensitiveText(key) { penalty += 0.25 }
        }
        return clamp(penalty)
    }

    private static func routineInterruptionPenalty(gaps: [TimeInterval], occurrenceCount: Int, instance: [InputEvent]) -> Double {
        guard !gaps.isEmpty else { return 0 }
        let longGapRatio = Double(gaps.count { $0 > 45 }) / Double(gaps.count)
        let scrollRatio = Double(instance.count { $0.kind == .scroll }) / Double(max(1, instance.count))
        let noisyRatio = Double(instance.count { isNoisyApp(appName: $0.appName, bundleIdentifier: $0.bundleIdentifier) }) / Double(max(1, instance.count))
        let supportPenalty = occurrenceCount <= 1 ? 0.20 : 0
        return clamp(longGapRatio * 0.55 + scrollRatio * 0.25 + noisyRatio * 0.35 + supportPenalty)
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
    public static func actionToken(_ event: InputEvent, surface: String) -> String {
        token(event, surface: surface)
    }

    public static func normalizedActionLabel(_ text: String?) -> String {
        normalizedLabel(text)
    }

    public static func isNoisySurface(appName: String, bundleIdentifier: String?) -> Bool {
        isNoisyApp(appName: appName, bundleIdentifier: bundleIdentifier)
    }

    public static func isAutomatableActionInstance(_ instance: [InputEvent]) -> Bool {
        isAutomatableInstance(instance)
    }

    public static func collapsedActionEvents(_ events: [InputEvent]) -> [InputEvent] {
        collapsingScrollBursts(events)
    }

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

    /// Video-meeting apps whose input is overwhelmingly noise (mute/camera/chat),
    /// excluded from routine mining. Conservative on purpose — matched by bundle id or
    /// an exact app name, NOT a loose substring, so unrelated apps aren't swept in, and
    /// it deliberately omits chat apps like Slack which CAN hold real workflows.
    static func isNoisyApp(appName: String, bundleIdentifier: String?) -> Bool {
        let noisyBundles = ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
                            "com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "com.google.meet"]
        if let bundle = bundleIdentifier?.lowercased(), noisyBundles.contains(where: { bundle == $0 }) {
            return true
        }
        let noisyNames: Set<String> = ["zoom", "zoom.us", "microsoft teams", "webex",
                                       "cisco webex meetings", "google meet"]
        return noisyNames.contains(appName.lowercased())
    }

    /// A step gap longer than this means a new sitting/task, not a pause within one
    /// routine — real routine steps are seconds apart (UiPath disregards actions >10min
    /// after their predecessor; this is tighter so a distraction ends the routine).
    static let maxIdleGap: TimeInterval = 180

    /// Whether the window `events[start ..< start+length]` is one continuous session —
    /// no internal step gap exceeds `maxGap`. A window that spans a big idle gap is two
    /// tasks, not one routine, and must not become a detected pattern. Pure.
    static func isWithinOneSession(_ events: [InputEvent], start: Int, length: Int, maxGap: TimeInterval = maxIdleGap) -> Bool {
        guard length >= 2, start >= 0, start + length <= events.count else { return true }
        for k in (start + 1)..<(start + length) where events[k].capturedAt.timeIntervalSince(events[k - 1].capturedAt) > maxGap {
            return false
        }
        return true
    }

    /// Drops events whose token appears fewer than `minSupport` times in the stream.
    /// PROVABLY lossless for repetition: a pattern with support ≥ minSupport needs each
    /// of its tokens present in ≥ minSupport occurrences, so a token below that count
    /// cannot be part of any such pattern — only one-off noise (a misclick, a stray
    /// interruption) is removed, which lets an interrupted routine close back up into a
    /// contiguous one. Pure given `surface`.
    static func keepingRepeatableTokens(_ events: [InputEvent], surface: (InputEvent) -> String, minSupport: Int = 2) -> [InputEvent] {
        var counts: [String: Int] = [:]
        for event in events { counts[token(event, surface: surface(event)), default: 0] += 1 }
        return events.filter { (counts[token($0, surface: surface($0))] ?? 0) >= minSupport }
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

    private struct EpisodeEventKey: Hashable {
        let episodeIndex: Int
        let eventIndex: Int
    }

    private static func matchedIndices(for span: PrefixSpanMiner.OccurrenceSpan) -> [Int] {
        span.matchedEventIndices.isEmpty
            ? Array(span.startEventIndex...span.endEventIndex)
            : span.matchedEventIndices
    }

    private static func events(
        for span: PrefixSpanMiner.OccurrenceSpan,
        matchedIndices: [Int],
        episodeEvents: [[InputEvent]]
    ) -> [InputEvent]? {
        guard episodeEvents.indices.contains(span.episodeIndex) else { return nil }
        let episode = episodeEvents[span.episodeIndex]
        guard matchedIndices.allSatisfy({ episode.indices.contains($0) }) else { return nil }
        return matchedIndices.map { episode[$0] }
    }

    private static func episodeSpanSort(_ lhs: PrefixSpanMiner.OccurrenceSpan, _ rhs: PrefixSpanMiner.OccurrenceSpan) -> Bool {
        if lhs.episodeIndex != rhs.episodeIndex { return lhs.episodeIndex < rhs.episodeIndex }
        if lhs.startEventIndex != rhs.startEventIndex { return lhs.startEventIndex < rhs.startEventIndex }
        return lhs.endEventIndex < rhs.endEventIndex
    }

    private static func newestOccurrenceFirst(_ lhs: [InputEvent], _ rhs: [InputEvent]) -> Bool {
        let lLast = lhs.last?.capturedAt ?? .distantPast
        let rLast = rhs.last?.capturedAt ?? .distantPast
        if lLast != rLast { return lLast > rLast }
        return lhs.map(\.id).lexicographicallyPrecedes(rhs.map(\.id))
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

    private static func evidenceIDs(instance: [InputEvent], allOccurrences: [[InputEvent]]) -> [Int64] {
        let source = allOccurrences.isEmpty ? [instance] : allOccurrences
        var seen = Set<Int64>()
        var ids: [Int64] = []
        for id in source.flatMap({ $0.map(\.id) }) where !seen.contains(id) {
            seen.insert(id)
            ids.append(id)
        }
        return ids
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

    static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func clamp(_ value: Double, lower: Double = 0, upper: Double = 1) -> Double {
        min(upper, max(lower, value))
    }
}

private extension Array where Element: Equatable {
    func isSubsequence(of other: [Element]) -> Bool {
        guard !isEmpty else { return true }
        var cursor = startIndex
        for element in other where self[cursor] == element {
            formIndex(after: &cursor)
            if cursor == endIndex { return true }
        }
        return false
    }
}
