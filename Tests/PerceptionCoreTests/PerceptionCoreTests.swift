// PerceptionCore leaf tests — imports PerceptionCore ONLY (never ProviderKit/AppShell):
// the leaf target's zero-deps guarantee extends to its test target.

import Foundation
import XCTest
@testable import PerceptionCore

final class PerceptionCoreTests: XCTestCase {

    // MARK: - (a) normalized() bridge + clamping pins

    func testNormalizedBridgePins() {
        XCTAssertEqual(AXMatchScore(clamping: 0).normalized(), Confidence(clamping: 0))
        XCTAssertEqual(AXMatchScore(clamping: 3).normalized().value, 1.0)
        XCTAssertEqual(AXMatchScore(clamping: 2).normalized().value, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testClampingPins() {
        XCTAssertEqual(AXMatchScore(clamping: 7).raw, 3)
        XCTAssertEqual(AXMatchScore(clamping: -1).raw, 0)
        XCTAssertEqual(Confidence(clamping: 1.5).value, 1.0)
        XCTAssertEqual(Confidence(clamping: -0.25).value, 0.0)
    }

    func testScoreAndConfidenceAreComparable() {
        XCTAssertLessThan(AXMatchScore(clamping: 1), AXMatchScore(clamping: 2))
        XCTAssertLessThan(Confidence(clamping: 0.2), Confidence(clamping: 0.9))
    }

    // MARK: - (b) space-type distinctness pins

    func testSpaceTypesAreDistinct() {
        XCTAssertNotEqual(ObjectIdentifier(Point<AXSpace>.self), ObjectIdentifier(Point<FrameSpace>.self))
        XCTAssertNotEqual(ObjectIdentifier(Point<FrameSpace>.self), ObjectIdentifier(Point<EventSpace>.self))
        XCTAssertNotEqual(ObjectIdentifier(Point<EventSpace>.self), ObjectIdentifier(Point<WebViewportSpace>.self))
        XCTAssertNotEqual(ObjectIdentifier(Rect<AXSpace>.self), ObjectIdentifier(Rect<FrameSpace>.self))
    }

    /// Compile-time witness: this function accepts ONLY Point<FrameSpace>.
    /// Passing a `Point<AXSpace>` here is a COMPILE error (negative-compile pinned by
    /// review — Swift/XCTest has no expect-not-to-compile harness). The positive path
    /// is exercised below.
    private func takesFrame(_ p: Point<FrameSpace>) -> Double { p.x + p.y }

    func testFrameSpaceWitnessCompiles() {
        let p = Point<FrameSpace>(x: 3, y: 4)
        XCTAssertEqual(takesFrame(p), 7)
        // let ax = Point<AXSpace>(x: 3, y: 4)
        // takesFrame(ax) // <- does not compile: cannot convert Point<AXSpace> to Point<FrameSpace>
    }

    func testRectMidpointStaysInSpace() {
        let r = Rect<FrameSpace>(x: 10, y: 20, width: 100, height: 40)
        let mid: Point<FrameSpace> = r.midpoint
        XCTAssertEqual(mid, Point<FrameSpace>(x: 60, y: 40))
    }

    // MARK: - (a2) Codable cannot bypass the clamp (audit minor #1)

    func testDecodingRoutesThroughClamp() throws {
        let decoder = JSONDecoder()
        // Out-of-range persisted payloads pin to the documented invariants, never leak through.
        XCTAssertEqual(try decoder.decode(Confidence.self, from: Data(#"{"value":7.3}"#.utf8)).value, 1.0)
        XCTAssertEqual(try decoder.decode(Confidence.self, from: Data(#"{"value":-2.0}"#.utf8)).value, 0.0)
        XCTAssertEqual(try decoder.decode(AXMatchScore.self, from: Data(#"{"raw":9}"#.utf8)).raw, 3)
        XCTAssertEqual(try decoder.decode(AXMatchScore.self, from: Data(#"{"raw":-4}"#.utf8)).raw, 0)
        // In-range values pass through unchanged.
        XCTAssertEqual(try decoder.decode(Confidence.self, from: Data(#"{"value":0.5}"#.utf8)).value, 0.5)
        XCTAssertEqual(try decoder.decode(AXMatchScore.self, from: Data(#"{"raw":2}"#.utf8)).raw, 2)
    }

    func testScoreEncodingKeysUnchangedByHandWrittenDecode() throws {
        // Encoding stays synthesized on the same keys — wire format byte-identical.
        XCTAssertEqual(
            String(data: try JSONEncoder().encode(Confidence(clamping: 0.5)), encoding: .utf8),
            #"{"value":0.5}"#
        )
        XCTAssertEqual(
            String(data: try JSONEncoder().encode(AXMatchScore(clamping: 2)), encoding: .utf8),
            #"{"raw":2}"#
        )
    }

    // MARK: - (b2) Codable cannot erase the phantom space tag (audit minor #2)

    func testPointDecodeRejectsCrossSpacePayload() throws {
        let ax = Point<AXSpace>(x: 3, y: 4)
        let data = try JSONEncoder().encode(ax)
        // Same-space round trip works.
        XCTAssertEqual(try JSONDecoder().decode(Point<AXSpace>.self, from: data), ax)
        // Cross-space decode THROWS — MISSED, never silently FALSE.
        XCTAssertThrowsError(try JSONDecoder().decode(Point<FrameSpace>.self, from: data))
        XCTAssertThrowsError(try JSONDecoder().decode(Point<EventSpace>.self, from: data))
    }

    func testRectDecodeRejectsCrossSpacePayload() throws {
        let frame = Rect<FrameSpace>(x: 10, y: 20, width: 100, height: 40)
        let data = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(Rect<FrameSpace>.self, from: data), frame)
        XCTAssertThrowsError(try JSONDecoder().decode(Rect<AXSpace>.self, from: data))
        // Untagged legacy payloads are rejected too (no silent re-tagging path).
        XCTAssertThrowsError(try JSONDecoder().decode(
            Rect<FrameSpace>.self,
            from: Data(#"{"x":1,"y":2,"width":3,"height":4}"#.utf8)
        ))
    }

    func testEncodedGeometryCarriesSpaceTag() throws {
        let data = try JSONEncoder().encode(Point<WebViewportSpace>(x: 1, y: 2))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["space"] as? String, "webViewport")
    }

    // MARK: - (c) ActionRisk migration pin — persisted-encoding stability across the move

    func testActionRiskRawValueEncodingIsStable() throws {
        let risks: [ActionRisk] = [.low, .elevated, .high, .destructive]
        let data = try JSONEncoder().encode(risks)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, #"["low","elevated","high","destructive"]"#)

        let decoded = try JSONDecoder().decode([ActionRisk].self, from: data)
        XCTAssertEqual(decoded, risks)
    }

    // MARK: - Grounding shapes round-trip (Confidence/FrameSpace-typed)

    func testGroundingVerdictCodableRoundTrip() throws {
        let candidate = GroundingCandidate(
            point: Point<FrameSpace>(x: 684, y: 711),
            rect: Rect<FrameSpace>(x: 660, y: 700, width: 48, height: 22),
            role: "AXButton",
            label: "New Document",
            targetText: "New Document",
            source: .ax,
            confidence: AXMatchScore(clamping: 3).normalized(),
            evidence: [.roleMatch, .labelExact]
        )
        let verdict = GroundingVerdict(selected: candidate, candidates: [candidate], reason: .axHit)
        let data = try JSONEncoder().encode(verdict)
        let decoded = try JSONDecoder().decode(GroundingVerdict.self, from: data)
        XCTAssertEqual(decoded, verdict)
        XCTAssertEqual(decoded.selected?.confidence.value, 1.0)
    }
}
