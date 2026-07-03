import CoreGraphics
import Foundation
import GroundingBench
import Testing

struct AXGroundingEvalTests {
    @Test
    func targetCorpusRoundTripsThroughJSONL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AXGroundingEvalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("targets.jsonl")
        let targets = [
            target(id: "ax:1111", label: "New Note", role: "AXButton", identifier: "new-note"),
            target(id: "ax:2222", label: "Privacy & Security", role: "AXCell", bundle: "com.apple.systempreferences"),
        ]

        try AXGroundingTargetJSONL.write(targets, to: url)
        let loaded = try AXGroundingTargetJSONL.load(from: url)

        #expect(loaded == targets)
        #expect(loaded[0].center == CGPoint(x: 130, y: 60))
        #expect(loaded[1].appKey == "com.apple.systempreferences")
    }

    @Test
    func evalScoresExposureAndLandingByFinalStateNotClickCount() {
        let targets = [
            target(id: "ax:landed", label: "New Note", role: "AXButton", bundle: "app.one"),
            target(id: "ax:off", label: "Delete", role: "AXButton", bundle: "app.one"),
            target(id: "ax:unread", label: "Search", role: "AXTextField", bundle: "app.one"),
            target(id: "ax:gone", label: "Phantom", role: "AXButton", bundle: "app.two", appName: "Two"),
            target(id: "ax:skip", label: "Later", role: "AXButton", bundle: "app.three", appName: "Three"),
        ]
        let resolutions: [String: AXGroundingProbeResolution] = [
            "ax:landed": .resolved(
                point: CGPoint(x: 130, y: 60),
                hit: AXGroundingHitIdentity(stableID: "ax:landed", role: "AXButton", label: "New Note")
            ),
            "ax:off": .resolved(
                point: CGPoint(x: 400, y: 300),
                hit: AXGroundingHitIdentity(stableID: "ax:other", role: "AXButton", label: "Duplicate")
            ),
            "ax:unread": .resolved(point: CGPoint(x: 90, y: 45), hit: nil),
            "ax:gone": .notExposed,
            "ax:skip": .appNotFrontmost,
        ]
        let report = AXGroundingEvalRunner().run(targets: targets) { probed in
            resolutions[probed.targetID] ?? .notExposed
        }

        #expect(report.totalTargets == 5)
        #expect(report.scoredTargets == 4)
        #expect(report.exposedTargets == 3)
        #expect(report.landedTargets == 1)
        #expect(report.notExposed == 1)
        #expect(report.resolvedOffTarget == 1)
        #expect(report.resolvedHitUnreadable == 1)
        #expect(report.skippedAppNotFrontmost == 1)
        #expect(report.exposureRate == 0.75)
        #expect(report.landRate == 0.25)
        #expect(report.perApp["app.one"]?.scored == 3)
        #expect(report.perApp["app.one"]?.exposed == 3)
        #expect(report.perApp["app.one"]?.landed == 1)
        #expect(report.perApp["app.two"]?.exposureRate == 0)
        #expect(report.perApp["app.three"] == nil)

        let landed = report.observations.first { $0.targetID == "ax:landed" }
        #expect(landed?.status == .landed)
        #expect(landed?.resolvedX == 130)
        #expect(landed?.withinCrawledFrame == true)
        #expect(landed?.hitElementID == "ax:landed")
        let off = report.observations.first { $0.targetID == "ax:off" }
        #expect(off?.status == .resolvedOffTarget)
        #expect(off?.withinCrawledFrame == false)
        #expect(off?.hitElementID == "ax:other")
    }

    @Test
    func identityMatchesByStableIDThenIdentifierThenNormalizedLabel() {
        let byStableID = target(id: "ax:same", label: "New Note", role: "AXButton")
        #expect(AXGroundingEvalRunner.identityMatches(
            target: byStableID,
            hit: AXGroundingHitIdentity(stableID: "ax:same", role: "AXCell", label: "renamed")
        ))

        let byIdentifier = target(id: "ax:a", label: "New Note", role: "AXButton", identifier: "new-note")
        #expect(AXGroundingEvalRunner.identityMatches(
            target: byIdentifier,
            hit: AXGroundingHitIdentity(stableID: "ax:b", role: "AXButton", label: "moved", identifier: "new-note")
        ))
        #expect(!AXGroundingEvalRunner.identityMatches(
            target: byIdentifier,
            hit: AXGroundingHitIdentity(stableID: "ax:b", role: "AXCell", label: "moved", identifier: "new-note")
        ))

        let byLabel = target(id: "ax:a", label: "Privacy & Security", role: "AXCell")
        #expect(AXGroundingEvalRunner.identityMatches(
            target: byLabel,
            hit: AXGroundingHitIdentity(stableID: "ax:b", role: "AXCell", label: "privacy and security")
        ))
        #expect(!AXGroundingEvalRunner.identityMatches(
            target: byLabel,
            hit: AXGroundingHitIdentity(stableID: "ax:b", role: "AXButton", label: "privacy and security")
        ))
        #expect(!AXGroundingEvalRunner.identityMatches(
            target: target(id: "ax:a", label: "  ", role: "AXCell"),
            hit: AXGroundingHitIdentity(stableID: "ax:b", role: "AXCell", label: "  ")
        ))
    }

    private func target(
        id: String,
        label: String,
        role: String,
        identifier: String? = nil,
        bundle: String? = "app.one",
        appName: String = "One"
    ) -> AXGroundingTarget {
        AXGroundingTarget(
            targetID: id,
            appBundle: bundle,
            appName: appName,
            label: label,
            role: role,
            identifier: identifier,
            frame: CGRect(x: 100, y: 40, width: 60, height: 40)
        )
    }
}
