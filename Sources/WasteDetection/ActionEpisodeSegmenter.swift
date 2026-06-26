import CascadeMemory
import Foundation

public enum ActionEpisodeBoundaryReason: String, Codable, Equatable, Hashable, Sendable {
    case idleGap
    case surfaceSwitch
    case windowSwitch
    case completionControl
    case noisySurface
    case sensitiveSurface
}

public struct ActionEpisode: Equatable, Sendable {
    public let eventIDs: [Int64]
    public let startAt: Date
    public let endAt: Date
    public let surfaceFlow: [String]
    public let windowTitles: [String]
    public let boundaryReasons: [ActionEpisodeBoundaryReason]
}

/// Splits low-level input into task-shaped episodes before routine mining.
/// Pure and deterministic: callers provide recorded events and an optional
/// surface resolver, and the segmenter returns ordered episode metadata only.
public struct ActionEpisodeSegmenter: Sendable {
    public let maxIdleGap: TimeInterval
    public let dataflowContinuityGap: TimeInterval

    public init(maxIdleGap: TimeInterval = 180, dataflowContinuityGap: TimeInterval = 90) {
        self.maxIdleGap = maxIdleGap
        self.dataflowContinuityGap = dataflowContinuityGap
    }

    public func segment(
        _ inputEvents: [InputEvent],
        surface surfaceResolver: (@Sendable (InputEvent) -> String?)? = nil
    ) -> [ActionEpisode] {
        let events = inputEvents.sorted {
            if $0.capturedAt == $1.capturedAt { return $0.id < $1.id }
            return $0.capturedAt < $1.capturedAt
        }
        let surface: (InputEvent) -> String = { event in
            let resolved = surfaceResolver?(event)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return resolved?.isEmpty == false ? resolved! : event.appName
        }

        var episodes: [ActionEpisode] = []
        var active: EpisodeBuilder?
        var pendingStartReasons: [ActionEpisodeBoundaryReason] = []

        func finishActive(with reasons: [ActionEpisodeBoundaryReason]) {
            guard var builder = active else { return }
            builder.close(with: reasons)
            episodes.append(builder.build())
            active = nil
        }

        for event in events {
            let currentSurface = surface(event)
            if Self.isSensitive(event, surface: currentSurface) {
                finishActive(with: [.sensitiveSurface])
                Self.appendUnique(.sensitiveSurface, to: &pendingStartReasons)
                continue
            }
            if Self.isNoisy(event, surface: currentSurface) {
                finishActive(with: [.noisySurface])
                Self.appendUnique(.noisySurface, to: &pendingStartReasons)
                continue
            }

            if var builder = active {
                let reasons = boundaryReasons(from: builder, to: event, surface: currentSurface)
                if !reasons.isEmpty {
                    builder.close(with: reasons)
                    episodes.append(builder.build())
                    active = EpisodeBuilder(event: event, surface: currentSurface, startReasons: pendingStartReasons)
                    pendingStartReasons.removeAll()
                } else {
                    builder.append(event, surface: currentSurface)
                    active = builder
                }
            } else {
                active = EpisodeBuilder(event: event, surface: currentSurface, startReasons: pendingStartReasons)
                pendingStartReasons.removeAll()
            }

            if Self.isCompletionControl(event), var builder = active {
                builder.close(with: [.completionControl])
                episodes.append(builder.build())
                active = nil
                Self.appendUnique(.completionControl, to: &pendingStartReasons)
            }
        }

        if let builder = active {
            episodes.append(builder.build())
        }
        return episodes
    }

    private func boundaryReasons(from builder: EpisodeBuilder, to event: InputEvent, surface: String) -> [ActionEpisodeBoundaryReason] {
        let gap = event.capturedAt.timeIntervalSince(builder.lastEvent.capturedAt)
        if gap > maxIdleGap { return [.idleGap] }

        let surfaceChanged = builder.lastSurface != surface
        let windowChanged = Self.isWindowSwitch(from: builder.lastEvent.windowTitle, to: event.windowTitle)
        guard surfaceChanged || windowChanged else { return [] }

        if continuesDataflow(from: builder, to: event, gap: gap) {
            return []
        }

        var reasons: [ActionEpisodeBoundaryReason] = []
        if surfaceChanged { reasons.append(.surfaceSwitch) }
        if windowChanged { reasons.append(.windowSwitch) }
        return reasons
    }

    private func continuesDataflow(from builder: EpisodeBuilder, to event: InputEvent, gap: TimeInterval) -> Bool {
        guard gap <= dataflowContinuityGap else { return false }
        if builder.hasOpenCopyFlow { return true }
        if let token = Self.dataflowToken(for: event), builder.hasRecentDataflowToken(token) { return true }
        return false
    }

    private static func isWindowSwitch(from previous: String?, to current: String?) -> Bool {
        let lhs = normalizedWindowTitle(previous)
        let rhs = normalizedWindowTitle(current)
        return !lhs.isEmpty && !rhs.isEmpty && lhs != rhs
    }

    private static func normalizedWindowTitle(_ title: String?) -> String {
        guard let title else { return "" }
        return title
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSensitive(_ event: InputEvent, surface: String) -> Bool {
        PrivacyRules.isSensitive(appName: event.appName, bundleIdentifier: event.bundleIdentifier, windowTitle: event.windowTitle)
            || PrivacyRules.isSensitiveText(surface)
    }

    private static func isNoisy(_ event: InputEvent, surface: String) -> Bool {
        if WasteDetector.isNoisyApp(appName: event.appName, bundleIdentifier: event.bundleIdentifier) {
            return true
        }
        let noisySurfaces: Set<String> = ["zoom", "zoom.us", "microsoft teams", "webex", "google meet"]
        return noisySurfaces.contains(surface.lowercased())
    }

    private static func isCompletionControl(_ event: InputEvent) -> Bool {
        if event.kind == .key {
            let key = event.key?.lowercased()
            let modifiers = Set(event.modifiers.map { $0.lowercased() })
            return (key == "s" && modifiers.contains("command"))
                || (key == "return" && (modifiers.contains("command") || modifiers.contains("control")))
        }

        guard event.kind == .click || event.kind == .doubleClick || event.kind == .rightClick else { return false }
        let label = WasteDetector.normalizedLabel(event.text)
        guard !label.isEmpty else { return false }
        let exact: Set<String> = [
            "archive", "complete", "done", "finish", "ok", "publish", "save",
            "save changes", "send", "send message", "submit"
        ]
        if exact.contains(label) { return true }
        return label.hasPrefix("save ") || label.hasPrefix("send ") || label.hasPrefix("submit ")
    }

    private static func isCopyShortcut(_ event: InputEvent) -> Bool {
        isShortcut(event, key: "c") || isShortcut(event, key: "x")
    }

    private static func isPasteShortcut(_ event: InputEvent) -> Bool {
        isShortcut(event, key: "v")
    }

    private static func isShortcut(_ event: InputEvent, key: String) -> Bool {
        guard event.kind == .key, event.key?.lowercased() == key else { return false }
        let modifiers = event.modifiers.map { $0.lowercased() }
        return modifiers.contains("command") || modifiers.contains("control")
    }

    private static func dataflowToken(for event: InputEvent) -> String? {
        switch event.kind {
        case .click, .doubleClick, .rightClick:
            let label = WasteDetector.normalizedLabel(event.text)
            return label.isEmpty ? nil : "click:\(label)"
        case .type:
            let text = WasteDetector.normalizedLabel(event.text)
            return text.isEmpty ? nil : "type:\(text)"
        case .key, .scroll:
            return nil
        }
    }

    fileprivate static func appendUnique(_ reason: ActionEpisodeBoundaryReason, to reasons: inout [ActionEpisodeBoundaryReason]) {
        if !reasons.contains(reason) { reasons.append(reason) }
    }

    private struct EpisodeBuilder {
        var events: [InputEvent]
        var surfaceFlow: [String]
        var windowTitles: [String]
        var boundaryReasons: [ActionEpisodeBoundaryReason]
        var lastSurface: String
        var hasOpenCopyFlow: Bool
        private var recentDataflowTokens: [String]

        var lastEvent: InputEvent { events[events.count - 1] }

        init(event: InputEvent, surface: String, startReasons: [ActionEpisodeBoundaryReason]) {
            self.events = []
            self.surfaceFlow = []
            self.windowTitles = []
            self.boundaryReasons = startReasons
            self.lastSurface = surface
            self.hasOpenCopyFlow = false
            self.recentDataflowTokens = []
            append(event, surface: surface)
        }

        mutating func append(_ event: InputEvent, surface: String) {
            events.append(event)
            lastSurface = surface
            Self.appendDistinct(surface, to: &surfaceFlow)
            if let title = cleanedWindowTitle(event.windowTitle) {
                Self.appendDistinct(title, to: &windowTitles)
            }
            if ActionEpisodeSegmenter.isCopyShortcut(event) {
                hasOpenCopyFlow = true
            } else if ActionEpisodeSegmenter.isPasteShortcut(event) {
                hasOpenCopyFlow = false
            }
            if let token = ActionEpisodeSegmenter.dataflowToken(for: event) {
                recentDataflowTokens.append(token)
                if recentDataflowTokens.count > 6 {
                    recentDataflowTokens.removeFirst(recentDataflowTokens.count - 6)
                }
            }
        }

        mutating func close(with reasons: [ActionEpisodeBoundaryReason]) {
            for reason in reasons {
                ActionEpisodeSegmenter.appendUnique(reason, to: &boundaryReasons)
            }
        }

        func hasRecentDataflowToken(_ token: String) -> Bool {
            recentDataflowTokens.contains(token)
        }

        func build() -> ActionEpisode {
            ActionEpisode(
                eventIDs: events.map(\.id),
                startAt: events.first?.capturedAt ?? Date(timeIntervalSince1970: 0),
                endAt: events.last?.capturedAt ?? Date(timeIntervalSince1970: 0),
                surfaceFlow: surfaceFlow,
                windowTitles: windowTitles,
                boundaryReasons: boundaryReasons
            )
        }

        private static func appendDistinct(_ value: String, to values: inout [String]) {
            if values.last != value {
                values.append(value)
            }
        }

        private func cleanedWindowTitle(_ title: String?) -> String? {
            guard let title else { return nil }
            let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
    }
}
