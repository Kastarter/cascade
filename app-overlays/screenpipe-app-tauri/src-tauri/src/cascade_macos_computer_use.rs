//! Rust wrapper for Cascade's native macOS ComputerUseKit.
//!
//! The Swift side owns real-screen capture and input routing through a small C
//! ABI. This module keeps that boundary narrow: callers pass/receive JSON, and
//! Rust handles C string ownership, envelope parsing, and platform fallback.

use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[cfg(not(target_os = "macos"))]
const UNSUPPORTED_ERROR: &str = "ComputerUseKit is only supported on macOS";

#[cfg(all(target_os = "macos", not(test)))]
mod ffi {
    use std::os::raw::c_char;

    extern "C" {
        pub fn cu_status_json() -> *mut c_char;
        pub fn cu_observe_json(config_json: *const c_char) -> *mut c_char;
        pub fn cu_act_json(action_json: *const c_char) -> *mut c_char;
        pub fn cu_free_string(ptr: *mut c_char);
    }
}

#[cfg(all(target_os = "macos", test))]
mod ffi {
    use once_cell::sync::Lazy;
    use std::ffi::CString;
    use std::os::raw::c_char;
    use std::sync::Mutex;

    static STATUS_RESPONSE: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
    static OBSERVE_RESPONSE: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
    static ACT_RESPONSE: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

    pub(super) fn set_status_response(json: &str) {
        *STATUS_RESPONSE.lock().expect("status response lock") = Some(json.to_string());
    }

    pub(super) fn set_observe_response(json: &str) {
        *OBSERVE_RESPONSE.lock().expect("observe response lock") = Some(json.to_string());
    }

    pub(super) fn set_act_response(json: &str) {
        *ACT_RESPONSE.lock().expect("act response lock") = Some(json.to_string());
    }

    pub unsafe fn cu_status_json() -> *mut c_char {
        response_ptr(
            &STATUS_RESPONSE,
            r#"{"ok":false,"error":"test status response unset"}"#,
        )
    }

    pub unsafe fn cu_observe_json(_config_json: *const c_char) -> *mut c_char {
        response_ptr(
            &OBSERVE_RESPONSE,
            r#"{"ok":false,"error":"test observe response unset"}"#,
        )
    }

    pub unsafe fn cu_act_json(_action_json: *const c_char) -> *mut c_char {
        response_ptr(
            &ACT_RESPONSE,
            r#"{"ok":false,"error":"test act response unset"}"#,
        )
    }

    pub unsafe fn cu_free_string(ptr: *mut c_char) {
        if !ptr.is_null() {
            let _ = CString::from_raw(ptr);
        }
    }

    fn response_ptr(slot: &Mutex<Option<String>>, fallback: &str) -> *mut c_char {
        let body = slot
            .lock()
            .expect("test response lock")
            .take()
            .unwrap_or_else(|| fallback.to_string());
        CString::new(body)
            .expect("test response should not contain nul bytes")
            .into_raw()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct ComputerUseStatus {
    pub available: Option<bool>,
    pub screen_recording_granted: bool,
    pub accessibility_granted: bool,
    pub input_monitoring_likely_granted: Option<bool>,
    pub screen_capture_available: bool,
    pub bridge_available: Option<bool>,
    pub healthy: Option<bool>,
    pub active_app_name: Option<String>,
    pub active_bundle_id: Option<String>,
    pub visible_window_count: Option<usize>,
    pub focused_window: Option<ComputerUseWindow>,
    pub windows: Vec<ComputerUseWindow>,
    pub missing: Vec<String>,
    pub metadata: Value,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct ComputerUseObserveConfig {
    pub mode: String,
    pub max_dimension: u32,
    pub jpeg_quality: f64,
    pub exclude_own_windows: bool,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl Default for ComputerUseObserveConfig {
    fn default() -> Self {
        Self {
            mode: "cursorScreen".to_string(),
            max_dimension: 1280,
            jpeg_quality: 0.82,
            exclude_own_windows: true,
            extra: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct ComputerUseObservation {
    pub image_base64: String,
    pub image_mime_type: String,
    pub logical_width: f64,
    pub logical_height: f64,
    pub screenshot_width: Option<f64>,
    pub screenshot_height: Option<f64>,
    pub display_scale: Option<f64>,
    pub display_frame: Option<ComputerUseRect>,
    pub cursor: Option<ComputerUsePoint>,
    pub active_app_name: Option<String>,
    pub active_bundle_id: Option<String>,
    pub active_window_title: Option<String>,
    pub focused_window: Option<ComputerUseWindow>,
    pub windows: Vec<ComputerUseWindow>,
    pub capture_timestamp_ms: Option<i64>,
    pub metadata: Value,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl ComputerUseObservation {
    pub fn effective_image_mime_type(&self) -> &str {
        if self.image_mime_type.trim().is_empty() {
            "image/png"
        } else {
            self.image_mime_type.as_str()
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct ComputerUseActionResult {
    pub success: bool,
    pub action: Option<String>,
    pub message: Option<String>,
    pub metadata: Value,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl Default for ComputerUseActionResult {
    fn default() -> Self {
        Self {
            success: false,
            action: None,
            message: None,
            metadata: Value::Null,
            extra: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct ComputerUseWindow {
    #[serde(alias = "windowID", alias = "windowId", alias = "id")]
    pub window_id: Option<u64>,
    pub title: Option<String>,
    pub app_name: Option<String>,
    pub bundle_id: Option<String>,
    #[serde(alias = "owner")]
    pub owner_name: Option<String>,
    #[serde(alias = "ownerPID", alias = "ownerPid")]
    pub owner_pid: Option<i64>,
    #[serde(alias = "pid")]
    pub process_id: Option<i64>,
    #[serde(alias = "bounds")]
    pub frame: Option<ComputerUseRect>,
    pub is_focused: Option<bool>,
    pub is_on_screen: Option<bool>,
    pub layer: Option<i64>,
    pub alpha: Option<f64>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct ComputerUseRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct ComputerUsePoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ComputerUseEnvelope {
    ok: Option<bool>,
    error: Option<String>,
    message: Option<String>,
    data: Option<Value>,
}

pub fn status() -> Result<ComputerUseStatus, String> {
    let raw = call_status_raw()?;
    parse_envelope(&raw, "status")
}

pub fn observe(config: &ComputerUseObserveConfig) -> Result<ComputerUseObservation, String> {
    let config_json =
        serde_json::to_string(config).map_err(|e| format!("serialize observe config: {e}"))?;
    observe_json(&config_json)
}

pub fn observe_json(config_json: &str) -> Result<ComputerUseObservation, String> {
    let raw = call_observe_raw(config_json)?;
    let observation: ComputerUseObservation = parse_envelope(&raw, "observe")?;
    if observation.image_base64.trim().is_empty() {
        return Err("ComputerUseKit observe returned no imageBase64".to_string());
    }
    Ok(observation)
}

pub fn act(action: &Value) -> Result<ComputerUseActionResult, String> {
    let action_json =
        serde_json::to_string(action).map_err(|e| format!("serialize action request: {e}"))?;
    act_json(&action_json)
}

pub fn act_json(action_json: &str) -> Result<ComputerUseActionResult, String> {
    let raw = call_act_raw(action_json)?;
    parse_action_result(&raw)
}

fn parse_envelope<T>(raw: &str, operation: &str) -> Result<T, String>
where
    T: DeserializeOwned,
{
    let value: Value =
        serde_json::from_str(raw).map_err(|e| format!("parse ComputerUseKit {operation}: {e}"))?;
    parse_envelope_value(value, operation)
}

fn parse_envelope_value<T>(value: Value, operation: &str) -> Result<T, String>
where
    T: DeserializeOwned,
{
    let envelope: ComputerUseEnvelope = serde_json::from_value(value.clone())
        .map_err(|e| format!("parse ComputerUseKit {operation} envelope: {e}"))?;

    if envelope.ok == Some(false) {
        return Err(envelope
            .error
            .or(envelope.message)
            .unwrap_or_else(|| format!("ComputerUseKit {operation} failed")));
    }

    let data = envelope.data.unwrap_or(value);
    serde_json::from_value(data).map_err(|e| format!("parse ComputerUseKit {operation} data: {e}"))
}

fn parse_action_result(raw: &str) -> Result<ComputerUseActionResult, String> {
    let value: Value =
        serde_json::from_str(raw).map_err(|e| format!("parse ComputerUseKit action: {e}"))?;
    let envelope: ComputerUseEnvelope = serde_json::from_value(value.clone())
        .map_err(|e| format!("parse ComputerUseKit action envelope: {e}"))?;

    if envelope.ok == Some(false) {
        return Err(envelope
            .error
            .or(envelope.message)
            .unwrap_or_else(|| "ComputerUseKit action failed".to_string()));
    }

    let ok = envelope.ok;
    let data = envelope.data.unwrap_or(value);
    let success_was_explicit = data.get("success").is_some();
    let mut result: ComputerUseActionResult = serde_json::from_value(data)
        .map_err(|e| format!("parse ComputerUseKit action data: {e}"))?;
    if ok == Some(true) && !success_was_explicit {
        result.success = true;
    }
    Ok(result)
}

#[cfg(not(target_os = "macos"))]
fn unsupported(operation: &str) -> String {
    format!("{UNSUPPORTED_ERROR}: {operation}")
}

#[cfg(target_os = "macos")]
fn call_status_raw() -> Result<String, String> {
    unsafe { take_swift_string(ffi::cu_status_json(), "status") }
}

#[cfg(not(target_os = "macos"))]
fn call_status_raw() -> Result<String, String> {
    Err(unsupported("status"))
}

#[cfg(target_os = "macos")]
fn call_observe_raw(config_json: &str) -> Result<String, String> {
    let config = cstring_arg(config_json, "observe config")?;
    unsafe { take_swift_string(ffi::cu_observe_json(config.as_ptr()), "observe") }
}

#[cfg(not(target_os = "macos"))]
fn call_observe_raw(_config_json: &str) -> Result<String, String> {
    Err(unsupported("observe"))
}

#[cfg(target_os = "macos")]
fn call_act_raw(action_json: &str) -> Result<String, String> {
    let action = cstring_arg(action_json, "action request")?;
    unsafe { take_swift_string(ffi::cu_act_json(action.as_ptr()), "action") }
}

#[cfg(not(target_os = "macos"))]
fn call_act_raw(_action_json: &str) -> Result<String, String> {
    Err(unsupported("action"))
}

#[cfg(target_os = "macos")]
fn cstring_arg(value: &str, label: &str) -> Result<CString, String> {
    CString::new(value).map_err(|_| format!("ComputerUseKit {label} contains a nul byte"))
}

#[cfg(target_os = "macos")]
unsafe fn take_swift_string(ptr: *mut c_char, operation: &str) -> Result<String, String> {
    if ptr.is_null() {
        return Err(format!(
            "ComputerUseKit {operation} returned a null pointer"
        ));
    }

    let body = CStr::from_ptr(ptr).to_string_lossy().into_owned();
    ffi::cu_free_string(ptr);

    if body.trim().is_empty() {
        return Err(format!(
            "ComputerUseKit {operation} returned an empty response"
        ));
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_status_envelope() {
        let raw = r#"{
            "ok": true,
            "data": {
                "screenRecordingGranted": true,
                "accessibilityGranted": true,
                "inputMonitoringLikelyGranted": false,
                "screenCaptureAvailable": true,
                "activeAppName": "Notes",
                "activeBundleId": "com.apple.Notes",
                "visibleWindowCount": 3,
                "missing": ["Input Monitoring"],
                "focusedWindow": {
                    "windowId": 42,
                    "title": "Daily note",
                    "appName": "Notes",
                    "frame": {"x": 10, "y": 20, "width": 800, "height": 600}
                }
            }
        }"#;

        let status: ComputerUseStatus = parse_envelope(raw, "status").expect("status parses");

        assert!(status.screen_recording_granted);
        assert_eq!(status.active_app_name.as_deref(), Some("Notes"));
        assert_eq!(
            status.focused_window.as_ref().and_then(|w| w.window_id),
            Some(42)
        );
        assert_eq!(status.missing, vec!["Input Monitoring"]);
    }

    #[test]
    fn parses_observation_envelope_and_defaults_mime_type() {
        let raw = r#"{
            "ok": true,
            "data": {
                "imageBase64": "abc123",
                "logicalWidth": 1440,
                "logicalHeight": 900,
                "screenshotWidth": 2880,
                "screenshotHeight": 1800,
                "displayScale": 2,
                "captureTimestampMs": 1710000000000,
                "windows": [{
                    "windowID": 7,
                    "ownerName": "Safari",
                    "bundleId": "com.apple.Safari"
                }]
            }
        }"#;

        let observation: ComputerUseObservation =
            parse_envelope(raw, "observe").expect("observation parses");

        assert_eq!(observation.image_base64, "abc123");
        assert_eq!(observation.effective_image_mime_type(), "image/png");
        assert_eq!(observation.display_scale, Some(2.0));
        assert_eq!(observation.windows[0].window_id, Some(7));
    }

    #[test]
    fn failed_envelope_returns_swift_error() {
        let err = parse_envelope::<ComputerUseStatus>(
            r#"{"ok":false,"error":"Screen Recording permission missing"}"#,
            "status",
        )
        .expect_err("failed envelope should become error");

        assert_eq!(err, "Screen Recording permission missing");
    }

    #[test]
    fn direct_data_without_envelope_still_parses() {
        let status: ComputerUseStatus = parse_envelope(
            r#"{"screenRecordingGranted":true,"screenCaptureAvailable":true}"#,
            "status",
        )
        .expect("direct status parses");

        assert!(status.screen_recording_granted);
        assert!(status.screen_capture_available);
    }

    #[test]
    fn action_success_inherits_ok_when_success_field_missing() {
        let result = parse_action_result(r#"{"ok":true,"data":{"action":"click"}}"#)
            .expect("action result parses");

        assert!(result.success);
        assert_eq!(result.action.as_deref(), Some("click"));
    }

    #[test]
    fn action_success_respects_explicit_false() {
        let result = parse_action_result(
            r#"{"ok":true,"data":{"success":false,"action":"click","message":"unclear"}}"#,
        )
        .expect("action result parses");

        assert!(!result.success);
        assert_eq!(result.message.as_deref(), Some("unclear"));
    }

    #[test]
    fn observe_config_defaults_match_swift_contract() {
        let config = ComputerUseObserveConfig::default();
        let value = serde_json::to_value(config).expect("serialize config");

        assert_eq!(value["mode"], "cursorScreen");
        assert_eq!(value["maxDimension"], 1280);
        assert_eq!(value["jpegQuality"], json!(0.82));
        assert_eq!(value["excludeOwnWindows"], true);
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn unsupported_status_is_graceful_off_macos() {
        let err = status().expect_err("non-macOS status should not call Swift");
        assert!(err.contains("only supported on macOS"));
        assert!(err.contains("status"));
    }

    #[cfg(all(target_os = "macos", test))]
    #[test]
    fn macos_test_shim_exercises_c_string_ownership_without_swift_library() {
        ffi::set_status_response(r#"{"ok":true,"data":{"screenRecordingGranted":true}}"#);

        let status = status().expect("shim status parses");

        assert!(status.screen_recording_granted);
    }

    #[cfg(all(target_os = "macos", test))]
    #[test]
    fn macos_test_shim_observe_and_act_do_not_need_swift_library() {
        ffi::set_observe_response(
            r#"{"ok":true,"data":{"imageBase64":"abc","imageMimeType":"image/jpeg"}}"#,
        );
        ffi::set_act_response(r#"{"ok":true,"data":{"success":true,"action":"click"}}"#);

        let observation = observe(&ComputerUseObserveConfig::default()).expect("observe parses");
        let result = act(&json!({"type":"click","x":10,"y":20})).expect("act parses");

        assert_eq!(observation.effective_image_mime_type(), "image/jpeg");
        assert!(result.success);
    }
}
