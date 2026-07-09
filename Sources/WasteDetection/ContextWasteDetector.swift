import CascadeMemory
import Foundation

public struct ContextWasteQuality: Sendable, Equatable {
    public let supportScore: Double
    public let durationScore: Double
    public let semanticStabilityScore: Double
    public let actionabilityScore: Double
    public let privacyPenalty: Double
    public let noisePenalty: Double
    public let score: Double

    public init(
        supportScore: Double,
        durationScore: Double,
        semanticStabilityScore: Double,
        actionabilityScore: Double,
        privacyPenalty: Double,
        noisePenalty: Double,
        score: Double? = nil
    ) {
        self.supportScore = supportScore
        self.durationScore = durationScore
        self.semanticStabilityScore = semanticStabilityScore
        self.actionabilityScore = actionabilityScore
        self.privacyPenalty = privacyPenalty
        self.noisePenalty = noisePenalty
        self.score = score ?? (
            supportScore
            * (0.45 + 0.55 * durationScore)
            * semanticStabilityScore
            * actionabilityScore
            * (1.0 - privacyPenalty)
            * (1.0 - noisePenalty)
        )
    }
}

public struct ContextWasteEntity: Sendable, Equatable {
    public let kind: WorkGraphEntityKind
    public let canonicalValue: String
    public let displayName: String

    public init(kind: WorkGraphEntityKind, canonicalValue: String, displayName: String) {
        self.kind = kind
        self.canonicalValue = canonicalValue
        self.displayName = displayName
    }
}

public struct ContextWasteParameter: Sendable, Equatable {
    public let role: String
    public let sourceKind: String
    public let count: Int
    public let valueShapes: [String]
    public let valueHashes: [String]

    public init(
        role: String,
        sourceKind: String,
        count: Int,
        valueShapes: [String] = [],
        valueHashes: [String] = []
    ) {
        self.role = role
        self.sourceKind = sourceKind
        self.count = count
        self.valueShapes = valueShapes
        self.valueHashes = valueHashes
    }
}

public enum ContextWasteAgentFeasibility: String, Sendable, Equatable {
    case linkedRecipe
    case needsDemo
    case goalOnlyCandidate
}

public struct ContextWasteCandidate: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let apps: [String]
    public let occurrences: Int
    public let estimatedSecondsPerRun: Int
    public let estimatedTotalSeconds: Int
    public let evidenceContextIDs: [Int64]
    public let sessionIDs: [Int64]
    public let signature: String
    public let startedAt: Date
    public let endedAt: Date
    public let lastSeenAt: Date
    public let snippets: [String]
    public let entities: [ContextWasteEntity]
    public let processTerms: [String]
    public let parameters: [ContextWasteParameter]
    public let quality: ContextWasteQuality
    public let suggestedGoal: String
    public let linkedActionSignature: String?
    public let linkedActionWaste: DetectedWaste?

    public var feasibility: ContextWasteAgentFeasibility {
        linkedActionSignature == nil ? .goalOnlyCandidate : .linkedRecipe
    }

    public init(
        id: UUID = UUID(),
        title: String,
        apps: [String],
        occurrences: Int,
        estimatedSecondsPerRun: Int,
        estimatedTotalSeconds: Int,
        evidenceContextIDs: [Int64],
        sessionIDs: [Int64],
        signature: String,
        startedAt: Date,
        endedAt: Date,
        lastSeenAt: Date,
        snippets: [String],
        entities: [ContextWasteEntity],
        processTerms: [String] = [],
        parameters: [ContextWasteParameter] = [],
        quality: ContextWasteQuality,
        suggestedGoal: String,
        linkedActionSignature: String? = nil,
        linkedActionWaste: DetectedWaste? = nil
    ) {
        self.id = id
        self.title = title
        self.apps = apps
        self.occurrences = occurrences
        self.estimatedSecondsPerRun = estimatedSecondsPerRun
        self.estimatedTotalSeconds = estimatedTotalSeconds
        self.evidenceContextIDs = evidenceContextIDs
        self.sessionIDs = sessionIDs
        self.signature = signature
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastSeenAt = lastSeenAt
        self.snippets = snippets
        self.entities = entities
        self.processTerms = processTerms
        self.parameters = parameters
        self.quality = quality
        self.suggestedGoal = suggestedGoal
        self.linkedActionSignature = linkedActionSignature
        self.linkedActionWaste = linkedActionWaste
    }

    public func linked(to actionSignature: String?) -> ContextWasteCandidate {
        ContextWasteCandidate(
            id: id,
            title: title,
            apps: apps,
            occurrences: occurrences,
            estimatedSecondsPerRun: estimatedSecondsPerRun,
            estimatedTotalSeconds: estimatedTotalSeconds,
            evidenceContextIDs: evidenceContextIDs,
            sessionIDs: sessionIDs,
            signature: signature,
            startedAt: startedAt,
            endedAt: endedAt,
            lastSeenAt: lastSeenAt,
            snippets: snippets,
            entities: entities,
            processTerms: processTerms,
            parameters: parameters,
            quality: quality,
            suggestedGoal: suggestedGoal,
            linkedActionSignature: actionSignature,
            linkedActionWaste: linkedActionWaste?.signature == actionSignature ? linkedActionWaste : nil
        )
    }

    public func linked(to actionWaste: DetectedWaste?) -> ContextWasteCandidate {
        ContextWasteCandidate(
            id: id,
            title: title,
            apps: apps,
            occurrences: occurrences,
            estimatedSecondsPerRun: estimatedSecondsPerRun,
            estimatedTotalSeconds: estimatedTotalSeconds,
            evidenceContextIDs: evidenceContextIDs,
            sessionIDs: sessionIDs,
            signature: signature,
            startedAt: startedAt,
            endedAt: endedAt,
            lastSeenAt: lastSeenAt,
            snippets: snippets,
            entities: entities,
            processTerms: processTerms,
            parameters: parameters,
            quality: quality,
            suggestedGoal: suggestedGoal,
            linkedActionSignature: actionWaste?.signature,
            linkedActionWaste: actionWaste
        )
    }
}

public struct ContextWasteReport: Sendable, Equatable {
    public let rawContextCount: Int
    public let safeContextCount: Int
    public let privacyRejectedCount: Int
    public let sessionCount: Int
    public let refinedEpisodeCount: Int
    public let groupedCount: Int
    public let promotedCount: Int
    public let passiveNoiseRejectedCount: Int
    public let sensitiveRejectedCount: Int
    public let linkedRecipeCount: Int
    public let needsDemoCount: Int
    public let finalCount: Int
    public let results: [ContextWasteCandidate]

    public init(
        rawContextCount: Int,
        safeContextCount: Int,
        privacyRejectedCount: Int = 0,
        sessionCount: Int,
        refinedEpisodeCount: Int? = nil,
        groupedCount: Int,
        promotedCount: Int? = nil,
        passiveNoiseRejectedCount: Int = 0,
        sensitiveRejectedCount: Int = 0,
        linkedRecipeCount: Int? = nil,
        needsDemoCount: Int? = nil,
        finalCount: Int,
        results: [ContextWasteCandidate]
    ) {
        self.rawContextCount = rawContextCount
        self.safeContextCount = safeContextCount
        self.privacyRejectedCount = privacyRejectedCount
        self.sessionCount = sessionCount
        self.refinedEpisodeCount = refinedEpisodeCount ?? sessionCount
        self.groupedCount = groupedCount
        self.promotedCount = promotedCount ?? finalCount
        self.passiveNoiseRejectedCount = passiveNoiseRejectedCount
        self.sensitiveRejectedCount = sensitiveRejectedCount
        self.linkedRecipeCount = linkedRecipeCount ?? results.filter { $0.feasibility == .linkedRecipe }.count
        self.needsDemoCount = needsDemoCount ?? 0
        self.finalCount = finalCount
        self.results = results
    }

    public static var empty: ContextWasteReport {
        ContextWasteReport(rawContextCount: 0, safeContextCount: 0, sessionCount: 0, groupedCount: 0, finalCount: 0, results: [])
    }

    public func replacingResults(_ results: [ContextWasteCandidate]) -> ContextWasteReport {
        ContextWasteReport(
            rawContextCount: rawContextCount,
            safeContextCount: safeContextCount,
            privacyRejectedCount: privacyRejectedCount,
            sessionCount: sessionCount,
            refinedEpisodeCount: refinedEpisodeCount,
            groupedCount: groupedCount,
            promotedCount: promotedCount,
            passiveNoiseRejectedCount: passiveNoiseRejectedCount,
            sensitiveRejectedCount: sensitiveRejectedCount,
            linkedRecipeCount: results.filter { $0.feasibility == .linkedRecipe }.count,
            needsDemoCount: needsDemoCount,
            finalCount: results.count,
            results: results
        )
    }
}

public struct ContextWasteDetector: Sendable {
    public struct Options: Sendable, Equatable {
        public let minOccurrences: Int
        public let minTotalSeconds: Int
        public let strongWasteSeconds: Int
        public let minSessionSeconds: Int
        public let minActionabilityScore: Double

        public init(
            minOccurrences: Int = 3,
            minTotalSeconds: Int = 45 * 60,
            strongWasteSeconds: Int = 3 * 60 * 60,
            minSessionSeconds: Int = 60,
            minActionabilityScore: Double = 0.30
        ) {
            self.minOccurrences = minOccurrences
            self.minTotalSeconds = minTotalSeconds
            self.strongWasteSeconds = strongWasteSeconds
            self.minSessionSeconds = minSessionSeconds
            self.minActionabilityScore = minActionabilityScore
        }
    }

    private struct SessionSummary: Sendable {
        let episode: Episode
        let contexts: [RecordedContext]
        let processKey: String
        let processVocabulary: ProcessVocabulary
        let processTerms: [String]
        let fieldRoles: [String]
        let entityRoleSlots: [String]
        let instanceBindings: [ProcessInstanceBinding]
        let semanticText: String
        let semanticVector: [Float]?
        let snippets: [String]
        let entities: [ContextWasteEntity]
        let actionability: Double
        let passiveBrowsing: Bool

        var durationSeconds: Int {
            max(0, Int(episode.duration.rounded()))
        }
    }

    private struct ProcessVocabulary: Sendable, Equatable {
        let surface: String
        let verbs: [String]
        let objects: [String]
        let fields: [String]
        let entityRoles: [String]
        let terms: [String]

        var hasWorkVocabulary: Bool {
            let strongObjects = objects.filter { strongObjectTerms.contains($0) }
            return (verbs.count + objects.count >= 2)
                || fields.count >= 2
                || !strongObjects.isEmpty && (verbs.count + fields.count + entityRoles.count >= 1)
        }
    }

    private struct ProcessInstanceBinding: Sendable, Equatable {
        let role: String
        let sourceKind: String
        let rawValue: String
        let valueShape: String
        let valueHash: String
    }

    private struct StructuredEvidence: Sendable, Equatable {
        var fieldRoles: [String] = []
        var tableHeaders: [String] = []
        var labelTerms: [String] = []
        var bindings: [ProcessInstanceBinding] = []
    }

    private struct ContextEpisodeProfile: Sendable, Equatable {
        var processTerms: Set<String>
        var fieldRoles: Set<String>
        var parameterRoles: Set<String>
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func detect(contexts: [RecordedContext], maxResults: Int = 5) -> [ContextWasteCandidate] {
        detectReport(contexts: contexts, maxResults: maxResults).results
    }

    public func detectReport(contexts: [RecordedContext], maxResults: Int = 5) -> ContextWasteReport {
        let safe = contexts
            .filter(Self.isUsableContext)
            .sorted { $0.capturedAt < $1.capturedAt }
        let rejected = contexts.count - safe.count
        let sensitiveRejected = contexts.filter {
            !$0.safeToShow
                || !$0.safeToSummarize
                || PrivacyRules.isSensitive($0)
                || WasteDetector.isNoisySurface(appName: $0.appName, bundleIdentifier: $0.bundleIdentifier)
        }.count
        let episodes = SessionSegmenter.segment(safe)
        let contextsByID = Dictionary(safe.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let taskEpisodes = Self.crossAppTaskEpisodes(from: episodes, contextsByID: contextsByID)
        let refinedEpisodes = Self.refinedEpisodes(from: taskEpisodes, contextsByID: contextsByID)
        let summaries = refinedEpisodes.compactMap { episode -> SessionSummary? in
            let episodeContexts = episode.momentIDs.compactMap { contextsByID[$0] }
            return Self.summarize(episode: episode, contexts: episodeContexts, options: options)
        }
        let grouped = Self.semanticClusters(from: summaries)
        let promoted = grouped
            .compactMap { Self.candidate(from: $0, options: options) }
            .sorted { lhs, rhs in
                if lhs.quality.score != rhs.quality.score { return lhs.quality.score > rhs.quality.score }
                if lhs.estimatedTotalSeconds != rhs.estimatedTotalSeconds { return lhs.estimatedTotalSeconds > rhs.estimatedTotalSeconds }
                return lhs.signature < rhs.signature
            }
        let candidates = promoted.prefix(maxResults).map { $0 }

        return ContextWasteReport(
            rawContextCount: contexts.count,
            safeContextCount: safe.count,
            privacyRejectedCount: rejected,
            sessionCount: episodes.count,
            refinedEpisodeCount: refinedEpisodes.count,
            groupedCount: grouped.count,
            promotedCount: promoted.count,
            passiveNoiseRejectedCount: summaries.filter { $0.passiveBrowsing }.count,
            sensitiveRejectedCount: sensitiveRejected,
            finalCount: candidates.count,
            results: candidates
        )
    }

    private static func isUsableContext(_ context: RecordedContext) -> Bool {
        guard context.safeToShow,
              context.safeToSummarize,
              !PrivacyRules.isSensitive(context),
              !WasteDetector.isNoisySurface(appName: context.appName, bundleIdentifier: context.bundleIdentifier)
        else { return false }
        return [context.windowTitle, context.ocrText, context.metadataJSON]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { !$0.isEmpty }
    }

    private static func crossAppTaskEpisodes(
        from episodes: [Episode],
        contextsByID: [Int64: RecordedContext]
    ) -> [Episode] {
        let ordered = episodes.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id < $1.id
        }
        var merged: [Episode] = []
        var currentEpisodes: [Episode] = []
        var currentContexts: [RecordedContext] = []
        var currentProfile: ContextEpisodeProfile?

        func flush() {
            guard let firstEpisode = currentEpisodes.first,
                  let firstContext = currentContexts.first,
                  let lastContext = currentContexts.last
            else { return }
            merged.append(Episode(
                id: firstEpisode.id,
                appName: firstEpisode.appName,
                bundleIdentifier: firstEpisode.bundleIdentifier,
                title: SessionSegmenter.representativeTitle(currentContexts),
                startedAt: firstContext.capturedAt,
                endedAt: lastContext.capturedAt,
                momentIDs: currentEpisodes.flatMap(\.momentIDs)
            ))
            currentEpisodes = []
            currentContexts = []
            currentProfile = nil
        }

        for episode in ordered {
            let episodeContexts = episode.momentIDs.compactMap { contextsByID[$0] }.sorted { $0.capturedAt < $1.capturedAt }
            let profile = refinementProfile(for: episodeContexts)
            if let previousEpisode = currentEpisodes.last,
               let existingProfile = currentProfile,
               shouldBreakCrossAppTask(previousEpisode, episode, existingProfile, profile) {
                flush()
            }
            currentEpisodes.append(episode)
            currentContexts.append(contentsOf: episodeContexts)
            currentProfile = currentProfile.map { mergedProfile($0, profile) } ?? profile
        }
        flush()
        return merged
    }

    private static func shouldBreakCrossAppTask(
        _ previous: Episode,
        _ next: Episode,
        _ lhs: ContextEpisodeProfile,
        _ rhs: ContextEpisodeProfile
    ) -> Bool {
        let gap = next.startedAt.timeIntervalSince(previous.endedAt)
        guard gap <= 120 else { return true }
        if (previous.bundleIdentifier ?? previous.appName) == (next.bundleIdentifier ?? next.appName) {
            return false
        }
        let fieldScore = jaccard(lhs.fieldRoles, rhs.fieldRoles)
        let roleScore = jaccard(lhs.parameterRoles, rhs.parameterRoles)
        let termOverlap = lhs.processTerms.intersection(rhs.processTerms)
        let strongTermOverlap = termOverlap.contains { strongObjectTerms.contains($0) || processVerbTerms.contains($0) }
        return fieldScore < 0.34 && roleScore < 0.34 && !strongTermOverlap
    }

    private static func mergedProfile(_ lhs: ContextEpisodeProfile, _ rhs: ContextEpisodeProfile) -> ContextEpisodeProfile {
        ContextEpisodeProfile(
            processTerms: lhs.processTerms.union(rhs.processTerms),
            fieldRoles: lhs.fieldRoles.union(rhs.fieldRoles),
            parameterRoles: lhs.parameterRoles.union(rhs.parameterRoles)
        )
    }

    private static func refinedEpisodes(
        from episodes: [Episode],
        contextsByID: [Int64: RecordedContext]
    ) -> [Episode] {
        episodes.flatMap { episode -> [Episode] in
            let contexts = episode.momentIDs.compactMap { contextsByID[$0] }.sorted { $0.capturedAt < $1.capturedAt }
            guard contexts.count > 1 else { return [episode] }
            var refined: [Episode] = []
            var current: [RecordedContext] = []
            var previousProfile: ContextEpisodeProfile?

            func flush() {
                guard let first = current.first, let last = current.last else { return }
                refined.append(Episode(
                    id: first.id,
                    appName: first.appName,
                    bundleIdentifier: first.bundleIdentifier,
                    title: SessionSegmenter.representativeTitle(current),
                    startedAt: first.capturedAt,
                    endedAt: last.capturedAt,
                    momentIDs: current.map(\.id)
                ))
                current = []
            }

            for context in contexts {
                let profile = refinementProfile(for: context)
                if !current.isEmpty,
                   let previousProfile,
                   shouldSplitContextEpisode(previousProfile, profile) {
                    flush()
                }
                current.append(context)
                previousProfile = profile
            }
            flush()
            return refined
        }
    }

    private static func refinementProfile(for context: RecordedContext) -> ContextEpisodeProfile {
        refinementProfile(for: [context])
    }

    private static func refinementProfile(for contexts: [RecordedContext]) -> ContextEpisodeProfile {
        let structured = structuredEvidence(from: contexts)
        let entities = contextWasteEntities(from: contexts.flatMap { WorkGraphExtractor.mentions(in: $0) })
        let bindings = uniqueBindings(
            instanceBindings(from: entities)
                + structured.bindings
                + contexts.flatMap { heuristicBindings(in: $0.windowTitle ?? "", sourceKind: "title") }
                + contexts.flatMap { heuristicBindings(in: $0.ocrText ?? "", sourceKind: "ocr") }
                + contexts.flatMap { metadataBindings(from: $0.metadataJSON) }
        )
        let instanceTokens = instanceValueTokens(from: bindings)
        let processText = processEvidenceText(contexts: contexts, structured: structured)
        return ContextEpisodeProfile(
            processTerms: Set(topProcessTokens(in: processText, excluding: instanceTokens, limit: 14)),
            fieldRoles: Set(structured.fieldRoles.map(normalizedRoleToken)),
            parameterRoles: Set(bindings.map(\.role))
        )
    }

    private static func shouldSplitContextEpisode(
        _ lhs: ContextEpisodeProfile,
        _ rhs: ContextEpisodeProfile
    ) -> Bool {
        if lhs.processTerms.isEmpty || rhs.processTerms.isEmpty { return false }
        let tokenScore = jaccard(lhs.processTerms, rhs.processTerms)
        let fieldScore = jaccard(lhs.fieldRoles, rhs.fieldRoles)
        let roleScore = jaccard(lhs.parameterRoles, rhs.parameterRoles)
        let strongOverlap = lhs.processTerms.intersection(rhs.processTerms).contains { strongObjectTerms.contains($0) || processVerbTerms.contains($0) }
        let lhsDiscriminators = discriminatingTerms(in: lhs.processTerms)
        let rhsDiscriminators = discriminatingTerms(in: rhs.processTerms)
        if !lhsDiscriminators.isEmpty,
           !rhsDiscriminators.isEmpty,
           lhsDiscriminators.isDisjoint(with: rhsDiscriminators) {
            return true
        }
        if fieldScore >= 0.50 || roleScore >= 0.50 { return false }
        if !strongOverlap && tokenScore < 0.30 { return true }
        return tokenScore < 0.24 && fieldScore < 0.50 && roleScore < 0.50
    }

    private static func summarize(
        episode: Episode,
        contexts: [RecordedContext],
        options: Options
    ) -> SessionSummary? {
        guard episode.duration >= TimeInterval(options.minSessionSeconds),
              !contexts.isEmpty else { return nil }

        let mentions = contexts.flatMap { WorkGraphExtractor.mentions(in: $0) }
        let entities = contextWasteEntities(from: mentions)
        let appIdentity = (episode.bundleIdentifier ?? episode.appName).lowercased()
        let structured = structuredEvidence(from: contexts)
        let bindings = uniqueBindings(
            instanceBindings(from: entities)
                + structured.bindings
                + contexts.flatMap { heuristicBindings(in: $0.windowTitle ?? "", sourceKind: "title") }
                + contexts.flatMap { heuristicBindings(in: $0.ocrText ?? "", sourceKind: "ocr") }
                + contexts.flatMap { metadataBindings(from: $0.metadataJSON) }
        )
        let instanceTokens = instanceValueTokens(from: bindings)
        let processText = processEvidenceText(contexts: contexts, structured: structured)
        let processTerms = topProcessTokens(in: processText, excluding: instanceTokens, limit: 18)
        let entityRoleSlots = semanticEntityRoleKeys(from: entities, bindings: bindings)
        let vocabulary = processVocabulary(
            appIdentity: appIdentity,
            processTerms: processTerms,
            fieldRoles: structured.fieldRoles,
            entityRoleSlots: entityRoleSlots
        )
        guard vocabulary.hasWorkVocabulary else { return nil }
        let snippets = safeEvidenceSnippets(contexts: contexts, vocabulary: vocabulary, bindings: bindings)
        let processKey = processKey(vocabulary: vocabulary)
        let actionability = actionabilityScore(vocabulary: vocabulary, bindings: bindings, appName: episode.appName)
        let passiveBrowsing = isPassiveBrowsing(appName: episode.appName, vocabulary: vocabulary, bindings: bindings)
        let semanticText = semanticProcessText(
            vocabulary: vocabulary,
            fieldRoles: structured.fieldRoles,
            bindings: bindings
        )

        return SessionSummary(
            episode: episode,
            contexts: contexts,
            processKey: processKey,
            processVocabulary: vocabulary,
            processTerms: processTerms,
            fieldRoles: structured.fieldRoles,
            entityRoleSlots: entityRoleSlots,
            instanceBindings: bindings,
            semanticText: semanticText,
            semanticVector: LocalSemanticVector.vector(for: semanticText),
            snippets: Array(snippets),
            entities: entities,
            actionability: actionability,
            passiveBrowsing: passiveBrowsing
        )
    }

    private static func semanticClusters(from summaries: [SessionSummary]) -> [[SessionSummary]] {
        let ordered = summaries.sorted {
            if $0.episode.startedAt != $1.episode.startedAt { return $0.episode.startedAt < $1.episode.startedAt }
            return $0.episode.id < $1.episode.id
        }
        var clusters: [[SessionSummary]] = []
        for summary in ordered {
            var bestIndex: Int?
            var bestScore = 0.0
            for (index, cluster) in clusters.enumerated() {
                let score = clusterCompatibility(summary, cluster)
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            if let bestIndex, bestScore >= 0.58 {
                clusters[bestIndex].append(summary)
            } else {
                clusters.append([summary])
            }
        }
        return clusters
    }

    private static func clusterCompatibility(_ summary: SessionSummary, _ cluster: [SessionSummary]) -> Double {
        cluster.map { semanticSimilarity(summary, $0) }.max() ?? 0
    }

    private static func semanticSimilarity(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Double {
        let lhsTerms = Set(lhs.processTerms.map(canonicalProcessToken))
        let rhsTerms = Set(rhs.processTerms.map(canonicalProcessToken))
        let lhsDiscriminators = discriminatingTerms(in: lhsTerms)
        let rhsDiscriminators = discriminatingTerms(in: rhsTerms)
        if !lhsDiscriminators.isEmpty,
           !rhsDiscriminators.isEmpty,
           lhsDiscriminators.isDisjoint(with: rhsDiscriminators) {
            return 0
        }
        let tokenScore = jaccard(lhsTerms, rhsTerms)
        let fieldScore = jaccard(Set(lhs.fieldRoles.map(normalizedRoleToken)), Set(rhs.fieldRoles.map(normalizedRoleToken)))
        let lhsRoles = Set(lhs.instanceBindings.map(\.role) + lhs.entityRoleSlots)
        let rhsRoles = Set(rhs.instanceBindings.map(\.role) + rhs.entityRoleSlots)
        let roleScore = jaccard(lhsRoles, rhsRoles)
        let verbScore = jaccard(Set(lhs.processVocabulary.verbs), Set(rhs.processVocabulary.verbs))
        let objectScore = jaccard(Set(lhs.processVocabulary.objects), Set(rhs.processVocabulary.objects))
        let vectorScore: Double
        if let lhsVector = lhs.semanticVector,
           let rhsVector = rhs.semanticVector,
           lhsVector.count == rhsVector.count {
            vectorScore = max(0, Double(LocalSemanticVector.cosine(lhsVector, rhsVector)))
        } else {
            vectorScore = 0
        }
        let surfaceScore = surfaceFamily(lhs.processVocabulary.surface) == surfaceFamily(rhs.processVocabulary.surface) ? 0.06 : 0.0
        let processScore = max(tokenScore, vectorScore)
        return min(
            1.0,
            processScore * 0.42
                + fieldScore * 0.20
                + roleScore * 0.16
                + verbScore * 0.10
                + objectScore * 0.12
                + surfaceScore
        )
    }

    private static func discriminatingTerms(in terms: Set<String>) -> Set<String> {
        let normalized = Set(terms.map(canonicalProcessToken))
        let hits = normalized.intersection(discriminatingProcessTerms)
        guard !hits.isEmpty else { return [] }
        if hits.contains("invoice") {
            return ["invoice"]
        }
        if hits.contains("ticket") {
            return ["ticket"]
        }
        if hits.contains("email") || hits.contains("reply") {
            return ["email"]
        }
        if hits.contains("export") || hits.contains("report") || hits.contains("spreadsheet") {
            return ["export"]
        }
        if hits.contains("approve") || hits.contains("approval") || hits.contains("submit") {
            return ["approval"]
        }
        return hits
    }

    private static func candidate(from sessions: [SessionSummary], options: Options) -> ContextWasteCandidate? {
        let sorted = sessions.sorted { $0.episode.startedAt < $1.episode.startedAt }
        let sessionOccurrences = sorted.count
        let totalSeconds = sorted.map(\.durationSeconds).reduce(0, +)
        let recordSupport = repeatedRecordSupport(in: sorted)
        let occurrences = sessionOccurrences >= 2 ? sessionOccurrences : max(sessionOccurrences, recordSupport)
        let crossesRepeatBar = occurrences >= options.minOccurrences
        let crossesDurationBar = totalSeconds >= options.minTotalSeconds
        let crossesStrongWasteBar = totalSeconds >= options.strongWasteSeconds
        guard sessionOccurrences >= 2 || (crossesStrongWasteBar && recordSupport >= options.minOccurrences) else { return nil }
        guard crossesRepeatBar || crossesDurationBar || crossesStrongWasteBar else { return nil }

        let actionability = sorted.map(\.actionability).reduce(0, +) / Double(max(1, sessionOccurrences))
        guard actionability >= options.minActionabilityScore else { return nil }
        let passiveRatio = Double(sorted.count(where: \.passiveBrowsing)) / Double(max(1, sessionOccurrences))
        guard passiveRatio < 0.50 else { return nil }

        let stability = semanticStability(sorted.map(\.processTerms))
        let quality = ContextWasteQuality(
            supportScore: min(1.0, Double(occurrences) / Double(max(options.minOccurrences, 1) + 2)),
            durationScore: min(1.0, Double(totalSeconds) / Double(max(options.strongWasteSeconds, 1))),
            semanticStabilityScore: max(0.35, stability),
            actionabilityScore: actionability,
            privacyPenalty: 0,
            noisePenalty: min(0.8, passiveRatio)
        )

        let apps = unique(sorted.flatMap { $0.contexts.map(\.appName) }).sorted()
        let snippets = unique(sorted.flatMap(\.snippets)).prefix(3).map { $0 }
        let entities = uniqueEntities(sorted.flatMap(\.entities)).prefix(8).map { $0 }
        let processTerms = topTitleTokens(in: sorted.flatMap(\.processTerms), limit: 8)
        let parameters = parameterSummaries(from: sorted.flatMap(\.instanceBindings)).prefix(10).map { $0 }
        let evidence = Array(Set(sorted.flatMap { $0.episode.momentIDs })).sorted().prefix(40).map { $0 }
        let sessionIDs = sorted.map(\.episode.id)
        guard let first = sorted.first?.episode.startedAt,
              let last = sorted.last?.episode.endedAt else { return nil }
        let title = title(for: sorted, apps: apps)
        return ContextWasteCandidate(
            title: title,
            apps: apps,
            occurrences: occurrences,
            estimatedSecondsPerRun: max(1, totalSeconds / max(1, occurrences)),
            estimatedTotalSeconds: totalSeconds,
            evidenceContextIDs: evidence,
            sessionIDs: sessionIDs,
            signature: processSignature(for: sorted),
            startedAt: first,
            endedAt: last,
            lastSeenAt: last,
            snippets: Array(snippets),
            entities: Array(entities),
            processTerms: Array(processTerms),
            parameters: Array(parameters),
            quality: quality,
            suggestedGoal: suggestedGoal(title: title, apps: apps)
        )
    }

    private static func repeatedRecordSupport(in sessions: [SessionSummary]) -> Int {
        let identityRoles: Set<String> = [
            "business_object", "invoice_id", "order_id", "project", "record_name", "task_id", "ticket_id"
        ]
        let identityBindings = sessions.flatMap(\.instanceBindings).filter { identityRoles.contains($0.role) }
        let structuredBindings = identityBindings.filter { ["control", "field", "metadata", "table"].contains($0.sourceKind) }
        let bindings = structuredBindings.isEmpty ? identityBindings : structuredBindings
        guard !bindings.isEmpty else { return 0 }
        let grouped = Dictionary(grouping: bindings) { $0.role }
        return grouped.values
            .map { Set($0.map(\.valueHash)).count }
            .max() ?? 0
    }

    private static func processKey(vocabulary: ProcessVocabulary) -> String {
        [
            "context-process:v3",
            "terms=\((vocabulary.verbs + vocabulary.objects).prefix(10).map(safeSignatureToken).joined(separator: ","))",
            "fieldRolesHash=\(AuditIdentity.hash(vocabulary.fields.sorted().joined(separator: "|")))",
            "entityRolesHash=\(AuditIdentity.hash(vocabulary.entityRoles.sorted().joined(separator: "|")))",
            "surfaceFamilyHash=\(AuditIdentity.hash(surfaceFamily(vocabulary.surface)))"
        ].joined(separator: "|")
    }

    private static func processSignature(for sessions: [SessionSummary]) -> String {
        let terms = topTitleTokens(in: sessions.flatMap(\.processTerms).map(canonicalProcessToken), limit: 12)
        let fields = unique(sessions.flatMap(\.fieldRoles).map(normalizedRoleToken)).sorted()
        let parameterRoles = unique(sessions.flatMap { $0.instanceBindings.map(\.role) }).sorted()
        let entityRoles = unique(sessions.flatMap(\.entityRoleSlots)).sorted()
        let surfaceFamilies = unique(sessions.map { surfaceFamily($0.processVocabulary.surface) }).sorted()
        return [
            "context-process:v3",
            "terms=\(terms.map(safeSignatureToken).joined(separator: ","))",
            "fieldRolesHash=\(AuditIdentity.hash(fields.joined(separator: "|")))",
            "parameterRolesHash=\(AuditIdentity.hash(parameterRoles.joined(separator: "|")))",
            "entityRolesHash=\(AuditIdentity.hash(entityRoles.joined(separator: "|")))",
            "surfaceFamiliesHash=\(AuditIdentity.hash(surfaceFamilies.joined(separator: "|")))"
        ].joined(separator: "|")
    }

    private static func semanticProcessText(
        vocabulary: ProcessVocabulary,
        fieldRoles: [String],
        bindings: [ProcessInstanceBinding]
    ) -> String {
        let roleText = unique(bindings.map(\.role)).sorted().joined(separator: " ")
        let fields = unique(fieldRoles.map(normalizedRoleToken)).sorted().joined(separator: " ")
        return [
            vocabulary.verbs.joined(separator: " "),
            vocabulary.objects.joined(separator: " "),
            vocabulary.terms.joined(separator: " "),
            fields,
            vocabulary.entityRoles.joined(separator: " "),
            roleText
        ].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func safeEvidenceSnippets(
        contexts: [RecordedContext],
        vocabulary: ProcessVocabulary,
        bindings: [ProcessInstanceBinding]
    ) -> [String] {
        let evidenceHash = AuditIdentity.hash(contexts.map { context in
            "\(context.id):\(context.frameHash.map(String.init) ?? "no-frame")"
        }.joined(separator: "|"))
        let terms = (vocabulary.verbs + vocabulary.objects + vocabulary.fields)
            .prefix(10)
            .map(safeSignatureToken)
            .joined(separator: ",")
        let roles = unique(bindings.map(\.role) + vocabulary.entityRoles)
            .sorted()
            .prefix(10)
            .joined(separator: ",")
        let shapeHash = AuditIdentity.hash(unique(bindings.map(\.valueShape)).sorted().joined(separator: "|"))
        let parts = [
            "evidenceHash=\(evidenceHash)",
            "contexts=\(contexts.count)",
            "terms=\(terms.isEmpty ? "none" : terms)",
            "roles=\(roles.isEmpty ? "none" : roles)",
            "shapeHash=\(shapeHash)"
        ]
        return [parts.joined(separator: " ")]
    }

    private static func contextWasteEntities(from mentions: [WorkGraphMention]) -> [ContextWasteEntity] {
        let usefulKinds: Set<WorkGraphEntityKind> = [
            .app, .window, .url, .file, .folder, .date, .person, .organization, .project, .task, .topic
        ]
        var seen = Set<String>()
        return mentions.compactMap { mention -> ContextWasteEntity? in
            guard usefulKinds.contains(mention.kind) else { return nil }
            let canonical = canonicalEntityValue(mention)
            guard !canonical.isEmpty else { return nil }
            let key = "\(mention.kind.rawValue):\(canonical)"
            guard seen.insert(key).inserted else { return nil }
            let role = parameterRole(kind: mention.kind, displayName: mention.displayName, canonicalValue: canonical)
            return ContextWasteEntity(
                kind: mention.kind,
                canonicalValue: AuditIdentity.hash(key),
                displayName: role.map { "[\($0)]" } ?? "[\(safeSignatureToken(mention.kind.rawValue))]"
            )
        }
    }

    private static func canonicalEntityValue(_ mention: WorkGraphMention) -> String {
        if mention.kind == .url, let host = URL(string: mention.canonicalValue)?.host {
            return host.lowercased()
        }
        return normalizeTokenPhrase(mention.canonicalValue)
    }

    private static func semanticEntityRoleKeys(from entities: [ContextWasteEntity], bindings: [ProcessInstanceBinding]) -> [String] {
        let entityRoles = entities.compactMap(parameterRole(for:)).map { "parameter:\($0)" }
        let parameterRoles = bindings.map { "parameter:\($0.role)" }
        return Set(entityRoles + parameterRoles).sorted()
    }

    private static func instanceBindings(from entities: [ContextWasteEntity]) -> [ProcessInstanceBinding] {
        entities.compactMap { entity -> ProcessInstanceBinding? in
            guard let role = parameterRole(for: entity) else { return nil }
            let raw = entity.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? entity.canonicalValue
                : entity.displayName
            return binding(role: role, sourceKind: "entity", rawValue: raw)
        }
    }

    private static func parameterRole(for entity: ContextWasteEntity) -> String? {
        switch entity.kind {
        case .organization:
            return "business_object"
        case .project:
            return "project"
        case .person:
            return "person"
        case .task:
            return "task"
        case .date:
            return "date"
        case .file:
            return "file"
        case .folder:
            return "folder"
        case .url:
            return "url"
        case .topic:
            return looksLikeRecordIdentifier(entity.displayName) || looksLikeRecordIdentifier(entity.canonicalValue) ? "task_id" : nil
        case .app, .window, .skill, .recipe, .subgoalType, .expectedEffect:
            return nil
        }
    }

    private static func parameterRole(
        kind: WorkGraphEntityKind,
        displayName: String,
        canonicalValue: String
    ) -> String? {
        switch kind {
        case .organization:
            return "business_object"
        case .project:
            return "project"
        case .person:
            return "person"
        case .task:
            return "task"
        case .date:
            return "date"
        case .file:
            return "file"
        case .folder:
            return "folder"
        case .url:
            return "url"
        case .topic:
            return looksLikeRecordIdentifier(displayName) || looksLikeRecordIdentifier(canonicalValue) ? "task_id" : nil
        case .app, .window, .skill, .recipe, .subgoalType, .expectedEffect:
            return nil
        }
    }

    private static func instanceValueTokens(from bindings: [ProcessInstanceBinding]) -> Set<String> {
        Set(bindings.flatMap { binding in
            tokenize(binding.rawValue).filter { !actionTerms.contains($0) && !safeProcessNouns.contains($0) }
        })
    }

    private static func uniqueEntities(_ entities: [ContextWasteEntity]) -> [ContextWasteEntity] {
        var seen = Set<String>()
        return entities.filter { entity in
            seen.insert("\(entity.kind.rawValue):\(entity.canonicalValue)").inserted
        }
    }

    private static func actionabilityScore(vocabulary: ProcessVocabulary, bindings: [ProcessInstanceBinding], appName: String) -> Double {
        let actionHits = vocabulary.verbs.count
        let objectHits = vocabulary.objects.count
        let fieldHits = min(3, vocabulary.fields.count)
        let parameterHits = min(3, Set(bindings.map(\.role)).count)
        let appBonus = browserLike(appName) ? 0.0 : 0.12
        return clamp(0.12 + Double(actionHits) * 0.13 + Double(objectHits) * 0.10 + Double(fieldHits) * 0.08 + Double(parameterHits) * 0.07 + appBonus)
    }

    private static func isPassiveBrowsing(appName: String, vocabulary: ProcessVocabulary, bindings: [ProcessInstanceBinding]) -> Bool {
        guard browserLike(appName) else { return false }
        let hasPassiveToken = vocabulary.terms.contains { passiveBrowsingTerms.contains($0) }
        let hasWorkEvidence = !bindings.isEmpty || !vocabulary.fields.isEmpty || !vocabulary.objects.isEmpty
        let hasActionToken = !vocabulary.verbs.isEmpty
        return hasPassiveToken && !hasWorkEvidence && !hasActionToken
    }

    private static func processVocabulary(
        appIdentity: String,
        processTerms: [String],
        fieldRoles: [String],
        entityRoleSlots: [String]
    ) -> ProcessVocabulary {
        let fields = unique(fieldRoles.map(normalizedRoleToken).filter { !$0.isEmpty }).sorted()
        var termSeed = processTerms
        termSeed += fields.flatMap { $0.split(separator: "_").map(String.init) }
        let terms = topTitleTokens(in: termSeed, limit: 18)
        let verbs = terms.filter { processVerbTerms.contains($0) }
        let objects = terms.filter { safeProcessNouns.contains($0) && !processVerbTerms.contains($0) }
        return ProcessVocabulary(
            surface: appIdentity,
            verbs: Array(unique(verbs).prefix(8)),
            objects: Array(unique(objects).prefix(10)),
            fields: fields,
            entityRoles: entityRoleSlots.sorted(),
            terms: terms
        )
    }

    private static func processEvidenceText(contexts: [RecordedContext], structured: StructuredEvidence) -> String {
        let contextText = contexts.flatMap { context in
            [context.windowTitle, context.ocrText].compactMap { $0 }
        }
        let fieldText = structured.fieldRoles.map { $0.replacingOccurrences(of: "_", with: " ") }
        return (contextText + fieldText + structured.tableHeaders + structured.labelTerms)
            .joined(separator: " ")
    }

    private static func structuredEvidence(from contexts: [RecordedContext]) -> StructuredEvidence {
        var evidence = StructuredEvidence()
        for context in contexts {
            guard let metadataJSON = context.metadataJSON,
                  let data = metadataJSON.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            collectStructuredEvidence(root, key: nil, sourceKind: "metadata", into: &evidence)
        }
        evidence.fieldRoles = unique(evidence.fieldRoles.map(normalizedRoleToken).filter { !$0.isEmpty })
        evidence.tableHeaders = unique(evidence.tableHeaders)
        evidence.labelTerms = unique(evidence.labelTerms)
        evidence.bindings = uniqueBindings(evidence.bindings)
        return evidence
    }

    private static func collectStructuredEvidence(
        _ value: Any,
        key: String?,
        sourceKind: String,
        into evidence: inout StructuredEvidence
    ) {
        if let dictionary = value as? [String: Any] {
            if let keyValueKey = stringValue(dictionary["key"]),
               let keyValueValue = stringValue(dictionary["value"]) {
                appendFieldEvidence(key: keyValueKey, value: keyValueValue, sourceKind: "field", into: &evidence)
            }
            if let label = stringValue(dictionary["label"]),
               let value = stringValue(dictionary["value"]) {
                appendFieldEvidence(key: label, value: value, sourceKind: "control", into: &evidence)
            }
            if let rows = dictionary["rows"] as? [[Any]] {
                appendTableRows(rows, headerIndex: dictionary["header_row_index"] as? Int, into: &evidence)
            } else if let rows = dictionary["rows"] as? [[String]] {
                appendTableRows(rows.map { $0.map { $0 as Any } }, headerIndex: dictionary["header_row_index"] as? Int, into: &evidence)
            }
            if let markdownTables = dictionary["markdown_tables"] as? [String] {
                for table in markdownTables { appendDelimitedTable(table, into: &evidence) }
            }
            if let csvTables = dictionary["csv_tables"] as? [String] {
                for table in csvTables { appendDelimitedTable(table, into: &evidence) }
            }
            if let kind = stringValue(dictionary["kind"]) {
                evidence.labelTerms.append(kind)
            }
            if let text = stringValue(dictionary["text"]), let kind = stringValue(dictionary["kind"]) {
                evidence.labelTerms.append(kind)
                evidence.labelTerms.append(text)
            }
            for (nestedKey, nestedValue) in dictionary {
                collectStructuredEvidence(nestedValue, key: nestedKey, sourceKind: sourceKind, into: &evidence)
            }
            return
        }
        if let array = value as? [Any] {
            for item in array {
                collectStructuredEvidence(item, key: key, sourceKind: sourceKind, into: &evidence)
            }
            return
        }
        guard let key, let scalar = stringValue(value) else { return }
        appendFieldEvidence(key: key, value: scalar, sourceKind: sourceKind, into: &evidence)
    }

    private static func appendFieldEvidence(
        key: String,
        value: String,
        sourceKind: String,
        into evidence: inout StructuredEvidence
    ) {
        guard let role = normalizeFieldRole(key) else { return }
        evidence.fieldRoles.append(role)
        evidence.labelTerms.append(key)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !PrivacyRules.isSensitiveText(trimmed),
              !PIIDetector.containsHighConfidencePII(trimmed),
              let binding = binding(role: parameterRole(forFieldRole: role), sourceKind: sourceKind, rawValue: trimmed)
        else { return }
        evidence.bindings.append(binding)
    }

    private static func appendTableRows(_ rows: [[Any]], headerIndex: Int?, into evidence: inout StructuredEvidence) {
        guard !rows.isEmpty else { return }
        let index = max(0, min(headerIndex ?? 0, rows.count - 1))
        let headers = rows[index].compactMap(stringValue).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for header in headers {
            evidence.tableHeaders.append(header)
            if let role = normalizeFieldRole(header) {
                evidence.fieldRoles.append(role)
            }
        }
        for row in rows.dropFirst() {
            for (column, cell) in row.enumerated() where headers.indices.contains(column) {
                guard let role = normalizeFieldRole(headers[column]),
                      let value = stringValue(cell),
                      let binding = binding(role: parameterRole(forFieldRole: role), sourceKind: "table", rawValue: value)
                else { continue }
                evidence.bindings.append(binding)
            }
        }
    }

    private static func appendDelimitedTable(_ table: String, into evidence: inout StructuredEvidence) {
        let rows = table.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("---") }
        guard let header = rows.first else { return }
        let delimiter: Character = header.contains("|") ? "|" : ","
        let headers = header.split(separator: delimiter).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        appendTableRows([headers.map { $0 as Any }], headerIndex: 0, into: &evidence)
    }

    private static func metadataBindings(from metadataJSON: String?) -> [ProcessInstanceBinding] {
        guard let metadataJSON,
              let data = metadataJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var bindings: [ProcessInstanceBinding] = []
        func walk(_ value: Any, key: String?) {
            if let dictionary = value as? [String: Any] {
                for (nestedKey, nestedValue) in dictionary { walk(nestedValue, key: nestedKey) }
                return
            }
            if let array = value as? [Any] {
                for item in array { walk(item, key: key) }
                return
            }
            guard let key, let role = normalizeFieldRole(key), let scalar = stringValue(value) else { return }
            if let binding = binding(role: parameterRole(forFieldRole: role), sourceKind: "metadata", rawValue: scalar) {
                bindings.append(binding)
            }
        }
        walk(root, key: nil)
        return uniqueBindings(bindings)
    }

    private static func heuristicBindings(in text: String, sourceKind: String) -> [ProcessInstanceBinding] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var bindings: [ProcessInstanceBinding] = []
        let labelPattern = #"\b(Customer|Client|Vendor|Account|Project|User|Owner|Assignee|Reviewer|Invoice\s*(?:#|No\.?|Number)?|INV|Document\s*ID|Order\s*(?:#|ID)?|Ticket\s*(?:#|ID)?|Case\s*(?:#|ID)?|Due\s*Date|Date|Total|Amount\s*Due|Balance\s*Due|URL|Link|File|Path|Folder|Ticker|Symbol)\s*[:#-]\s*([^\n,;|]{2,80})"#
        for match in capturedRegexMatches(labelPattern, in: text, options: [.caseInsensitive]) {
            let label = match.groups.first ?? ""
            let value = match.groups.dropFirst().first ?? ""
            guard let role = normalizeFieldRole(label),
                  let binding = binding(role: parameterRole(forFieldRole: role), sourceKind: sourceKind, rawValue: value)
            else { continue }
            bindings.append(binding)
        }
        for match in regexMatches(#"\b(?:INV|Invoice|Order|Ticket|Case|Task)[-\s#:]*[A-Z0-9][A-Z0-9_-]{2,24}\b"#, in: text, options: [.caseInsensitive]) {
            let lower = match.value.lowercased()
            let role = lower.contains("ticket") || lower.contains("case") ? "ticket_id" : (lower.contains("order") ? "order_id" : "invoice_id")
            if let binding = binding(role: role, sourceKind: sourceKind, rawValue: match.value) {
                bindings.append(binding)
            }
        }
        for match in regexMatches(#"\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}/\d{1,2}/\d{2,4}\b"#, in: text) {
            if let binding = binding(role: "date", sourceKind: sourceKind, rawValue: match.value) {
                bindings.append(binding)
            }
        }
        for match in regexMatches(#"\$\s?\d[\d,]*(?:\.\d{2})?\b"#, in: text) {
            if let binding = binding(role: "total", sourceKind: sourceKind, rawValue: match.value) {
                bindings.append(binding)
            }
        }
        for match in regexMatches(#"(?:~|/Users|/Volumes|/private|/var|/tmp)(?:/[^\s"'<>|]+)+"#, in: text) {
            if let binding = binding(role: "file", sourceKind: sourceKind, rawValue: match.value) {
                bindings.append(binding)
            }
        }
        for match in regexMatches(#"https?://[^\s"'<>|]+"#, in: text, options: [.caseInsensitive]) {
            if let binding = binding(role: "url", sourceKind: sourceKind, rawValue: match.value) {
                bindings.append(binding)
            }
        }
        for match in regexMatches(#"\$[A-Z]{1,5}\b"#, in: text) {
            if let binding = binding(role: "ticker", sourceKind: sourceKind, rawValue: match.value) {
                bindings.append(binding)
            }
        }
        if sourceKind == "title" {
            bindings += titleRecordNameBindings(in: text, sourceKind: sourceKind)
        }
        return uniqueBindings(bindings)
    }

    private static func titleRecordNameBindings(in title: String, sourceKind: String) -> [ProcessInstanceBinding] {
        let parts = title.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count >= 2 else { return [] }
        var bindings: [ProcessInstanceBinding] = []
        for index in parts.indices where index > 0 {
            let normalized = normalizedProcessToken(normalizeTokenPhrase(parts[index]))
            guard safeProcessNouns.contains(normalized) || processVerbTerms.contains(normalized) else { continue }
            let prefix = parts[..<index].suffix(3)
            let names = prefix.filter { looksLikeDisplayNameToken($0) }
            guard !names.isEmpty else { continue }
            let raw = names.joined(separator: " ")
            if let binding = binding(role: "record_name", sourceKind: sourceKind, rawValue: raw) {
                bindings.append(binding)
            }
            break
        }
        return bindings
    }

    private static func parameterSummaries(from bindings: [ProcessInstanceBinding]) -> [ContextWasteParameter] {
        let grouped = Dictionary(grouping: bindings) { "\($0.role)|\($0.sourceKind)" }
        return grouped.values.map { group in
            let first = group[0]
            return ContextWasteParameter(
                role: first.role,
                sourceKind: first.sourceKind,
                count: group.count,
                valueShapes: Array(unique(group.map(\.valueShape)).prefix(5)),
                valueHashes: Array(unique(group.map(\.valueHash)).prefix(8))
            )
        }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if lhs.role != rhs.role { return lhs.role < rhs.role }
            return lhs.sourceKind < rhs.sourceKind
        }
    }

    private static func binding(role: String?, sourceKind: String, rawValue: String) -> ProcessInstanceBinding? {
        guard let role else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              !PrivacyRules.isSensitiveText(trimmed),
              !PIIDetector.containsHighConfidencePII(trimmed)
        else { return nil }
        return ProcessInstanceBinding(
            role: normalizedRoleToken(role),
            sourceKind: normalizedRoleToken(sourceKind),
            rawValue: trimmed,
            valueShape: valueShape(trimmed, role: role),
            valueHash: AuditIdentity.hash("\(normalizedRoleToken(role))|\(normalizeTokenPhrase(trimmed))")
        )
    }

    private static func uniqueBindings(_ bindings: [ProcessInstanceBinding]) -> [ProcessInstanceBinding] {
        var seen = Set<String>()
        return bindings.filter { binding in
            seen.insert("\(binding.role)|\(binding.sourceKind)|\(binding.valueHash)").inserted
        }
    }

    private static func normalizeFieldRole(_ key: String) -> String? {
        let normalized = normalizeTokenPhrase(key)
        guard !normalized.isEmpty else { return nil }
        let compact = normalized.replacingOccurrences(of: " ", with: "")
        switch compact {
        case "total", "amountdue", "balancedue", "balance", "amount", "subtotal", "price", "cost":
            return "total"
        case "invoice", "invoiceid", "invoiceids", "invoiceno", "invoicenumber", "inv", "documentid", "documentnumber":
            return "invoice_id"
        case "order", "orderid", "ordernumber":
            return "order_id"
        case "ticket", "ticketid", "ticketnumber", "case", "caseid", "casenumber":
            return "ticket_id"
        case "customer", "client", "vendor", "account", "company", "organization", "business":
            return "business_object"
        case "project", "projectname", "repo", "repository":
            return "project"
        case "user", "owner", "assignee", "reviewer", "person", "from", "to", "manager":
            return "person"
        case "date", "duedate", "due", "period", "month", "year":
            return "date"
        case "url", "link", "website":
            return "url"
        case "file", "filepath", "path", "filename":
            return "file"
        case "folder", "directory":
            return "folder"
        case "ticker", "symbol":
            return "ticker"
        case "status", "state", "stage":
            return "status"
        case "email", "emailaddress":
            return "email"
        default:
            let tokens = normalized.split(separator: " ").map(String.init)
                .filter { safeProcessNouns.contains($0) || processVerbTerms.contains($0) }
            guard !tokens.isEmpty else { return nil }
            return tokens.prefix(3).joined(separator: "_")
        }
    }

    private static func parameterRole(forFieldRole role: String) -> String {
        switch role {
        case "business_object":
            return "business_object"
        case "invoice_id", "order_id", "ticket_id", "project", "person", "date", "url", "file", "folder", "ticker", "email", "total":
            return role
        default:
            return role.hasSuffix("_id") ? role : "record_value"
        }
    }

    private static func valueShape(_ value: String, role: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if role == "url" { return "url" }
        if role == "file" || role == "folder" { return "path" }
        if role == "date" { return "date" }
        if role == "email" { return "email" }
        if role == "total" || normalized.contains("$") { return "currency:\(characterShape(normalized))" }
        if role == "ticker" { return "ticker:\(characterShape(normalized))" }
        if looksLikeRecordIdentifier(normalized) { return "id:\(characterShape(normalized))" }
        let wordCount = normalizeTokenPhrase(normalized).split(separator: " ").count
        if normalized.rangeOfCharacter(from: .decimalDigits) != nil {
            return "mixed:\(characterShape(normalized))"
        }
        return "words:\(max(1, wordCount))"
    }

    private static func characterShape(_ value: String) -> String {
        value.prefix(40).map { character in
            if character.isNumber { return "0" }
            if character.isLetter { return character.isUppercase ? "A" : "a" }
            if character.isWhitespace { return " " }
            return String(character)
        }.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func redact(_ value: String, bindings: [ProcessInstanceBinding]) -> String {
        var redacted = value
        let sorted = bindings
            .map(\.rawValue)
            .filter { $0.count >= 2 }
            .sorted { $0.count > $1.count }
        for raw in sorted {
            redacted = redacted.replacingOccurrences(
                of: raw,
                with: "[\(normalizedRoleToken(parameterRoleForRedaction(raw, bindings: bindings)))]",
                options: [.caseInsensitive]
            )
        }
        return redacted
    }

    private static func parameterRoleForRedaction(_ raw: String, bindings: [ProcessInstanceBinding]) -> String {
        bindings.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }?.role ?? "value"
    }

    private static func safeSignatureToken(_ value: String) -> String {
        AuditIdentity.safeToken(value.lowercased())
    }

    private static func normalizedRoleToken(_ value: String) -> String {
        let normalized = normalizeTokenPhrase(value).replacingOccurrences(of: " ", with: "_")
        return AuditIdentity.safeToken(normalized)
    }

    private static func looksLikeDisplayNameToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard trimmed.count >= 2 else { return false }
        let normalized = normalizedProcessToken(normalizeTokenPhrase(trimmed))
        guard !normalized.isEmpty,
              !stopwords.contains(normalized),
              !safeProcessNouns.contains(normalized),
              !processVerbTerms.contains(normalized) else { return false }
        return trimmed.first?.isUppercase == true || looksLikeRecordIdentifier(trimmed)
    }

    private static func looksLikeRecordIdentifier(_ value: String) -> Bool {
        value.range(of: #"[A-Z]{1,10}[-_ ]?\d{2,}"#, options: [.regularExpression]) != nil
            || value.range(of: #"\d{4,}"#, options: [.regularExpression]) != nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private struct RegexMatch {
        let value: String
        let groups: [String]
    }

    private static func regexMatches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [RegexMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: range).map { match in
            RegexMatch(value: nsText.substring(with: match.range), groups: [])
        }
    }

    private static func capturedRegexMatches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [RegexMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: range).map { match in
            let groups = (1..<match.numberOfRanges).compactMap { index -> String? in
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return nil }
                return nsText.substring(with: range)
            }
            return RegexMatch(value: nsText.substring(with: match.range), groups: groups)
        }
    }

    private static func browserLike(_ appName: String) -> Bool {
        let value = appName.lowercased()
        return ["safari", "chrome", "arc", "firefox", "browser"].contains { value.contains($0) }
    }

    private static func semanticStability(_ tokenSets: [[String]]) -> Double {
        guard tokenSets.count > 1 else { return 1 }
        let sets = tokenSets.map { Set($0) }.filter { !$0.isEmpty }
        guard sets.count > 1 else { return 0.4 }
        var scores: [Double] = []
        for index in 0..<sets.count {
            for other in (index + 1)..<sets.count {
                let union = sets[index].union(sets[other])
                guard !union.isEmpty else { continue }
                scores.append(Double(sets[index].intersection(sets[other]).count) / Double(union.count))
            }
        }
        guard !scores.isEmpty else { return 0.4 }
        return scores.reduce(0, +) / Double(scores.count)
    }

    private static func jaccard<T: Hashable>(_ lhs: Set<T>, _ rhs: Set<T>) -> Double {
        if lhs.isEmpty && rhs.isEmpty { return 1 }
        let union = lhs.union(rhs)
        guard !union.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(union.count)
    }

    private static func surfaceFamily(_ value: String) -> String {
        let normalized = normalizeTokenPhrase(value)
        if normalized.contains("safari") || normalized.contains("chrome") || normalized.contains("firefox") || normalized.contains("browser") || normalized.contains("arc") {
            return "browser"
        }
        if normalized.contains("quickbooks") || normalized.contains("xero") || normalized.contains("netsuite") {
            return "finance"
        }
        if normalized.contains("salesforce") || normalized.contains("hubspot") || normalized.contains("crm") {
            return "crm"
        }
        if normalized.contains("gmail") || normalized.contains("mail") || normalized.contains("outlook") {
            return "mail"
        }
        return safeSignatureToken(normalized.isEmpty ? "unknown" : normalized)
    }

    private static func title(for sessions: [SessionSummary], apps: [String]) -> String {
        let tokens = topTitleTokens(in: sessions.flatMap(\.processTerms), limit: 4)
        if !tokens.isEmpty {
            return "Repeated \(tokens.joined(separator: " ")) work"
        }
        return "Repeated work in \(apps.first ?? "an app")"
    }

    private static func suggestedGoal(title: String, apps: [String]) -> String {
        let appText = apps.isEmpty ? "the relevant apps" : apps.joined(separator: " and ")
        return "Teach Cascade to handle \(title.lowercased()) in \(appText)."
    }

    private static func topTokens(in text: String, limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for token in tokenize(text) {
            counts[token, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(limit)
            .map(\.key)
    }

    private static func topProcessTokens(in text: String, excluding instanceTokens: Set<String>, limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for token in tokenize(text)
        where (!instanceTokens.contains(token) || actionTerms.contains(token))
            && allowedProcessTerm(token)
            && !looksLikeRecordIdentifier(token)
            && !parameterNoiseTerms.contains(token) {
            counts[token, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                let lhsAction = processVerbTerms.contains(lhs.key) || safeProcessNouns.contains(lhs.key)
                let rhsAction = processVerbTerms.contains(rhs.key) || safeProcessNouns.contains(rhs.key)
                if lhsAction != rhsAction { return lhsAction }
                return lhs.key < rhs.key
            }
            .prefix(limit)
            .map(\.key)
    }

    private static func allowedProcessTerm(_ token: String) -> Bool {
        processVerbTerms.contains(token) || safeProcessNouns.contains(token) || actionTerms.contains(token)
    }

    private static func topTitleTokens(in tokens: [String], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for token in tokens {
            counts[token, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                let lhsAction = actionTerms.contains(lhs.key)
                let rhsAction = actionTerms.contains(rhs.key)
                if lhsAction != rhsAction { return lhsAction }
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(limit)
            .map(\.key)
    }

    private static func tokenize(_ text: String) -> [String] {
        let normalized = normalizeTokenPhrase(text)
        return normalized.split(separator: " ").compactMap { raw -> String? in
            let token = normalizedProcessToken(String(raw))
            guard token.count >= 3,
                  !stopwords.contains(token),
                  token.rangeOfCharacter(from: .letters) != nil,
                  !PrivacyRules.isSensitiveText(token)
            else { return nil }
            return token
        }
    }

    private static func normalizedProcessToken(_ token: String) -> String {
        let stemmed: String
        guard token.count > 4 else { return canonicalProcessToken(token) }
        if token.hasSuffix("ies") {
            stemmed = String(token.dropLast(3)) + "y"
        } else if token.hasSuffix("s"),
                  !token.hasSuffix("ss"),
                  !token.hasSuffix("us"),
                  token != "status" {
            stemmed = String(token.dropLast())
        } else {
            stemmed = token
        }
        return canonicalProcessToken(stemmed)
    }

    private static func canonicalProcessToken(_ token: String) -> String {
        switch token {
        case "bill", "payable", "payables", "payment":
            return "invoice"
        case "case", "incident":
            return "ticket"
        case "client", "customer", "vendor", "supplier":
            return "business"
        case "spreadsheet", "worksheet":
            return "sheet"
        default:
            return token
        }
    }

    private static func normalizeTokenPhrase(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let chars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(chars).split(separator: " ").joined(separator: " ")
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static let actionTerms: Set<String> = [
        "approve", "audit", "batch", "case", "classify", "copy", "crm", "customer",
        "dashboard", "data", "draft", "email", "export", "file", "fill", "form",
        "invoice", "lead", "mark", "order", "paid", "paste", "pipeline", "process",
        "quote", "receipt", "reconcile", "refund", "reply", "report", "review",
        "row", "sheet", "spreadsheet", "status", "submit", "ticket", "triage",
        "update", "upload", "vendor"
    ]

    private static let processVerbTerms: Set<String> = [
        "approve", "audit", "classify", "copy", "draft", "export", "fill", "mark",
        "paste", "process", "reconcile", "refund", "reply", "review", "submit",
        "triage", "update", "upload"
    ]

    private static let safeProcessNouns: Set<String> = [
        "account", "amount", "batch", "business", "case", "client", "crm", "customer", "dashboard",
        "data", "document", "email", "file", "form", "invoice", "lead", "order",
        "paid", "pipeline", "project", "queue", "quote", "receipt", "record",
        "refund", "report", "request", "row", "sheet", "spreadsheet", "status",
        "table", "task", "ticket", "total", "vendor"
    ]

    private static let strongObjectTerms: Set<String> = [
        "case", "email", "form", "invoice", "lead", "order", "queue", "receipt",
        "refund", "report", "spreadsheet", "ticket"
    ]

    private static let discriminatingProcessTerms: Set<String> = [
        "approval", "approve", "email", "export", "invoice", "lead", "order",
        "receipt", "refund", "reply", "report", "spreadsheet", "submit", "ticket",
        "triage"
    ]

    private static let parameterNoiseTerms: Set<String> = [
        "acme", "beta", "contoso", "corp", "corporation", "inc", "llc", "ltd"
    ]

    private static let passiveBrowsingTerms: Set<String> = [
        "article", "blog", "documentation", "docs", "news", "post", "read", "reading",
        "reddit", "video", "watch", "youtube"
    ]

    private static let stopwords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "back", "been", "before",
        "being", "between", "button", "can", "click", "com", "could", "done", "each",
        "from", "has", "have", "into", "just", "last", "more", "new", "next", "not",
        "now", "one", "open", "page", "same", "screen", "see", "seen", "show", "that",
        "the", "then", "there", "this", "time", "today", "was", "what", "when", "where",
        "which", "with", "work", "you", "your"
    ]
}
