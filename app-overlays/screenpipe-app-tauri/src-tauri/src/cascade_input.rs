// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
//! Native macOS input synthesis for the computer-use agent ("Cascade Hands").
//!
//! The agent has its OWN on-screen cursor (rendered by the overlay window). To
//! actually act, it posts synthesized events at screen coordinates via
//! CoreGraphics, then restores the user's real pointer to where they left it —
//! so the employee keeps working while the agent does its task. Raw CoreGraphics
//! FFI (the framework is already linked by the app) keeps this dependency-free
//! and API-stable.

#![cfg(target_os = "macos")]

use std::ffi::c_void;
use std::os::raw::c_int;

#[repr(C)]
#[derive(Clone, Copy)]
struct CGPoint {
    x: f64,
    y: f64,
}

type CGEventRef = *const c_void;
type CGEventSourceRef = *const c_void;

// CGEventType
const LEFT_MOUSE_DOWN: u32 = 1;
const LEFT_MOUSE_UP: u32 = 2;
// CGMouseButton
const MOUSE_BUTTON_LEFT: u32 = 0;
// CGEventTapLocation
const HID_EVENT_TAP: u32 = 0;
// CGEventFlags
const FLAG_COMMAND: u64 = 0x0010_0000;
const FLAG_SHIFT: u64 = 0x0002_0000;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventCreate(source: CGEventSourceRef) -> CGEventRef;
    fn CGEventGetLocation(event: CGEventRef) -> CGPoint;
    fn CGEventCreateMouseEvent(
        source: CGEventSourceRef,
        mouse_type: u32,
        cursor: CGPoint,
        button: u32,
    ) -> CGEventRef;
    fn CGEventCreateKeyboardEvent(
        source: CGEventSourceRef,
        keycode: u16,
        key_down: bool,
    ) -> CGEventRef;
    fn CGEventKeyboardSetUnicodeString(event: CGEventRef, length: usize, string: *const u16);
    fn CGEventSetFlags(event: CGEventRef, flags: u64);
    fn CGEventPost(tap: u32, event: CGEventRef);
    fn CGWarpMouseCursorPosition(new_position: CGPoint) -> c_int;
    // Variadic in C, but always called here with wheelCount = 1, so a fixed
    // 4-arg declaration matches the bytes we pass.
    fn CGEventCreateScrollWheelEvent(
        source: CGEventSourceRef,
        units: u32,
        wheel_count: u32,
        wheel1: i32,
    ) -> CGEventRef;
}

// CGScrollEventUnit
const SCROLL_UNIT_PIXEL: u32 = 0;

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(cf: *const c_void);
}

fn current_cursor() -> CGPoint {
    unsafe {
        let ev = CGEventCreate(std::ptr::null());
        if ev.is_null() {
            return CGPoint { x: 0.0, y: 0.0 };
        }
        let p = CGEventGetLocation(ev);
        CFRelease(ev);
        p
    }
}

/// Click at a logical screen point, then snap the real pointer back to where the
/// user left it. The synthesized event reaches whatever app is at that point.
pub fn click(x: f64, y: f64) {
    unsafe {
        let saved = current_cursor();
        let p = CGPoint { x, y };
        let down = CGEventCreateMouseEvent(std::ptr::null(), LEFT_MOUSE_DOWN, p, MOUSE_BUTTON_LEFT);
        if !down.is_null() {
            CGEventPost(HID_EVENT_TAP, down);
            CFRelease(down);
        }
        let up = CGEventCreateMouseEvent(std::ptr::null(), LEFT_MOUSE_UP, p, MOUSE_BUTTON_LEFT);
        if !up.is_null() {
            CGEventPost(HID_EVENT_TAP, up);
            CFRelease(up);
        }
        // Return the user's pointer.
        CGWarpMouseCursorPosition(saved);
    }
}

pub fn double_click(x: f64, y: f64) {
    click(x, y);
    click(x, y);
}

/// Scroll via a synthesized scroll-wheel event. `dy` follows the agent's
/// convention: positive = down, negative = up (in pixels). CoreGraphics treats a
/// positive wheel value as scroll-up, so we negate.
pub fn scroll(dy: f64) {
    unsafe {
        let ev = CGEventCreateScrollWheelEvent(std::ptr::null(), SCROLL_UNIT_PIXEL, 1, -(dy as i32));
        if !ev.is_null() {
            CGEventPost(HID_EVENT_TAP, ev);
            CFRelease(ev);
        }
    }
}

/// Type a unicode string into the focused element via synthesized key events.
pub fn type_text(text: &str) {
    unsafe {
        for ch in text.chars() {
            let utf16: Vec<u16> = ch.to_string().encode_utf16().collect();
            let down = CGEventCreateKeyboardEvent(std::ptr::null(), 0, true);
            if !down.is_null() {
                CGEventKeyboardSetUnicodeString(down, utf16.len(), utf16.as_ptr());
                CGEventPost(HID_EVENT_TAP, down);
                CFRelease(down);
            }
            let up = CGEventCreateKeyboardEvent(std::ptr::null(), 0, false);
            if !up.is_null() {
                CGEventKeyboardSetUnicodeString(up, utf16.len(), utf16.as_ptr());
                CGEventPost(HID_EVENT_TAP, up);
                CFRelease(up);
            }
        }
    }
}

/// A small set of named keys the agent can press (with optional cmd/shift).
fn keycode_for(key: &str) -> Option<u16> {
    Some(match key.to_lowercase().as_str() {
        "return" | "enter" => 36,
        "tab" => 48,
        "space" => 49,
        "delete" | "backspace" => 51,
        "escape" | "esc" => 53,
        "left" => 123,
        "right" => 124,
        "down" => 125,
        "up" => 126,
        "s" => 1,
        "c" => 8,
        "v" => 9,
        "a" => 0,
        "t" => 17,
        "n" => 45,
        "f" => 3,
        _ => return None,
    })
}

/// Press a key, optionally with command/shift modifiers (e.g. "cmd+s").
pub fn press_key(combo: &str) {
    let lower = combo.to_lowercase();
    let mut flags = 0u64;
    if lower.contains("cmd") || lower.contains("command") || lower.contains("meta") {
        flags |= FLAG_COMMAND;
    }
    if lower.contains("shift") {
        flags |= FLAG_SHIFT;
    }
    let key = lower.rsplit('+').next().unwrap_or(&lower).trim();
    let Some(code) = keycode_for(key) else { return };
    unsafe {
        let down = CGEventCreateKeyboardEvent(std::ptr::null(), code, true);
        if !down.is_null() {
            if flags != 0 {
                CGEventSetFlags(down, flags);
            }
            CGEventPost(HID_EVENT_TAP, down);
            CFRelease(down);
        }
        let up = CGEventCreateKeyboardEvent(std::ptr::null(), code, false);
        if !up.is_null() {
            if flags != 0 {
                CGEventSetFlags(up, flags);
            }
            CGEventPost(HID_EVENT_TAP, up);
            CFRelease(up);
        }
    }
}

/// Launch (or focus) an application by name, e.g. "Notes", "Safari".
pub fn open_app(name: &str) {
    let _ = std::process::Command::new("open").arg("-a").arg(name).spawn();
}
