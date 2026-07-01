import CascadeMemory
@testable import MacContextKit
import Testing

@Test
func typedInputIsPersistedAsShapeOnly() {
    #expect(InputEventSanitizer.sanitize(text: "secret123", kind: .type) == "typed 9 chars")
    #expect(InputEventSanitizer.sanitize(text: "typed 9 chars", kind: .type) == "typed 9 chars")
}

@Test
func clickLabelsUsePIIPlaceholders() {
    let label = InputEventSanitizer.sanitize(text: "Reply to jane@example.com", kind: .click)
    #expect(label == "Reply to <EMAIL>")
}

@Test
func sensitiveClickLabelsAreDropped() {
    #expect(InputEventSanitizer.sanitize(text: "Password reset", kind: .click) == nil)
    #expect(InputEventSanitizer.sanitize(descriptor: "AXGroup: bank balance") == nil)
}
