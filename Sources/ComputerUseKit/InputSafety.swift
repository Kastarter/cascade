import CascadeMemory
import CoreGraphics
import Foundation
#if canImport(Carbon)
import Carbon
#endif

/// macOS "Secure Input" — engaged when a password field has focus (or by some
/// terminals/password managers) — silently DROPS synthetic keyboard events. When
/// it's active the agent "types" into the void: keys press, nothing lands. We
/// detect it and refuse with a clear message instead of failing invisibly, which
/// was a real "it's pressing but nothing is written" failure mode (SEQ-09).
public enum SecureInputGuard {
    /// Whether macOS Secure Input is currently engaged process-wide.
    public static func isActive() -> Bool {
        #if canImport(Carbon)
        return IsSecureEventInputEnabled()
        #else
        return false
        #endif
    }

    /// A user-facing refusal reason when synthetic keyboard input can't land, or
    /// nil when typing is safe. Pure (takes the state) so it's unit-testable
    /// without toggling system-wide Secure Input.
    public static func refusalReason(secureInputActive: Bool) -> String? {
        guard secureInputActive else { return nil }
        return "macOS Secure Input is active (a password field has focus), so synthetic "
            + "keystrokes won't register. Ask the user to type this themselves, or move focus "
            + "out of the secure field, then retry."
    }
}

/// Splits text into UTF-16 chunks for `keyboardSetUnicodeString` that NEVER split
/// a grapheme cluster. Emoji, flags, skin-tone/ZWJ sequences, and combining marks
/// span multiple UTF-16 units; cutting them on a raw fixed window injects a broken
/// half-glyph (the classic "🎉" → two replacement chars) or drops the character.
public enum TextChunker {
    /// Grapheme-safe chunks, each at most `maxUTF16` UTF-16 units — except a single
    /// grapheme longer than `maxUTF16`, which becomes its own chunk rather than
    /// being split.
    public static func graphemeSafeChunks(_ text: String, maxUTF16: Int = 16) -> [[UniChar]] {
        precondition(maxUTF16 > 0)
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            // Flush before this grapheme would overflow the window.
            if !current.isEmpty, current.count + units.count > maxUTF16 {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
            // A single grapheme at/over the window is emitted whole on its own.
            if current.count >= maxUTF16 {
                chunks.append(current)
                current = []
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

public struct TextInjectionResult: Equatable, Sendable {
    public enum Method: String, Equatable, Sendable {
        case ax
        case paste
        case unicodeEvent
        case physicalKeys
    }

    public enum ReadbackStatus: String, Equatable, Sendable {
        case notAvailable
        case matched
        case mismatched
        case notChecked
    }

    public let method: Method
    public let succeeded: Bool
    public let focusedRole: String?
    public let focusedSubrole: String?
    public let bundleIdentifier: String?
    public let secureInputEnabled: Bool
    public let readbackStatus: ReadbackStatus
    public let fallbackReason: String?
    public let elapsedMs: Int
    public let characterCount: Int
    public let textHash: String

    public init(
        method: Method,
        succeeded: Bool,
        focusedRole: String? = nil,
        focusedSubrole: String? = nil,
        bundleIdentifier: String? = nil,
        secureInputEnabled: Bool,
        readbackStatus: ReadbackStatus = .notChecked,
        fallbackReason: String? = nil,
        elapsedMs: Int,
        characterCount: Int,
        textHash: String
    ) {
        self.method = method
        self.succeeded = succeeded
        self.focusedRole = focusedRole
        self.focusedSubrole = focusedSubrole
        self.bundleIdentifier = bundleIdentifier
        self.secureInputEnabled = secureInputEnabled
        self.readbackStatus = readbackStatus
        self.fallbackReason = fallbackReason
        self.elapsedMs = elapsedMs
        self.characterCount = characterCount
        self.textHash = textHash
    }

    public static func make(
        method: Method,
        text: String,
        succeeded: Bool,
        focusedRole: String? = nil,
        focusedSubrole: String? = nil,
        bundleIdentifier: String? = nil,
        secureInputEnabled: Bool,
        readbackStatus: ReadbackStatus = .notChecked,
        fallbackReason: String? = nil,
        elapsedMs: Int
    ) -> TextInjectionResult {
        TextInjectionResult(
            method: method,
            succeeded: succeeded,
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole,
            bundleIdentifier: bundleIdentifier,
            secureInputEnabled: secureInputEnabled,
            readbackStatus: readbackStatus,
            fallbackReason: fallbackReason,
            elapsedMs: elapsedMs,
            characterCount: text.count,
            textHash: AuditIdentity.hash(text)
        )
    }

    public var auditDetail: String {
        var parts = [
            "method=\(method.rawValue)",
            "status=\(succeeded ? "ok" : "fallback")",
            "chars=\(characterCount)",
            "textHash=\(textHash)",
            "secureInput=\(secureInputEnabled ? "true" : "false")",
            "readback=\(readbackStatus.rawValue)",
            "elapsedMs=\(max(0, elapsedMs))",
        ]
        if let focusedRole { parts.append("role=\(AuditIdentity.safeToken(focusedRole))") }
        if let focusedSubrole { parts.append("subrole=\(AuditIdentity.safeToken(focusedSubrole))") }
        if let bundleIdentifier { parts.append("bundleHash=\(AuditIdentity.hash(bundleIdentifier))") }
        if let fallbackReason { parts.append("fallbackReason=\(AuditIdentity.safeToken(fallbackReason))") }
        return parts.joined(separator: " ")
    }
}

public struct KeyboardKeyMapping: Equatable, Sendable {
    public let keyCode: CGKeyCode
    public let requiredModifiers: CGEventFlags

    public init(keyCode: CGKeyCode, requiredModifiers: CGEventFlags = []) {
        self.keyCode = keyCode
        self.requiredModifiers = requiredModifiers
    }
}

public enum KeyboardLayoutMapper {
    public static func mapping(for key: String) -> KeyboardKeyMapping? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mapped = currentLayoutMapping(for: trimmed) {
            return mapped
        }
        return usFallbackMapping(for: trimmed)
    }

    public static func usFallbackMapping(for key: String) -> KeyboardKeyMapping? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        switch lower {
        case "return", "enter": return KeyboardKeyMapping(keyCode: 36)
        case "escape", "esc": return KeyboardKeyMapping(keyCode: 53)
        case "tab": return KeyboardKeyMapping(keyCode: 48)
        case "space": return KeyboardKeyMapping(keyCode: 49)
        case "delete", "backspace": return KeyboardKeyMapping(keyCode: 51)
        case "forwarddelete": return KeyboardKeyMapping(keyCode: 117)
        case "home": return KeyboardKeyMapping(keyCode: 115)
        case "end": return KeyboardKeyMapping(keyCode: 119)
        case "pageup": return KeyboardKeyMapping(keyCode: 116)
        case "pagedown": return KeyboardKeyMapping(keyCode: 121)
        case "left": return KeyboardKeyMapping(keyCode: 123)
        case "right": return KeyboardKeyMapping(keyCode: 124)
        case "down": return KeyboardKeyMapping(keyCode: 125)
        case "up": return KeyboardKeyMapping(keyCode: 126)
        case "f1": return KeyboardKeyMapping(keyCode: 122)
        case "f2": return KeyboardKeyMapping(keyCode: 120)
        case "f3": return KeyboardKeyMapping(keyCode: 99)
        case "f4": return KeyboardKeyMapping(keyCode: 118)
        case "f5": return KeyboardKeyMapping(keyCode: 96)
        case "f6": return KeyboardKeyMapping(keyCode: 97)
        case "f7": return KeyboardKeyMapping(keyCode: 98)
        case "f8": return KeyboardKeyMapping(keyCode: 100)
        case "f9": return KeyboardKeyMapping(keyCode: 101)
        case "f10": return KeyboardKeyMapping(keyCode: 109)
        case "f11": return KeyboardKeyMapping(keyCode: 103)
        case "f12": return KeyboardKeyMapping(keyCode: 111)
        case "a": return KeyboardKeyMapping(keyCode: 0, requiredModifiers: normalized == "A" ? .maskShift : [])
        case "s": return KeyboardKeyMapping(keyCode: 1, requiredModifiers: normalized == "S" ? .maskShift : [])
        case "d": return KeyboardKeyMapping(keyCode: 2, requiredModifiers: normalized == "D" ? .maskShift : [])
        case "f": return KeyboardKeyMapping(keyCode: 3, requiredModifiers: normalized == "F" ? .maskShift : [])
        case "h": return KeyboardKeyMapping(keyCode: 4, requiredModifiers: normalized == "H" ? .maskShift : [])
        case "g": return KeyboardKeyMapping(keyCode: 5, requiredModifiers: normalized == "G" ? .maskShift : [])
        case "z": return KeyboardKeyMapping(keyCode: 6, requiredModifiers: normalized == "Z" ? .maskShift : [])
        case "x": return KeyboardKeyMapping(keyCode: 7, requiredModifiers: normalized == "X" ? .maskShift : [])
        case "c": return KeyboardKeyMapping(keyCode: 8, requiredModifiers: normalized == "C" ? .maskShift : [])
        case "v": return KeyboardKeyMapping(keyCode: 9, requiredModifiers: normalized == "V" ? .maskShift : [])
        case "b": return KeyboardKeyMapping(keyCode: 11, requiredModifiers: normalized == "B" ? .maskShift : [])
        case "q": return KeyboardKeyMapping(keyCode: 12, requiredModifiers: normalized == "Q" ? .maskShift : [])
        case "w": return KeyboardKeyMapping(keyCode: 13, requiredModifiers: normalized == "W" ? .maskShift : [])
        case "e": return KeyboardKeyMapping(keyCode: 14, requiredModifiers: normalized == "E" ? .maskShift : [])
        case "r": return KeyboardKeyMapping(keyCode: 15, requiredModifiers: normalized == "R" ? .maskShift : [])
        case "y": return KeyboardKeyMapping(keyCode: 16, requiredModifiers: normalized == "Y" ? .maskShift : [])
        case "t": return KeyboardKeyMapping(keyCode: 17, requiredModifiers: normalized == "T" ? .maskShift : [])
        case "o": return KeyboardKeyMapping(keyCode: 31, requiredModifiers: normalized == "O" ? .maskShift : [])
        case "u": return KeyboardKeyMapping(keyCode: 32, requiredModifiers: normalized == "U" ? .maskShift : [])
        case "i": return KeyboardKeyMapping(keyCode: 34, requiredModifiers: normalized == "I" ? .maskShift : [])
        case "p": return KeyboardKeyMapping(keyCode: 35, requiredModifiers: normalized == "P" ? .maskShift : [])
        case "l": return KeyboardKeyMapping(keyCode: 37, requiredModifiers: normalized == "L" ? .maskShift : [])
        case "j": return KeyboardKeyMapping(keyCode: 38, requiredModifiers: normalized == "J" ? .maskShift : [])
        case "k": return KeyboardKeyMapping(keyCode: 40, requiredModifiers: normalized == "K" ? .maskShift : [])
        case "n": return KeyboardKeyMapping(keyCode: 45, requiredModifiers: normalized == "N" ? .maskShift : [])
        case "m": return KeyboardKeyMapping(keyCode: 46, requiredModifiers: normalized == "M" ? .maskShift : [])
        case "1": return KeyboardKeyMapping(keyCode: 18)
        case "2": return KeyboardKeyMapping(keyCode: 19)
        case "3": return KeyboardKeyMapping(keyCode: 20)
        case "4": return KeyboardKeyMapping(keyCode: 21)
        case "5": return KeyboardKeyMapping(keyCode: 23)
        case "6": return KeyboardKeyMapping(keyCode: 22)
        case "7": return KeyboardKeyMapping(keyCode: 26)
        case "8": return KeyboardKeyMapping(keyCode: 28)
        case "9": return KeyboardKeyMapping(keyCode: 25)
        case "0": return KeyboardKeyMapping(keyCode: 29)
        case "-", "minus": return KeyboardKeyMapping(keyCode: 27)
        case "_": return KeyboardKeyMapping(keyCode: 27, requiredModifiers: .maskShift)
        case "=", "equal", "equals": return KeyboardKeyMapping(keyCode: 24)
        case "+", "plus": return KeyboardKeyMapping(keyCode: 24, requiredModifiers: .maskShift)
        case "[": return KeyboardKeyMapping(keyCode: 33)
        case "{": return KeyboardKeyMapping(keyCode: 33, requiredModifiers: .maskShift)
        case "]": return KeyboardKeyMapping(keyCode: 30)
        case "}": return KeyboardKeyMapping(keyCode: 30, requiredModifiers: .maskShift)
        case "\\": return KeyboardKeyMapping(keyCode: 42)
        case "|": return KeyboardKeyMapping(keyCode: 42, requiredModifiers: .maskShift)
        case ";": return KeyboardKeyMapping(keyCode: 41)
        case ":": return KeyboardKeyMapping(keyCode: 41, requiredModifiers: .maskShift)
        case "'": return KeyboardKeyMapping(keyCode: 39)
        case "\"": return KeyboardKeyMapping(keyCode: 39, requiredModifiers: .maskShift)
        case ",", "comma": return KeyboardKeyMapping(keyCode: 43)
        case "<": return KeyboardKeyMapping(keyCode: 43, requiredModifiers: .maskShift)
        case ".", "period": return KeyboardKeyMapping(keyCode: 47)
        case ">": return KeyboardKeyMapping(keyCode: 47, requiredModifiers: .maskShift)
        case "/", "slash": return KeyboardKeyMapping(keyCode: 44)
        case "?": return KeyboardKeyMapping(keyCode: 44, requiredModifiers: .maskShift)
        case "`", "grave": return KeyboardKeyMapping(keyCode: 50)
        case "~": return KeyboardKeyMapping(keyCode: 50, requiredModifiers: .maskShift)
        case "!": return KeyboardKeyMapping(keyCode: 18, requiredModifiers: .maskShift)
        case "@": return KeyboardKeyMapping(keyCode: 19, requiredModifiers: .maskShift)
        case "#": return KeyboardKeyMapping(keyCode: 20, requiredModifiers: .maskShift)
        case "$": return KeyboardKeyMapping(keyCode: 21, requiredModifiers: .maskShift)
        case "%": return KeyboardKeyMapping(keyCode: 23, requiredModifiers: .maskShift)
        case "^": return KeyboardKeyMapping(keyCode: 22, requiredModifiers: .maskShift)
        case "&": return KeyboardKeyMapping(keyCode: 26, requiredModifiers: .maskShift)
        case "*": return KeyboardKeyMapping(keyCode: 28, requiredModifiers: .maskShift)
        case "(": return KeyboardKeyMapping(keyCode: 25, requiredModifiers: .maskShift)
        case ")": return KeyboardKeyMapping(keyCode: 29, requiredModifiers: .maskShift)
        default: return nil
        }
    }

    private static func currentLayoutMapping(for key: String) -> KeyboardKeyMapping? {
        // The Carbon TIS APIs below (TISCopyCurrentKeyboardLayoutInputSource /
        // TISGetInputSourceProperty) assert they run on the MAIN thread — calling them
        // off-main crashes with dispatch_assert_queue_fail (SIGTRAP). The actuation path
        // can run on a background executor (grounding became async as of seq-11), so hop
        // to main before touching them. Root cause lives in seq-09's KeyboardLayoutMapper.
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { currentLayoutMapping(for: key) }
        }
        guard key.count == 1, let target = key.first else { return nil }
        #if canImport(Carbon)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(rawLayout, to: CFData.self)
        guard let keyboardLayout = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = unsafeBitCast(keyboardLayout, to: UnsafePointer<UCKeyboardLayout>.self)
        let modifierCandidates: [(UInt32, CGEventFlags)] = [
            (0, []),
            (UInt32(shiftKey >> 8), .maskShift),
            (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
        ]
        for keyCode in 0..<128 {
            for (modifierState, flags) in modifierCandidates {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDisplay),
                    modifierState,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
                guard status == noErr, length > 0 else { continue }
                let produced = String(utf16CodeUnits: chars, count: length)
                if produced.count == 1, produced.first == target {
                    return KeyboardKeyMapping(keyCode: CGKeyCode(keyCode), requiredModifiers: flags)
                }
            }
        }
        #endif
        return nil
    }
}

public struct KeyboardEventStep: Equatable, Sendable {
    public let keyCode: CGKeyCode
    public let keyDown: Bool
    public let flags: CGEventFlags

    public init(keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.keyDown = keyDown
        self.flags = flags
    }
}

public struct ScrollEventConfiguration: Equatable, Sendable {
    public let deltaX: Int32
    public let deltaY: Int32
    public let continuous: Bool
    public let phase: Int64
    public let momentumPhase: Int64

    public init(deltaX: Int32, deltaY: Int32, continuous: Bool = true, phase: Int64 = 1, momentumPhase: Int64 = 0) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.continuous = continuous
        self.phase = phase
        self.momentumPhase = momentumPhase
    }
}

public enum EventSynthesisPlan {
    public static func clickStates(clickCount: Int) -> [Int64] {
        guard clickCount > 0 else { return [] }
        return (1...clickCount).map(Int64.init)
    }

    public static func modifierEventSequence(mainKeyCode: CGKeyCode, flags: CGEventFlags) -> [KeyboardEventStep] {
        let modifiers = modifierKeyCodes(for: flags)
        guard !modifiers.isEmpty else {
            return [
                KeyboardEventStep(keyCode: mainKeyCode, keyDown: true, flags: flags),
                KeyboardEventStep(keyCode: mainKeyCode, keyDown: false, flags: flags),
            ]
        }
        var events: [KeyboardEventStep] = []
        var currentFlags: CGEventFlags = []
        for modifier in modifiers {
            currentFlags.insert(modifier.flag)
            events.append(KeyboardEventStep(keyCode: modifier.keyCode, keyDown: true, flags: currentFlags))
        }
        events.append(KeyboardEventStep(keyCode: mainKeyCode, keyDown: true, flags: flags))
        events.append(KeyboardEventStep(keyCode: mainKeyCode, keyDown: false, flags: flags))
        for modifier in modifiers.reversed() {
            currentFlags.remove(modifier.flag)
            events.append(KeyboardEventStep(keyCode: modifier.keyCode, keyDown: false, flags: currentFlags))
        }
        return events
    }

    public static func scrollConfiguration(deltaX: Double, deltaY: Double) -> ScrollEventConfiguration {
        ScrollEventConfiguration(
            deltaX: boundedInt32(deltaX),
            deltaY: boundedInt32(deltaY)
        )
    }

    private static func boundedInt32(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        if value > Double(Int32.max) { return Int32.max }
        if value < Double(Int32.min) { return Int32.min }
        return Int32(value.rounded())
    }

    private static func modifierKeyCodes(for flags: CGEventFlags) -> [(flag: CGEventFlags, keyCode: CGKeyCode)] {
        var out: [(CGEventFlags, CGKeyCode)] = []
        if flags.contains(.maskControl) { out.append((.maskControl, 59)) }
        if flags.contains(.maskAlternate) { out.append((.maskAlternate, 58)) }
        if flags.contains(.maskShift) { out.append((.maskShift, 56)) }
        if flags.contains(.maskCommand) { out.append((.maskCommand, 55)) }
        return out
    }
}
