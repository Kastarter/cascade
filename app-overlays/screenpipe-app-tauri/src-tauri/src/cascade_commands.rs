// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

//! Cascade-specific Tauri commands.
//!
//! The single non-trivial command here is `cascade_set_anthropic_key`:
//!   1. write the API key to macOS Keychain (service `com.cascade.app`)
//!   2. mirror it into `~/.pi/agent/auth.json` so the pi agent (which is what
//!      runs our Cascade pipe) picks it up on next start
//!
//! Re-using `screenpipe_secrets::keychain` rather than the `keyring` crate — see
//! that crate's comment about ACL stability across app updates.
//!
//! Other commands forward to `cascade_schema` so the M6 sidecar tables are
//! reachable from the UI for manual tagging dogfood.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::fs;
use tauri::Manager;

const CASCADE_KEYCHAIN_SERVICE: &str = "com.cascade.app";
const ANTHROPIC_KEY_NAME: &str = "anthropic-api-key";

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CascadeKeyStatus {
    pub has_anthropic_key: bool,
}

fn pi_config_dir() -> std::io::Result<PathBuf> {
    let home = dirs::home_dir().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::NotFound, "home dir not found")
    })?;
    let dir = home.join(".pi").join("agent");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// Write the user's Anthropic API key to Keychain + mirror to ~/.pi/agent/auth.json.
///
/// The pi agent reads providers from auth.json on startup. We keep Keychain
/// as source of truth; auth.json is rewritten at runtime so an uninstall or
/// `cascade_clear_anthropic_key` leaves no orphan key on disk.
#[tauri::command]
#[specta::specta]
pub async fn cascade_set_anthropic_key(key: String) -> Result<(), String> {
    if !key.starts_with("sk-ant-") {
        return Err("invalid Anthropic key format".into());
    }

    // 1) Keychain via macOS `security` CLI. The screenpipe-secrets keychain helpers
    //    are designed for a 32-byte encryption key, not arbitrary strings, so we
    //    call `security` directly here.
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("security")
            .args([
                "add-generic-password",
                "-a", ANTHROPIC_KEY_NAME,
                "-s", CASCADE_KEYCHAIN_SERVICE,
                "-w", &key,
                "-U", // update if exists
            ])
            .output()
            .map_err(|e| format!("keychain write failed: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "keychain write failed: {}",
                String::from_utf8_lossy(&out.stderr)
            ));
        }
    }

    // 2) Mirror into ~/.pi/agent/auth.json. We merge rather than overwrite so
    //    we don't clobber other providers the user has set up via pi directly.
    let cfg = pi_config_dir().map_err(|e| e.to_string())?;
    let auth_path = cfg.join("auth.json");

    let mut auth: serde_json::Value = if auth_path.exists() {
        let s = fs::read_to_string(&auth_path).map_err(|e| e.to_string())?;
        serde_json::from_str(&s).unwrap_or_else(|_| serde_json::json!({}))
    } else {
        serde_json::json!({})
    };

    let providers = auth
        .as_object_mut()
        .and_then(|o| o.entry("providers").or_insert_with(|| serde_json::json!({})).as_object_mut())
        .ok_or_else(|| "failed to mutate auth.json".to_string())?;

    providers.insert(
        "anthropic-byok".to_string(),
        serde_json::json!({ "apiKey": key }),
    );

    let s = serde_json::to_string_pretty(&auth).map_err(|e| e.to_string())?;
    fs::write(&auth_path, s).map_err(|e| e.to_string())?;

    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_key_status() -> Result<CascadeKeyStatus, String> {
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("security")
            .args([
                "find-generic-password",
                "-a", ANTHROPIC_KEY_NAME,
                "-s", CASCADE_KEYCHAIN_SERVICE,
            ])
            .output()
            .map_err(|e| format!("keychain probe failed: {e}"))?;
        return Ok(CascadeKeyStatus { has_anthropic_key: out.status.success() });
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(CascadeKeyStatus { has_anthropic_key: false })
    }
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_clear_anthropic_key() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("security")
            .args([
                "delete-generic-password",
                "-a", ANTHROPIC_KEY_NAME,
                "-s", CASCADE_KEYCHAIN_SERVICE,
            ])
            .output();
    }

    if let Ok(cfg) = pi_config_dir() {
        let auth_path = cfg.join("auth.json");
        if auth_path.exists() {
            if let Ok(s) = fs::read_to_string(&auth_path) {
                if let Ok(mut auth) = serde_json::from_str::<serde_json::Value>(&s) {
                    if let Some(providers) = auth.get_mut("providers").and_then(|v| v.as_object_mut()) {
                        providers.remove("anthropic-byok");
                    }
                    if let Ok(s) = serde_json::to_string_pretty(&auth) {
                        let _ = fs::write(&auth_path, s);
                    }
                }
            }
        }
    }
    Ok(())
}

/// Tag a frame manually. Forward-compat hook for Layer 2's classifier (M6).
#[tauri::command]
#[specta::specta]
pub async fn cascade_tag_event(
    _app: tauri::AppHandle,
    frame_id: i64,
    tag: String,
) -> Result<i64, String> {
    // Wire-up to cascade_schema::tag_event happens once the schema crate is
    // added as a dependency of the Tauri app via patch 0003. For now this is
    // a stub that returns the frame_id so the overlay component can render
    // optimistically; replace with real DB call in M6.
    tracing::info!("cascade_tag_event(frame_id={frame_id}, tag={tag}) — stub");
    Ok(frame_id)
}

pub fn register<R: tauri::Runtime>(builder: tauri::Builder<R>) -> tauri::Builder<R> {
    builder.invoke_handler(tauri::generate_handler![
        cascade_set_anthropic_key,
        cascade_key_status,
        cascade_clear_anthropic_key,
        cascade_tag_event,
    ])
}
