import CascadeMemory
import CoreGraphics
import Foundation

// d17 (AX-first grounding, Screen2AX): synthetic AX-like nodes from vision.
//
// Only ~a third of macOS apps expose a full accessibility tree (Screen2AX);
// for the rest — canvases, custom-drawn controls, some Electron surfaces —
// the visual grounder answers "where is X" with a bare pixel-derived point.
// Until now that answer stayed a bare point: no role, no label, no frame, no
// actions — so every downstream consumer (verifier evidence, audits, planner
// notes, the executor's hit-test guards) had a SECOND, weaker shape to handle.
//
// `SyntheticAXNode` closes that split: vision output is distilled into the
// SAME structural node shape a native AX harvest produces — `{source: vision,
// role, label, frame, confidence, actions}` plus a stable id — and can be
// handed to any `AXElementResolver.Match` consumer via `asMatch`. The node is
// honest about its provenance: `source` is always `.vision`, its id lives in
// the `vax:` namespace (which the d12 mark-token regex deliberately cannot
// match, so a synthetic node can never be picked as a native AX mark), and its
// trust NEVER rises above the visual grounder's own confidence — native AX
// outranks synthetic in the d13 trust order unless verification proved AX
// wrong. Pure value type; no AX traffic, no live element reference.
public struct SyntheticAXNode: Sendable, Equatable {
    /// Where the synthesized node's evidence came from. Only vision today —
    /// AX/OCR/DOM candidates already carry real structural identity.
    public enum Source: String, Codable, Sendable, Equatable {
        case vision
    }

    public let source: Source
    /// Best-effort AX role inferred for the target ("AXButton" unless the
    /// target's own words say field/checkbox/menu/…). Never trusted as a real
    /// role — it exists so role-shaped consumers see a familiar token.
    public let role: String
    public let label: String
    /// Display-local AppKit points (bottom-left origin) — the executor's
    /// click space, exactly like a mapped AX candidate frame.
    public let frame: CGRect
    /// The visual grounder's own confidence, clamped to 0…1. Deliberately NOT
    /// inflated by the synthesized structure — the structure is derived, not
    /// observed evidence.
    public let confidence: Double
    /// AX-action vocabulary the inferred role would support (AXPress,
    /// AXConfirm, AXIncrement…). Descriptive parity with native nodes: there
    /// is no live AXUIElement behind a synthetic node, so these describe the
    /// intended interaction (executed by coordinate), never a callable action.
    public let actions: [String]
    /// Stable id in the `vax:` namespace (vision-AX) — deterministic over
    /// role + normalized label + a coarse frame bucket, so the same control
    /// keeps its identity across small jitter while distinct controls hash
    /// apart. Never `ax:` — synthetic ids must not collide with native marks.
    public let stableID: String

    public init(
        source: Source = .vision,
        role: String,
        label: String,
        frame: CGRect,
        confidence: Double,
        actions: [String]? = nil
    ) {
        self.source = source
        self.role = role
        self.label = label
        self.frame = frame
        self.confidence = min(1, max(0, confidence))
        self.actions = actions ?? Self.actions(forRole: role)
        self.stableID = Self.stableID(role: role, label: label, frame: frame)
    }

    // MARK: - Role / action inference (deterministic, unit-pinned)

    /// Infers an AX role from the words the planner used to NAME the target —
    /// "the search field" is a text field, "the Wi-Fi toggle" a checkbox.
    /// Deterministic, first-match-wins, defaults to AXButton (a click target).
    public static func inferredRole(forTarget target: String) -> String {
        let t = target.lowercased()
        func hasAny(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if hasAny(["field", "text box", "textbox", "input", "search", "placeholder", "text area", "textarea"]) {
            return "AXTextField"
        }
        if hasAny(["checkbox", "check box", "toggle", "switch"]) { return "AXCheckBox" }
        if hasAny(["radio"]) { return "AXRadioButton" }
        if hasAny(["menu bar"]) { return "AXMenuBarItem" }
        if hasAny(["menu"]) { return "AXMenuItem" }
        if hasAny(["tab "]) || t.hasSuffix(" tab") { return "AXTab" }
        if hasAny(["link", "hyperlink", "url"]) { return "AXLink" }
        if hasAny(["slider"]) { return "AXSlider" }
        if hasAny(["disclosure"]) { return "AXDisclosureTriangle" }
        if hasAny(["row", "cell", "list item"]) { return "AXRow" }
        return "AXButton"
    }

    /// The AX-action vocabulary a native node of this role typically exposes,
    /// derived through the same role→modality mapping the compressed planner
    /// observation uses (d10) so the two can never disagree.
    public static func actions(forRole role: String) -> [String] {
        switch AXCompressedObservation.modality(role: role, supportedActions: []) {
        case .type:
            return ["AXConfirm"]
        case .adjust:
            return ["AXIncrement", "AXDecrement"]
        case .click, .toggle, .select, .disclose:
            return ["AXPress"]
        }
    }

    /// Deterministic synthetic identity: role + tolerantly-normalized label +
    /// the frame center bucketed to 16pt cells (small jitter keeps identity,
    /// different controls hash apart). Namespaced `vax:` on purpose — see
    /// the type comment.
    public static func stableID(role: String, label: String, frame: CGRect) -> String {
        let bucket: CGFloat = 16
        let cx = Int((frame.midX / bucket).rounded(.down))
        let cy = Int((frame.midY / bucket).rounded(.down))
        let material = [role, AXElementResolver.normalize(label), String(cx), String(cy)]
            .joined(separator: "|")
        return "vax:\(AuditIdentity.hash(material))"
    }

    // MARK: - The shared structural interface

    /// The node as the SAME structural value a native AX harvest produces, so
    /// every `Match` consumer (compressed observation rendering, semantic
    /// hit-test guards, future mark surfacing) can consume a synthetic node
    /// identically to a native one. `displayCGBounds` is the CG-global bounds
    /// of the display the node's frame is local to — Match centers/frames are
    /// CG-global top-left while the node frame is display-local bottom-left,
    /// and that conversion must be explicit, never guessed. The match score is
    /// `confidence × 3` (the AX label-match scale, 3 = exact) so a synthetic
    /// node can never outrank an exact native match.
    public func asMatch(displayCGBounds bounds: CGRect) -> AXElementResolver.Match? {
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let center = CGPoint(
            x: bounds.minX + frame.midX,
            y: bounds.minY + (bounds.height - frame.midY)
        )
        let cgFrame = CGRect(
            x: bounds.minX + frame.minX,
            y: bounds.minY + (bounds.height - frame.maxY),
            width: frame.width,
            height: frame.height
        )
        return AXElementResolver.Match(
            id: stableID,
            center: center,
            frame: cgFrame,
            role: role,
            title: label,
            score: confidence * 3,
            actionableNode: AXElementResolver.ActionableNode(
                stableID: stableID,
                role: role,
                title: label,
                supportedActions: actions,
                enabled: true
            )
        )
    }
}
