import CascadeMemory
import Foundation

// MARK: - d15 routing gate: AX-first, vision only for canvas / non-AX / stale-AX
//
// ONE place that decides, per grounding request, whether the AX-first path may
// run or the request belongs to the visual grounder. Before d15 these checks
// were scattered across `MixtureGrounder` call sites (`namesCanvasConcept`
// guards, the Cascade-own-UI guard, `AppSkill.axUnreliable`,
// `AXRuntimeProfile.isSparse`) — the same policy re-implemented per entry
// point, with no record of WHY a request skipped AX. The router folds them
// into a single decision whose reason is a stable audit token, so every
// vision-only route is visible in the `grounding.route` audit trail.
//
// AX-first is the DEFAULT; vision is the exception:
//  • canvas concept — the target names a drawn surface (canvas / placeholder)
//    with no faithful AX node; a fuzzy label match would hijack chrome (the
//    Keynote "title placeholder" → Format-panel "Title" checkbox failure).
//  • own UI — Cascade's own window is frontmost; AX-first would read ITS tree
//    and click Cascade instead of the app behind it (the audited
//    "Agents"/"Create new…" hijack). The captured screenshot excludes
//    Cascade's windows, so the visual grounder sees the real target.
//  • ax_unreliable_app — the app's skill explicitly distrusts its AX tree
//    (Blender, Figma, Photoshop): canvas/Electron surfaces where AX lies.
//  • sparse_ax — the live runtime profile shows a tree too thin to trust
//    (few/unlabeled actionables, error-dominated, canvas-sized nodes).
//  • stale_ax — the tree answers but its nodes are dying under the reader
//    (stale-node errors dominate the sample): frames can't be trusted, so a
//    "successful" AX match may click where the control used to be. New in
//    d15 and flag-gated (`staleAXGateEnabled` rides the same
//    `cascade.experimentalCompressedObservation` cluster as d11–d13); gate
//    off keeps shipped routing byte-identical.
public enum GroundingRouter {
    /// Why a request was routed away from the AX-first path. Raw values are
    /// stable audit vocabulary (`grounding.route` rows) — never repurpose.
    public enum VisualRouteReason: String, Sendable, Equatable, CaseIterable {
        case canvasConcept = "canvas_concept"
        case ownUI = "own_ui"
        case axUnreliableApp = "ax_unreliable_app"
        case sparseAX = "sparse_ax"
        case staleAX = "stale_ax"
    }

    /// What the caller may ground with for one request.
    public enum Route: Equatable, Sendable {
        /// Default: resolve structurally via AX first; the visual grounder
        /// stays the fallback for what AX cannot see.
        case axFirst
        /// AX is skipped for this request; the visual grounder owns it.
        case visualOnly(VisualRouteReason)
    }

    /// The grounding entry point being gated. A mark pick resolves a
    /// planner-named STABLE ID against a fresh harvest — identity is exact,
    /// not a fuzzy label match — so the canvas-word and sparse/stale-tree
    /// protections (which exist to keep fuzzy label matches honest) do not
    /// apply and no runtime-profile scrape is spent on it. App-level distrust
    /// (own UI, `axUnreliable`) always applies.
    public enum RequestKind: String, Sendable, Equatable {
        case labelMatch = "label"
        case markPick = "mark"
    }

    /// One request's routing decision plus the audit-safe evidence behind it.
    public struct Decision: Equatable, Sendable {
        public let route: Route
        public let requestKind: RequestKind
        /// The runtime profile the router evaluated to decide. nil when the
        /// decision was made before the profile stage (own UI / distrusted
        /// app / canvas target) or for mark picks, which never scrape one.
        public let runtimeProfile: AXRuntimeProfile?
        /// SHA-256 audit hash of the frontmost bundle id — hashes only.
        public let bundleHash: String

        public init(
            route: Route,
            requestKind: RequestKind,
            runtimeProfile: AXRuntimeProfile? = nil,
            bundleHash: String
        ) {
            self.route = route
            self.requestKind = requestKind
            self.runtimeProfile = runtimeProfile
            self.bundleHash = bundleHash
        }

        public var allowsAX: Bool {
            if case .axFirst = route { return true }
            return false
        }

        public var visualReason: VisualRouteReason? {
            if case .visualOnly(let reason) = route { return reason }
            return nil
        }

        /// Audit-safe summary: enum tokens, hashes, and counts only — never
        /// the target text, labels, or OCR content.
        public var safeAuditDetail: String {
            var parts = ["route=\(allowsAX ? "ax_first" : "visual_only")"]
            if let reason = visualReason {
                parts.append("reason=\(reason.rawValue)")
            }
            parts.append("kind=\(requestKind.rawValue)")
            parts.append("bundleHash=\(bundleHash)")
            if let profile = runtimeProfile {
                parts.append("nodes=\(profile.sampledNodeCount)")
                parts.append("actionable=\(profile.actionableRoleCount)")
                parts.append("labeledActionable=\(profile.labeledActionableCount)")
                parts.append("errors=\(profile.timeoutOrErrorCount)")
                parts.append("staleNodes=\(profile.axErrorSummary.staleNodeCount)")
                parts.append("canvasRatio=\(String(format: "%.2f", profile.canvasSizedElementRatio))")
                parts.append("sparse=\(profile.isSparse ? "true" : "false")")
            }
            return parts.joined(separator: " ")
        }
    }

    /// Stale-node errors at or above this share of the sampled tree mark the
    /// AX snapshot untrustworthy for fuzzy label grounding.
    public static let staleNodeRatioThreshold = 0.25
    /// …but never on a trivial sample: below this many stale hits the tree is
    /// noisy, not dying.
    public static let staleNodeMinimumCount = 4

    /// True when the profile's sample is stale-node dominated: the tree
    /// responds, but enough nodes vanished mid-read that any matched frame may
    /// describe where a control USED to be. Pure + unit-pinned.
    public static func isStaleDominated(_ profile: AXRuntimeProfile) -> Bool {
        let stale = profile.axErrorSummary.staleNodeCount
        guard stale >= staleNodeMinimumCount else { return false }
        let sampled = max(profile.sampledNodeCount + stale, 1)
        return Double(stale) / Double(sampled) >= staleNodeRatioThreshold
    }

    /// Words that denote a drawn surface with no faithful accessibility node,
    /// so a target naming one must be grounded visually, never by AX label
    /// match. Kept tiny and generic — these are not app-specific UI labels.
    /// Pure + pinned. (Moved from `MixtureGrounder.namesCanvasConcept`.)
    public static func namesCanvasConcept(_ target: String) -> Bool {
        let t = target.lowercased()
        return t.contains("placeholder") || t.contains("canvas")
    }

    /// THE routing gate. Checks are ordered cheapest-first and by authority:
    /// app-level distrust (own UI, `axUnreliable`) → target semantics (canvas
    /// concept) → live tree health (sparse, then stale). `runtimeProfile` is a
    /// closure so the AX scrape is only paid when routing actually reaches the
    /// tree-health stage (never for distrusted apps or mark picks).
    public static func route(
        target: String,
        requestKind: RequestKind = .labelMatch,
        frontmostBundleIdentifier: String?,
        ownBundleIdentifier: String? = nil,
        axUnreliable: Bool,
        staleAXGateEnabled: Bool = false,
        runtimeProfile: () -> AXRuntimeProfile? = { nil }
    ) -> Decision {
        let bundleHash = AuditIdentity.hash(frontmostBundleIdentifier)
        func decision(_ route: Route, profile: AXRuntimeProfile? = nil) -> Decision {
            Decision(
                route: route,
                requestKind: requestKind,
                runtimeProfile: profile,
                bundleHash: bundleHash
            )
        }
        // App-level distrust applies to EVERY request kind.
        if let ownBundleIdentifier, frontmostBundleIdentifier == ownBundleIdentifier {
            return decision(.visualOnly(.ownUI))
        }
        if axUnreliable {
            return decision(.visualOnly(.axUnreliableApp))
        }
        // Mark picks resolve exact planner-named ids — the fuzzy-label
        // protections below do not apply, and no profile scrape is spent.
        guard requestKind == .labelMatch else {
            return decision(.axFirst)
        }
        if namesCanvasConcept(target) {
            return decision(.visualOnly(.canvasConcept))
        }
        let profile = runtimeProfile()
        if let profile, profile.isSparse {
            return decision(.visualOnly(.sparseAX), profile: profile)
        }
        if staleAXGateEnabled, let profile, isStaleDominated(profile) {
            return decision(.visualOnly(.staleAX), profile: profile)
        }
        return decision(.axFirst, profile: profile)
    }
}
