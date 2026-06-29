import CoreGraphics
import Foundation
import Testing

import CascadeMemory
import ComputerUseKit
import ProviderKit
@testable import AppShell

struct LocalRegionNarrowerTests {
    @Test func accessibilityCandidateBeatsDuplicateOCRTextForRegions() {
        let index = ScreenElementIndex.build(from: [
            candidate(
                label: "Approve",
                role: .text,
                source: .ocr,
                bounds: bounds(14, 14, 80, 18),
                confidence: 0.98,
                trust: 0.45,
                clickSafety: .passive),
            candidate(
                label: "Approve",
                role: .button,
                source: .accessibility,
                bounds: bounds(10, 10, 110, 32),
                confidence: 0.86,
                trust: 0.95,
                clickSafety: .safe),
        ])

        let selected = LocalRegionNarrower.bestRegionCandidate(for: "approve", in: index)

        #expect(selected?.candidate.source == .accessibility)
        #expect(selected?.candidate.label == "Approve")
    }

    @Test func passiveOCRTextCanGroundRegionHighlights() {
        let index = ScreenElementIndex.build(from: [
            candidate(
                label: "Student evaluation section",
                role: .text,
                source: .ocr,
                bounds: bounds(30, 80, 260, 24),
                confidence: 0.91,
                trust: 0.45,
                clickSafety: .passive),
        ])

        let selected = LocalRegionNarrower.bestRegionCandidate(for: "student evaluation", in: index)

        #expect(selected?.candidate.source == .ocr)
        #expect(selected?.candidate.clickSafety == .passive)
        #expect(selected?.candidate.bounds == bounds(30, 80, 260, 24))
    }

    @Test func ambiguousRegionCandidatesReturnNil() {
        let index = ScreenElementIndex.build(from: [
            candidate(
                label: "Download",
                role: .text,
                source: .ocr,
                bounds: bounds(20, 40, 100, 20),
                trust: 0.45,
                clickSafety: .passive),
            candidate(
                label: "Download",
                role: .text,
                source: .ocr,
                bounds: bounds(20, 160, 100, 20),
                trust: 0.45,
                clickSafety: .passive),
        ])

        #expect(LocalRegionNarrower.bestRegionCandidate(for: "download", in: index) == nil)
    }

    @Test func sparseRegionCandidatesReturnNil() {
        #expect(LocalRegionNarrower.bestRegionCandidate(for: "download", in: []) == nil)
    }

    @Test func targetAliasesResolveBeforeRegionScoring() {
        let index = ScreenElementIndex.build(from: [
            candidate(
                label: "Title placeholder",
                role: .text,
                source: .ocr,
                bounds: bounds(100, 120, 180, 30),
                trust: 0.45,
                clickSafety: .passive),
        ])

        let selected = LocalRegionNarrower.bestRegionCandidate(
            for: "the title box",
            in: index,
            aliases: ["Title placeholder": ["title box", "heading field"]]
        )

        #expect(selected?.candidate.label == "Title placeholder")
    }

    @MainActor @Test func appModelUsesLocalRegionWhenVisualGrounderIsDisabled() async throws {
        let localRect = CGRect(x: 16, y: 24, width: 160, height: 36)
        let store = try temporaryStore(named: "CascadeLocalRegionNoGrounder")
        let defaults = UserDefaults(suiteName: "CascadeLocalRegionNoGrounder-\(UUID().uuidString)")!
        defaults.set(false, forKey: "cascade.visualGrounder")
        let model = try CascadeAppModel(
            store: store,
            defaults: defaults,
            startsSubsystems: false,
            appSkills: .init(),
            localRegionNarrowerOverride: { _, _, _, _ in
                ElementRegion(rect: localRect, speech: "local")
            }
        )

        let result = await model.locateRegionGrounded(
            screenshot: Data([0]),
            question: "where is approve",
            displayWidthPoints: 800,
            displayHeightPoints: 600,
            conversation: []
        )

        #expect(result.rect == localRect)
        #expect(result.speech == "local")
    }

    @MainActor @Test func appModelUsesLocalRegionBeforeConfiguredVisualGrounder() async throws {
        let counter = RegionGrounderCallCounter()
        let localRect = CGRect(x: 10, y: 20, width: 120, height: 40)
        let baseRect = CGRect(x: 500, y: 500, width: 40, height: 40)
        let store = try temporaryStore(named: "CascadeLocalRegionBeforeGrounder")
        let defaults = UserDefaults(suiteName: "CascadeLocalRegionBeforeGrounder-\(UUID().uuidString)")!
        let model = try CascadeAppModel(
            store: store,
            defaults: defaults,
            startsSubsystems: false,
            appSkills: .init(),
            visualGrounderOverride: RegionFallbackGrounder(
                counter: counter,
                region: ElementRegion(rect: baseRect, speech: "base")
            ),
            localRegionNarrowerOverride: { _, _, _, _ in
                ElementRegion(rect: localRect, speech: "local")
            }
        )

        let result = await model.locateRegionGrounded(
            screenshot: Data([0]),
            question: "where is approve",
            displayWidthPoints: 800,
            displayHeightPoints: 600,
            conversation: []
        )

        #expect(result.rect == localRect)
        #expect(result.speech == "local")
        #expect(await counter.value() == 0)
    }

    @Test func mixtureGrounderUsesLocalRegionBeforeBaseFallback() async {
        let counter = RegionGrounderCallCounter()
        let localRect = CGRect(x: 10, y: 20, width: 120, height: 40)
        let base = RegionFallbackGrounder(
            counter: counter,
            region: ElementRegion(rect: CGRect(x: 500, y: 500, width: 40, height: 40), speech: "base")
        )
        let grounder = MixtureGrounder(
            base: base,
            skills: AppSkillRegistry(),
            regionNarrower: { _, _, _, _ in
                ElementRegion(rect: localRect, speech: "local")
            }
        )

        let result = await grounder.groundRegion(
            screenshot: Data([0]),
            target: "target",
            displayWidthPoints: 800,
            displayHeightPoints: 600
        )

        #expect(result?.rect == localRect)
        #expect(result?.speech == "local")
        #expect(await counter.value() == 0)
    }

    @Test func mixtureGrounderFallsBackToBaseRegionWhenLocalNarrowerMisses() async {
        let counter = RegionGrounderCallCounter()
        let baseRect = CGRect(x: 500, y: 500, width: 40, height: 40)
        let grounder = MixtureGrounder(
            base: RegionFallbackGrounder(counter: counter, region: ElementRegion(rect: baseRect, speech: "base")),
            skills: AppSkillRegistry(),
            regionNarrower: { _, _, _, _ in nil }
        )

        let result = await grounder.groundRegion(
            screenshot: Data([0]),
            target: "target",
            displayWidthPoints: 800,
            displayHeightPoints: 600
        )

        #expect(result?.rect == baseRect)
        #expect(result?.speech == "base")
        #expect(await counter.value() == 1)
    }

    private func candidate(
        label: String,
        role: ScreenElementIndex.Role,
        source: ScreenElementIndex.Source,
        bounds: ScreenElementIndex.Bounds,
        confidence: Double = 0.90,
        trust: Double? = nil,
        clickSafety: ScreenElementIndex.ClickSafety? = nil
    ) -> ScreenElementIndex.Candidate {
        ScreenElementIndex.Candidate(
            bounds: bounds,
            label: label,
            role: role,
            source: source,
            confidence: confidence,
            trust: trust,
            clickSafety: clickSafety
        )
    }

    private func bounds(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> ScreenElementIndex.Bounds {
        ScreenElementIndex.Bounds(x: x, y: y, width: width, height: height)
    }

    private func temporaryStore(named prefix: String) throws -> CascadeStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).sqlite")
            .path
        return try CascadeStore(path: path)
    }
}

private actor RegionGrounderCallCounter {
    private var calls = 0

    func increment() {
        calls += 1
    }

    func value() -> Int {
        calls
    }
}

private struct RegionFallbackGrounder: VisualGrounder {
    let counter: RegionGrounderCallCounter
    let region: ElementRegion

    func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        nil
    }

    func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult {
        GroundingResult()
    }

    func groundRegion(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> ElementRegion? {
        await counter.increment()
        return region
    }
}
