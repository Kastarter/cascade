import GovernanceKit
import PerceptionCore
import ProviderKit
import Testing
@testable import AppShell

// MARK: - CUAction → ActionDescriptor mapper pins (all 15 cases)

@Test
func actionDescriptorKindTokensMatchCUStepVocabulary() {
    let cases: [(CUAction, String)] = [
        (.move(x: 1, y: 2), "move"),
        (.click(x: 1, y: 2), "click"),
        (.doubleClick(x: 1, y: 2), "double_click"),
        (.tripleClick(x: 1, y: 2), "triple_click"),
        (.rightClick(x: 1, y: 2), "right_click"),
        (.drag(fromX: 1, fromY: 2, toX: 3, toY: 4), "drag"),
        (.type("hello"), "type"),
        (.key("cmd+a"), "key"),
        (.scroll(x: 1, y: 2, direction: "down", amount: 3), "scroll"),
        (.wait, "wait"),
        (.screenshot, "screenshot"),
        (.openApp("Keynote"), "open_app"),
        (.openURL("https://example.com"), "open_url"),
        (.zoom(nx: 0, ny: 0, nw: 1, nh: 1), "zoom"),
        (.highlight(x: 1, y: 2, width: 3, height: 4, label: "here"), "highlight"),
    ]
    for (action, expected) in cases {
        #expect(CascadeAppModel.actionDescriptor(for: action).kindToken == expected)
    }
}

@Test
func actionDescriptorCarriesPayloadFieldsAndOmitsGeometry() {
    let typed = CascadeAppModel.actionDescriptor(for: .type("hello world"))
    #expect(typed.typedText == "hello world")
    #expect(typed.targetText == nil)

    let app = CascadeAppModel.actionDescriptor(for: .openApp("Keynote"))
    #expect(app.targetText == "Keynote")

    let url = CascadeAppModel.actionDescriptor(for: .openURL("https://example.com"))
    #expect(url.targetText == "https://example.com")

    let highlight = CascadeAppModel.actionDescriptor(
        for: .highlight(x: 10, y: 20, width: 30, height: 40, label: "the save button"))
    #expect(highlight.targetText == "the save button")

    // point is DELIBERATELY nil for every case — CUAction coords are display-local
    // AppKit; mapping them into Point<FrameSpace> without a typed converter is the
    // 34c2efa mis-spaced bug class.
    let allActions: [CUAction] = [
        .move(x: 1, y: 2), .click(x: 1, y: 2), .doubleClick(x: 1, y: 2),
        .tripleClick(x: 1, y: 2), .rightClick(x: 1, y: 2),
        .drag(fromX: 1, fromY: 2, toX: 3, toY: 4), .type("t"), .key("k"),
        .scroll(x: 1, y: 2, direction: "up", amount: 1), .wait, .screenshot,
        .openApp("A"), .openURL("u"), .zoom(nx: 0, ny: 0, nw: 1, nh: 1),
        .highlight(x: 1, y: 2, width: 3, height: 4, label: "l"),
    ]
    for action in allActions {
        #expect(CascadeAppModel.actionDescriptor(for: action).point == nil)
    }
}

// MARK: - executeCU governance gate (structural, LAW 1)

/// A hostile enforcer proving the ON wiring can actually STOP an action — the gate
/// is control flow, not advice the model could ignore.
private struct DropEverythingEnforcer: PolicyEnforcing {
    func evaluateCapture(_ ctx: CaptureContext) -> PolicyVerdict { .allow }
    func evaluateAction(_ action: ActionDescriptor, risk: ActionRisk) -> PolicyVerdict {
        .drop(reason: "tenant-blocked")
    }
}

private struct PauseEverythingEnforcer: PolicyEnforcing {
    func evaluateCapture(_ ctx: CaptureContext) -> PolicyVerdict { .allow }
    func evaluateAction(_ action: ActionDescriptor, risk: ActionRisk) -> PolicyVerdict {
        .pause(reason: "needs-supervisor")
    }
}

@Test
func governanceGateBlocksWhenEnforcerDropsAndAuditsKindToken() {
    let detail = CascadeAppModel.governanceBlockDetail(
        enforcer: DropEverythingEnforcer(),
        action: .click(x: 10, y: 20)
    )
    #expect(detail != nil)
    #expect(detail?.contains("kind=click") == true)
    // The reason is AuditIdentity-hashed — the raw string must not leak into audit detail.
    #expect(detail?.contains("tenant-blocked") == false)
}

@Test
func governanceGateBlocksOnPauseToo() {
    let detail = CascadeAppModel.governanceBlockDetail(
        enforcer: PauseEverythingEnforcer(),
        action: .type("secret")
    )
    #expect(detail != nil)
    #expect(detail?.contains("kind=type") == true)
    // Typed text must never appear in the audit detail.
    #expect(detail?.contains("secret") == false)
}

/// A risk-keyed enforcer: blocks anything the gate classifies above `.low`. Proves
/// the gate hands the enforcer the REAL PreActionVerifier classification, not a
/// hardcoded `.low` (which would make every risk-keyed tenant policy under-block).
private struct BlockNonLowRiskEnforcer: PolicyEnforcing {
    func evaluateCapture(_ ctx: CaptureContext) -> PolicyVerdict { .allow }
    func evaluateAction(_ action: ActionDescriptor, risk: ActionRisk) -> PolicyVerdict {
        risk == .low ? .allow : .drop(reason: "risk:\(risk.rawValue)")
    }
}

@Test
func governanceGatePassesRealPerActionRiskNotHardcodedLow() {
    let enforcer = BlockNonLowRiskEnforcer()
    // cmd+q is an irreversible combo ⇒ PreActionVerifier classifies destructive ⇒ blocked.
    #expect(CascadeAppModel.governanceBlockDetail(enforcer: enforcer, action: .key("cmd+q")) != nil)
    // Typing text with destructive intent ⇒ non-low ⇒ blocked.
    #expect(CascadeAppModel.governanceBlockDetail(enforcer: enforcer, action: .type("delete the invoice")) != nil)
    // A plain click / benign typing stays low ⇒ allowed.
    #expect(CascadeAppModel.governanceBlockDetail(enforcer: enforcer, action: .click(x: 1, y: 2)) == nil)
    #expect(CascadeAppModel.governanceBlockDetail(enforcer: enforcer, action: .type("hello")) == nil)
}

@Test
func governanceGateAllowsWithDefaultPolicyAndWithNoEnforcer() {
    // Flag OFF ⇒ enforcer nil ⇒ nothing blocks (the shipped path).
    #expect(CascadeAppModel.governanceBlockDetail(enforcer: nil, action: .click(x: 1, y: 2)) == nil)
    // Flag ON with the built-in default ⇒ still nothing blocks (behavior == today).
    let defaultEnforcer = DefaultGovernancePolicy(capture: .default, tenant: nil)
    let allActions: [CUAction] = [
        .move(x: 1, y: 2), .click(x: 1, y: 2), .doubleClick(x: 1, y: 2),
        .tripleClick(x: 1, y: 2), .rightClick(x: 1, y: 2),
        .drag(fromX: 1, fromY: 2, toX: 3, toY: 4), .type("t"), .key("cmd+q"),
        .scroll(x: 1, y: 2, direction: "up", amount: 1), .wait, .screenshot,
        .openApp("A"), .openURL("u"), .zoom(nx: 0, ny: 0, nw: 1, nh: 1),
        .highlight(x: 1, y: 2, width: 3, height: 4, label: "l"),
    ]
    for action in allActions {
        #expect(CascadeAppModel.governanceBlockDetail(enforcer: defaultEnforcer, action: action) == nil)
    }
}
