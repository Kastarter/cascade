import MacContextKit
import Testing

@MainActor
@Test
func enumeratorReturnsAppsAndWellFormedDisplays() {
    let snapshot = SystemEnumerator.snapshot(includeWindows: true)
    // The host process and system apps are always running.
    #expect(!snapshot.runningApps.isEmpty)
    // Any reported display must have a real, positive frame.
    for display in snapshot.displays {
        #expect(display.frame.width > 0)
        #expect(display.frame.height > 0)
    }
}
