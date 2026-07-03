import CoreGraphics
import Foundation
import GroundingBench
import Testing

// d21: the ablation math and the hybrid arm's policy are pure — pinned here so
// the live run only has to prove the numbers, not the plumbing.
struct AXGroundingAblationTests {
    @Test
    func hybridPrefersAXAndFallsToVisionOnlyWhenAXHasNoCandidate() async {
        let axLanded = target(id: "ax:landed", label: "New Note")
        let axMissing = target(id: "ax:missing", label: "Phantom")
        let skipped = target(id: "ax:skip", label: "Later")

        let visionCalls = CallRecorder()
        let probe = AXGroundingAblationRunner.hybridProbe(
            ax: { probed in
                switch probed.targetID {
                case "ax:landed":
                    return .resolved(
                        point: CGPoint(x: 130, y: 60),
                        hit: AXGroundingHitIdentity(stableID: "ax:landed", role: "AXButton", label: "New Note")
                    )
                case "ax:skip":
                    return .appNotFrontmost
                default:
                    return .notExposed
                }
            },
            vision: { probed in
                await visionCalls.record(probed.targetID)
                return .resolved(point: CGPoint(x: 10, y: 10), hit: nil)
            },
            routesToVision: { _ in false }
        )

        // AX resolution wins outright — vision never consulted.
        if case .resolved(let point, let hit) = await probe(axLanded) {
            #expect(point == CGPoint(x: 130, y: 60))
            #expect(hit?.stableID == "ax:landed")
        } else {
            Issue.record("expected an AX resolution")
        }
        // No AX candidate — vision owns the fallback.
        if case .resolved(let point, _) = await probe(axMissing) {
            #expect(point == CGPoint(x: 10, y: 10))
        } else {
            Issue.record("expected the vision fallback")
        }
        // Frontmost-discipline skip stays a skip — no vision consolation round.
        if case .appNotFrontmost = await probe(skipped) {} else {
            Issue.record("expected the skip to propagate")
        }
        #expect(await visionCalls.calls == ["ax:missing"])
    }

    @Test
    func hybridRoutesCanvasConceptsStraightToVision() async {
        let canvas = target(id: "ax:canvas", label: "title placeholder")
        let axCalls = CallRecorder()
        let probe = AXGroundingAblationRunner.hybridProbe(
            ax: { probed in
                await axCalls.record(probed.targetID)
                return .resolved(point: CGPoint(x: 1, y: 1), hit: nil)
            },
            vision: { _ in .resolved(point: CGPoint(x: 500, y: 400), hit: nil) },
            routesToVision: { $0.label.lowercased().contains("placeholder") }
        )

        if case .resolved(let point, _) = await probe(canvas) {
            #expect(point == CGPoint(x: 500, y: 400))
        } else {
            Issue.record("expected the vision route")
        }
        #expect(await axCalls.calls.isEmpty)
    }

    @Test
    func reportComparesArmsAndComputesHybridFailureRate() async {
        let targets = [
            target(id: "ax:a", label: "New Note"),
            target(id: "ax:b", label: "Delete"),
            target(id: "ax:c", label: "Search"),
            target(id: "ax:d", label: "Share"),
        ]
        let landing: @Sendable (String) -> AXGroundingProbeResolution = { id in
            .resolved(
                point: CGPoint(x: 130, y: 60),
                hit: AXGroundingHitIdentity(stableID: id, role: "AXButton", label: "x")
            )
        }
        let offTarget = AXGroundingProbeResolution.resolved(
            point: CGPoint(x: 5, y: 5),
            hit: AXGroundingHitIdentity(stableID: "ax:other", role: "AXButton", label: "y")
        )
        // ax_only lands 2/4 (two not exposed), vision lands 1/4, hybrid 3/4.
        let probes: [AXGroundingAblationArm: AXGroundingAblationRunner.ArmProbe] = [
            .axOnly: { probed in
                switch probed.targetID {
                case "ax:a", "ax:b": return landing(probed.targetID)
                default: return .notExposed
                }
            },
            .visionOnly: { probed in
                probed.targetID == "ax:c" ? landing(probed.targetID) : offTarget
            },
            .hybrid: { probed in
                switch probed.targetID {
                case "ax:a", "ax:b", "ax:c": return landing(probed.targetID)
                default: return offTarget
                }
            },
        ]

        let report = await AXGroundingAblationRunner().run(targets: targets, probes: probes)

        #expect(report.targetCount == 4)
        #expect(report.arms.count == 3)
        #expect(report.arms["ax_only"]?.landRate == 0.5)
        #expect(report.arms["vision_only"]?.landRate == 0.25)
        #expect(report.arms["hybrid"]?.landRate == 0.75)
        #expect(report.summaries.map(\.arm) == ["ax_only", "vision_only", "hybrid"])
        #expect(report.summaries[0].candidates == 2)
        #expect(report.summaries[2].failureRate == 0.25)
        #expect(report.hybridMinusAXOnlyLandRate == 0.25)
        #expect(report.hybridMinusVisionOnlyLandRate == 0.5)
        #expect(report.hybridFailureRate == 0.25)
        #expect(report.hybridWins == true)
        #expect(report.corpusHash == AXGroundingAblationRunner.corpusHash(of: targets))
        #expect(report.summaries.allSatisfy { ($0.p50Latency ?? 0) >= 0 })

        let json = try? report.jsonString()
        #expect(json?.contains("hybrid_failure_rate") == true)
    }

    @Test
    func reportLeavesComparisonsNilWhenArmsAreMissingOrUnscored() {
        let targets = [target(id: "ax:a", label: "New Note")]
        let axRows = [
            AXGroundingEvalRunner.observation(for: targets[0], resolution: .notExposed)
        ]
        let report = AXGroundingAblationRunner.report(
            targets: targets,
            observationsByArm: [.axOnly: axRows]
        )

        #expect(report.arms.count == 1)
        #expect(report.summaries.map(\.arm) == ["ax_only"])
        #expect(report.summaries[0].failureRate == 1)
        #expect(report.hybridMinusAXOnlyLandRate == nil)
        #expect(report.hybridMinusVisionOnlyLandRate == nil)
        #expect(report.hybridFailureRate == nil)
        #expect(report.hybridWins == nil)

        // A hybrid arm where every row was skipped scores nothing — the
        // comparison must stay nil, not claim a 0% failure rate.
        let skippedHybrid = AXGroundingAblationRunner.report(
            targets: targets,
            observationsByArm: [
                .axOnly: axRows,
                .hybrid: [AXGroundingEvalRunner.observation(for: targets[0], resolution: .appNotFrontmost)],
            ]
        )
        #expect(skippedHybrid.hybridFailureRate == nil)
        #expect(skippedHybrid.hybridWins == nil)
    }

    @Test
    func corpusGroupsPreserveManifestAndFirstSeenOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AXGroundingAblationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Flat-target grouping keeps first-seen app order.
        let flat = [
            target(id: "ax:1", label: "A", bundle: "app.two", appName: "Two"),
            target(id: "ax:2", label: "B", bundle: "app.one", appName: "One"),
            target(id: "ax:3", label: "C", bundle: "app.two", appName: "Two"),
        ]
        let groups = AXGroundingAblationCorpus.groups(fromTargets: flat)
        #expect(groups.map(\.bundleID) == ["app.two", "app.one"])
        #expect(groups[0].targets.map(\.targetID) == ["ax:1", "ax:3"])

        // A corpus directory without a manifest is refused with a clear error.
        #expect(throws: AXGroundingAblationCorpusError.missingManifest(directory.path)) {
            try AXGroundingAblationCorpus.loadGroups(fromCorpusDirectory: directory)
        }
    }

    private func target(
        id: String,
        label: String,
        bundle: String? = "app.one",
        appName: String = "One"
    ) -> AXGroundingTarget {
        AXGroundingTarget(
            targetID: id,
            appBundle: bundle,
            appName: appName,
            label: label,
            role: "AXButton",
            frame: CGRect(x: 100, y: 40, width: 60, height: 40)
        )
    }
}

private actor CallRecorder {
    private(set) var calls: [String] = []

    func record(_ id: String) {
        calls.append(id)
    }
}
