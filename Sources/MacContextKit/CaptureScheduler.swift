import Foundation

public enum CaptureReason: String, Codable, Sendable, Equatable {
    case appActivated
    case click
    case typingPause
    case scrollEnd
    case keyCombo
    case idleHeartbeat
    case streamHeartbeat
    case windowChanged
}

public enum InputActivityKind: String, Sendable, Equatable {
    case click
    case typingRun
    case scroll
    case keyCombo
    case appActivated
    case windowChanged
}

public struct InputActivity: Sendable, Equatable {
    public let kind: InputActivityKind
    public let capturedAt: Date
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitle: String?

    public init(
        kind: InputActivityKind,
        capturedAt: Date = Date(),
        appName: String,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil
    ) {
        self.kind = kind
        self.capturedAt = capturedAt
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
    }
}

public struct ScheduledCapture: Sendable, Equatable {
    public let reason: CaptureReason
    public let delay: TimeInterval

    public init(reason: CaptureReason, delay: TimeInterval) {
        self.reason = reason
        self.delay = delay
    }
}

public struct CaptureScheduler: Sendable, Equatable {
    public static let clickDelay: TimeInterval = 0.22
    public static let typingPauseDelay: TimeInterval = 0.75
    public static let scrollEndDelay: TimeInterval = 0.42
    public static let keyComboDelay: TimeInterval = 0.25
    public static let appActivationDelay: TimeInterval = 1.5
    public static let idleHeartbeatInterval: TimeInterval = 10
    public static let streamHeartbeatInterval: TimeInterval = 8

    private var lastCaptureByReason: [CaptureReason: Date] = [:]

    public init() {}

    public mutating func schedule(for activity: InputActivity, now: Date = Date()) -> ScheduledCapture? {
        let scheduled: ScheduledCapture
        switch activity.kind {
        case .click:
            scheduled = ScheduledCapture(reason: .click, delay: Self.clickDelay)
        case .typingRun:
            scheduled = ScheduledCapture(reason: .typingPause, delay: Self.typingPauseDelay)
        case .scroll:
            scheduled = ScheduledCapture(reason: .scrollEnd, delay: Self.scrollEndDelay)
        case .keyCombo:
            scheduled = ScheduledCapture(reason: .keyCombo, delay: Self.keyComboDelay)
        case .appActivated:
            scheduled = ScheduledCapture(reason: .appActivated, delay: Self.appActivationDelay)
        case .windowChanged:
            scheduled = ScheduledCapture(reason: .windowChanged, delay: Self.appActivationDelay)
        }
        guard admits(reason: scheduled.reason, now: now) else { return nil }
        return scheduled
    }

    public mutating func admits(reason: CaptureReason, now: Date = Date()) -> Bool {
        let minGap: TimeInterval
        switch reason {
        case .typingPause:
            minGap = 0.7
        case .scrollEnd:
            minGap = 0.35
        case .click, .keyCombo:
            minGap = 0.15
        case .appActivated, .windowChanged:
            minGap = 1.0
        case .idleHeartbeat:
            minGap = Self.idleHeartbeatInterval
        case .streamHeartbeat:
            minGap = Self.streamHeartbeatInterval
        }
        if let previous = lastCaptureByReason[reason], now.timeIntervalSince(previous) < minGap {
            return false
        }
        lastCaptureByReason[reason] = now
        return true
    }
}
