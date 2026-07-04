// StableAXSnapshot — constructor-enforced multi-sampled AX perception (§4a PERCEIVE).
//
// Structuralizes the 27a6fc8 flicker fix: an app's AX tree can momentarily
// collapse (a real 270-candidate tree read as 7 during a transition/redraw
// instant), and any single-sample read at that instant becomes the decision
// input for grounding. This type's ONLY initializer takes >= 2 samples and
// keeps the RICHEST, so no callsite can ever forget to multi-sample.
//
// Reads are pid-PINNED via `AXElementResolver.liveCandidates(pid:)` against a
// `PerceptionCore.AppTarget` resolved ONCE before sampling —
// `NSWorkspace.frontmostApplication` is never consulted per-sample, so a
// flickering-instant frontmost switch cannot swap the tree mid-decision.
//
// Referenced module-qualified as `PerceptionCore.AppTarget` deliberately:
// PerceptionCore's `VerificationOracle` collides with ComputerUseKit's
// (PostActionVerifier.swift), so this file references nothing else from
// PerceptionCore.

import Foundation
import PerceptionCore

/// Default-OFF gate for the `StableAXSnapshot` perception path
/// (`RecordAnswerTracer.flagKey` pattern). With the flag unset/false the
/// shipped `interactables()`/`liveCandidates()` path is byte-identical.
public enum PerceptionSnapshotFlag {
    public static let key = "cascade.perceptionSnapshot"
    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }
}

public struct StableAXSnapshot: Sendable {
    /// The pinned app this snapshot was read from.
    public let target: PerceptionCore.AppTarget
    /// The RICHEST sample's candidates (first-wins on ties).
    public let candidates: [AXElementResolver.Candidate]
    /// How many samples were actually taken (0 only for the own-UI degrade).
    public let sampleCount: Int
    /// Per-sample candidate counts, in sample order — for grounding.route /
    /// audit detail (counts only, never labels).
    public let sampleRichness: [Int]
    /// True when the target is Cascade itself — candidates are empty so every
    /// caller degrades to the visual-grounder/plain-nudge lane (MISSED, never FALSE).
    public let isOwnUI: Bool

    /// The 660af3c self-guard constant: grounding Cascade's own UI made the
    /// agent click/type into Cascade instead of the target app behind it.
    public static let ownBundleID = "com.humain.cascade"

    /// The ONLY initializer — CONSTRUCTOR-ENFORCED >= 2 samples (there is no
    /// single-sample entry point, so the 270->7 flicker instant can never be
    /// the decision input). `sampler` is injectable for tests; nil uses the
    /// real pid-pinned AX walk off-main.
    public init(
        target: PerceptionCore.AppTarget,
        samples: Int = 2,
        interSampleDelay: Duration = .milliseconds(60),
        sampler: (@Sendable (pid_t) -> [AXElementResolver.Candidate])? = nil
    ) async {
        self.target = target

        // OWN-UI SELF-GUARD FIRST — a runtime branch, not an assertion
        // (660af3c / LAW 7: pinning shrinks the case, it doesn't delete the
        // path). Empty candidates make every caller degrade to the
        // visual-grounder/plain-nudge lane exactly as an empty interactables()
        // does today. No AX read happens at all.
        if target.bundleID == Self.ownBundleID {
            self.isOwnUI = true
            self.candidates = []
            self.sampleCount = 0
            self.sampleRichness = []
            return
        }
        self.isOwnUI = false

        let n = max(2, samples)
        var collected: [[AXElementResolver.Candidate]] = []
        var richness: [Int] = []
        for index in 0..<n {
            let sample: [AXElementResolver.Candidate]
            if let sampler {
                sample = sampler(target.pid)
            } else {
                // OFF-MAIN BY DESIGN — DO NOT 'clean up' this Task.detached hop
                // (b40ede8): AXUIElement calls are IPC with no main-thread
                // assert, and a hung target app would otherwise block the main
                // actor — and STOP — behind 0.3s AX timeouts. The round-2
                // 'cleanup' that removed this hop shipped a live regression.
                sample = await Task.detached(priority: .userInitiated) {
                    AXElementResolver.liveCandidates(pid: target.pid)
                }.value
            }
            collected.append(sample)
            richness.append(sample.count)
            if index < n - 1, interSampleDelay > .zero {
                try? await Task.sleep(for: interSampleDelay)
            }
        }

        // KEEP THE RICHEST — count is 27a6fc8's richness semantics; first-wins
        // tie-break keeps the earliest of equally rich samples.
        var richest = collected[0]
        for sample in collected.dropFirst() where sample.count > richest.count {
            richest = sample
        }
        self.candidates = richest
        self.sampleCount = n
        self.sampleRichness = richness
    }

    /// Same filter as the shipped `interactables()` path BY CONSTRUCTION —
    /// routes through the verbatim-extracted `interactableMatches(from:limit:)`.
    public func interactables(limit: Int = 40) -> [AXElementResolver.Match] {
        AXElementResolver.interactableMatches(from: candidates, limit: limit)
    }
}
