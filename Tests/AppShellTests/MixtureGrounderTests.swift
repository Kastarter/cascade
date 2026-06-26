import AppKit
import CoreGraphics
import Testing

@testable import AppShell

/// Pins the mixture grounder's coordinate conversion — the one number that, if
/// wrong, sends every AX-grounded click into empty space. `displayLocalPoint`
/// maps an element center in CG-global (top-left origin, the AX space) into the
/// display-local AppKit point (bottom-left origin) the executor consumes. It must
/// match `ElementLocator.guide` / `UITARSGrounder.toDisplayPoint` exactly so an
/// AX point and a visual point are interchangeable.
struct MixtureGrounderTests {
    @Test func primaryDisplayCenterFlipsY() {
        // 1440×900 primary at the CG origin; a center at (720,450) → local
        // (720, 900-450 = 450).
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let p = MixtureGrounder.displayLocalPoint(
            cgGlobalCenter: CGPoint(x: 720, y: 450), displayCGBounds: bounds, displayHeightPoints: 900
        )
        #expect(p == CGPoint(x: 720, y: 450))
    }

    @Test func topLeftBecomesTopLeftAppKit() {
        // A point near the CG top-left (0,0) is near the AppKit TOP — i.e. y ≈ height.
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let p = MixtureGrounder.displayLocalPoint(
            cgGlobalCenter: CGPoint(x: 10, y: 10), displayCGBounds: bounds, displayHeightPoints: 900
        )
        #expect(p == CGPoint(x: 10, y: 890))
    }

    @Test func bottomEdgeBecomesZeroY() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let p = MixtureGrounder.displayLocalPoint(
            cgGlobalCenter: CGPoint(x: 100, y: 900), displayCGBounds: bounds, displayHeightPoints: 900
        )
        #expect(p == CGPoint(x: 100, y: 0))
    }

    @Test func offsetSecondaryDisplaySubtractsOrigin() {
        // A 1280×720 secondary whose CG origin is (1440,0): a center at
        // (1440+640, 360) → local (640, 720-360 = 360).
        let bounds = CGRect(x: 1440, y: 0, width: 1280, height: 720)
        let p = MixtureGrounder.displayLocalPoint(
            cgGlobalCenter: CGPoint(x: 2080, y: 360), displayCGBounds: bounds, displayHeightPoints: 720
        )
        #expect(p == CGPoint(x: 640, y: 360))
    }

    @Test func pointOffTheDisplayIsRejected() {
        // A match whose center lands on a DIFFERENT monitor must return nil so the
        // caller falls back to the visual grounder rather than clicking blind.
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(MixtureGrounder.displayLocalPoint(
            cgGlobalCenter: CGPoint(x: 2000, y: 450), displayCGBounds: bounds, displayHeightPoints: 900
        ) == nil)
        #expect(MixtureGrounder.displayLocalPoint(
            cgGlobalCenter: CGPoint(x: 100, y: -50), displayCGBounds: bounds, displayHeightPoints: 900
        ) == nil)
    }

    @Test func degenerateBoundsReturnNil() {
        #expect(MixtureGrounder.displayLocalPoint(
            cgGlobalCenter: CGPoint(x: 0, y: 0), displayCGBounds: .zero, displayHeightPoints: 0
        ) == nil)
    }

    @Test func canvasConceptsBypassAX() {
        // Canvas placeholders/surfaces must go to the visual grounder, never an AX
        // substring match (the Keynote inspector-checkbox hijack).
        #expect(MixtureGrounder.namesCanvasConcept("the subtitle placeholder"))
        #expect(MixtureGrounder.namesCanvasConcept("the drawing canvas"))
        // Real chrome controls still take the AX-first path.
        #expect(!MixtureGrounder.namesCanvasConcept("the New Document button"))
        #expect(!MixtureGrounder.namesCanvasConcept("the Save button"))
        #expect(!MixtureGrounder.namesCanvasConcept("the Reply All button"))
    }

    @Test func onlyActionableRolesAreTrusted() {
        // Static text / images are matched by `find` but must NOT be trusted for a
        // click — that's what lets "the title" grab a chrome label instead of the
        // canvas placeholder.
        #expect(MixtureGrounder.clickableRoles.contains("AXButton"))
        #expect(MixtureGrounder.clickableRoles.contains("AXTextField"))
        #expect(!MixtureGrounder.clickableRoles.contains("AXStaticText"))
        #expect(!MixtureGrounder.clickableRoles.contains("AXImage"))
    }

    @Test func oversizedAXMatchIsNotTrustedSoItFallsToVisual() {
        // The Keynote bug: AX exposes the title placeholder as a wide AXTextArea, and
        // its CENTER is empty space (a double-click there spawns a new text box). A
        // frame covering a big share of the slide must NOT be AX-trusted — defer to
        // the visual grounder. ~1100×320 on a 1440×900 display ≈ 27% → rejected.
        #expect(!MixtureGrounder.isTrustableControlSize(
            CGSize(width: 1100, height: 320), displayWidthPoints: 1440, displayHeightPoints: 900
        ))
    }

    @Test func normalControlsKeepTheAXFastPath() {
        // A button / field / menu item is a small fraction of the screen — its center
        // is exactly where you'd click, so AX-first stays (free + exact).
        #expect(MixtureGrounder.isTrustableControlSize(
            CGSize(width: 120, height: 32), displayWidthPoints: 1440, displayHeightPoints: 900
        ))
        // A full-width but SHORT row/toolbar item is still a control (small area).
        #expect(MixtureGrounder.isTrustableControlSize(
            CGSize(width: 1440, height: 28), displayWidthPoints: 1440, displayHeightPoints: 900
        ))
    }

    @Test func wholeSlideRegionIsRejected_unknownDisplayNeverOverRejects() {
        // A near-full-screen match is plainly a region, not a control.
        #expect(!MixtureGrounder.isTrustableControlSize(
            CGSize(width: 1440, height: 900), displayWidthPoints: 1440, displayHeightPoints: 900
        ))
        // An unknown display (0 area) must not reject — degrade safely to AX, the
        // no-effect detector remains the backstop.
        #expect(MixtureGrounder.isTrustableControlSize(
            CGSize(width: 1100, height: 320), displayWidthPoints: 0, displayHeightPoints: 0
        ))
    }

    @Test func ocrTextPointMapsBoxCenterToDisplayPointWithoutYFlip() {
        // OCR point grounding (the Keynote canvas fix): a Vision box (normalized 0…1,
        // LOWER-LEFT origin) → the CENTER as a display-local AppKit point (bottom-left,
        // NO Y flip), the executor's space. A box at (0.2,0.6) sized 0.3×0.05 has
        // center (0.35, 0.625) → on a 1280×800 display → (448, 500).
        let p = MixtureGrounder.pointFromVisionBox(
            CGRect(x: 0.2, y: 0.6, width: 0.3, height: 0.05),
            displayWidthPoints: 1280, displayHeightPoints: 800
        )
        #expect(p.x == 448)
        #expect(p.y == 500)
    }

    @Test func ocrTextBoxMapsToDisplayRectWithoutYFlip() {
        // OCR text grounding (the fix for "point at document text"): a Vision box
        // (normalized 0…1, LOWER-LEFT origin) → display-local AppKit rect (also
        // bottom-left), so it scales with NO Y flip. A box at (0.2,0.6) sized
        // 0.3×0.05 on a 1280×800 display → (256,480) sized 384×40.
        let r = MixtureGrounder.rectFromVisionBox(
            CGRect(x: 0.2, y: 0.6, width: 0.3, height: 0.05),
            displayWidthPoints: 1280, displayHeightPoints: 800
        )
        #expect(r.minX == 256)
        #expect(r.minY == 480)
        #expect(r.width == 384)
        #expect(r.height == 40)
    }
}
