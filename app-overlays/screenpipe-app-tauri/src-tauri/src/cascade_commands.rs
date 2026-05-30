// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

//! Cascade-specific Tauri commands.
//!
//! This module owns the BYOK Anthropic key surface + manual frame tagging.
//! The Layer 2 agents (#2 detector, #3 generator, #4 monitor, #5 aggregator)
//! live in `cascade_agents.rs`.

use cascade_schema::{tag_event, TagSource};
use serde::{Deserialize, Serialize};
use specta::Type;
use std::fs;
use std::path::PathBuf;

const CASCADE_KEYCHAIN_SERVICE: &str = "com.cascade.app";
const ANTHROPIC_KEY_NAME: &str = "anthropic-api-key";

#[derive(Debug, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CascadeKeyStatus {
    pub has_anthropic_key: bool,
}

fn pi_config_dir() -> std::io::Result<PathBuf> {
    let home = dirs::home_dir()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "home dir not found"))?;
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

    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("security")
            .args([
                "add-generic-password",
                "-a",
                ANTHROPIC_KEY_NAME,
                "-s",
                CASCADE_KEYCHAIN_SERVICE,
                "-w",
                &key,
                "-U",
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
        .and_then(|o| {
            o.entry("providers")
                .or_insert_with(|| serde_json::json!({}))
                .as_object_mut()
        })
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
                "-a",
                ANTHROPIC_KEY_NAME,
                "-s",
                CASCADE_KEYCHAIN_SERVICE,
            ])
            .output()
            .map_err(|e| format!("keychain probe failed: {e}"))?;
        return Ok(CascadeKeyStatus {
            has_anthropic_key: out.status.success(),
        });
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(CascadeKeyStatus {
            has_anthropic_key: false,
        })
    }
}

/// Return the saved Anthropic key from the Keychain, so the in-browser Reel
/// Q&A chat uses the SAME key the Settings page saved (single source of truth).
/// The key already lives in the JS context for that chat's direct API call, so
/// exposing it here is not a new disclosure.
#[tauri::command]
#[specta::specta]
pub async fn cascade_get_anthropic_key() -> Result<Option<String>, String> {
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("security")
            .args([
                "find-generic-password",
                "-a",
                ANTHROPIC_KEY_NAME,
                "-s",
                CASCADE_KEYCHAIN_SERVICE,
                "-w",
            ])
            .output()
            .map_err(|e| format!("keychain read failed: {e}"))?;
        if out.status.success() {
            let key = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !key.is_empty() {
                return Ok(Some(key));
            }
        }
        return Ok(None);
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(None)
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
                "-a",
                ANTHROPIC_KEY_NAME,
                "-s",
                CASCADE_KEYCHAIN_SERVICE,
            ])
            .output();
    }

    if let Ok(cfg) = pi_config_dir() {
        let auth_path = cfg.join("auth.json");
        if auth_path.exists() {
            if let Ok(s) = fs::read_to_string(&auth_path) {
                if let Ok(mut auth) = serde_json::from_str::<serde_json::Value>(&s) {
                    if let Some(providers) =
                        auth.get_mut("providers").and_then(|v| v.as_object_mut())
                    {
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

/// Tag a frame manually. Forward-compat hook for Layer 2's classifier.
#[tauri::command]
#[specta::specta]
pub async fn cascade_tag_event(
    app: tauri::AppHandle,
    frame_id: i64,
    tag: String,
) -> Result<i64, String> {
    let pool = crate::cascade_agents::cascade_pool(&app).await?;
    tag_event(&pool, frame_id, &tag, TagSource::Manual, None)
        .await
        .map_err(|e| format!("tag event: {e}"))
}
