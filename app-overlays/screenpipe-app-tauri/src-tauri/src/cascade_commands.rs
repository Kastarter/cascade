// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

//! Cascade-specific Tauri commands.
//!
//! This module owns the BYOK Anthropic key surface + manual frame tagging.
//! The Layer 2 agents (#2 detector, #3 generator, #4 monitor, #5 aggregator)
//! live in `cascade_agents.rs`.

use crate::cascade_llm::{call_anthropic, LlmCall, MODEL_SONNET};
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

#[derive(Debug, Deserialize, Type)]
#[serde(rename_all = "snake_case")]
pub struct CascadeReelFrameInput {
    pub timestamp: Option<String>,
    pub app_name: Option<String>,
    pub window_name: Option<String>,
    pub text: Option<String>,
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

fn reel_system_prompt() -> String {
    r#"You are Cascade. You have read-only access to one moment of the user's recorded workday (provided in MOMENT METADATA + OCR TEXT below). Your job is to answer the user's exact question briefly, with cited evidence.

HARD RULES - NEVER VIOLATE:
1. Never fabricate timestamps, app names, file names, or quotes. If the provided context doesn't contain enough information, say so plainly.
2. No psychological judgments. Forbidden phrasings: "you seemed unfocused", "you wasted time", "you were distracted", "you should have", "you procrastinated". Describe data, not the user.
3. Retrospective only - never generative. Refuse to write emails, draft replies, compose messages, or take forward-looking actions. If asked, redirect: "I only answer about what you've already done."
4. No fishing. Refuse questions about other people's screens or anything not derivable from this moment.
5. No PII echoing. If OCR text contains anything that looks like a password, API key, credit card, or token, do not include it. Say "[sensitive content detected, hidden]" if relevant.

ANSWER SHAPE - BE BRIEF BUT COMPLETE:
- Lead with the direct answer in ONE sentence. No preamble. No "Let me", "I'll", "Based on", "Looking at", "Sure".
- Then AT MOST 2 short bullets of the key supporting facts (only if they add real info). Each <= 1 line.
- HARD CAP: 4 lines total. Be terse - pack the information densely, cut every filler word. Never pad.
- Cite inline only when it matters: (HH:MMam/pm, App detail). Don't cite every line.
- Don't end with "Want me to dig deeper?" or "Anything else?".
- Never use markdown bold (**...**). Plain text only.

REFUSALS:
- Zero evidence: "I don't see evidence of that in this moment."
- Out of scope: "I only have what was on your screen at this captured moment."
- Generative request: "I only answer about what you've already done - I don't compose or send.""#.to_string()
}

fn redact_pii(text: &str) -> String {
    let mut out = text.to_string();
    let patterns = [
        (r"sk-ant-[A-Za-z0-9_-]{20,}", "[REDACTED_API_KEY]"),
        (r"sk-[A-Za-z0-9_-]{20,}", "[REDACTED_API_KEY]"),
        (r"gh[opsu]_[A-Za-z0-9]{36,}", "[REDACTED_GH_TOKEN]"),
        (r"AKIA[0-9A-Z]{16}", "[REDACTED_AWS_KEY]"),
        (
            r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}",
            "[REDACTED_JWT]",
        ),
        (r"(?i)Bearer\s+[A-Za-z0-9_.-]{20,}", "Bearer [REDACTED]"),
        (
            r"(?i)(password|passwd|pwd|secret)\s*[:=]\s*\S+",
            "$1: [REDACTED]",
        ),
    ];

    for (pattern, replacement) in patterns {
        if let Ok(re) = regex::Regex::new(pattern) {
            out = re.replace_all(&out, replacement).into_owned();
        }
    }

    if let Ok(re) = regex::Regex::new(r"\b(?:\d[ -]?){13,19}\b") {
        out = re
            .replace_all(&out, |caps: &regex::Captures| {
                let raw = caps.get(0).map(|m| m.as_str()).unwrap_or_default();
                let digits = raw.chars().filter(|c| c.is_ascii_digit()).count();
                if (13..=19).contains(&digits) {
                    "[REDACTED_CARD]".to_string()
                } else {
                    raw.to_string()
                }
            })
            .into_owned();
    }

    out
}

fn reel_context(frame: Option<CascadeReelFrameInput>) -> String {
    let Some(frame) = frame else {
        return "(no specific frame is selected - answer from general knowledge of recording behavior, or ask the user to scrub to a moment)".to_string();
    };

    let safe_text = redact_pii(&frame.text.unwrap_or_default())
        .chars()
        .take(4_000)
        .collect::<String>();

    format!(
        "MOMENT METADATA\n- timestamp: {}\n- app: {}\n- window: {}\n\nOCR TEXT (verbatim from screen, may contain noise):\n\"\"\"\n{}\n\"\"\"",
        frame.timestamp.unwrap_or_else(|| "unknown".to_string()),
        frame.app_name.unwrap_or_else(|| "unknown".to_string()),
        frame.window_name.unwrap_or_else(|| "unknown".to_string()),
        if safe_text.trim().is_empty() { "(no text captured)" } else { safe_text.as_str() }
    )
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_ask_reel_question(
    question: String,
    frame: Option<CascadeReelFrameInput>,
) -> Result<String, String> {
    let question = question.trim();
    if question.is_empty() {
        return Err("question is empty".to_string());
    }

    let call = LlmCall {
        model: MODEL_SONNET,
        system: reel_system_prompt(),
        user: format!("{}\n\nQUESTION: {}", reel_context(frame), question),
        temperature: 0.1,
        max_tokens: 260,
    };

    Ok(call_anthropic(&call).await?.text.trim().to_string())
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
