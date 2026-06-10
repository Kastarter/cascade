import CascadeMemory
import Foundation

/// Collapses recorded moments into a compact, chronological digest of app
/// sessions ("02:45–03:10 Google Chrome — WhatsApp"), so a whole day of context
/// fits in one prompt. This is what lets the Reel chat answer day-scale
/// questions ("what did I do today?") instead of only knowing the freshest
/// few moments.
public enum ActivityTimeline {
    public struct Segment: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let appName: String
        public let windowTitle: String?
        public let moments: Int

        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// Merges consecutive same-app moments into one segment. A gap longer than
    /// `maxGap` splits even a same-app run — it usually means the machine sat
    /// idle in between.
    public static func segments(
        from contexts: [RecordedContext],
        maxGap: TimeInterval = 15 * 60
    ) -> [Segment] {
        let ordered = contexts.sorted { $0.capturedAt < $1.capturedAt }
        var segments: [Segment] = []
        var open: Segment?
        for context in ordered {
            if let current = open,
               current.appName == context.appName,
               context.capturedAt.timeIntervalSince(current.end) <= maxGap {
                open = Segment(
                    start: current.start,
                    end: context.capturedAt,
                    appName: current.appName,
                    windowTitle: context.windowTitle ?? current.windowTitle,
                    moments: current.moments + 1
                )
            } else {
                if let current = open { segments.append(current) }
                open = Segment(
                    start: context.capturedAt,
                    end: context.capturedAt,
                    appName: context.appName,
                    windowTitle: context.windowTitle,
                    moments: 1
                )
            }
        }
        if let current = open { segments.append(current) }
        return segments
    }

    /// Renders the segments oldest-first, one line per app session, with a day
    /// header whenever the date changes so "today" stays unambiguous in a
    /// window that crosses midnight. Keeps the `maxLines` longest segments when
    /// there are too many, noting how many brief visits were cut.
    public static func digest(
        from contexts: [RecordedContext],
        maxLines: Int = 60,
        timeZone: TimeZone = .current
    ) -> String {
        var segments = segments(from: contexts)
        guard !segments.isEmpty else { return "" }

        var omitted = 0
        if segments.count > maxLines {
            let kept = segments.enumerated()
                .sorted { ($0.element.duration, $0.element.moments) > ($1.element.duration, $1.element.moments) }
                .prefix(maxLines)
                .sorted { $0.offset < $1.offset }
                .map(\.element)
            omitted = segments.count - kept.count
            segments = kept
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = timeZone
        time.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "EEE MMM d"

        let crossesDays = !calendar.isDate(segments[0].start, inSameDayAs: segments[segments.count - 1].end)
        var lines: [String] = []
        var currentDay: Date?
        for segment in segments {
            if crossesDays {
                let dayStart = calendar.startOfDay(for: segment.start)
                if dayStart != currentDay {
                    currentDay = dayStart
                    lines.append("\(day.string(from: segment.start)):")
                }
            }
            let span = segment.start == segment.end
                ? time.string(from: segment.start)
                : "\(time.string(from: segment.start))–\(time.string(from: segment.end))"
            let title = segment.windowTitle.map { " — \($0.prefix(80))" } ?? ""
            let weight = segment.moments > 1 ? " (\(segment.moments) moments)" : ""
            lines.append("• \(span) \(segment.appName)\(title)\(weight)")
        }
        if omitted > 0 {
            lines.append("(+\(omitted) briefer visits not shown)")
        }
        return lines.joined(separator: "\n")
    }
}
