import AppKit
import ComputerUseKit
import Testing

@Test
func defaultUseDeviceHotkeyMatchesControlOptionSpace() {
    let hotkey = UseDeviceHotkey.default

    #expect(hotkey.matches(keyCode: 49, modifierFlags: [.control, .option]))
    #expect(!hotkey.matches(keyCode: 49, modifierFlags: [.command]))
    #expect(!hotkey.matches(keyCode: 36, modifierFlags: [.control, .option]))
}
