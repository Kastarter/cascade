import CascadeMemory
import Foundation
import PerceptionCore
import Testing

@testable import ComputerUseKit

/// Exercised ON-path tests for the constructor-enforced multi-sampled
/// perception snapshot — zero live AX via the injected sampler.
struct StableAXSnapshotTests {

    /// Thread-safe call counter for the @Sendable sampler closure.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        /// Increments and returns the 1-based call index.
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static func candidates(_ n: Int, labelPrefix: String = "Button") -> [AXElementResolver.Candidate] {
        (0..<n).map { index in
            AXElementResolver.Candidate(
                id: "fixture-\(labelPrefix)-\(index)",
                descriptor: AXTargetDescriptorV2(label: "\(labelPrefix) \(index)", role: "AXButton"),
                center: CGPoint(x: Double(index) + 1, y: Double(index) + 1),
                source: .accessibility,
                confidence: 0.5
            )
        }
    }

    private static let target = PerceptionCore.AppTarget(pid: 4242, bundleID: "com.example.someapp")

    // t1 — flicker-kill pin: the 270→7 collapse instant can never be the
    // decision input, whichever order the samples arrive in.
    @Test func keepsRichestSampleWhenFlickerCollapsesFirst() async {
        let counter = CallCounter()
        let snapshot = await StableAXSnapshot(
            target: Self.target,
            interSampleDelay: .zero,
            sampler: { @Sendable _ in
                counter.next() == 1 ? Self.candidates(7) : Self.candidates(270)
            }
        )
        #expect(snapshot.candidates.count == 270)
        #expect(snapshot.sampleRichness == [7, 270])
        #expect(snapshot.sampleCount == 2)
        #expect(!snapshot.isOwnUI)
    }

    @Test func keepsRichestSampleWhenFlickerCollapsesSecond() async {
        let counter = CallCounter()
        let snapshot = await StableAXSnapshot(
            target: Self.target,
            interSampleDelay: .zero,
            sampler: { @Sendable _ in
                counter.next() == 1 ? Self.candidates(270) : Self.candidates(7)
            }
        )
        #expect(snapshot.candidates.count == 270)
        #expect(snapshot.sampleRichness == [270, 7])
    }

    // t2 — constructor enforcement: no callsite can hand the loop a single
    // sample; 0 and 1 clamp to exactly 2 sampler invocations.
    @Test func zeroAndOneSampleRequestsStillTakeTwoSamples() async {
        for requested in [0, 1] {
            let counter = CallCounter()
            let snapshot = await StableAXSnapshot(
                target: Self.target,
                samples: requested,
                interSampleDelay: .zero,
                sampler: { @Sendable _ in
                    _ = counter.next()
                    return Self.candidates(3)
                }
            )
            #expect(counter.count == 2)
            #expect(snapshot.sampleCount == 2)
            #expect(snapshot.sampleRichness == [3, 3])
        }
    }

    // t3 — own-UI degrade (660af3c / LAW 7): Cascade's own bundle yields empty
    // candidates without a single AX read, so callers degrade to visual
    // (MISSED, never FALSE).
    @Test func ownUITargetDegradesWithoutSampling() async {
        let counter = CallCounter()
        let snapshot = await StableAXSnapshot(
            target: PerceptionCore.AppTarget(pid: 4242, bundleID: StableAXSnapshot.ownBundleID),
            interSampleDelay: .zero,
            sampler: { @Sendable _ in
                _ = counter.next()
                return Self.candidates(5)
            }
        )
        #expect(snapshot.isOwnUI)
        #expect(snapshot.candidates.isEmpty)
        #expect(snapshot.sampleCount == 0)
        #expect(snapshot.sampleRichness.isEmpty)
        #expect(counter.count == 0)
        #expect(snapshot.interactables().isEmpty)
    }

    // t4 — filter parity: the ON-path filter IS the shipped filter (verbatim
    // extraction) on a mixed actionable/passive/duplicate/over-length fixture.
    @Test func interactablesMatchesSharedFilterOnMixedFixture() async {
        let fixture: [AXElementResolver.Candidate] = [
            AXElementResolver.Candidate(
                id: "b1",
                descriptor: AXTargetDescriptorV2(label: "Save", role: "AXButton"),
                center: CGPoint(x: 10, y: 10),
                source: .accessibility,
                confidence: 0.9
            ),
            AXElementResolver.Candidate(
                id: "static",
                descriptor: AXTargetDescriptorV2(label: "Just a label", role: "AXStaticText"),
                center: CGPoint(x: 20, y: 20),
                source: .accessibility,
                confidence: 0.9
            ),
            AXElementResolver.Candidate(
                id: "b1-dup",
                descriptor: AXTargetDescriptorV2(label: "Save", role: "AXButton"),
                center: CGPoint(x: 30, y: 30),
                source: .accessibility,
                confidence: 0.4
            ),
            AXElementResolver.Candidate(
                id: "no-center",
                descriptor: AXTargetDescriptorV2(label: "Cancel", role: "AXButton"),
                center: nil,
                source: .accessibility,
                confidence: 0.4
            ),
            AXElementResolver.Candidate(
                id: "too-long",
                descriptor: AXTargetDescriptorV2(
                    label: String(repeating: "x", count: 80),
                    role: "AXButton"
                ),
                center: CGPoint(x: 40, y: 40),
                source: .accessibility,
                confidence: 0.4
            ),
            AXElementResolver.Candidate(
                id: "field",
                descriptor: AXTargetDescriptorV2(label: "Search", role: "AXTextField"),
                center: CGPoint(x: 50, y: 50),
                source: .accessibility,
                confidence: 0.7
            ),
        ]
        let snapshot = await StableAXSnapshot(
            target: Self.target,
            interSampleDelay: .zero,
            sampler: { @Sendable _ in fixture }
        )
        for limit in [1, 2, 40] {
            let viaSnapshot = snapshot.interactables(limit: limit)
            let direct = AXElementResolver.interactableMatches(from: fixture, limit: limit)
            #expect(viaSnapshot.count == direct.count)
            for (a, b) in zip(viaSnapshot, direct) {
                #expect(a.center == b.center)
                #expect(a.role == b.role)
                #expect(a.title == b.title)
                #expect(a.score == b.score)
            }
        }
        // Pins the filter semantics themselves: dedupe + passive-role +
        // missing-center + over-length drops leave Save and Search.
        let matches = snapshot.interactables()
        #expect(matches.map(\.title) == ["Save", "Search"])
    }

    // t5 — flag default: OFF on a fresh defaults suite.
    @Test func perceptionSnapshotFlagDefaultsOff() {
        let suiteName = "StableAXSnapshotTests-\(UUID().uuidString)"
        let fresh = UserDefaults(suiteName: suiteName)
        #expect(fresh?.bool(forKey: PerceptionSnapshotFlag.key) == false)
        fresh?.removePersistentDomain(forName: suiteName)
    }
}
