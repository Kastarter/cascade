import AppKit
import Foundation
import ProviderKit

// MARK: - Web grounding split (the background analog of MixtureGrounder)
//
// The on-screen Scout grounds named targets AX-first, falling back to UI-TARS on a
// screenshot (MixtureGrounder). The web sandbox has an even better structural source
// than AX — the live DOM — so the background Scout grounds DOM-first: it resolves a
// named target to an element by its text/aria-label/placeholder/role/contenteditable
// and returns that element's click point, for free, with no network round trip and
// no snapshot-coordinate error. Only when the DOM can't find the target does it fall
// back to a visual grounder (UI-TARS on the snapshot), for the rare canvas/image-map
// case. This is what makes the background Scout as efficient as the on-screen one —
// most web targets resolve structurally — and it fixes the audited Notion failure,
// where the title is a contenteditable the DOM resolver now sees. See
// [[cascade-cu-downgrade-research]].

/// A `VisualGrounder` that resolves named targets against the sandbox's live DOM,
/// falling back to an optional visual grounder on a miss.
public struct WebDOMGrounder: VisualGrounder {
    private let sandbox: WebSandbox
    private let fallback: (any VisualGrounder)?

    /// - Parameters:
    ///   - sandbox: the web sandbox whose DOM is queried (its `@MainActor` isolation
    ///     makes it safely Sendable to hold here).
    ///   - fallback: a visual grounder (e.g. hosted UI-TARS) used only when the DOM
    ///     resolver finds nothing — omit for DOM-only grounding (needs no API key).
    public init(sandbox: WebSandbox, fallback: (any VisualGrounder)? = nil) {
        self.sandbox = sandbox
        self.fallback = fallback
    }

    public func ground(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> CGPoint? {
        await groundResult(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        ).selectedPoint
    }

    public func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult {
        // DOM-first: free, exact, sees contenteditable. The viewport height flips the
        // top-left CSS point the DOM reports into the bottom-left space the sandbox
        // executor consumes (the same space WebSandbox.height defines).
        if let point = await sandbox.domGround(target: target, viewportHeight: CGFloat(displayHeightPoints)) {
            let rect = UITARSGrounder.boxAround(
                point: point,
                displayW: displayWidthPoints,
                displayH: displayHeightPoints
            )
            return GroundingResult(
                candidates: [
                    GroundingCandidate(
                        point: point,
                        region: rect,
                        confidence: 0.96,
                        source: .dom,
                        coordinateSpace: .displayLocalAppKitPoints,
                        reason: "dom label match",
                        candidateID: "dom-\(Self.stableHash(target))",
                        displayBounds: rect
                    )
                ],
                selectedIndex: 0
            )
        }
        // Visual fallback (UI-TARS on the snapshot) for what the DOM can't name.
        guard let fallback else {
            return GroundingResult(
                candidates: [
                    GroundingCandidate(
                        point: nil,
                        confidence: 0,
                        source: .dom,
                        coordinateSpace: .viewportCSSPixelsTopLeft,
                        reason: "dom miss; no visual fallback"
                    )
                ],
                selectedIndex: nil,
                verifierVerdict: .abstain,
                verifierFailureKind: .noCandidates
            )
        }
        let result = await fallback.groundResult(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        guard !result.candidates.isEmpty else {
            return GroundingResult(
                candidates: [
                    GroundingCandidate(
                        point: nil,
                        confidence: 0,
                        source: .dom,
                        coordinateSpace: .viewportCSSPixelsTopLeft,
                        reason: "dom miss; visual fallback miss"
                    )
                ],
                selectedIndex: nil,
                verifierVerdict: result.verifierVerdict ?? .abstain,
                verifierFailureKind: result.verifierFailureKind ?? .noCandidates
            )
        }
        return GroundingResult(
            candidates: result.candidates.map { candidate in
                GroundingCandidate(
                    point: candidate.point,
                    region: candidate.region,
                    confidence: candidate.confidence,
                    source: candidate.source,
                    coordinateSpace: candidate.coordinateSpace,
                    rawModel: candidate.rawModel,
                    latency: candidate.latency,
                    dispersion: candidate.dispersion,
                    reason: [candidate.reason, "dom fallback"].compactMap { $0 }.joined(separator: " "),
                    candidateID: candidate.candidateID,
                    markNumber: candidate.markNumber,
                    displayBounds: candidate.displayBounds,
                    imageBounds: candidate.imageBounds
                )
            },
            selectedIndex: result.selectedIndex,
            selectedCandidateID: result.selectedCandidateID,
            verifierVerdict: result.verifierVerdict,
            verifierFailureKind: result.verifierFailureKind,
            alternativeCount: result.alternativeCount
        )
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
