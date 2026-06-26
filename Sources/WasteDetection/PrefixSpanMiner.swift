import Foundation

/// A small, bounded PrefixSpan-style miner for repeated action episodes.
///
/// The public string API is convenience only: tokens are deterministically
/// compressed to integer IDs before mining so candidate expansion and ordering
/// stay stable. Support is classic sequence support: the number of episodes
/// containing at least one occurrence of the pattern.
public struct PrefixSpanMiner: Sendable {
    public struct Event: Sendable, Equatable {
        public let token: String
        public let timestamp: TimeInterval?

        public init(_ token: String, timestamp: TimeInterval? = nil) {
            self.token = token
            self.timestamp = timestamp
        }
    }

    public struct EncodedEvent: Sendable, Equatable {
        public let tokenID: Int
        public let timestamp: TimeInterval?

        public init(tokenID: Int, timestamp: TimeInterval? = nil) {
            self.tokenID = tokenID
            self.timestamp = timestamp
        }
    }

    public struct OccurrenceSpan: Sendable, Equatable {
        public let episodeIndex: Int
        public let startEventIndex: Int
        public let endEventIndex: Int
        public let startTime: TimeInterval?
        public let endTime: TimeInterval?

        public var eventLength: Int { endEventIndex - startEventIndex + 1 }

        public var durationSeconds: TimeInterval? {
            guard let startTime, let endTime else { return nil }
            return endTime - startTime
        }
    }

    public struct EncodedPattern: Sendable, Equatable {
        public let tokenIDs: [Int]
        public let support: Int
        public let occurrenceSpans: [OccurrenceSpan]

        public var occurrenceCount: Int { occurrenceSpans.count }
    }

    public struct Pattern: Sendable, Equatable {
        public let tokens: [String]
        public let support: Int
        public let occurrenceSpans: [OccurrenceSpan]

        public var occurrenceCount: Int { occurrenceSpans.count }
    }

    public let minSupport: Int
    public let maxPatternLength: Int
    public let maxGapEvents: Int
    public let maxSpanSeconds: TimeInterval?
    public let closedOnly: Bool

    public init(
        minSupport: Int = 2,
        maxPatternLength: Int = 5,
        maxGapEvents: Int = 1,
        maxSpanSeconds: TimeInterval? = nil,
        closedOnly: Bool = true
    ) {
        self.minSupport = max(1, minSupport)
        self.maxPatternLength = max(1, maxPatternLength)
        self.maxGapEvents = max(0, maxGapEvents)
        self.maxSpanSeconds = maxSpanSeconds
        self.closedOnly = closedOnly
    }

    public func mine(episodes: [[String]]) -> [Pattern] {
        mine(episodes: episodes.map { episode in
            episode.map { Event($0) }
        })
    }

    public func mine(episodes: [[Event]]) -> [Pattern] {
        let tokens = Array(Set(episodes.flatMap { episode in episode.map(\.token) })).sorted()
        let idByToken = Dictionary(uniqueKeysWithValues: tokens.enumerated().map { index, token in
            (token, index)
        })
        let encodedEpisodes = episodes.map { episode in
            episode.compactMap { event -> EncodedEvent? in
                guard let tokenID = idByToken[event.token] else { return nil }
                return EncodedEvent(tokenID: tokenID, timestamp: event.timestamp)
            }
        }

        return mine(encodedEpisodes: encodedEpisodes).map { pattern in
            Pattern(
                tokens: pattern.tokenIDs.map { tokens[$0] },
                support: pattern.support,
                occurrenceSpans: pattern.occurrenceSpans
            )
        }
    }

    public func mine(encodedEpisodes: [[EncodedEvent]]) -> [EncodedPattern] {
        guard maxPatternLength > 0 else { return [] }

        let tokenIDs = Array(Set(encodedEpisodes.flatMap { episode in episode.map(\.tokenID) })).sorted()
        var patterns: [EncodedPattern] = []

        for tokenID in tokenIDs {
            let occurrences = singletonOccurrences(for: tokenID, in: encodedEpisodes)
            guard support(of: occurrences) >= minSupport else { continue }
            grow(
                prefix: [tokenID],
                occurrences: occurrences,
                episodes: encodedEpisodes,
                into: &patterns
            )
        }

        let filtered = closedOnly ? closedPatterns(patterns) : patterns
        return sortPatterns(filtered)
    }
}

private extension PrefixSpanMiner {
    struct EncodedOccurrence: Hashable {
        let episodeIndex: Int
        let startEventIndex: Int
        let endEventIndex: Int
        let startTime: TimeInterval?
        let endTime: TimeInterval?

        func hash(into hasher: inout Hasher) {
            hasher.combine(episodeIndex)
            hasher.combine(startEventIndex)
            hasher.combine(endEventIndex)
        }

        static func == (lhs: EncodedOccurrence, rhs: EncodedOccurrence) -> Bool {
            lhs.episodeIndex == rhs.episodeIndex
                && lhs.startEventIndex == rhs.startEventIndex
                && lhs.endEventIndex == rhs.endEventIndex
        }

        var span: OccurrenceSpan {
            OccurrenceSpan(
                episodeIndex: episodeIndex,
                startEventIndex: startEventIndex,
                endEventIndex: endEventIndex,
                startTime: startTime,
                endTime: endTime
            )
        }
    }

    func grow(
        prefix: [Int],
        occurrences: [EncodedOccurrence],
        episodes: [[EncodedEvent]],
        into patterns: inout [EncodedPattern]
    ) {
        patterns.append(
            EncodedPattern(
                tokenIDs: prefix,
                support: support(of: occurrences),
                occurrenceSpans: occurrences.map(\.span)
            )
        )

        guard prefix.count < maxPatternLength else { return }

        for (tokenID, nextOccurrences) in extensionOccurrences(from: occurrences, episodes: episodes) {
            guard support(of: nextOccurrences) >= minSupport else { continue }
            grow(
                prefix: prefix + [tokenID],
                occurrences: nextOccurrences,
                episodes: episodes,
                into: &patterns
            )
        }
    }

    func singletonOccurrences(for tokenID: Int, in episodes: [[EncodedEvent]]) -> [EncodedOccurrence] {
        var occurrences: [EncodedOccurrence] = []

        for (episodeIndex, episode) in episodes.enumerated() {
            for (eventIndex, event) in episode.enumerated() where event.tokenID == tokenID {
                occurrences.append(
                    EncodedOccurrence(
                        episodeIndex: episodeIndex,
                        startEventIndex: eventIndex,
                        endEventIndex: eventIndex,
                        startTime: event.timestamp,
                        endTime: event.timestamp
                    )
                )
            }
        }

        return sortOccurrences(unique(occurrences))
    }

    func extensionOccurrences(
        from occurrences: [EncodedOccurrence],
        episodes: [[EncodedEvent]]
    ) -> [(Int, [EncodedOccurrence])] {
        var candidates: [Int: [EncodedOccurrence]] = [:]

        for occurrence in occurrences {
            let episode = episodes[occurrence.episodeIndex]
            let startIndex = occurrence.endEventIndex + 1
            guard startIndex < episode.count else { continue }

            let remainingEvents = episode.count - occurrence.endEventIndex - 1
            let allowedAdvance = maxGapEvents >= remainingEvents ? remainingEvents : maxGapEvents + 1
            let endIndex = occurrence.endEventIndex + allowedAdvance
            guard startIndex <= endIndex else { continue }

            for eventIndex in startIndex...endIndex {
                let event = episode[eventIndex]
                guard spanAllowed(start: occurrence.startTime, end: event.timestamp) else { continue }
                candidates[event.tokenID, default: []].append(
                    EncodedOccurrence(
                        episodeIndex: occurrence.episodeIndex,
                        startEventIndex: occurrence.startEventIndex,
                        endEventIndex: eventIndex,
                        startTime: occurrence.startTime,
                        endTime: event.timestamp
                    )
                )
            }
        }

        return candidates
            .map { tokenID, occurrences in (tokenID, sortOccurrences(unique(occurrences))) }
            .sorted { $0.0 < $1.0 }
    }

    func spanAllowed(start: TimeInterval?, end: TimeInterval?) -> Bool {
        guard let maxSpanSeconds else { return true }
        guard let start, let end else { return true }
        return end >= start && end - start <= maxSpanSeconds
    }

    func support(of occurrences: [EncodedOccurrence]) -> Int {
        Set(occurrences.map(\.episodeIndex)).count
    }

    func unique(_ occurrences: [EncodedOccurrence]) -> [EncodedOccurrence] {
        Array(Set(occurrences))
    }

    func sortOccurrences(_ occurrences: [EncodedOccurrence]) -> [EncodedOccurrence] {
        occurrences.sorted {
            if $0.episodeIndex != $1.episodeIndex { return $0.episodeIndex < $1.episodeIndex }
            if $0.startEventIndex != $1.startEventIndex { return $0.startEventIndex < $1.startEventIndex }
            return $0.endEventIndex < $1.endEventIndex
        }
    }

    func closedPatterns(_ patterns: [EncodedPattern]) -> [EncodedPattern] {
        patterns.filter { candidate in
            !patterns.contains { other in
                other.support == candidate.support
                    && other.tokenIDs.count > candidate.tokenIDs.count
                    && candidate.tokenIDs.isSubsequence(of: other.tokenIDs)
            }
        }
    }

    func sortPatterns(_ patterns: [EncodedPattern]) -> [EncodedPattern] {
        patterns.sorted { lhs, rhs in
            if lhs.support != rhs.support { return lhs.support > rhs.support }
            if lhs.tokenIDs.count != rhs.tokenIDs.count { return lhs.tokenIDs.count > rhs.tokenIDs.count }
            return lhs.tokenIDs.lexicographicallyPrecedes(rhs.tokenIDs)
        }
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
