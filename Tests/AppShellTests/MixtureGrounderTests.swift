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

    @Test func axFrameMapsToFittedDisplayLocalRect() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = MixtureGrounder.displayLocalRect(
            cgGlobalFrame: CGRect(x: 100, y: 120, width: 240, height: 60),
            displayCGBounds: bounds,
            displayHeightPoints: 900
        )
        #expect(rect == CGRect(x: 100, y: 720, width: 240, height: 60))
    }

    @Test func axFrameOffDisplayIsRejected() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(MixtureGrounder.displayLocalRect(
            cgGlobalFrame: CGRect(x: 1600, y: 100, width: 40, height: 40),
            displayCGBounds: bounds,
            displayHeightPoints: 900
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

    @Test func targetAliasesNormalizeLearnedGroundingNames() {
        let aliases = ["Title placeholder": ["title box", "heading field"]]
        #expect(MixtureGrounder.applyTargetAliases("the title box", aliases: aliases) == "Title placeholder")
        #expect(MixtureGrounder.applyTargetAliases("Save button", aliases: aliases) == "Save button")
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
