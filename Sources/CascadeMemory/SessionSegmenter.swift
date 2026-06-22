import Foundation

/// A work SESSION (episode): a contiguous stretch of moments the user spent in
/// one app without a long break. This is the unit a *log* should be retrieved
/// by — "what did I work on this morning" wants sessions, not the 300 near-
/// identical frames inside them. Identified by its anchor (first) moment's id,
/// so it stays citable and the Reel can jump straight to where the session
/// began.
public struct Episode: Sendable, Equatable, Identifiable {
    /// The first moment's id — stable and citable (survives as long as that
    /// moment isn't pruned), so `[#id]` in a session list can be inspected/jumped.
    public let id: Int64
    public let appName: String
    public let bundleIdentifier: String?
    /// Representative window title (the session's most-seen title), or nil.
    public let title: String?
    public let startedAt: Date
    public let endedAt: Date
    /// The session's moments in time order — for drilling in or scoping search.
    public let momentIDs: [Int64]

    public var momentCount: Int { momentIDs.count }
    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    public init(
        id: Int64,
        appName: String,
        bundleIdentifier: String?,
        title: String?,
        startedAt: Date,
        endedAt: Date,
        momentIDs: [Int64]
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.momentIDs = momentIDs
    }
}

/// Groups recorded moments into work sessions — cheap and LLM-free, off signals
/// we already store (app identity + capture time). This is the "treat the log
/// as sessions, not frames" engine the rewind/recall tools retrieve through.
public enum SessionSegmenter {
    /// Max gap WITHIN one app before the session is treated as ended (you left
    /// and came back). Generous on purpose: a static screen produces few frames
    /// (dedup skips identical ones), so a real reading/thinking pause can leave a
    /// minutes-long gap inside one genuine session — only a longer break splits
    /// it. An app switch always starts a new session regardless of this.
    public static let defaultMaxGap: TimeInterval = 600 // 10 minutes

    /// Segments time-ordered moments into sessions. A new session begins when the
    /// app (bundle id, or name when no bundle) changes OR the gap since the
    /// previous moment exceeds `maxGap`. Pure + deterministic; tolerates
    /// out-of-order input by sorting oldest-first.
    public static func segment(_ moments: [RecordedContext], maxGap: TimeInterval = defaultMaxGap) -> [Episode] {
        let ordered = moments.sorted { $0.capturedAt < $1.capturedAt }
        var episodes: [Episode] = []
        var current: [RecordedContext] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            episodes.append(Episode(
                id: first.id,
                appName: first.appName,
                bundleIdentifier: first.bundleIdentifier,
                title: representativeTitle(current),
                startedAt: first.capturedAt,
                endedAt: last.capturedAt,
                momentIDs: current.map(\.id)
            ))
            current = []
        }

        for moment in ordered {
            if let prev = current.last {
                let appChanged = appIdentity(moment) != appIdentity(prev)
                let gappedOut = moment.capturedAt.timeIntervalSince(prev.capturedAt) > maxGap
                if appChanged || gappedOut { flush() }
            }
            current.append(moment)
        }
        flush()
        return episodes
    }

    /// App switches are keyed on bundle id when present (two apps can share a
    /// display name), falling back to the display name.
    private static func appIdentity(_ moment: RecordedContext) -> String {
        moment.bundleIdentifier ?? moment.appName
    }

    /// The session's most-frequent non-empty window title (ties → the earliest
    /// one seen), as its representative label. nil when no moment had a title.
    public static func representativeTitle(_ moments: [RecordedContext]) -> String? {
        var counts: [String: Int] = [:]
        var firstIndex: [String: Int] = [:]
        for (index, moment) in moments.enumerated() {
            guard let title = moment.windowTitle,
                  !title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            counts[title, default: 0] += 1
            if firstIndex[title] == nil { firstIndex[title] = index }
        }
        return counts.keys.max { a, b in
            counts[a]! != counts[b]! ? counts[a]! < counts[b]! : firstIndex[a]! > firstIndex[b]!
        }
    }
}
