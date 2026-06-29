import CoreGraphics
import Testing

@testable import ComputerUseKit

struct ScreenElementIndexTests {
    @Test func accessibilityCandidateBeatsDuplicateOCRTextByTrust() {
        let index = ScreenElementIndex.build(from: [
            candidate(
                label: "Send",
                role: .text,
                source: .ocr,
                bounds: bounds(104, 104, 36, 14),
                confidence: 0.98),
            candidate(
                label: "Send",
                role: .button,
                source: .accessibility,
                bounds: bounds(96, 96, 70, 32),
                confidence: 0.82),
        ])

        #expect(index.count == 1)
        #expect(index[0].source == .accessibility)
        #expect(index[0].role == .button)
        #expect(index[0].label == "Send")
        #expect(index[0].contributingSources == [.accessibility, .ocr])
        #expect(index[0].isSafeToClick)
    }

    @Test func overlappingBoxesMergePredictably() {
        let first = candidate(
            label: "Approve",
            role: .button,
            source: .visual,
            bounds: bounds(20, 40, 100, 44),
            confidence: 0.74,
            trust: 0.62)
        let second = candidate(
            label: "Approve",
            role: .button,
            source: .accessibility,
            bounds: bounds(24, 42, 92, 40),
            confidence: 0.80,
            trust: 0.90)

        let forward = ScreenElementIndex.build(from: [first, second])
        let reversed = ScreenElementIndex.build(from: [second, first])

        #expect(forward == reversed)
        #expect(forward.count == 1)
        #expect(forward[0].bounds == bounds(20, 40, 100, 44))
        #expect(forward[0].source == .accessibility)
        #expect(forward[0].confidence == 0.80)
        #expect(forward[0].trust == 0.90)
    }

    @Test func stableIDsDoNotDependOnInputOrder() {
        let candidates = [
            candidate(label: "First name", role: .textField, source: .accessibility, bounds: bounds(20, 20, 180, 36)),
            candidate(label: "Cancel", role: .button, source: .visual, bounds: bounds(20, 76, 80, 32)),
            candidate(label: "Save", role: .button, source: .accessibility, bounds: bounds(112, 76, 80, 32)),
        ]

        let original = ScreenElementIndex.build(from: candidates)
        let shuffled = ScreenElementIndex.build(from: candidates.reversed())

        #expect(original.map(\.id) == shuffled.map(\.id))
        #expect(original.map(\.label) == ["First name", "Cancel", "Save"])
    }

    @Test func indexedCandidatesCarryDisplayAndImageBounds() {
        let display = bounds(20, 30, 120, 40)
        let image = bounds(40, 60, 240, 80)
        let index = ScreenElementIndex.build(from: [
            candidate(label: "Send", role: .button, source: .accessibility, bounds: display, imageBounds: image)
        ])

        #expect(index.first?.bounds == display)
        #expect(index.first?.imageBounds == image)
        #expect(index.first?.center == CGPoint(x: 80, y: 50))
    }

    @Test func bestCandidateUsesSharedTextTrustPolicy() {
        let index = ScreenElementIndex.build(from: [
            candidate(label: "Send", role: .text, source: .ocr, bounds: bounds(10, 10, 50, 20), trust: 0.45),
            candidate(label: "Send", role: .button, source: .accessibility, bounds: bounds(10, 10, 80, 32), trust: 0.95),
            candidate(label: "Settings", role: .button, source: .accessibility, bounds: bounds(120, 10, 80, 32), trust: 0.95),
        ])

        #expect(ScreenElementIndex.bestCandidate(for: "the send button", in: index)?.label == "Send")
        #expect(ScreenElementIndex.bestCandidate(for: "missing", in: index) == nil)
    }

    @Test func markLabelsAreUniqueReadableAndInReadingOrder() {
        let index = ScreenElementIndex.build(from: [
            candidate(label: "Bottom", role: .button, source: .accessibility, bounds: bounds(20, 140, 90, 30)),
            candidate(label: "Top left", role: .button, source: .accessibility, bounds: bounds(20, 20, 90, 30)),
            candidate(label: "Top right", role: .button, source: .accessibility, bounds: bounds(140, 22, 90, 30)),
        ])

        #expect(index.map(\.label) == ["Top left", "Top right", "Bottom"])
        #expect(index.map(\.mark.label) == ["1", "2", "3"])
        #expect(Set(index.map(\.mark.label)).count == index.count)
        #expect(index.allSatisfy { !$0.mark.label.isEmpty })
    }

    @Test func unsafeAndPassiveCandidatesAreNotMarkedSafeToClick() {
        let index = ScreenElementIndex.build(from: [
            candidate(
                label: "Warning",
                role: .text,
                source: .ocr,
                bounds: bounds(20, 20, 100, 20)),
            candidate(
                label: "Delete account",
                role: .button,
                source: .accessibility,
                bounds: bounds(20, 60, 140, 32),
                clickSafety: .unsafe),
            candidate(
                label: "Continue",
                role: .button,
                source: .accessibility,
                bounds: bounds(20, 110, 100, 32)),
        ])

        let warning = index.first { $0.label == "Warning" }
        let delete = index.first { $0.label == "Delete account" }
        let proceed = index.first { $0.label == "Continue" }

        #expect(warning?.mark.isSafeToClick == false)
        #expect(warning?.isSafeToClick == false)
        #expect(delete?.mark.isSafeToClick == false)
        #expect(delete?.isSafeToClick == false)
        #expect(proceed?.mark.isSafeToClick == true)
        #expect(proceed?.isSafeToClick == true)
    }

    @Test func nonFiniteScoresAndExtremeBoundsDoNotTrap() {
        let outOfRange = Double(Int.max) * 2
        let candidates = [
            candidate(
                label: "Untrusted score",
                role: .button,
                source: .visual,
                bounds: bounds(outOfRange, 20, outOfRange, 44),
                confidence: .nan,
                trust: .nan),
            candidate(
                label: "Extreme finite bounds",
                role: .textField,
                source: .accessibility,
                bounds: bounds(-outOfRange, 90, outOfRange, 36),
                confidence: 0.75,
                trust: 0.95),
        ]

        let index = ScreenElementIndex.build(from: candidates)
        let repeated = ScreenElementIndex.build(from: candidates.reversed())

        #expect(index.count == 2)
        #expect(index.allSatisfy { $0.confidence.isFinite && $0.trust.isFinite })
        #expect(index.first { $0.label == "Untrusted score" }?.confidence == 0)
        #expect(index.first { $0.label == "Untrusted score" }?.trust == 0)
        #expect(index.map(\.id) == repeated.map(\.id))
        #expect(index.map(\.mark.number) == [1, 2])
        #expect(index.map(\.mark.label) == repeated.map(\.mark.label))
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
            imageBounds: nil,
            label: label,
            role: role,
            source: source,
            confidence: confidence,
            trust: trust,
            clickSafety: clickSafety)
    }

    private func candidate(
        label: String,
        role: ScreenElementIndex.Role,
        source: ScreenElementIndex.Source,
        bounds: ScreenElementIndex.Bounds,
        imageBounds: ScreenElementIndex.Bounds?,
        confidence: Double = 0.90,
        trust: Double? = nil,
        clickSafety: ScreenElementIndex.ClickSafety? = nil
    ) -> ScreenElementIndex.Candidate {
        ScreenElementIndex.Candidate(
            bounds: bounds,
            imageBounds: imageBounds,
            label: label,
            role: role,
            source: source,
            confidence: confidence,
            trust: trust,
            clickSafety: clickSafety)
    }

    private func bounds(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> ScreenElementIndex.Bounds {
        ScreenElementIndex.Bounds(x: x, y: y, width: width, height: height)
    }
}
