import CoreGraphics
import Testing

@testable import ComputerUseKit

/// The multi-cursor model: each companion is an independent observable so several
/// translucent agent cursors can fly/click/pulse on screen at once. (The overlay
/// rendering + flight choreography are visual and verified by eye.)
@MainActor
struct CompanionCursorTests {
    @Test func startsIdleAtItsSpawnPoint() {
        let cursor = CompanionCursor(id: "agent-2", theme: .pink, globalPoint: CGPoint(x: 10, y: 20))
        #expect(cursor.id == "agent-2")
        #expect(cursor.theme == .pink)
        #expect(cursor.globalPoint == CGPoint(x: 10, y: 20))
        #expect(cursor.label == "")
        #expect(cursor.pointing == false)
        #expect(cursor.thinking == false)
        #expect(cursor.pressTrigger == 0)
    }

    @Test func eachCursorIsIndependentlyIdentified() {
        let a = CompanionCursor(id: "a", theme: .peach, globalPoint: .zero)
        let b = CompanionCursor(id: "b", theme: .purple, globalPoint: .zero)
        #expect(a.id != b.id)
        #expect(a.theme != b.theme)
    }
}
