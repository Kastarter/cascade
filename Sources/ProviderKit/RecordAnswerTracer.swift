import CascadeMemory
import Foundation

/// Diagnosis-only timing tracer for the rewind-chat path
/// (CascadeAppModel.ask → CascadeOrchestrator.askRecord → RecordSearchAnswerer).
///
/// INSTRUMENT ONLY — it never changes control flow. Behind the DEFAULT-OFF
/// UserDefaults bool `cascade.recordAnswerTracing`; when the flag is false or
/// absent `ifEnabled` returns nil and every `await tracer?.emit(...)` is a
/// no-op (optional chaining skips argument evaluation too), so the OFF path
/// writes zero audit rows and reads zero clocks beyond a captured DispatchTime
/// that is never used.
///
/// To diagnose a "Searching your record…" hang:
///   defaults write com.humain.cascade cascade.recordAnswerTracing -bool YES
/// reproduce the hang, then:
///   SELECT created_at, detail FROM audit_event
///   WHERE action='record.answer.trace' ORDER BY id
/// The last stage row before silence names the pre-LLM blocker. Cross-layer
/// rows join on qhash= (AuditIdentity.hash of the question) plus per-layer
/// ask= ids and t= offsets. Question text is NEVER stored — only hashes and
/// character counts.
/// Carries a `UserDefaults` across Sendable boundaries for the per-call flag
/// read. UserDefaults is documented thread-safe but the SDK does not mark it
/// Sendable, hence the `@unchecked` box (same trust as `.standard` reads
/// elsewhere in the codebase).
public struct RecordAnswerTracingDefaults: @unchecked Sendable {
    public let defaults: UserDefaults

    public init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }
}

public struct RecordAnswerTracer: Sendable {
    public static let flagKey = "cascade.recordAnswerTracing"
    public static let auditAction = "record.answer.trace"

    /// 6-hex random correlation id, unique per traced ask within one layer.
    public let askID: String
    private let store: CascadeStore
    private let start: DispatchTime

    /// Non-nil only when the user has flipped the flag ON. Read per call so a
    /// flip takes effect without relaunching the app.
    public static func ifEnabled(store: CascadeStore, defaults: UserDefaults = .standard) -> RecordAnswerTracer? {
        guard defaults.bool(forKey: flagKey) else { return nil }
        return RecordAnswerTracer(store: store)
    }

    private init(store: CascadeStore) {
        self.store = store
        self.askID = String(format: "%06x", UInt32.random(in: 0...0xFFFFFF))
        self.start = DispatchTime.now()
    }

    /// Milliseconds since this tracer was created (= since the layer's ask began).
    public func elapsedMs() -> Int {
        Self.millisecondsSince(start)
    }

    /// Milliseconds since an arbitrary step start — for per-step span fields.
    public static func millisecondsSince(_ stepStart: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- stepStart.uptimeNanoseconds) / 1_000_000)
    }

    /// Appends one trace row. Awaited inline on the store actor so test
    /// assertions are deterministic; failures are swallowed (tracing must
    /// never break the answer path).
    public func emit(_ stage: String, _ fields: [(String, String)] = []) async {
        var detail = "ask=\(askID) t=\(elapsedMs()) stage=\(stage)"
        for (key, value) in fields {
            detail += " \(key)=\(value)"
        }
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: Self.auditAction, detail: detail))
    }
}
