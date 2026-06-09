import MacContextKit
import Testing

@Test
func gateAllowsOrdinaryEvents() {
    #expect(InputCaptureGate.shouldRecord(isOwnApp: false, isSensitive: false, isKeyEvent: false, secureInputEnabled: false))
    #expect(InputCaptureGate.shouldRecord(isOwnApp: false, isSensitive: false, isKeyEvent: true, secureInputEnabled: false))
}

@Test
func gateBlocksOwnAppAndSensitiveApp() {
    #expect(!InputCaptureGate.shouldRecord(isOwnApp: true, isSensitive: false, isKeyEvent: false, secureInputEnabled: false))
    #expect(!InputCaptureGate.shouldRecord(isOwnApp: false, isSensitive: true, isKeyEvent: false, secureInputEnabled: false))
}

@Test
func secureInputBlocksOnlyKeystrokes() {
    // Keystrokes are dropped under secure input (password fields)...
    #expect(!InputCaptureGate.shouldRecord(isOwnApp: false, isSensitive: false, isKeyEvent: true, secureInputEnabled: true))
    // ...but clicks are still allowed.
    #expect(InputCaptureGate.shouldRecord(isOwnApp: false, isSensitive: false, isKeyEvent: false, secureInputEnabled: true))
}
