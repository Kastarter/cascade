// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
//! Shared Anthropic client for the Layer 2 server-side agents (#2 Waste
//! Detector, #3 Agent Generator, #4 Deployment Monitor).
//!
//! Agent #1 (Reel Q&A) runs through the `pi` subprocess; these batch/on-demand
//! agents are simpler as a direct Messages API call from Rust. The user's key
//! is read from the same Keychain entry the BYOK flow writes
//! (`cascade_set_anthropic_key`).

use serde::de::DeserializeOwned;
use serde::Deserialize;
use std::time::Duration;

const CASCADE_KEYCHAIN_SERVICE: &str = "com.cascade.app";
const ANTHROPIC_KEY_NAME: &str = "anthropic-api-key";
const ANTHROPIC_URL: &str = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION: &str = "2023-06-01";

/// Model IDs pinned to match `lib/cascade-defaults.ts` so server agents and the
/// Reel chat never drift apart.
pub const MODEL_OPUS: &str = "claude-opus-4-7";
pub const MODEL_SONNET: &str = "claude-sonnet-4-6";

/// A single non-streaming completion request.
pub struct LlmCall {
    pub model: &'static str,
    pub system: String,
    pub user: String,
    pub temperature: f32,
    pub max_tokens: u32,
}

#[derive(Debug, Clone)]
pub struct LlmResult {
    pub text: String,
    pub input_tokens: u32,
    pub output_tokens: u32,
    pub cost_usd: f64,
}

#[derive(Debug, Deserialize)]
struct AnthropicResponse {
    content: Vec<AnthropicContentBlock>,
    #[serde(default)]
    usage: AnthropicUsage,
}

#[derive(Debug, Deserialize)]
struct AnthropicContentBlock {
    #[serde(rename = "type")]
    block_type: String,
    #[serde(default)]
    text: String,
}

#[derive(Debug, Default, Deserialize)]
struct AnthropicUsage {
    #[serde(default)]
    input_tokens: u32,
    #[serde(default)]
    output_tokens: u32,
}

/// Rough public list pricing, USD per 1M tokens. Used only for KPI/budget
/// estimates — not billing.
fn price_per_mtok(model: &str) -> (f64, f64) {
    if model.contains("opus") {
        (15.0, 75.0)
    } else if model.contains("sonnet") {
        (3.0, 15.0)
    } else {
        (1.0, 5.0)
    }
}

fn cost_for(model: &str, input_tokens: u32, output_tokens: u32) -> f64 {
    let (pin, pout) = price_per_mtok(model);
    (input_tokens as f64 / 1_000_000.0) * pin + (output_tokens as f64 / 1_000_000.0) * pout
}

/// Read the BYOK Anthropic key from the macOS Keychain. Returns a friendly
/// error the UI can surface ("add your key in Settings") rather than panicking.
pub fn read_anthropic_key() -> Result<String, String> {
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
        if !out.status.success() {
            return Err(
                "no Anthropic API key found — add one in Cascade settings before running agents"
                    .to_string(),
            );
        }
        let key = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if key.is_empty() {
            return Err("Anthropic API key is empty".to_string());
        }
        Ok(key)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err("Anthropic key storage is only implemented on macOS".to_string())
    }
}

/// Call the Messages API once and return the concatenated text + usage.
pub async fn call_anthropic(call: &LlmCall) -> Result<LlmResult, String> {
    let key = read_anthropic_key()?;
    let client = reqwest::Client::new();

    // NOTE: `temperature` is intentionally NOT sent — newer Claude models reject
    // it ("temperature is deprecated for this model" → 400). The field is kept on
    // LlmCall for callers' intent but not transmitted.
    let _ = call.temperature;
    let body = serde_json::json!({
        "model": call.model,
        "max_tokens": call.max_tokens,
        "system": call.system,
        "messages": [{ "role": "user", "content": call.user }],
    });

    let response = client
        .post(ANTHROPIC_URL)
        .header("x-api-key", key)
        .header("anthropic-version", ANTHROPIC_VERSION)
        .header("content-type", "application/json")
        .timeout(Duration::from_secs(90))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("anthropic request failed: {e}"))?;

    let status = response.status();
    if !status.is_success() {
        let detail = response.text().await.unwrap_or_default();
        let detail = detail.chars().take(400).collect::<String>();
        return Err(format!("anthropic returned {status}: {detail}"));
    }

    let parsed = response
        .json::<AnthropicResponse>()
        .await
        .map_err(|e| format!("parse anthropic response: {e}"))?;

    let text = parsed
        .content
        .iter()
        .filter(|b| b.block_type == "text")
        .map(|b| b.text.as_str())
        .collect::<Vec<_>>()
        .join("");

    if text.trim().is_empty() {
        return Err("anthropic returned no text content".to_string());
    }

    Ok(LlmResult {
        cost_usd: cost_for(call.model, parsed.usage.input_tokens, parsed.usage.output_tokens),
        input_tokens: parsed.usage.input_tokens,
        output_tokens: parsed.usage.output_tokens,
        text,
    })
}

/// Vision call: send a screenshot (base64 PNG) plus instructions, return text.
/// Used by the computer-use agent to decide its next action from the screen.
pub async fn call_anthropic_vision(
    model: &str,
    system: &str,
    user_text: &str,
    image_png_base64: &str,
    temperature: f32,
    max_tokens: u32,
) -> Result<LlmResult, String> {
    let key = read_anthropic_key()?;
    let client = reqwest::Client::new();

    // `temperature` not sent (deprecated / rejected by newer models).
    let _ = temperature;
    let body = serde_json::json!({
        "model": model,
        "max_tokens": max_tokens,
        "system": system,
        "messages": [{
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/png",
                        "data": image_png_base64,
                    }
                },
                { "type": "text", "text": user_text }
            ]
        }],
    });

    let response = client
        .post(ANTHROPIC_URL)
        .header("x-api-key", key)
        .header("anthropic-version", ANTHROPIC_VERSION)
        .header("content-type", "application/json")
        .timeout(Duration::from_secs(90))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("anthropic vision request failed: {e}"))?;

    let status = response.status();
    if !status.is_success() {
        let detail = response.text().await.unwrap_or_default();
        return Err(format!(
            "anthropic vision returned {status}: {}",
            detail.chars().take(400).collect::<String>()
        ));
    }

    let parsed = response
        .json::<AnthropicResponse>()
        .await
        .map_err(|e| format!("parse vision response: {e}"))?;
    let text = parsed
        .content
        .iter()
        .filter(|b| b.block_type == "text")
        .map(|b| b.text.as_str())
        .collect::<Vec<_>>()
        .join("");
    Ok(LlmResult {
        cost_usd: cost_for(model, parsed.usage.input_tokens, parsed.usage.output_tokens),
        input_tokens: parsed.usage.input_tokens,
        output_tokens: parsed.usage.output_tokens,
        text,
    })
}

/// Pull the first balanced JSON object out of a model response, tolerating
/// ```json fences and leading/trailing prose.
pub fn extract_json_str(text: &str) -> Result<String, String> {
    let trimmed = text.trim();

    // Strip a fenced block if present.
    let candidate = if let Some(start) = trimmed.find("```") {
        let after = &trimmed[start + 3..];
        let after = after.strip_prefix("json").unwrap_or(after);
        let after = after.trim_start_matches(|c| c == '\n' || c == '\r');
        match after.find("```") {
            Some(end) => &after[..end],
            None => after,
        }
    } else {
        trimmed
    };

    // Find the first balanced {...}, respecting string literals.
    let bytes = candidate.as_bytes();
    let start = candidate.find('{').ok_or("no JSON object in response")?;
    let mut depth = 0i32;
    let mut in_str = false;
    let mut escaped = false;
    for i in start..bytes.len() {
        let c = bytes[i] as char;
        if in_str {
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_str = false;
            }
            continue;
        }
        match c {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Ok(candidate[start..=i].to_string());
                }
            }
            _ => {}
        }
    }
    Err("unbalanced JSON object in response".to_string())
}

/// Call the model and deserialize its JSON output into `T`. Returns the parsed
/// value alongside the raw result (for cost/token accounting).
pub async fn call_anthropic_json<T: DeserializeOwned>(
    call: &LlmCall,
) -> Result<(T, LlmResult), String> {
    let result = call_anthropic(call).await?;
    let json_str = extract_json_str(&result.text)?;
    let value = serde_json::from_str::<T>(&json_str)
        .map_err(|e| format!("model JSON did not match expected shape: {e}"))?;
    Ok((value, result))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_fenced_json() {
        let raw = "Here you go:\n```json\n{\"a\": 1, \"b\": \"}\"}\n```\nThanks!";
        let out = extract_json_str(raw).unwrap();
        assert_eq!(out, "{\"a\": 1, \"b\": \"}\"}");
    }

    #[test]
    fn extracts_bare_json_with_nesting() {
        let raw = "{\"x\": {\"y\": [1,2,3]}, \"z\": \"a{b}c\"}";
        let out = extract_json_str(raw).unwrap();
        assert_eq!(out, raw);
    }

    #[test]
    fn errors_without_object() {
        assert!(extract_json_str("no json here").is_err());
    }

    #[test]
    fn cost_is_positive() {
        assert!(cost_for(MODEL_OPUS, 1000, 1000) > cost_for(MODEL_SONNET, 1000, 1000));
    }
}
