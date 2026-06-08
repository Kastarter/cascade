import AppKit
import ApplicationServices
import CascadeMemory
import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit

public struct CapturePermissionStatus: Equatable, Sendable {
    public var screenRecording: Bool
    public var accessibility: Bool
    public var inputMonitoring: Bool

    public init(screenRecording: Bool, accessibility: Bool, inputMonitoring: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    public var canRecordContext: Bool {
        screenRecording
    }

    public var canRunScreenAgent: Bool {
        screenRecording && accessibility && inputMonitoring
    }

    public var missingLabels: [String] {
        var labels: [String] = []
        if !screenRecording { labels.append("Screen Recording") }
        if !accessibility { labels.append("Accessibility") }
        if !inputMonitoring { labels.append("Input Monitoring") }
        return labels
    }
}

public enum PermissionPromptKind: Sendable {
    case accessibility
    case inputMonitoring
}

public struct PermissionDiagnostics: Equatable, Sendable {
    public var bundleIdentifier: String
    public var bundlePath: String
    public var executablePath: String
    public var screenRecording: Bool
    public var accessibility: Bool
    public var inputMonitoring: Bool

    public init(
        bundleIdentifier: String,
        bundlePath: String,
        executablePath: String,
        screenRecording: Bool,
        accessibility: Bool,
        inputMonitoring: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }
}

@MainActor
public enum PermissionProbe {
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "permissions")

    public static func currentStatus() -> CapturePermissionStatus {
        let status = CapturePermissionStatus(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
        logger.info(
            "Permission preflight bundle=\(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public) screen=\(status.screenRecording, privacy: .public) ax=\(status.accessibility, privacy: .public) input=\(status.inputMonitoring, privacy: .public)"
        )
        return status
    }

    public static func diagnostics() -> PermissionDiagnostics {
        let status = currentStatus()
        return PermissionDiagnostics(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            bundlePath: Bundle.main.bundleURL.path,
            executablePath: Bundle.main.executableURL?.path ?? "unknown",
            screenRecording: status.screenRecording,
            accessibility: status.accessibility,
            inputMonitoring: status.inputMonitoring
        )
    }

    public static func requestScreenRecordingPrompt() -> Bool {
        logger.info("Explicit Screen Recording request for \(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public)")
        return CGRequestScreenCaptureAccess()
    }

    public static func request(_ kind: PermissionPromptKind) {
        switch kind {
        case .accessibility:
            logger.info("Explicit Accessibility request for \(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public)")
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            logger.info("Explicit Input Monitoring request for \(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public)")
            _ = CGRequestListenEventAccess()
        }
    }
}

public struct AppWindowSnapshot: Equatable, Sendable {
    public let appName: String
    public let bundleIdentifier: String?
    public let processIdentifier: pid_t?
    public let windowTitle: String?

    public init(
        appName: String,
        bundleIdentifier: String?,
        processIdentifier: pid_t?,
        windowTitle: String?
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowTitle = windowTitle
    }
}

@MainActor
public final class AppWindowObserver: ObservableObject {
    @Published public private(set) var latest: AppWindowSnapshot

    public init() {
        latest = Self.snapshot()
    }

    @discardableResult
    public func refresh() -> AppWindowSnapshot {
        let snapshot = Self.snapshot()
        latest = snapshot
        return snapshot
    }

    public static func snapshot() -> AppWindowSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let title = frontmostWindowTitle(for: app?.processIdentifier)
        return AppWindowSnapshot(
            appName: app?.localizedName ?? "Unknown app",
            bundleIdentifier: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier,
            windowTitle: title
        )
    }

    private static func frontmostWindowTitle(for pid: pid_t?) -> String? {
        guard let pid else { return nil }
        let appRef = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused else {
            return nil
        }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }
}

public struct ContextRecorderStatus: Equatable, Sendable {
    public var running: Bool
    public var permissions: CapturePermissionStatus
    public var latestContext: RecordedContext?
    public var message: String
}

@MainActor
public final class ContextRecorder: ObservableObject {
    @Published public private(set) var status: ContextRecorderStatus

    private let store: CascadeStore
    private let observer: AppWindowObserver
    private var timer: Timer?

    public init(store: CascadeStore, observer: AppWindowObserver = AppWindowObserver()) {
        self.store = store
        self.observer = observer
        let permissions = PermissionProbe.currentStatus()
        status = ContextRecorderStatus(
            running: false,
            permissions: permissions,
            latestContext: nil,
            message: permissions.canRecordContext ? "Ready to record local context." : "Screen Recording is required before context recording starts."
        )
    }

    public func refreshPermissions() {
        let permissions = PermissionProbe.currentStatus()
        status.permissions = permissions
        if !permissions.canRecordContext {
            status.running = false
            status.message = "Screen Recording is required before context recording starts."
            timer?.invalidate()
            timer = nil
        }
    }

    public func start(interval: TimeInterval = 4.0) {
        refreshPermissions()
        guard status.permissions.canRecordContext else {
            status.message = "Open Settings to grant Screen Recording before recording."
            return
        }
        guard timer == nil else { return }
        status.running = true
        status.message = "Recording local context."
        captureOnce()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureOnce() }
        }
    }

    public func pause() {
        timer?.invalidate()
        timer = nil
        status.running = false
        status.message = "Recording paused."
    }

    public func captureOnce() {
        let snapshot = observer.refresh()
        let metadata = """
        {"processIdentifier":\(snapshot.processIdentifier.map(String.init) ?? "null")}
        """
        let context = RecordedContext(
            source: .app,
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle,
            ocrText: nil,
            metadataJSON: metadata
        )
        Task {
            do {
                let inserted = try await store.insert(context)
                _ = try await store.appendAudit(AuditEvent(actor: "system", action: "context.capture", detail: inserted.appName))
                await MainActor.run {
                    status.latestContext = inserted
                    status.message = status.running ? "Recording local context." : "Captured one context sample."
                }
            } catch {
                await MainActor.run {
                    status.message = "Could not write context: \(error.localizedDescription)"
                }
            }
        }
    }
}
