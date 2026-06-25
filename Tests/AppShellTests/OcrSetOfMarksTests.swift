import Testing

@testable import AppShell

/// Pins the gate for the OCR Set-of-Marks push: it fires ONLY where the AX tree is
/// sparse (canvas / non-AX surfaces like the Keynote slide canvas or Blender), so
/// rich-AX apps keep relying on the proven AX controls push and never pay the OCR
/// pass. The push itself is the structural fix for "the planner assumes what's on
/// the page" — on canvas it hands Scout the real on-screen text to name.
struct OcrSetOfMarksTests {
    @Test func axIsSparseBelowThreshold() {
        // Canvas / Electron: the AX walk returned almost nothing → OCR supplements.
        #expect(CascadeAppModel.axIsSparse(controlCount: 0))
        #expect(CascadeAppModel.axIsSparse(controlCount: 7))
        // Rich-AX chrome: plenty of named controls already → skip OCR.
        #expect(!CascadeAppModel.axIsSparse(controlCount: 8))
        #expect(!CascadeAppModel.axIsSparse(controlCount: 40))
    }

    @Test func ocrFiresOnCanvasNotBrowser() {
        // Sparse-AX NATIVE canvas (Keynote slide canvas, Blender): supplement w/ OCR.
        #expect(CascadeAppModel.shouldOcrSetOfMarks(axControlCount: 3, isBrowser: false))
        // Sparse-AX BROWSER page: OCR would dump page text as noise; the DOM-native
        // background agent owns the web — so don't.
        #expect(!CascadeAppModel.shouldOcrSetOfMarks(axControlCount: 3, isBrowser: true))
        // Rich-AX app: the AX controls push already covers it.
        #expect(!CascadeAppModel.shouldOcrSetOfMarks(axControlCount: 20, isBrowser: false))
    }
}
