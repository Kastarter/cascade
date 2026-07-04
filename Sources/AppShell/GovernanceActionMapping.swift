import CascadeMemory
import Foundation
import GovernanceKit
import PerceptionCore
import ProviderKit

// The ONE CUAction → ActionDescriptor boundary (§3.2/§7). GovernanceKit must never
// import ProviderKit, so the mapping lives here at the callsite, in AppShell.
extension CascadeAppModel {
    /// Maps a CUAction to GovernanceKit's leaf-safe ActionDescriptor. `kindToken`
    /// uses the same vocabulary as `CUStep.kindToken`. `point` is DELIBERATELY nil:
    /// CUAction coordinates are display-local AppKit points and
    /// `ActionDescriptor.point` is `Point<FrameSpace>` — converting spaces here
    /// without a typed mapper is exactly the 34c2efa mis-spaced-rect bug class, so
    /// geometry is omitted until a space-typed conversion exists.
    nonisolated static func actionDescriptor(for action: CUAction) -> ActionDescriptor {
        switch action {
        case .move:
            ActionDescriptor(kindToken: "move")
        case .click:
            ActionDescriptor(kindToken: "click")
        case .doubleClick:
            ActionDescriptor(kindToken: "double_click")
        case .tripleClick:
            ActionDescriptor(kindToken: "triple_click")
        case .rightClick:
            ActionDescriptor(kindToken: "right_click")
        case .drag:
            ActionDescriptor(kindToken: "drag")
        case .type(let text):
            ActionDescriptor(kindToken: "type", typedText: text)
        case .key:
            ActionDescriptor(kindToken: "key")
        case .scroll:
            ActionDescriptor(kindToken: "scroll")
        case .wait:
            ActionDescriptor(kindToken: "wait")
        case .screenshot:
            ActionDescriptor(kindToken: "screenshot")
        case .openApp(let name):
            ActionDescriptor(kindToken: "open_app", targetText: name)
        case .openURL(let url):
            ActionDescriptor(kindToken: "open_url", targetText: url)
        case .zoom:
            ActionDescriptor(kindToken: "zoom")
        case .highlight(_, _, _, _, let label):
            ActionDescriptor(kindToken: "highlight", targetText: label)
        }
    }

    /// The executeCU governance gate, extracted pure for tests. Returns `nil` when
    /// the action may proceed (no enforcer configured — the default — or the
    /// enforcer allows); a non-nil value is the audit detail for the blocked
    /// action (kindToken in the clear, reason AuditIdentity-hashed). With the flag
    /// OFF the enforcer is nil, so this is a single nil-check: no descriptor
    /// built, no defaults read, no audit row, no risk classification.
    ///
    /// `risk` is the REAL per-action classification from ProviderKit's pure
    /// `PreActionVerifier.verify(action:)` (irreversible key combos ⇒ destructive,
    /// destructive/privacy-sensitive text intent + external URLs/side-effect text
    /// ⇒ high, everything else low) — never a hardcoded placeholder, so a future
    /// risk-keyed tenant policy sees honest values from day one.
    nonisolated static func governanceBlockDetail(
        enforcer: (any PolicyEnforcing)?,
        action: CUAction
    ) -> String? {
        guard let enforcer else { return nil }
        let descriptor = actionDescriptor(for: action)
        switch enforcer.evaluateAction(descriptor, risk: PreActionVerifier.verify(action: action).risk) {
        case .allow, .redact:
            return nil
        case .drop(let reason), .pause(let reason):
            return "kind=\(descriptor.kindToken) " + AuditIdentity.descriptor("reason", reason)
        }
    }
}
