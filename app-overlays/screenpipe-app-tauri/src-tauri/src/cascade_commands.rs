// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

//! Cascade-specific Tauri commands.
//!
//! This module owns two product-specific backend surfaces:
//! 1. BYOK Anthropic key management.
//! 2. Waste-detection signals + manager-facing suggestion outbox generation.

use cascade_schema::{
    create_detection_run, insert_manager_suggestion, list_manager_suggestions, migrate, open,
    tag_event, update_manager_suggestion_status, ManagerSuggestionInput, TagSource,
};
use chrono::{Duration, Utc};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use specta::Type;
use std::cmp::Ordering;
use std::fs;
use std::path::PathBuf;

const CASCADE_KEYCHAIN_SERVICE: &str = "com.cascade.app";
const ANTHROPIC_KEY_NAME: &str = "anthropic-api-key";
const MANAGER_OUTBOX_DIR: &str = "cascade-manager-outbox";
const DETECTOR_NAME: &str = "cascade-waste-detector-v1";

const CODING_APPS: &[&str] = &[
    "wezterm",
    "iterm2",
    "terminal",
    "alacritty",
    "kitty",
    "warp",
    "hyper",
    "vscode",
    "visual studio code",
    "code",
    "zed",
    "xcode",
    "intellij idea",
    "webstorm",
    "pycharm",
    "cursor",
    "neovim",
    "vim",
];

const BROWSER_APPS: &[&str] = &[
    "arc",
    "google chrome",
    "chrome",
    "safari",
    "firefox",
    "brave browser",
    "microsoft edge",
    "opera",
];

const MEETING_APPS: &[&str] = &[
    "zoom.us",
    "zoom",
    "microsoft teams",
    "teams",
    "google meet",
    "slack huddle",
    "facetime",
    "webex",
    "discord",
];

const COMMUNICATION_APPS: &[&str] = &[
    "slack",
    "messages",
    "telegram",
    "whatsapp",
    "signal",
    "mail",
    "gmail",
    "outlook",
    "thunderbird",
];

const WRITING_APPS: &[&str] = &[
    "obsidian",
    "notion",
    "notes",
    "bear",
    "ulysses",
    "typora",
    "google docs",
    "microsoft word",
    "pages",
];

#[derive(Debug, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CascadeKeyStatus {
    pub has_anthropic_key: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CascadeManagerEvidence {
    pub label: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CascadeManagerSuggestion {
    pub id: Option<i64>,
    pub kind: String,
    pub title: String,
    pub summary: String,
    pub evidence: Vec<CascadeManagerEvidence>,
    pub suggested_agent_kind: String,
    pub severity_score: f64,
    pub confidence: f64,
    pub status: String,
    pub created_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CascadeManagerSuggestionBatch {
    pub generated_at: String,
    pub window_start: String,
    pub window_end: String,
    pub hours_analyzed: u32,
    pub delivery_mode: String,
    pub outbox_path: String,
    pub suggestions: Vec<CascadeManagerSuggestion>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActivitySummaryResponse {
    apps: Vec<ActivityAppUsage>,
    windows: Vec<ActivityWindow>,
    key_texts: Vec<ActivityKeyText>,
    data_status: String,
    total_frames: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActivityAppUsage {
    name: String,
    frame_count: i64,
    minutes: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActivityWindow {
    app_name: String,
    window_name: String,
    minutes: f64,
    frame_count: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActivityKeyText {
    text: String,
    app_name: String,
    window_name: String,
    timestamp: String,
}

fn pi_config_dir() -> std::io::Result<PathBuf> {
    let home = dirs::home_dir().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::NotFound, "home dir not found")
    })?;
    let dir = home.join(".pi").join("agent");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn cascade_data_dir(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let store = crate::store::SettingsStore::get(app)
        .map_err(|e| format!("failed to load settings store: {e}"))?
        .unwrap_or_default();
    let (data_dir, _) = crate::config::resolve_data_dir(&store.data_dir);
    Ok(data_dir)
}

async fn cascade_pool(
    app: &tauri::AppHandle,
) -> Result<cascade_schema::sqlx::sqlite::SqlitePool, String> {
    let db_path = cascade_data_dir(app)?.join("db.sqlite");
    if !db_path.exists() {
        return Err(format!("database not found at {}", db_path.display()));
    }
    let pool = open(&db_path).await.map_err(|e| format!("open cascade schema: {e}"))?;
    migrate(&pool)
        .await
        .map_err(|e| format!("migrate cascade schema: {e}"))?;
    Ok(pool)
}

fn classify_app(app_name: &str) -> Option<&'static str> {
    let lower = app_name.trim().to_lowercase();
    if CODING_APPS.iter().any(|a| *a == lower) {
        return Some("coding");
    }
    if BROWSER_APPS.iter().any(|a| *a == lower) {
        return Some("browser");
    }
    if MEETING_APPS.iter().any(|a| *a == lower) {
        return Some("meeting");
    }
    if COMMUNICATION_APPS.iter().any(|a| *a == lower) {
        return Some("communication");
    }
    if WRITING_APPS.iter().any(|a| *a == lower) {
        return Some("writing");
    }
    None
}

fn truncate_label(value: &str, max: usize) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return "untitled".to_string();
    }
    let count = trimmed.chars().count();
    if count <= max {
        return trimmed.to_string();
    }
    trimmed.chars().take(max.saturating_sub(1)).collect::<String>() + "…"
}

fn ratio_string(numerator: f64, denominator: f64) -> String {
    if denominator <= 0.0 {
        return "0%".to_string();
    }
    format!("{:.0}%", (numerator / denominator) * 100.0)
}

fn minutes_string(minutes: f64) -> String {
    if minutes >= 120.0 {
        format!("{:.1}h", minutes / 60.0)
    } else {
        format!("{:.0}m", minutes.round())
    }
}

fn cmp_f64_desc(a: f64, b: f64) -> Ordering {
    b.partial_cmp(&a).unwrap_or(Ordering::Equal)
}

fn top_app_labels(
    apps: &[ActivityAppUsage],
    classifier: &str,
    limit: usize,
) -> String {
    let mut names: Vec<String> = apps
        .iter()
        .filter(|app| classify_app(&app.name) == Some(classifier))
        .map(|app| format!("{} ({})", app.name, minutes_string(app.minutes)))
        .collect();
    names.truncate(limit);
    if names.is_empty() {
        "none".to_string()
    } else {
        names.join(", ")
    }
}

fn top_window_labels(
    windows: &[ActivityWindow],
    classifier: &str,
    limit: usize,
) -> String {
    let mut items: Vec<&ActivityWindow> = windows
        .iter()
        .filter(|window| classify_app(&window.app_name) == Some(classifier))
        .collect();
    items.sort_by(|a, b| cmp_f64_desc(a.minutes, b.minutes));
    items
        .into_iter()
        .take(limit)
        .map(|window| {
            format!(
                "{} · {}",
                window.app_name,
                truncate_label(&window.window_name, 36)
            )
        })
        .collect::<Vec<_>>()
        .join(" | ")
}

fn build_context_switching_suggestion(
    windows: &[ActivityWindow],
    total_minutes: f64,
    hours: u32,
) -> Option<CascadeManagerSuggestion> {
    let active_windows: Vec<&ActivityWindow> = windows.iter().filter(|w| w.minutes >= 1.0).collect();
    if total_minutes < 90.0 || active_windows.len() < 8 {
        return None;
    }

    let avg_window_minutes =
        active_windows.iter().map(|w| w.minutes).sum::<f64>() / active_windows.len() as f64;
    if avg_window_minutes > 8.0 {
        return None;
    }

    let severity = ((active_windows.len() as f64 / 18.0) * 0.6
        + ((8.0 - avg_window_minutes).max(0.0) / 8.0) * 0.4)
        .min(1.0);

    let mut top_windows = active_windows.clone();
    top_windows.sort_by(|a, b| cmp_f64_desc(a.minutes, b.minutes));

    Some(CascadeManagerSuggestion {
        id: None,
        kind: "context_switching".to_string(),
        title: "Heavy context switching".to_string(),
        summary: format!(
            "The last {} hours show frequent short hops between windows, which is a strong signal of switching overhead rather than sustained execution.",
            hours
        ),
        evidence: vec![
            CascadeManagerEvidence {
                label: "windows touched".to_string(),
                value: active_windows.len().to_string(),
            },
            CascadeManagerEvidence {
                label: "average dwell".to_string(),
                value: format!("{:.1} min/window", avg_window_minutes),
            },
            CascadeManagerEvidence {
                label: "heaviest loop".to_string(),
                value: top_windows
                    .iter()
                    .take(3)
                    .map(|window| format!("{} · {}", window.app_name, truncate_label(&window.window_name, 28)))
                    .collect::<Vec<_>>()
                    .join(" | "),
            },
        ],
        suggested_agent_kind: "focus-guard".to_string(),
        severity_score: severity,
        confidence: 0.74,
        status: "pending".to_string(),
        created_at: None,
    })
}

fn build_communication_suggestion(
    apps: &[ActivityAppUsage],
    total_minutes: f64,
    hours: u32,
) -> Option<CascadeManagerSuggestion> {
    let communication_minutes: f64 = apps
        .iter()
        .filter(|app| classify_app(&app.name) == Some("communication"))
        .map(|app| app.minutes)
        .sum();
    let communication_ratio = if total_minutes > 0.0 {
        communication_minutes / total_minutes
    } else {
        0.0
    };

    if communication_minutes < 45.0 || communication_ratio < 0.30 {
        return None;
    }

    Some(CascadeManagerSuggestion {
        id: None,
        kind: "communication_churn".to_string(),
        title: "Communication churn is consuming a large share of the day".to_string(),
        summary: format!(
            "Communication tools took a disproportionate share of the last {} hours, which suggests batching, triage, or message drafting work could be delegated.",
            hours
        ),
        evidence: vec![
            CascadeManagerEvidence {
                label: "communication time".to_string(),
                value: minutes_string(communication_minutes),
            },
            CascadeManagerEvidence {
                label: "share of analyzed window".to_string(),
                value: ratio_string(communication_minutes, total_minutes),
            },
            CascadeManagerEvidence {
                label: "top communication apps".to_string(),
                value: top_app_labels(apps, "communication", 3),
            },
        ],
        suggested_agent_kind: "inbox-batcher".to_string(),
        severity_score: (communication_ratio * 1.6).min(1.0),
        confidence: 0.77,
        status: "pending".to_string(),
        created_at: None,
    })
}

fn build_meeting_suggestion(
    apps: &[ActivityAppUsage],
    windows: &[ActivityWindow],
    total_minutes: f64,
    hours: u32,
) -> Option<CascadeManagerSuggestion> {
    let meeting_minutes: f64 = apps
        .iter()
        .filter(|app| classify_app(&app.name) == Some("meeting"))
        .map(|app| app.minutes)
        .sum();
    let meeting_ratio = if total_minutes > 0.0 {
        meeting_minutes / total_minutes
    } else {
        0.0
    };

    if meeting_minutes < 60.0 || meeting_ratio < 0.25 {
        return None;
    }

    Some(CascadeManagerSuggestion {
        id: None,
        kind: "meeting_load".to_string(),
        title: "Meeting time is crowding out execution time".to_string(),
        summary: format!(
            "Meeting-heavy time blocks dominated the last {} hours. A recap or async follow-up agent is likely to recover time from repeated sync work.",
            hours
        ),
        evidence: vec![
            CascadeManagerEvidence {
                label: "meeting time".to_string(),
                value: minutes_string(meeting_minutes),
            },
            CascadeManagerEvidence {
                label: "share of analyzed window".to_string(),
                value: ratio_string(meeting_minutes, total_minutes),
            },
            CascadeManagerEvidence {
                label: "top meeting contexts".to_string(),
                value: top_window_labels(windows, "meeting", 2),
            },
        ],
        suggested_agent_kind: "meeting-recap".to_string(),
        severity_score: (meeting_ratio * 1.5).min(1.0),
        confidence: 0.79,
        status: "pending".to_string(),
        created_at: None,
    })
}

fn build_browser_friction_suggestion(
    apps: &[ActivityAppUsage],
    windows: &[ActivityWindow],
    total_minutes: f64,
    hours: u32,
) -> Option<CascadeManagerSuggestion> {
    let browser_minutes: f64 = apps
        .iter()
        .filter(|app| classify_app(&app.name) == Some("browser"))
        .map(|app| app.minutes)
        .sum();
    let focus_minutes: f64 = apps
        .iter()
        .filter(|app| matches!(classify_app(&app.name), Some("coding") | Some("writing")))
        .map(|app| app.minutes)
        .sum();
    let browser_ratio = if total_minutes > 0.0 {
        browser_minutes / total_minutes
    } else {
        0.0
    };

    if browser_minutes < 60.0 || browser_ratio < 0.35 || focus_minutes < 20.0 {
        return None;
    }

    Some(CascadeManagerSuggestion {
        id: None,
        kind: "research_friction".to_string(),
        title: "Repeated lookup loops are eating execution time".to_string(),
        summary: format!(
            "Browser-heavy time alongside real build or writing time suggests recurring retrieval or setup friction in the last {} hours.",
            hours
        ),
        evidence: vec![
            CascadeManagerEvidence {
                label: "browser time".to_string(),
                value: minutes_string(browser_minutes),
            },
            CascadeManagerEvidence {
                label: "paired focus time".to_string(),
                value: minutes_string(focus_minutes),
            },
            CascadeManagerEvidence {
                label: "top browser contexts".to_string(),
                value: top_window_labels(windows, "browser", 3),
            },
        ],
        suggested_agent_kind: "research-assistant".to_string(),
        severity_score: (browser_ratio * 1.35).min(1.0),
        confidence: 0.64,
        status: "pending".to_string(),
        created_at: None,
    })
}

fn build_admin_churn_suggestion(
    key_texts: &[ActivityKeyText],
    hours: u32,
) -> Option<CascadeManagerSuggestion> {
    let admin_keywords = [
        "status update",
        "follow up",
        "follow-up",
        "timesheet",
        "jira",
        "linear",
        "asana",
        "hubspot",
        "crm",
        "standup",
        "spreadsheet",
    ];

    let hits: Vec<&ActivityKeyText> = key_texts
        .iter()
        .filter(|entry| {
            let haystack = format!(
                "{} {} {}",
                entry.app_name.to_lowercase(),
                entry.window_name.to_lowercase(),
                entry.text.to_lowercase()
            );
            admin_keywords.iter().any(|needle| haystack.contains(needle))
        })
        .collect();

    if hits.len() < 4 {
        return None;
    }

    Some(CascadeManagerSuggestion {
        id: None,
        kind: "manual_admin_work".to_string(),
        title: "Manual admin/status work appears repetitive".to_string(),
        summary: format!(
            "The last {} hours include repeated admin or status-oriented work that could likely be standardized into a helper workflow before it reaches the employee again.",
            hours
        ),
        evidence: vec![
            CascadeManagerEvidence {
                label: "detected admin-style moments".to_string(),
                value: hits.len().to_string(),
            },
            CascadeManagerEvidence {
                label: "latest signal".to_string(),
                value: format!(
                    "{} · {}",
                    hits[0].app_name,
                    truncate_label(&hits[0].window_name, 34)
                ),
            },
            CascadeManagerEvidence {
                label: "latest timestamp".to_string(),
                value: hits[0].timestamp.clone(),
            },
        ],
        suggested_agent_kind: "status-automation".to_string(),
        severity_score: 0.58,
        confidence: 0.62,
        status: "pending".to_string(),
        created_at: None,
    })
}

fn analyze_waste_signals(
    summary: &ActivitySummaryResponse,
    hours: u32,
) -> Vec<CascadeManagerSuggestion> {
    let total_minutes = summary.apps.iter().map(|app| app.minutes).sum::<f64>();
    let mut suggestions = Vec::new();

    if let Some(suggestion) = build_context_switching_suggestion(&summary.windows, total_minutes, hours) {
        suggestions.push(suggestion);
    }
    if let Some(suggestion) = build_communication_suggestion(&summary.apps, total_minutes, hours) {
        suggestions.push(suggestion);
    }
    if let Some(suggestion) = build_meeting_suggestion(&summary.apps, &summary.windows, total_minutes, hours) {
        suggestions.push(suggestion);
    }
    if let Some(suggestion) = build_browser_friction_suggestion(&summary.apps, &summary.windows, total_minutes, hours) {
        suggestions.push(suggestion);
    }
    if let Some(suggestion) = build_admin_churn_suggestion(&summary.key_texts, hours) {
        suggestions.push(suggestion);
    }

    suggestions.sort_by(|a, b| cmp_f64_desc(a.severity_score, b.severity_score));
    suggestions.truncate(4);
    suggestions
}

async fn fetch_activity_summary(
    app: &tauri::AppHandle,
    hours: u32,
) -> Result<(String, String, ActivitySummaryResponse), String> {
    let end = Utc::now();
    let start = end - Duration::hours(hours as i64);
    let start_iso = start.to_rfc3339();
    let end_iso = end.to_rfc3339();
    let path = format!(
        "/activity-summary?start_time={}&end_time={}&include_memories=false&include_guidance=false&include_snippets=false&max_snippets=0&max_memories=0",
        urlencoding::encode(&start_iso),
        urlencoding::encode(&end_iso),
    );

    let api = crate::recording::local_api_context_from_app(app);
    let client = Client::new();
    let response = api
        .apply_auth(client.get(api.url(&path)))
        .timeout(std::time::Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| format!("fetch activity summary: {e}"))?;

    if !response.status().is_success() {
        return Err(format!("activity summary returned {}", response.status()));
    }

    let body = response
        .json::<ActivitySummaryResponse>()
        .await
        .map_err(|e| format!("parse activity summary: {e}"))?;

    Ok((start_iso, end_iso, body))
}

fn write_manager_outbox(
    app: &tauri::AppHandle,
    batch: &CascadeManagerSuggestionBatch,
) -> Result<String, String> {
    let outbox_dir = cascade_data_dir(app)?.join(MANAGER_OUTBOX_DIR);
    fs::create_dir_all(&outbox_dir)
        .map_err(|e| format!("create manager outbox dir {}: {e}", outbox_dir.display()))?;

    let outbox_path = outbox_dir.join("latest.json");
    let body = serde_json::to_string_pretty(batch)
        .map_err(|e| format!("serialize manager outbox: {e}"))?;
    fs::write(&outbox_path, body)
        .map_err(|e| format!("write manager outbox {}: {e}", outbox_path.display()))?;
    Ok(outbox_path.display().to_string())
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
                "-a", ANTHROPIC_KEY_NAME,
                "-s", CASCADE_KEYCHAIN_SERVICE,
                "-w", &key,
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

/// Tag a frame manually. Forward-compat hook for Layer 2's classifier.
#[tauri::command]
#[specta::specta]
pub async fn cascade_tag_event(
    app: tauri::AppHandle,
    frame_id: i64,
    tag: String,
) -> Result<i64, String> {
    let pool = cascade_pool(&app).await?;
    tag_event(&pool, frame_id, &tag, TagSource::Manual, None)
        .await
        .map_err(|e| format!("tag event: {e}"))
}

/// Analyze recent activity, persist the waste-detection run, and emit a
/// manager-facing outbox payload the future web app can consume.
#[tauri::command]
#[specta::specta]
pub async fn cascade_generate_manager_suggestions(
    app: tauri::AppHandle,
    hours: Option<u32>,
) -> Result<CascadeManagerSuggestionBatch, String> {
    let hours = hours.unwrap_or(8).clamp(1, 24);
    let (window_start, window_end, summary) = fetch_activity_summary(&app, hours).await?;

    if summary.data_status != "ok" || summary.total_frames == 0 {
        let mut batch = CascadeManagerSuggestionBatch {
            generated_at: Utc::now().to_rfc3339(),
            window_start,
            window_end,
            hours_analyzed: hours,
            delivery_mode: "local_outbox".to_string(),
            outbox_path: String::new(),
            suggestions: Vec::new(),
        };
        batch.outbox_path = write_manager_outbox(&app, &batch)?;
        return Ok(batch);
    }

    let mut suggestions = analyze_waste_signals(&summary, hours);
    let pool = cascade_pool(&app).await?;
    let run_id = create_detection_run(
        &pool,
        DETECTOR_NAME,
        &window_start,
        &window_end,
        &serde_json::json!({
            "dataStatus": summary.data_status,
            "totalFrames": summary.total_frames,
            "suggestionCount": suggestions.len(),
        })
        .to_string(),
    )
    .await
    .map_err(|e| format!("create detection run: {e}"))?;

    for suggestion in suggestions.iter_mut() {
        let id = insert_manager_suggestion(
            &pool,
            run_id,
            &ManagerSuggestionInput {
                kind: suggestion.kind.clone(),
                title: suggestion.title.clone(),
                summary: suggestion.summary.clone(),
                evidence_json: serde_json::to_string(&suggestion.evidence)
                    .map_err(|e| format!("serialize suggestion evidence: {e}"))?,
                suggested_agent_kind: suggestion.suggested_agent_kind.clone(),
                severity_score: suggestion.severity_score,
                confidence: suggestion.confidence,
            },
        )
        .await
        .map_err(|e| format!("insert manager suggestion: {e}"))?;
        suggestion.id = Some(id);
        suggestion.created_at = Some(Utc::now().to_rfc3339());
    }

    let mut batch = CascadeManagerSuggestionBatch {
        generated_at: Utc::now().to_rfc3339(),
        window_start,
        window_end,
        hours_analyzed: hours,
        delivery_mode: "local_outbox".to_string(),
        outbox_path: String::new(),
        suggestions,
    };
    batch.outbox_path = write_manager_outbox(&app, &batch)?;
    Ok(batch)
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_list_manager_suggestions(
    app: tauri::AppHandle,
    status: Option<String>,
    limit: Option<u32>,
) -> Result<Vec<CascadeManagerSuggestion>, String> {
    let pool = cascade_pool(&app).await?;
    let records = list_manager_suggestions(
        &pool,
        status.as_deref(),
        limit.unwrap_or(25).clamp(1, 100) as i64,
    )
    .await
    .map_err(|e| format!("list manager suggestions: {e}"))?;

    records
        .into_iter()
        .map(|record| {
            let evidence = serde_json::from_str::<Vec<CascadeManagerEvidence>>(&record.evidence_json)
                .map_err(|e| format!("parse suggestion evidence {}: {e}", record.id))?;
            Ok(CascadeManagerSuggestion {
                id: Some(record.id),
                kind: record.kind,
                title: record.title,
                summary: record.summary,
                evidence,
                suggested_agent_kind: record.suggested_agent_kind,
                severity_score: record.severity_score,
                confidence: record.confidence,
                status: record.status,
                created_at: Some(record.created_at),
            })
        })
        .collect()
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_update_manager_suggestion_status(
    app: tauri::AppHandle,
    suggestion_id: i64,
    status: String,
) -> Result<(), String> {
    let allowed = ["pending", "sent", "approved", "rejected", "deployed"];
    if !allowed.contains(&status.as_str()) {
        return Err(format!("invalid suggestion status: {status}"));
    }

    let pool = cascade_pool(&app).await?;
    update_manager_suggestion_status(&pool, suggestion_id, &status)
        .await
        .map_err(|e| format!("update suggestion status: {e}"))
}
