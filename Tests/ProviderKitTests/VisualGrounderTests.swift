import CoreGraphics
import Foundation
import Testing

@testable import ProviderKit

/// Pins the UI-TARS grounder's two pure, runtime-independent pieces: the
/// coordinate-grammar parser and the image→display scaling. The live model call is
/// runtime-unverified (no 7B model in CI), so correctness here is the safety net —
/// a wrong number clicks empty space. This is the engine for Phase 1's grounding
/// split (move WHERE-to-click out of the cloud thinker). See [[cascade-cu-downgrade-research]].
struct VisualGrounderTests {

    // MARK: parseBox — UI-TARS action-grammar variants

    @Test func parsesStartBoxParens() {
        let p = UITARSGrounder.parseBox("click(start_box='(197,525)')")
        #expect(p == CGPoint(x: 197, y: 525))
    }

    @Test func parsesBoxTokenWrappedCoords() {
        let p = UITARSGrounder.parseBox("click(start_box='<|box_start|>(100,200)<|box_end|>')")
        #expect(p == CGPoint(x: 100, y: 200))
    }

    @Test func parsesBarePair() {
        #expect(UITARSGrounder.parseBox("(640, 360)") == CGPoint(x: 640, y: 360))
    }

    @Test func parsesBracketPair() {
        #expect(UITARSGrounder.parseBox("[100, 200]") == CGPoint(x: 100, y: 200))
    }

    @Test func fourNumberRegionCollapsesToCenter() {
        // start_box as a region (x1,y1,x2,y2) → its center point.
        #expect(UITARSGrounder.parseBox("click(start_box='(10,20,30,40)')") == CGPoint(x: 20, y: 30))
    }

    @Test func parsesDecimals() {
        #expect(UITARSGrounder.parseBox("(12.5, 30)") == CGPoint(x: 12.5, y: 30))
    }

    @Test func fallsBackToFirstPairWithoutBrackets() {
        // Some deployments answer with prose; take the first numeric pair.
        #expect(UITARSGrounder.parseBox("the button is at 320, 240 on screen") == CGPoint(x: 320, y: 240))
    }

    @Test func noCoordinatesReturnsNil() {
        #expect(UITARSGrounder.parseBox("I cannot find that element.") == nil)
        #expect(UITARSGrounder.parseBox("") == nil)
    }

    // MARK: toDisplayPoint — image pixels (top-left) → display points (bottom-left)

    @Test func centerMapsToCenterWithYFlip() {
        // Center of a 1280x800 image on a 1440x900 display: x scales, y flips.
        let p = UITARSGrounder.toDisplayPoint(
            imagePoint: CGPoint(x: 640, y: 400), imageW: 1280, imageH: 800, displayW: 1440, displayH: 900
        )
        #expect(p.x == 720)
        #expect(p.y == 450)  // 900 - (400/800 * 900)
    }

    @Test func imageTopLeftMapsToDisplayBottomLeft() {
        let p = UITARSGrounder.toDisplayPoint(
            imagePoint: .zero, imageW: 1280, imageH: 800, displayW: 1440, displayH: 900
        )
        #expect(p.x == 0)
        #expect(p.y == 900)  // top of image (y=0) → top in AppKit = displayH
    }

    @Test func imageBottomRightMapsToDisplayBottomRight() {
        let p = UITARSGrounder.toDisplayPoint(
            imagePoint: CGPoint(x: 1280, y: 800), imageW: 1280, imageH: 800, displayW: 1440, displayH: 900
        )
        #expect(p.x == 1440)
        #expect(p.y == 0)  // bottom of image → y=0 in AppKit
    }

    @Test func outOfRangeIsClamped() {
        // A hallucinated coord past the image edge clamps to the edge, never NaN/huge.
        let p = UITARSGrounder.toDisplayPoint(
            imagePoint: CGPoint(x: 5000, y: -100), imageW: 1280, imageH: 800, displayW: 1440, displayH: 900
        )
        #expect(p.x == 1440)  // clamped to imageW then scaled
        #expect(p.y == 900)   // y clamped to 0 (top) → displayH
    }

    // MARK: boxAround — region framing for the highlight

    @Test func boxAroundCentersAndSizesToDisplayFraction() {
        let r = UITARSGrounder.boxAround(point: CGPoint(x: 720, y: 450), displayW: 1440, displayH: 900)
        #expect(r.width == 1440 * 0.12)
        #expect(r.height == 900 * 0.08)
        #expect(r.midX == 720)
        #expect(r.midY == 450)
    }

    @Test func boxAroundClampsToScreenEdges() {
        // A point in the corner produces a box fully on screen, never off-edge.
        let r = UITARSGrounder.boxAround(point: .zero, displayW: 1000, displayH: 1000)
        #expect(r.minX == 0)
        #expect(r.minY == 0)
        let far = UITARSGrounder.boxAround(point: CGPoint(x: 1000, y: 1000), displayW: 1000, displayH: 1000)
        #expect(far.maxX == 1000)
        #expect(far.maxY == 1000)
    }

    // MARK: extractContent — OpenAI chat-completions reply

    @Test func extractsStringContent() {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"click(start_box='(5,6)')"}}]}"#
        #expect(UITARSGrounder.extractContent(Data(json.utf8)) == "click(start_box='(5,6)')")
    }

    @Test func extractsArrayContent() {
        let json = #"{"choices":[{"message":{"content":[{"type":"text","text":"(1,2)"}]}}]}"#
        #expect(UITARSGrounder.extractContent(Data(json.utf8)) == "(1,2)")
    }

    @Test func missingChoicesReturnsNil() {
        #expect(UITARSGrounder.extractContent(Data(#"{"error":"nope"}"#.utf8)) == nil)
    }
}
