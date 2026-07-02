import ComputerUseKit
import CoreGraphics
import Foundation

// d17 (AX-first grounding, Screen2AX): visual-grounder output → synthetic
// AX-like nodes, applied at the grounding OUTPUT boundary.
//
// A successful vision ground (UI-TARS / a hosted VLM) used to leave the
// pipeline with a bare point: `role`, `label`, `region`, `displayBounds`, and
// `candidateID` all nil — precisely the fields every AX candidate populates
// (see `MixtureGrounder.axVerifierCandidate` / `markPickCandidate`). This
// converter distills each vision candidate into a `SyntheticAXNode` and fills
// ONLY those missing structural fields on the same `GroundingCandidate`, so
// the rest of the pipeline (executor guards, audits, caching, retry cropping)
// sees ONE structural interface regardless of which grounder answered.
//
// Trust is deliberately untouched: the candidate keeps its vision `source`
// (so the d13 trust order still ranks native AX above it — "AX outranks
// synthetic unless verification proves AX wrong"), keeps its own confidence,
// and enrichment runs AFTER verifier arbitration so a synthesized label can
// never masquerade as observed text evidence during verification.
public enum Screen2AX {
    /// Sources whose candidates are pixel-derived model output with no
    /// structural identity of their own. `.compatibility` is excluded on
    /// purpose — the legacy point wrapper is used by BOTH vision fallbacks and
    /// AX legacy points, so its provenance is ambiguous. `.cache` is excluded
    /// because cached results were already enriched (or deliberately not)
    /// when they were stored.
    public static let visionSources: Set<GroundingSource> = [.uiTars, .visualModel, .claude]

    /// Control-sized default frame when the grounder returned only a point —
    /// the same 96×28 box the AX label path assumes for a matched control.
    public static let defaultNodeSize = CGSize(width: 96, height: 28)

    static let maxLabelLength = 80

    /// The synthetic AX-like node for one vision candidate, or nil when the
    /// candidate is not vision-derived, has no point, or its coordinates are
    /// not display-local (a parse miss / un-mapped candidate must never grow
    /// an invented display frame).
    public static func syntheticNode(
        from candidate: GroundingCandidate,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) -> SyntheticAXNode? {
        guard visionSources.contains(candidate.source),
              candidate.coordinateSpace == .displayLocalAppKitPoints,
              let point = candidate.point else { return nil }
        let role = candidate.role ?? SyntheticAXNode.inferredRole(forTarget: target)
        let label = normalizedLabel(candidate.label ?? target)
        let frame = candidate.region
            ?? candidate.displayBounds
            ?? defaultFrame(
                around: point,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints
            )
        return SyntheticAXNode(
            role: role,
            label: label,
            frame: frame,
            confidence: candidate.confidence
        )
    }

    /// Every vision candidate in the result, converted through its synthetic
    /// node: missing structural fields filled, everything observed (point,
    /// confidence, source, coordinate chain, latency, dispersion) untouched.
    /// Selection metadata, verdicts, and candidate order carry over, so the
    /// enriched result is a drop-in replacement.
    public static func enriched(
        _ result: GroundingResult,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) -> GroundingResult {
        guard result.candidates.contains(where: { needsEnrichment($0) }) else { return result }
        return GroundingResult(
            candidates: result.candidates.map {
                enrichedCandidate(
                    $0,
                    target: target,
                    displayWidthPoints: displayWidthPoints,
                    displayHeightPoints: displayHeightPoints
                )
            },
            selectedIndex: result.selectedIndex,
            selectedCandidateID: result.selectedCandidateID,
            verifierVerdict: result.verifierVerdict,
            verifierFailureKind: result.verifierFailureKind,
            alternativeCount: result.alternativeCount
        )
    }

    /// One candidate through the Screen2AX fill: role, label, frame
    /// (region/displayBounds), and stable id are populated ONLY where nil —
    /// a candidate that already carries structure (AX, OCR, marked picks)
    /// passes through unchanged, as does anything the node builder refuses.
    public static func enrichedCandidate(
        _ candidate: GroundingCandidate,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) -> GroundingCandidate {
        guard needsEnrichment(candidate),
              let node = syntheticNode(
                  from: candidate,
                  target: target,
                  displayWidthPoints: displayWidthPoints,
                  displayHeightPoints: displayHeightPoints
              )
        else { return candidate }
        return GroundingCandidate(
            point: candidate.point,
            region: candidate.region ?? node.frame,
            confidence: candidate.confidence,
            source: candidate.source,
            coordinateSpace: candidate.coordinateSpace,
            rawModel: candidate.rawModel,
            latency: candidate.latency,
            dispersion: candidate.dispersion,
            reason: candidate.reason.map { "\($0) screen2ax" } ?? "screen2ax",
            candidateID: candidate.candidateID ?? node.stableID,
            markNumber: candidate.markNumber,
            displayBounds: candidate.displayBounds ?? node.frame,
            imageBounds: candidate.imageBounds,
            role: candidate.role ?? node.role,
            label: candidate.label ?? node.label,
            nearbyOCRText: candidate.nearbyOCRText,
            ocrDistancePoints: candidate.ocrDistancePoints,
            agreeingSources: candidate.agreeingSources,
            coordinateChain: candidate.coordinateChain
        )
    }

    /// A vision candidate with a display-local point that is missing any of
    /// the structural fields an AX candidate would carry.
    static func needsEnrichment(_ candidate: GroundingCandidate) -> Bool {
        guard visionSources.contains(candidate.source),
              candidate.coordinateSpace == .displayLocalAppKitPoints,
              candidate.point != nil else { return false }
        return candidate.role == nil
            || candidate.label == nil
            || candidate.candidateID == nil
            || (candidate.region == nil && candidate.displayBounds == nil)
    }

    /// Control-sized frame centered on the grounded point, clamped on screen.
    static func defaultFrame(
        around point: CGPoint,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) -> CGRect {
        let w = min(defaultNodeSize.width, CGFloat(max(1, displayWidthPoints)))
        let h = min(defaultNodeSize.height, CGFloat(max(1, displayHeightPoints)))
        let x = max(0, min(point.x - w / 2, CGFloat(displayWidthPoints) - w))
        let y = max(0, min(point.y - h / 2, CGFloat(displayHeightPoints) - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The label a synthetic node carries in-memory: whitespace-collapsed and
    /// bounded. It never reaches an audit row raw — audits hash it (the same
    /// treatment native AX labels get).
    static func normalizedLabel(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(maxLabelLength))
    }
}
