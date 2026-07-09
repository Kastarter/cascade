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

public enum RecorderThermalCondition: String, Codable, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .serious
        }
    }
}

public enum RecorderOCRPolicy: String, Codable, Sendable, Equatable {
    case adaptive
    case fastOnly
}

public struct RecorderCadenceBudget: Sendable, Equatable {
    public let admitsCapture: Bool
    public let heartbeatInterval: TimeInterval
    public let ocrPolicy: RecorderOCRPolicy
    public let allowsNativeResolutionOCR: Bool
    public let allowsSemanticIndexing: Bool
    public let pendingFrameByteBudget: Int

    public init(
        admitsCapture: Bool = true,
        heartbeatInterval: TimeInterval = CaptureScheduler.idleHeartbeatInterval,
        ocrPolicy: RecorderOCRPolicy = .adaptive,
        allowsNativeResolutionOCR: Bool = true,
        allowsSemanticIndexing: Bool = true,
        pendingFrameByteBudget: Int = 16 * 1024 * 1024
    ) {
        self.admitsCapture = admitsCapture
        self.heartbeatInterval = heartbeatInterval
        self.ocrPolicy = ocrPolicy
        self.allowsNativeResolutionOCR = allowsNativeResolutionOCR
        self.allowsSemanticIndexing = allowsSemanticIndexing
        self.pendingFrameByteBudget = pendingFrameByteBudget
    }

    public static let normal = RecorderCadenceBudget()
}

public struct RecorderCadenceController: Sendable, Equatable {
    public static let idleSlowdownAfter: TimeInterval = 90
    public static let typingQuietWindow: TimeInterval = 1.2
    public static let scrollQuietWindow: TimeInterval = 0.65
    public static let backlogPressureBytes = 8 * 1024 * 1024

    private var lastInputAt: Date?
    private var lastActivationAt: Date?
    private var lastActivityKind: InputActivityKind?
    private var lowPowerMode = false
    private var thermalCondition: RecorderThermalCondition = .nominal
    private var isProcessing = false
    private var pendingFrameBytes = 0

    public init() {}

    public mutating func record(activity: InputActivityKind, at date: Date = Date()) {
        lastActivityKind = activity
        switch activity {
        case .appActivated, .windowChanged:
            lastActivationAt = date
        case .click, .typingRun, .scroll, .keyCombo:
            lastInputAt = date
        }
    }

    public mutating func updatePower(lowPowerMode: Bool, thermalCondition: RecorderThermalCondition) {
        self.lowPowerMode = lowPowerMode
        self.thermalCondition = thermalCondition
    }

    public mutating func updateBacklog(isProcessing: Bool, pendingFrameBytes: Int) {
        self.isProcessing = isProcessing
        self.pendingFrameBytes = max(0, pendingFrameBytes)
    }

    public func budget(now: Date = Date()) -> RecorderCadenceBudget {
        let secondsSinceInput = lastInputAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let secondsSinceActivation = lastActivationAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let typingQuiet = lastActivityKind == .typingRun && secondsSinceInput < Self.typingQuietWindow
        let scrollQuiet = lastActivityKind == .scroll && secondsSinceInput < Self.scrollQuietWindow
        let backlogPressured = isProcessing && pendingFrameBytes >= Self.backlogPressureBytes

        switch thermalCondition {
        case .critical:
            return RecorderCadenceBudget(
                admitsCapture: false,
                heartbeatInterval: 90,
                ocrPolicy: .fastOnly,
                allowsNativeResolutionOCR: false,
                allowsSemanticIndexing: false,
                pendingFrameByteBudget: 2 * 1024 * 1024
            )
        case .serious:
            return RecorderCadenceBudget(
                admitsCapture: !scrollQuiet && !backlogPressured,
                heartbeatInterval: 45,
                ocrPolicy: .fastOnly,
                allowsNativeResolutionOCR: false,
                allowsSemanticIndexing: false,
                pendingFrameByteBudget: 4 * 1024 * 1024
            )
        case .fair, .nominal:
            break
        }

        if lowPowerMode {
            return RecorderCadenceBudget(
                admitsCapture: !scrollQuiet && !backlogPressured,
                heartbeatInterval: 30,
                ocrPolicy: .fastOnly,
                allowsNativeResolutionOCR: false,
                allowsSemanticIndexing: false,
                pendingFrameByteBudget: 8 * 1024 * 1024
            )
        }

        if backlogPressured {
            return RecorderCadenceBudget(
                admitsCapture: false,
                heartbeatInterval: 20,
                ocrPolicy: .fastOnly,
                allowsNativeResolutionOCR: false,
                allowsSemanticIndexing: false,
                pendingFrameByteBudget: 8 * 1024 * 1024
            )
        }

        if typingQuiet || scrollQuiet {
            // Mid-scroll frames ARE captured (with the cheap fast-OCR pass) —
            // content the user scrolls past is exactly the evidence rewind exists
            // to keep. Thermal/low-power branches above still shed scroll bursts.
            return RecorderCadenceBudget(
                admitsCapture: true,
                heartbeatInterval: CaptureScheduler.idleHeartbeatInterval,
                ocrPolicy: .fastOnly,
                allowsNativeResolutionOCR: false,
                allowsSemanticIndexing: true,
                pendingFrameByteBudget: 16 * 1024 * 1024
            )
        }

        if secondsSinceInput >= Self.idleSlowdownAfter && secondsSinceActivation >= Self.idleSlowdownAfter {
            return RecorderCadenceBudget(
                admitsCapture: true,
                heartbeatInterval: 30,
                ocrPolicy: .adaptive,
                allowsNativeResolutionOCR: true,
                allowsSemanticIndexing: true,
                pendingFrameByteBudget: 16 * 1024 * 1024
            )
        }

        return .normal
    }
}

public struct CaptureScheduler: Sendable, Equatable {
    public static let clickDelay: TimeInterval = 0.22
    public static let typingPauseDelay: TimeInterval = 0.75
    public static let scrollEndDelay: TimeInterval = 0.42
    public static let keyComboDelay: TimeInterval = 0.25
    public static let appActivationDelay: TimeInterval = 1.5
    public static let idleHeartbeatInterval: TimeInterval = 10
    /// The SCStream runs at ~1fps and dedup already drops unchanged frames, so a
    /// 1s persistence gap means every *changed* frame becomes a moment — smooth
    /// scroll-through playback instead of one screenshot per 8 seconds.
    public static let streamHeartbeatInterval: TimeInterval = 1.0

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
