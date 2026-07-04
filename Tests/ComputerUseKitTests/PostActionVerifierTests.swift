import CoreGraphics
import Foundation
import Testing

@testable import CascadeMemory
@testable import ComputerUseKit

/// Exercised ON-path tests for the §4a post-action verification ladder (LAW 6:
/// a flag whose ON path is never exercised is a banned no-op shape). Probes are
/// stubs that record whether they fired, so the tests pin BOTH the verdicts and
/// the cost discipline (an exempt action must probe nothing).
struct PostActionVerifierTests {
    private let verifier = PostActionVerifier()

    /// Thread-safe flag box the @Sendable probe closures can mark.
    private final class ProbeFlags: @unchecked Sendable {
        private let lock = NSLock()
        private var fired: Set<String> = []
        func mark(_ name: String) {
            lock.lock()
            fired.insert(name)
            lock.unlock()
        }
        func didFire(_ name: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired.contains(name)
        }
        var any: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !fired.isEmpty
        }
    }

    private func evidence(
        flags: ProbeFlags,
        axValue: String? = nil,
        frontName: String? = nil,
        frontBundle: String? = nil,
        fileExists: Bool = false,
        ocrBefore: String? = nil,
        ocrAfter: String? = nil,
        hashesBefore: [UInt64]? = nil,
        hashesAfter: [UInt64]? = nil
    ) -> PostActionEvidence {
        PostActionEvidence(
            readFocusedAXValue: {
                flags.mark("ax")
                return axValue
            },
            frontmostFingerprint: {
                flags.mark("front")
                return (frontName, frontBundle)
            },
            fileExists: { _ in
                flags.mark("file")
                return fileExists
            },
            ocrBefore: ocrBefore,
            ocrAfter: { _ in
                flags.mark("ocr")
                return ocrAfter
            },
            gridHashesBefore: hashesBefore,
            gridHashesAfter: hashesAfter
        )
    }

    // (1) Rung-0 structural exemption: an exempt KIND returns immediately and
    // fires NO probe — the exemption comes from the action kind, never from a
    // model report and never from observation work.
    @Test func exemptKindsShortCircuitWithoutProbes() async {
        for kind in ["wait", "screenshot", "zoom", "highlight", "move"] {
            let flags = ProbeFlags()
            let verdict = await verifier.verify(
                VerifiableAction(kindToken: kind),
                evidence: evidence(flags: flags, axValue: "x", frontName: "x", ocrBefore: "x", ocrAfter: "y")
            )
            #expect(verdict.status == .exempt)
            #expect(verdict.rung == 0)
            #expect(verdict.mechanism == "predicted_effect")
            #expect(!flags.any, "exempt kind \(kind) must fire no probe")
        }
    }

    // (2) Typing rung 1: verified REQUIRES the AX read-back reflect the text
    // (abd97e6); a readable value that does NOT contain it is a definitive
    // rung-1 failure with .verifierRejected.
    @Test func typingAXReadbackVerifiesOrRejects() async {
        let action = VerifiableAction(kindToken: "type", typedText: "hello world")

        let okFlags = ProbeFlags()
        let ok = await verifier.verify(
            action,
            evidence: evidence(flags: okFlags, axValue: "Draft: hello world!")
        )
        #expect(ok.status == .verified)
        #expect(ok.rung == 1)
        #expect(ok.mechanism == "ax_value")
        #expect(ok.failureKind == nil)

        let badFlags = ProbeFlags()
        let bad = await verifier.verify(
            action,
            evidence: evidence(flags: badFlags, axValue: "something else entirely")
        )
        #expect(bad.status == .failed)
        #expect(bad.rung == 1)
        #expect(bad.mechanism == "ax_value")
        #expect(bad.failureKind == .verifierRejected)
    }

    // (3) Rung-1 unavailable falls to rung 2: AX probe nil, OCR delta on the
    // target rect confirms the effect with zero model calls.
    @Test func unreadableAXValueFallsToOCRDelta() async {
        let flags = ProbeFlags()
        let action = VerifiableAction(
            kindToken: "type",
            typedText: "hello",
            targetRect: CGRect(x: 100, y: 100, width: 320, height: 160)
        )
        let verdict = await verifier.verify(
            action,
            evidence: evidence(flags: flags, axValue: nil, ocrBefore: "Draft", ocrAfter: "Draft hello")
        )
        #expect(verdict.status == .verified)
        #expect(verdict.rung == 2)
        #expect(verdict.mechanism == "ocr_delta")
        #expect(flags.didFire("ax"), "rung 1 must have been attempted first")
        #expect(flags.didFire("ocr"))
    }

    // (4) open_app rung 1: frontmost fingerprint match verifies; a readable
    // but mismatching frontmost is a definitive failure.
    @Test func openAppFingerprintMatchAndMismatch() async {
        let action = VerifiableAction(kindToken: "open_app", expectedApp: "Keynote")

        let hit = await verifier.verify(
            action,
            evidence: evidence(flags: ProbeFlags(), frontName: "Keynote Creator Studio", frontBundle: "com.apple.Keynote")
        )
        #expect(hit.status == .verified)
        #expect(hit.rung == 1)
        #expect(hit.mechanism == "frontmost_fingerprint")

        let miss = await verifier.verify(
            action,
            evidence: evidence(flags: ProbeFlags(), frontName: "Finder", frontBundle: "com.apple.finder")
        )
        #expect(miss.status == .failed)
        #expect(miss.rung == 1)
        #expect(miss.failureKind == .wrongStartState)
    }

    // (4b) Save-shaped key with a structural expectedFileURL: file-exists is
    // the rung-1 mechanism.
    @Test func expectedFileURLUsesFileExistsProbe() async {
        let url = URL(fileURLWithPath: "/tmp/cascade-test-artifact.key")
        let action = VerifiableAction(kindToken: "key", expectedFileURL: url)

        let saved = await verifier.verify(action, evidence: evidence(flags: ProbeFlags(), fileExists: true))
        #expect(saved.status == .verified)
        #expect(saved.rung == 1)
        #expect(saved.mechanism == "file_exists")

        let missing = await verifier.verify(action, evidence: evidence(flags: ProbeFlags(), fileExists: false))
        #expect(missing.status == .failed)
        #expect(missing.failureKind == .verifierRejected)
    }

    // (5) The 85f945a law: rung-3 ambiguity is "unclear", NEVER "failed" —
    // identical grid hashes, and missing hashes, both stay unclear.
    @Test func imageDiffAmbiguityIsUnclearNeverFailed() async {
        let action = VerifiableAction(
            kindToken: "click",
            targetRect: CGRect(x: 10, y: 10, width: 320, height: 160)
        )
        let same: [UInt64] = Array(repeating: 0xDEADBEEF, count: 9)

        let unchanged = await verifier.verify(
            action,
            evidence: evidence(flags: ProbeFlags(), hashesBefore: same, hashesAfter: same)
        )
        #expect(unchanged.status == .unclear)
        #expect(unchanged.status != .failed)
        #expect(unchanged.rung == 3)
        #expect(unchanged.mechanism == "image_diff")
        #expect(unchanged.failureKind == nil)

        let missing = await verifier.verify(action, evidence: evidence(flags: ProbeFlags()))
        #expect(missing.status == .unclear)
        #expect(missing.status != .failed)
        #expect(missing.rung == 3)

        // And a genuinely changed frame verifies at rung 3.
        let changed = await verifier.verify(
            action,
            evidence: evidence(
                flags: ProbeFlags(),
                hashesBefore: same,
                hashesAfter: Array(repeating: 0x12345678, count: 9)
            )
        )
        #expect(changed.status == .verified)
        #expect(changed.rung == 3)
        #expect(changed.mechanism == "image_diff")
    }

    // (6) predictedEffect(forKind:) is total over every kindToken CUStep emits,
    // with the exact structural mapping the ladder relies on.
    @Test func predictedEffectMappingIsTotalOverCUStepKindTokens() {
        let expected: [String: PredictedEffect] = [
            "move": .none,
            "wait": .none,
            "screenshot": .none,
            "zoom": .none,
            "highlight": .none,
            "type": .axValue,
            "open_app": .frontmostApp,
            "click": .visualDelta,
            "double_click": .visualDelta,
            "triple_click": .visualDelta,
            "right_click": .visualDelta,
            "drag": .visualDelta,
            "key": .visualDelta,
            "scroll": .visualDelta,
            "open_url": .visualDelta,
        ]
        for (kind, effect) in expected {
            #expect(VerifiableAction.predictedEffect(forKind: kind) == effect, "kind \(kind)")
        }
        // A structural save target upgrades the instance-level mechanism.
        let save = VerifiableAction(kindToken: "key", expectedFileURL: URL(fileURLWithPath: "/tmp/x"))
        #expect(save.predictedEffect == .fileExists)
    }
}
