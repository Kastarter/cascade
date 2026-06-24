import AppKit
import Testing

@testable import SandboxKit

/// Pins the pure pieces of the web grounding split: the select-all detection that
/// makes the native fill pattern (click → cmd+a → type → return) REPLACE on the
/// web, and the DOM resolver's coordinate parse/flip (top-left CSS px → bottom-left
/// AppKit). The live DOM resolution itself needs a real WebView and is exercised at
/// runtime, not in CI.
struct WebDOMGrounderTests {
    @Test func selectAllCombosDetected() {
        #expect(WebSandbox.isSelectAll("cmd+a"))
        #expect(WebSandbox.isSelectAll("ctrl+a"))
        #expect(WebSandbox.isSelectAll("command+a"))
        #expect(WebSandbox.isSelectAll("CMD+A"))
    }

    @Test func nonSelectAllCombosIgnored() {
        #expect(!WebSandbox.isSelectAll("a"))          // bare a is typing, not select-all
        #expect(!WebSandbox.isSelectAll("cmd+c"))
        #expect(!WebSandbox.isSelectAll("return"))
        #expect(!WebSandbox.isSelectAll("cmd+shift+s"))
    }

    @Test func groundResultParsesAndFlipsY() {
        // viewport height 560; element center at top-left (450, 100) → bottom-left
        // (450, 460).
        let p = WebSandbox.parseGroundResult("450,100", viewportHeight: 560)
        #expect(p == CGPoint(x: 450, y: 460))
    }

    @Test func groundResultToleratesSpacesAndRejectsGarbage() {
        #expect(WebSandbox.parseGroundResult(" 12 , 34 ", viewportHeight: 560) == CGPoint(x: 12, y: 526))
        #expect(WebSandbox.parseGroundResult("", viewportHeight: 560) == nil)
        #expect(WebSandbox.parseGroundResult("nope", viewportHeight: 560) == nil)
        #expect(WebSandbox.parseGroundResult("1,2,3", viewportHeight: 560) == nil)
    }
}
