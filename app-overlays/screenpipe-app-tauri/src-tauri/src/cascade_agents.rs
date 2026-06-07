// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
//! Cascade Layer 2 agents.
//!
//! Five agents, in the order trust must be earned (see `docs/agents.md`):
//!   #5 Privacy Aggregator  — on-device, deterministic. Turns the raw day into
//!                            an allowlist-only metric set. The ONLY thing the
//!                            LLM agents below are allowed to read.
//!   #2 Waste Detector      — Opus over the aggregator output (never raw OCR).
//!   #3 Agent Generator     — Opus turns an approved pattern into a typed,
//!                            reviewable agent spec (not executable yet).
//!   #4 Deployment Monitor  — Sonnet sandbox dry-run + lifecycle + anomaly
//!                            detection + immutable audit log.
//!
//! Agent #1 (Reel Q&A) lives in the `pi` subprocess, not here.

use crate::cascade_llm::{
    call_anthropic, call_anthropic_json, read_anthropic_key, LlmCall, LlmResult, MODEL_OPUS,
    MODEL_SONNET,
};
use cascade_schema::{
    append_audit, count_live_runs, create_detection_run, get_agent_action, get_agent_spec,
    insert_agent_action, insert_agent_run, insert_agent_spec, insert_manager_suggestion,
    last_daily_summary_at, last_detection_run_at, last_live_run_at, list_actions_for_spec,
    list_agent_runs, list_agent_specs, list_audit, list_deployed_specs, list_manager_suggestions,
    list_privacy_aggregates, list_recent_daily_summaries, migrate, open,
    replace_privacy_aggregates, update_agent_action_state, update_agent_spec_status,
    update_manager_suggestion_status, upsert_daily_summary, AgentActionInput, AgentRunInput,
    AgentSpecInput, ManagerSuggestionInput, PrivacyAggregateInput,
};
use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone, Utc};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use specta::Type;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;

const MANAGER_OUTBOX_DIR: &str = "cascade-manager-outbox";
const PRIVACY_OUTBOX_DIR: &str = "cascade-privacy-outbox";
const DETECTOR_NAME: &str = "cascade-waste-detector-llm-v1";

fn require_anthropic_key_for(action: &str) -> Result<(), String> {
    read_anthropic_key()
        .map(|_| ())
        .map_err(|_| format!("Add your Anthropic API key in Settings before {action}."))
}

// ─── App → category classifier (shared, deterministic) ──────────────

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

/// Apps + window markers that must NEVER be aggregated, even anonymously.
/// Banking / health / legal / dating / private browsing (agents.md #5 guardrail).
const SENSITIVE_MARKERS: &[&str] = &[
    // finance
    "bank",
    "chase",
    "wells fargo",
    "fidelity",
    "vanguard",
    "robinhood",
    "coinbase",
    "venmo",
    "paypal",
    "mint",
    "quickbooks",
    "turbotax",
    // health / medical
    "mychart",
    "teladoc",
    "doctor",
    "clinic",
    "pharmacy",
    "calm",
    "headspace",
    "clue",
    "flo",
    // legal
    "docusign",
    "clio",
    "lawpay",
    "legalzoom",
    // dating
    "tinder",
    "hinge",
    "bumble",
    "grindr",
    "okcupid",
    "match.com",
    // private browsing
    "private browsing",
    "incognito",
    "inprivate",
];

fn classify_app(app_name: &str) -> &'static str {
    let lower = app_name.trim().to_lowercase();
    if CODING_APPS.iter().any(|a| *a == lower) {
        "coding"
    } else if BROWSER_APPS.iter().any(|a| *a == lower) {
        "browser"
    } else if MEETING_APPS.iter().any(|a| *a == lower) {
        "meeting"
    } else if COMMUNICATION_APPS.iter().any(|a| *a == lower) {
        "communication"
    } else if WRITING_APPS.iter().any(|a| *a == lower) {
        "writing"
    } else {
        "other"
    }
}

fn is_sensitive(text: &str) -> bool {
    let lower = text.to_lowercase();
    SENSITIVE_MARKERS.iter().any(|m| lower.contains(m))
}

/// The notes/docs app the employee actually uses most over the recent window,
/// so a computer-use agent writes where the employee already works instead of
/// a fixed destination. None if they haven't used a writing app recently.
pub(crate) async fn preferred_notes_app(app: &tauri::AppHandle) -> Option<String> {
    let (_, _, summary) = fetch_activity_summary(app, 24).await.ok()?;
    let mut best: Option<(String, f64)> = None;
    for a in &summary.apps {
        if classify_app(&a.name) == "writing" {
            let better = best.as_ref().map(|(_, m)| a.minutes > *m).unwrap_or(true);
            if better {
                best = Some((a.name.clone(), a.minutes));
            }
        }
    }
    best.map(|(n, _)| n)
}

// ─── Shared infra (data dir, pool, activity summary) ────────────────

fn cascade_data_dir(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let store = crate::store::SettingsStore::get(app)
        .map_err(|e| format!("failed to load settings store: {e}"))?
        .unwrap_or_default();
    let (data_dir, _) = crate::config::resolve_data_dir(&store.data_dir);
    Ok(data_dir)
}

pub(crate) async fn cascade_pool(
    app: &tauri::AppHandle,
) -> Result<cascade_schema::sqlx::sqlite::SqlitePool, String> {
    let db_path = cascade_data_dir(app)?.join("db.sqlite");
    if !db_path.exists() {
        return Err(format!("database not found at {}", db_path.display()));
    }
    let pool = open(&db_path)
        .await
        .map_err(|e| format!("open cascade schema: {e}"))?;
    migrate(&pool)
        .await
        .map_err(|e| format!("migrate cascade schema: {e}"))?;
    Ok(pool)
}

pub(crate) async fn should_supervise_live_run(
    app: &tauri::AppHandle,
    spec_id: i64,
) -> Result<bool, String> {
    let pool = cascade_pool(app).await?;
    let live_runs = count_live_runs(&pool, spec_id)
        .await
        .map_err(|e| format!("count live runs: {e}"))?;
    Ok(live_runs < 3)
}

// NOTE: the /activity-summary server response is plain snake_case
// (`data_status`, `total_frames`, `app_name`, …) — NOT camelCase. We must match
// that exactly or serde fails with "error decoding response body". We only pull
// the subset we need; serde ignores the rest.
#[derive(Debug, Default, Deserialize)]
struct ActivitySummaryResponse {
    #[serde(default)]
    apps: Vec<ActivityAppUsage>,
    #[serde(default)]
    windows: Vec<ActivityWindow>,
    #[serde(default)]
    data_status: String,
    #[serde(default)]
    total_frames: i64,
}

#[derive(Debug, Deserialize)]
struct ActivityAppUsage {
    #[serde(default)]
    name: String,
    #[serde(default)]
    minutes: f64,
}

#[derive(Debug, Deserialize)]
struct ActivityWindow {
    #[serde(default)]
    app_name: String,
    #[serde(default)]
    window_name: String,
    #[serde(default)]
    minutes: f64,
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

// ─── The Rewind: actual on-screen content from the recording ─────────
//
// The detector + the agents read THIS — what the employee was really doing
// (window titles + OCR of the screen) — not thin app-minute aggregates. Sensitive
// apps/windows are still dropped before anything is summarized or leaves the device.

#[derive(Debug, Default, Deserialize)]
struct SearchResponse {
    #[serde(default)]
    data: Vec<SearchItem>,
}
#[derive(Debug, Default, Deserialize)]
struct SearchItem {
    #[serde(default)]
    content: SearchContent,
}
#[derive(Debug, Default, Deserialize)]
struct SearchContent {
    // screenpipe's OCRContent serializes `browser_url` (and may serialize other
    // string fields) as JSON `null` for non-browser frames — `#[serde(default)]`
    // only covers a MISSING key, not an explicit `null`, so a plain `String` here
    // makes `response.json()` fail with "error decoding response body" on almost
    // every real recording. de_null_string maps null → "" so the parse survives.
    #[serde(default, deserialize_with = "de_null_string")]
    timestamp: String,
    #[serde(default, deserialize_with = "de_null_string")]
    app_name: String,
    #[serde(default, deserialize_with = "de_null_string")]
    window_name: String,
    #[serde(default, deserialize_with = "de_null_string")]
    text: String,
    #[serde(default, deserialize_with = "de_null_string")]
    browser_url: String,
}

/// Fetch the raw Rewind frames (OCR) over the last `hours`, sorted by time.
async fn fetch_rewind_frames(
    app: &tauri::AppHandle,
    hours: u32,
    max_frames: u32,
) -> Result<Vec<SearchContent>, String> {
    let end = Utc::now();
    let start = end - Duration::hours(hours as i64);
    fetch_rewind_frames_range(app, start, end, max_frames).await
}

/// OCR frames over an explicit UTC time range (used to summarize a specific
/// calendar day, where a trailing-hours window won't do). `fetch_rewind_frames`
/// is the trailing-window wrapper over this.
async fn fetch_rewind_frames_range(
    app: &tauri::AppHandle,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    max_frames: u32,
) -> Result<Vec<SearchContent>, String> {
    let path = format!(
        "/search?content_type=ocr&start_time={}&end_time={}&limit={}",
        urlencoding::encode(&start.to_rfc3339()),
        urlencoding::encode(&end.to_rfc3339()),
        max_frames,
    );
    let api = crate::recording::local_api_context_from_app(app);
    let client = Client::new();
    let response = api
        .apply_auth(client.get(api.url(&path)))
        .timeout(std::time::Duration::from_secs(20))
        .send()
        .await
        .map_err(|e| format!("fetch rewind: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("rewind search returned {}", response.status()));
    }
    // Read the body as text first so a decode failure can log the ACTUAL JSON
    // that broke (e.g. a field shape the struct doesn't tolerate), instead of an
    // opaque "error decoding response body".
    let raw = response
        .text()
        .await
        .map_err(|e| format!("read rewind body: {e}"))?;
    let body: SearchResponse = serde_json::from_str(&raw).map_err(|e| {
        eprintln!(
            "[cascade-rewind] parse FAILED: {e} — first 400 bytes: {}",
            raw.chars().take(400).collect::<String>()
        );
        format!("parse rewind: {e}")
    })?;
    let mut frames: Vec<SearchContent> = body.data.into_iter().map(|i| i.content).collect();
    frames.sort_by(|a, b| a.timestamp.cmp(&b.timestamp));
    eprintln!(
        "[cascade-rewind] parsed {} frames for {}..{}",
        frames.len(),
        start.to_rfc3339(),
        end.to_rfc3339()
    );
    Ok(frames)
}

/// Host portion of a URL (no scheme crate needed).
pub(crate) fn host_from_url(u: &str) -> Option<String> {
    let s = u.trim();
    if s.is_empty() {
        return None;
    }
    let after = s.split("://").nth(1).unwrap_or(s);
    let host = after.split(['/', '?', '#']).next().unwrap_or("");
    if host.is_empty() {
        None
    } else {
        Some(host.to_lowercase())
    }
}

fn normalized_host(host: &str) -> String {
    let mut h = host.trim().trim_end_matches('.').to_lowercase();
    if h.starts_with('[') {
        if let Some(end) = h.find(']') {
            h = h[1..end].to_string();
        }
    } else if h.matches(':').count() == 1 {
        if let Some((base, port)) = h.rsplit_once(':') {
            if port.chars().all(|c| c.is_ascii_digit()) {
                h = base.to_string();
            }
        }
    }
    h
}

fn is_noise_host(host: &str) -> bool {
    let h = normalized_host(host);
    if h.is_empty()
        || h == "localhost"
        || h == "127.0.0.1"
        || h == "::1"
        || h.ends_with(".localhost")
        || h.starts_with("newtab")
    {
        return true;
    }
    let search_or_start_hosts = [
        "google.com",
        "www.google.com",
        "bing.com",
        "www.bing.com",
        "duckduckgo.com",
        "www.duckduckgo.com",
        "search.brave.com",
        "search.yahoo.com",
        "startpage.com",
        "www.startpage.com",
    ];
    search_or_start_hosts.iter().any(|noise| h == *noise)
}

pub(crate) fn is_candidate_target_host(host: &str) -> bool {
    !is_noise_host(host) && !is_sensitive(host)
}

pub(crate) fn host_matches_any(host: &str, candidates: &[String]) -> bool {
    let h = normalized_host(host);
    if h.is_empty() {
        return false;
    }
    candidates.iter().any(|candidate| {
        let raw = host_from_url(candidate).unwrap_or_else(|| candidate.to_string());
        let c = normalized_host(&raw);
        !c.is_empty() && (h == c || h.ends_with(&format!(".{c}")) || c.ends_with(&format!(".{h}")))
    })
}

fn task_keywords(task: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for part in task
        .split(|c: char| !c.is_alphanumeric())
        .map(|s| s.trim().to_lowercase())
        .filter(|s| s.len() >= 3)
    {
        if seen.insert(part.clone()) {
            out.push(part);
        }
    }
    out
}

fn frame_text_blob(frame: &SearchContent) -> String {
    format!(
        "{} {} {} {}",
        frame.app_name, frame.window_name, frame.text, frame.browser_url
    )
    .to_lowercase()
}

fn rewind_snippet(frame: &SearchContent, max_chars: usize) -> String {
    frame
        .text
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(max_chars)
        .collect()
}

fn dedupe_push(items: &mut Vec<String>, value: String) {
    if value.trim().is_empty() {
        return;
    }
    if items
        .iter()
        .any(|existing| existing.eq_ignore_ascii_case(&value))
    {
        return;
    }
    items.push(value);
}

fn collapse_whitespace(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn truncate_chars(value: &str, max_chars: usize) -> String {
    let mut chars = value.chars();
    let truncated: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        format!("{truncated}…")
    } else {
        truncated
    }
}

fn preview_delimited(
    value: &str,
    delimiter: &str,
    max_items: usize,
    max_chars: usize,
    joiner: &str,
) -> String {
    let mut items = value
        .split(delimiter)
        .map(collapse_whitespace)
        .filter(|item| !item.is_empty())
        .take(max_items)
        .map(|item| truncate_chars(&item, max_chars))
        .collect::<Vec<_>>();
    if items.is_empty() {
        String::new()
    } else {
        items.truncate(max_items);
        items.join(joiner)
    }
}

fn contains_any(haystack: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| haystack.contains(needle))
}

fn sanitize_detector_text(value: &str, max_chars: usize) -> String {
    truncate_chars(&collapse_whitespace(value), max_chars)
}

fn sanitize_evidence_label(label: &str) -> String {
    let normalized = collapse_whitespace(label).to_lowercase();
    match normalized.as_str() {
        "app" | "apps" | "app used" | "apps used" => "apps used".to_string(),
        "site" | "sites" | "tool" | "tools" | "web tools" | "web tools used" => {
            "web tools used".to_string()
        }
        "url" | "start url" | "starting url" | "target url" => "starting url".to_string(),
        "workflow" | "workflow observed" | "observed workflow" => "workflow observed".to_string(),
        "how they finished it" | "completion pattern" | "finished with" => {
            "how they finished it".to_string()
        }
        "proposed automation" | "automation" | "agent purpose" => "proposed automation".to_string(),
        _ => normalized,
    }
}

fn sanitize_evidence_value(label: &str, value: &str) -> String {
    let normalized_label = sanitize_evidence_label(label);
    let cleaned = collapse_whitespace(value);
    if cleaned.is_empty() {
        return String::new();
    }
    match normalized_label.as_str() {
        "workflow observed" => preview_delimited(&cleaned, "|", 4, 82, " | "),
        "how they finished it" => preview_delimited(&cleaned, "->", 4, 72, " -> "),
        "apps used" | "web tools used" => preview_delimited(&cleaned, ",", 4, 28, ", "),
        "starting url" => truncate_chars(&cleaned, 110),
        _ => truncate_chars(&cleaned, 180),
    }
}

fn sanitize_detector_evidence(items: Vec<CascadeManagerEvidence>) -> Vec<CascadeManagerEvidence> {
    let mut out = Vec::new();
    for item in items {
        let label = sanitize_evidence_label(&item.label);
        let value = sanitize_evidence_value(&label, &item.value);
        if value.is_empty()
            || out.iter().any(|existing: &CascadeManagerEvidence| {
                existing.label == label && existing.value == value
            })
        {
            continue;
        }
        out.push(CascadeManagerEvidence { label, value });
        if out.len() >= 7 {
            break;
        }
    }
    out
}

fn suggestion_purpose(s: &CascadeManagerSuggestion) -> String {
    s.evidence
        .iter()
        .find(|e| e.label == "proposed automation")
        .map(|e| e.value.clone())
        .unwrap_or_default()
}

fn suggestion_descriptor_blob(s: &CascadeManagerSuggestion) -> String {
    format!(
        "{} {} {} {}",
        s.kind,
        s.title,
        s.summary,
        suggestion_purpose(s)
    )
    .to_lowercase()
}

fn repeatability_score(s: &CascadeManagerSuggestion, grounding: &WorkflowGrounding) -> f64 {
    let text = suggestion_descriptor_blob(s);
    let recurring_cues = [
        "daily",
        "every",
        "each",
        "recurring",
        "repeat",
        "repeated",
        "repeatedly",
        "routine",
        "schedule",
        "scheduled",
        "monitor",
        "check",
        "digest",
        "triage",
        "follow-up",
        "follow up",
        "status",
        "recap",
        "deadline",
        "availability",
        "grades",
    ];
    let one_off_cues = [
        "fix",
        "debug",
        "investigate",
        "migration",
        "migrate",
        "install",
        "setup",
        "set up",
        "refactor",
        "rename",
        "repair",
        "clean up",
        "one-time",
        "one off",
    ];

    let mut score: f64 = 0.0;
    if contains_any(&text, &recurring_cues) {
        score += 0.45;
    }
    if grounding.observed_workflow.len() >= 3 {
        score += 0.2;
    }
    if !grounding.completion_pattern.trim().is_empty() {
        score += 0.15;
    }
    if grounding.target_hosts.len() + grounding.observed_apps.len() >= 2 {
        score += 0.2;
    }
    if contains_any(&text, &one_off_cues) {
        score -= 0.45;
    }
    score.clamp(0.0, 1.0)
}

fn agent_fit_score(s: &CascadeManagerSuggestion, grounding: &WorkflowGrounding) -> f64 {
    let text = suggestion_descriptor_blob(s);
    let feasible_cues = [
        "summarize",
        "summary",
        "draft",
        "digest",
        "check",
        "monitor",
        "post",
        "send",
        "collect",
        "compile",
        "copy",
        "sync",
        "review",
        "update",
        "triage",
        "remind",
        "notify",
        "compare",
        "track",
        "log in",
        "login",
        "open",
    ];
    let hard_cues = [
        "brainstorm",
        "decide",
        "strategy",
        "creative",
        "design",
        "architect",
        "write code",
        "coding",
        "learn",
        "study",
    ];

    let mut score: f64 = 0.0;
    if contains_any(&text, &feasible_cues) {
        score += 0.5;
    }
    if grounding.execution_mode == "browser"
        && (!grounding.target_hosts.is_empty() || !grounding.primary_url.is_empty())
    {
        score += 0.25;
    }
    if !grounding.observed_apps.is_empty() {
        score += 0.1;
    }
    if !grounding.observed_workflow.is_empty() || !grounding.completion_pattern.is_empty() {
        score += 0.15;
    }
    if contains_any(&text, &hard_cues) {
        score -= 0.5;
    }
    score.clamp(0.0, 1.0)
}

fn repeat_signal_summary(grounding: &WorkflowGrounding) -> String {
    let mut parts = Vec::new();
    if !grounding.target_hosts.is_empty() {
        parts.push(format!(
            "Keeps happening in {}",
            grounding
                .target_hosts
                .iter()
                .take(2)
                .cloned()
                .collect::<Vec<_>>()
                .join(", ")
        ));
    } else if !grounding.observed_apps.is_empty() {
        parts.push(format!(
            "Shows up across {}",
            grounding
                .observed_apps
                .iter()
                .take(2)
                .cloned()
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    if grounding.observed_workflow.len() >= 3 {
        parts.push(format!(
            "{} repeatable screens matched this task",
            grounding.observed_workflow.len()
        ));
    }
    if !grounding.completion_pattern.trim().is_empty() {
        parts.push(format!(
            "Often ends with {}",
            preview_delimited(&grounding.completion_pattern, "->", 2, 48, " -> ")
        ));
    }
    truncate_chars(&parts.join(" · "), 180)
}

fn should_keep_manager_suggestion(
    s: &CascadeManagerSuggestion,
    grounding: &WorkflowGrounding,
) -> bool {
    if s.title.trim().is_empty() || s.summary.trim().is_empty() {
        return false;
    }
    if suggestion_purpose(s).chars().count() < 18 {
        return false;
    }
    if s.confidence < 0.55 || s.severity_score < 0.35 {
        return false;
    }
    if grounding.observed_workflow.len() < 2
        && grounding.target_hosts.is_empty()
        && grounding.observed_apps.is_empty()
    {
        return false;
    }
    repeatability_score(s, grounding) >= 0.55 && agent_fit_score(s, grounding) >= 0.55
}

fn top_ranked(mut counts: HashMap<String, i64>, limit: usize) -> Vec<String> {
    let mut items: Vec<(String, i64)> = counts.drain().collect();
    items.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    items
        .into_iter()
        .map(|(value, _)| value)
        .filter(|value| !value.trim().is_empty())
        .take(limit)
        .collect()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowGrounding {
    #[serde(
        default = "default_execution_mode",
        deserialize_with = "de_null_string"
    )]
    pub execution_mode: String,
    #[serde(default, deserialize_with = "de_null_string")]
    pub primary_url: String,
    #[serde(default)]
    pub target_hosts: Vec<String>,
    #[serde(default)]
    pub observed_apps: Vec<String>,
    #[serde(default)]
    pub observed_workflow: Vec<String>,
    #[serde(default, deserialize_with = "de_null_string")]
    pub completion_pattern: String,
}

fn derive_rewind_grounding(frames: &[SearchContent], task: &str) -> WorkflowGrounding {
    let keywords = task_keywords(task);
    let visible: Vec<&SearchContent> = frames
        .iter()
        .filter(|f| {
            !(f.app_name.is_empty() && f.window_name.is_empty() && f.text.trim().is_empty())
                && !is_sensitive(&f.app_name)
                && !is_sensitive(&f.window_name)
                && !is_sensitive(&f.text)
        })
        .collect();
    let matched: Vec<&SearchContent> = visible
        .iter()
        .copied()
        .filter(|f| {
            if keywords.is_empty() {
                return true;
            }
            let blob = frame_text_blob(f);
            keywords.iter().any(|kw| blob.contains(kw))
        })
        .collect();
    let relevant: Vec<&SearchContent> = if matched.len() >= 3 { matched } else { visible };

    let mut host_counts: HashMap<String, i64> = HashMap::new();
    let mut app_counts: HashMap<String, i64> = HashMap::new();
    let mut observed_workflow = Vec::new();
    let mut workflow_seen = HashSet::new();
    let mut completion = Vec::new();
    let mut primary_url = String::new();

    for frame in &relevant {
        if !frame.app_name.trim().is_empty() {
            *app_counts
                .entry(frame.app_name.trim().to_string())
                .or_insert(0) += 1;
        }
        if let Some(host) = host_from_url(&frame.browser_url) {
            if is_candidate_target_host(&host) {
                let entry = host_counts.entry(host.clone()).or_insert(0);
                *entry += 1;
                if primary_url.is_empty() {
                    primary_url = format!("https://{host}");
                }
            }
        }

        let hhmm = frame.timestamp.get(11..16).unwrap_or("");
        let host = host_from_url(&frame.browser_url).unwrap_or_default();
        let app = if frame.app_name.trim().is_empty() {
            "Browser"
        } else {
            frame.app_name.trim()
        };
        let window = frame.window_name.trim();
        let snippet = rewind_snippet(frame, 120);
        let key = format!("{app}|{window}|{host}");
        if workflow_seen.insert(key) {
            let mut line = format!("[{hhmm}] {app}");
            if !host.is_empty() {
                line.push_str(&format!(" ({host})"));
            }
            if !window.is_empty() {
                line.push_str(&format!(" — {window}"));
            }
            if !snippet.is_empty() {
                line.push_str(&format!(" :: {snippet}"));
            }
            if observed_workflow.len() < 6 {
                dedupe_push(&mut observed_workflow, line);
            }
        }
    }

    for frame in relevant.iter().rev().take(3).rev() {
        let host = host_from_url(&frame.browser_url).unwrap_or_default();
        let window = frame.window_name.trim();
        let snippet = rewind_snippet(frame, 80);
        let mut line = if !host.is_empty() {
            host
        } else if !window.is_empty() {
            window.to_string()
        } else if !frame.app_name.trim().is_empty() {
            frame.app_name.trim().to_string()
        } else {
            snippet.clone()
        };
        if !snippet.is_empty() && !line.contains(&snippet) {
            line.push_str(&format!(" ({snippet})"));
        }
        dedupe_push(&mut completion, line);
    }

    let target_hosts = top_ranked(host_counts, 4);
    let observed_apps = top_ranked(app_counts, 4);
    let execution_mode = if !target_hosts.is_empty() || !primary_url.is_empty() {
        "browser".to_string()
    } else {
        default_execution_mode()
    };

    WorkflowGrounding {
        execution_mode,
        primary_url,
        target_hosts,
        observed_apps,
        observed_workflow,
        completion_pattern: completion.join(" -> "),
    }
}

pub(crate) async fn fetch_rewind_grounding(
    app: &tauri::AppHandle,
    hours: u32,
    task: &str,
    max_frames: u32,
) -> Result<WorkflowGrounding, String> {
    let frames = fetch_rewind_frames(app, hours, max_frames).await?;
    Ok(derive_rewind_grounding(&frames, task))
}

fn add_grounding_evidence(s: &mut CascadeManagerSuggestion, grounding: &WorkflowGrounding) {
    let repeat_signal = repeat_signal_summary(grounding);
    if !repeat_signal.is_empty() {
        s.evidence.push(CascadeManagerEvidence {
            label: "repeat signal".to_string(),
            value: repeat_signal,
        });
    }
    if !grounding.primary_url.is_empty() {
        s.evidence.push(CascadeManagerEvidence {
            label: "starting url".to_string(),
            value: sanitize_evidence_value("starting url", &grounding.primary_url),
        });
    }
    if !grounding.observed_apps.is_empty() {
        s.evidence.push(CascadeManagerEvidence {
            label: "apps used".to_string(),
            value: sanitize_evidence_value("apps used", &grounding.observed_apps.join(", ")),
        });
    }
    if !grounding.target_hosts.is_empty() {
        s.evidence.push(CascadeManagerEvidence {
            label: "web tools used".to_string(),
            value: sanitize_evidence_value("web tools used", &grounding.target_hosts.join(", ")),
        });
    }
    if !grounding.observed_workflow.is_empty() {
        s.evidence.push(CascadeManagerEvidence {
            label: "workflow observed".to_string(),
            value: sanitize_evidence_value(
                "workflow observed",
                &grounding.observed_workflow.join(" | "),
            ),
        });
    }
    if !grounding.completion_pattern.is_empty() {
        s.evidence.push(CascadeManagerEvidence {
            label: "how they finished it".to_string(),
            value: sanitize_evidence_value("how they finished it", &grounding.completion_pattern),
        });
    }
}

fn merge_grounding_into_spec(doc: &mut AgentSpecDoc, grounding: &WorkflowGrounding) {
    // Reconcile execution mode with the Rewind signal WITHOUT forcing a state the
    // rest of the spec can't satisfy. Grounding often reads "browser" just because
    // the employee's work touched a website, but if the model deliberately designed
    // a background workflow (no browser.use step), forcing browser here only makes
    // validate_spec reject an otherwise-valid spec. So grounding may push toward
    // "browser" ONLY when there's a browser.use step to back it (correcting a model
    // that built browser work but mislabeled the mode); a heuristic "browser" with
    // no such step degrades to background instead of self-invalidating.
    let has_browser_step = doc
        .workflow
        .iter()
        .any(|s| s.tool.as_deref() == Some("browser.use"));
    if doc.execution_mode.trim().is_empty() {
        doc.execution_mode = if grounding.execution_mode == "browser" && !has_browser_step {
            default_execution_mode()
        } else {
            grounding.execution_mode.clone()
        };
    } else if grounding.execution_mode == "browser" && has_browser_step {
        doc.execution_mode = "browser".to_string();
    }
    if doc.target_url.trim().is_empty() {
        doc.target_url = grounding.primary_url.clone();
    }
    for host in &grounding.target_hosts {
        if !doc
            .target_hosts
            .iter()
            .any(|existing| existing.eq_ignore_ascii_case(host))
        {
            doc.target_hosts.push(host.clone());
        }
    }
    for app in &grounding.observed_apps {
        if !doc
            .observed_apps
            .iter()
            .any(|existing| existing.eq_ignore_ascii_case(app))
        {
            doc.observed_apps.push(app.clone());
        }
    }
    for step in &grounding.observed_workflow {
        if !doc
            .observed_workflow
            .iter()
            .any(|existing| existing.eq_ignore_ascii_case(step))
        {
            doc.observed_workflow.push(step.clone());
        }
    }
    if doc.completion_pattern.trim().is_empty() {
        doc.completion_pattern = grounding.completion_pattern.clone();
    }
    let required_sources = [
        "cascade_rewind_digest",
        "cascade_rewind_workflow",
        "cascade_rewind_tools",
    ];
    for source in required_sources {
        if !doc
            .required_inputs
            .iter()
            .any(|input| input.source.eq_ignore_ascii_case(source))
        {
            doc.required_inputs.push(RequiredInput {
                source: source.to_string(),
                fields: Vec::new(),
            });
        }
    }
}

/// The web app this agent should actually operate in — derived from the Rewind,
/// not from a fixed destination. We pick the site the employee uses most for this kind of
/// work: count the hosts they actually browsed (dropping search/new-tab noise and
/// sensitive sites), and bias toward one whose host matches a word in the task.
/// Returns the origin ("https://host") to open + sign into, or None.
pub(crate) async fn rewind_primary_url(
    app: &tauri::AppHandle,
    hours: u32,
    task: &str,
) -> Option<String> {
    let frames = fetch_rewind_frames(app, hours, 500).await.ok()?;
    let task_l = task.to_lowercase();
    let keywords: Vec<&str> = task_l
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.len() >= 4)
        .collect();

    use std::collections::HashMap;
    let mut score: HashMap<String, i64> = HashMap::new();
    for f in &frames {
        let Some(host) = host_from_url(&f.browser_url) else {
            continue;
        };
        // Drop browser/search/local noise plus sensitive hosts before scoring.
        if !is_candidate_target_host(&host) {
            continue;
        }
        let entry = score.entry(host.clone()).or_insert(0);
        *entry += 1;
        // Strong boost if the host matches what the task is about.
        if keywords.iter().any(|k| host.contains(k)) {
            *entry += 50;
        }
    }
    let best = score.into_iter().max_by_key(|(_, n)| *n)?.0;
    Some(format!("https://{best}"))
}

/// A compact, chronological digest of what the employee actually did on screen
/// over the last `hours`, built from the Rewind recording (OCR + window titles).
/// Returns (digest, frames_used, sensitive_excluded). Sensitive frames dropped.
pub(crate) async fn fetch_rewind_digest(
    app: &tauri::AppHandle,
    hours: u32,
    max_frames: u32,
) -> Result<(String, usize, u32), String> {
    let owned = fetch_rewind_frames(app, hours, max_frames).await?;
    Ok(build_digest_from_frames(&owned))
}

/// Build a compact, deduped chronological digest from already-fetched frames —
/// the frame→text step shared by the trailing-window digest and the per-day
/// summarizer. Returns (digest, frames_used, sensitive_excluded).
fn build_digest_from_frames(owned: &[SearchContent]) -> (String, usize, u32) {
    let frames: Vec<&SearchContent> = owned.iter().collect();

    let mut lines: Vec<String> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut last_key = String::new();
    let mut used = 0usize;
    let mut excluded = 0u32;
    let mut total_len = 0usize;

    for f in frames {
        if f.app_name.is_empty() && f.window_name.is_empty() && f.text.trim().is_empty() {
            continue;
        }
        if is_sensitive(&f.app_name) || is_sensitive(&f.window_name) || is_sensitive(&f.text) {
            excluded += 1;
            continue;
        }
        used += 1;
        let hhmm = f.timestamp.get(11..16).unwrap_or("");
        let app_name = if f.app_name.is_empty() {
            "?"
        } else {
            f.app_name.trim()
        };
        let win = f.window_name.trim();
        let key = format!("{app_name}|{win}");
        if key != last_key {
            let header = format!("\n[{hhmm}] {app_name} — {win}");
            total_len += header.len();
            lines.push(header);
            last_key = key;
        }
        // One deduped, whitespace-collapsed OCR snippet per distinct screen.
        let snippet: String = f.text.split_whitespace().collect::<Vec<_>>().join(" ");
        let snippet: String = snippet.chars().take(220).collect();
        if !snippet.is_empty() && seen.insert(snippet.clone()) {
            let line = format!("    {snippet}");
            total_len += line.len();
            lines.push(line);
        }
        if total_len > 7000 {
            break;
        }
    }

    (lines.join("\n").trim().to_string(), used, excluded)
}

/// One recorded user action (from screenpipe's accessibility-derived `ui_events`).
struct UiStep {
    event_type: String,
    app: String,
    window: String,
    element: String,
    text: String,
}

/// The actual click-by-click PLAYBOOK the employee performed for their work —
/// labeled clicks and app switches, in order (typed text is deliberately excluded
/// for privacy; see the query). Feeding this to an agent lets it FOLLOW the real
/// path instead of re-deriving every step from vision (which is why agents
/// otherwise "don't know what to do"). Fully general: reads whatever `ui_events`
/// recorded, with NO app/site-specific handling.
/// Returns "" when nothing usable was recorded.
/// True for the common desktop browsers — used to keep a browser agent's playbook
/// focused on web steps instead of unrelated Finder/terminal/desktop clicks.
fn is_browser_app(app: &str) -> bool {
    let a = app.to_lowercase();
    [
        "chrome", "safari", "firefox", "edge", "arc", "brave", "chromium", "opera", "vivaldi",
    ]
    .iter()
    .any(|b| a.contains(b))
}

/// Structural accessibility labels that name a container, not a real target —
/// clicking "cell"/"scroll area" tells the agent nothing, so they're dropped.
fn is_generic_element(name: &str) -> bool {
    let n = name.trim().to_lowercase();
    if n.chars().count() <= 2 {
        return true;
    }
    matches!(
        n.as_str(),
        "cell"
            | "scroll area"
            | "list view"
            | "row"
            | "group"
            | "button"
            | "image"
            | "text"
            | "web area"
            | "html content"
            | "generic"
            | "document"
            | "list"
            | "table"
            | "list item"
            | "heading"
            | "main"
            | "navigation"
            | "banner"
            | "link"
            | "static text"
            | "contentinfo"
            | "complementary"
            | "toolbar"
    )
}

pub(crate) async fn fetch_rewind_steps(
    app: &tauri::AppHandle,
    hours: u32,
    max_events: u32,
    browser_only: bool,
) -> Result<String, String> {
    use cascade_schema::sqlx::{self, Row};
    let pool = cascade_pool(app).await?;
    let since = (Utc::now() - Duration::hours(hours as i64)).to_rfc3339();
    // ui_events.timestamp is RFC3339 with a fixed +00:00 offset, so lexicographic
    // compare == chronological. We take only actionable events (no move/scroll).
    let rows = sqlx::query(
        // We intentionally do NOT read 'text'/keystroke events: ui_events stores
        // raw typed characters (not masked like OCR) with no secure-field marker
        // (element_role is null), and this playbook is sent to the LLM — so typed
        // content could leak passwords. The click/app-switch path is the real
        // signal; the agent types from the live screen.
        "SELECT event_type, \
                COALESCE(app_name,'')     AS app_name, \
                COALESCE(window_title,'') AS window_title, \
                COALESCE(element_role,'') AS element_role, \
                COALESCE(element_name,'') AS element_name, \
                COALESCE(text_content,'') AS text_content \
         FROM ui_events \
         WHERE event_type IN ('click','app_switch') AND timestamp >= ?1 \
         ORDER BY timestamp ASC, id ASC \
         LIMIT ?2",
    )
    .bind(&since)
    .bind(max_events as i64)
    .fetch_all(&pool)
    .await
    .map_err(|e| format!("query ui_events: {e}"))?;

    let steps: Vec<UiStep> = rows
        .iter()
        .map(|r| UiStep {
            event_type: r.try_get::<String, _>("event_type").unwrap_or_default(),
            app: r.try_get::<String, _>("app_name").unwrap_or_default(),
            window: r.try_get::<String, _>("window_title").unwrap_or_default(),
            element: r.try_get::<String, _>("element_name").unwrap_or_default(),
            text: r.try_get::<String, _>("text_content").unwrap_or_default(),
        })
        .collect();

    let playbook = build_step_playbook(&steps, browser_only);
    eprintln!(
        "[cascade-steps] {} ui_events over {hours}h → {}-step playbook (browser_only={browser_only})",
        rows.len(),
        playbook.lines().count()
    );
    Ok(playbook)
}

fn build_step_playbook(rows: &[UiStep], browser_only: bool) -> String {
    // Typed text is deliberately excluded upstream (see the query) for privacy —
    // this builds the path from clicks + app switches only.
    let mut out: Vec<String> = Vec::new();
    let mut last_app = String::new();

    for r in rows {
        if is_sensitive(&r.app)
            || is_sensitive(&r.window)
            || is_sensitive(&r.element)
            || is_sensitive(&r.text)
        {
            continue;
        }
        // For a browser agent, keep only web steps — Finder/terminal/desktop
        // clicks aren't part of the workflow it will reproduce.
        if browser_only && !is_browser_app(&r.app) {
            continue;
        }
        match r.event_type.as_str() {
            "app_switch" => {
                let app = r.app.trim();
                if !app.is_empty() && !app.eq_ignore_ascii_case(&last_app) {
                    out.push(format!("Open {app}"));
                    last_app = app.to_string();
                }
            }
            "click" => {
                // Skip unlabeled or purely-structural clicks — accessibility names
                // cover only some clicks, and "cell"/"" tells the agent nothing.
                let name = r.element.trim();
                if name.is_empty() || is_generic_element(name) {
                    continue;
                }
                let where_ = if !r.window.trim().is_empty() {
                    r.window.trim()
                } else {
                    r.app.trim()
                };
                let mut line = format!("Click \"{}\"", name.chars().take(50).collect::<String>());
                if !where_.is_empty() {
                    line.push_str(&format!(
                        " — {}",
                        where_.chars().take(40).collect::<String>()
                    ));
                }
                out.push(line);
            }
            _ => {}
        }
    }

    // Dedupe consecutive repeats, number, cap to a readable length.
    let mut numbered: Vec<String> = Vec::new();
    let mut prev = String::new();
    for s in out {
        if s == prev {
            continue;
        }
        prev = s.clone();
        numbered.push(format!("{}. {}", numbered.len() + 1, s));
        if numbered.len() >= 20 {
            break;
        }
    }
    numbered.join("\n")
}

fn cmp_f64_desc(a: f64, b: f64) -> Ordering {
    b.partial_cmp(&a).unwrap_or(Ordering::Equal)
}

fn write_json_outbox(
    app: &tauri::AppHandle,
    dir_name: &str,
    body: &impl Serialize,
) -> Result<String, String> {
    let outbox_dir = cascade_data_dir(app)?.join(dir_name);
    fs::create_dir_all(&outbox_dir)
        .map_err(|e| format!("create outbox dir {}: {e}", outbox_dir.display()))?;
    let outbox_path = outbox_dir.join("latest.json");
    let text = serde_json::to_string_pretty(body).map_err(|e| format!("serialize outbox: {e}"))?;
    fs::write(&outbox_path, text)
        .map_err(|e| format!("write outbox {}: {e}", outbox_path.display()))?;
    Ok(outbox_path.display().to_string())
}

// ════════════════════════════════════════════════════════════════════
// Agent #5 — Privacy Aggregator (on-device, deterministic, $0)
// ════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CascadePrivacyAggregate {
    pub app: String,
    pub category: String,
    pub duration_min: f64,
    pub context_switches: i64,
    pub noised: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CascadePrivacyReport {
    pub generated_at: String,
    pub window_start: String,
    pub window_end: String,
    pub hours_analyzed: u32,
    pub aggregates: Vec<CascadePrivacyAggregate>,
    /// Number of apps/windows dropped because they matched a sensitive marker.
    pub excluded_count: u32,
    /// Allowlist of fields that leave the device. Shown in the outbox preview.
    pub shared_fields: Vec<String>,
    pub outbox_path: String,
}

/// ε≈1 Laplace-style jitter for small counts, without pulling in `rand`. The
/// jitter is seeded by the app name so it's stable across a window (re-running
/// the aggregator doesn't leak the true value through averaging) but differs
/// per app. Only counts < 10 are perturbed; larger counts are not re-identifying.
fn dp_jitter(app: &str, count: i64) -> (i64, bool) {
    if count >= 10 {
        return (count, false);
    }
    let mut h: u64 = 1469598103934665603; // FNV-1a
    for b in app.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(1099511628211);
    }
    // map hash to {-2,-1,0,+1,+2}
    let delta = (h % 5) as i64 - 2;
    ((count + delta).max(0), true)
}

/// Project the raw activity summary down to the allowlist schema. This is the
/// privacy boundary: no window titles, no OCR text, no per-frame detail leaves
/// this function. Sensitive apps/windows are dropped entirely.
fn sanitize(summary: &ActivitySummaryResponse) -> (Vec<CascadePrivacyAggregate>, u32) {
    use std::collections::BTreeMap;
    let mut excluded = 0u32;
    let mut by_app: BTreeMap<String, (f64, i64)> = BTreeMap::new();

    if !summary.windows.is_empty() {
        // Window-level is the most precise source: lets us drop private-browsing
        // windows even when the parent app is otherwise allowed.
        for w in &summary.windows {
            if is_sensitive(&w.app_name) || is_sensitive(&w.window_name) {
                excluded += 1;
                continue;
            }
            let entry = by_app.entry(w.app_name.clone()).or_insert((0.0, 0));
            entry.0 += w.minutes;
            entry.1 += 1; // each distinct window contributes one context switch
        }
    } else {
        for a in &summary.apps {
            if is_sensitive(&a.name) {
                excluded += 1;
                continue;
            }
            by_app.entry(a.name.clone()).or_insert((0.0, 0)).0 += a.minutes;
        }
    }

    let mut aggregates: Vec<CascadePrivacyAggregate> = by_app
        .into_iter()
        .filter(|(_, (minutes, _))| *minutes >= 0.5)
        .map(|(app, (minutes, switches))| {
            let (noised_switches, noised) = dp_jitter(&app, switches);
            CascadePrivacyAggregate {
                category: classify_app(&app).to_string(),
                app,
                duration_min: (minutes * 10.0).round() / 10.0,
                context_switches: noised_switches,
                noised,
            }
        })
        .collect();
    aggregates.sort_by(|a, b| cmp_f64_desc(a.duration_min, b.duration_min));
    (aggregates, excluded)
}

/// Run the privacy aggregator over the recent window, persist the sanitized
/// snapshot, and write a previewable outbox the employee can inspect before it
/// is ever read by a downstream agent.
#[tauri::command]
#[specta::specta]
pub async fn cascade_run_privacy_aggregation(
    app: tauri::AppHandle,
    hours: Option<u32>,
) -> Result<CascadePrivacyReport, String> {
    let hours = hours.unwrap_or(8).clamp(1, 24);
    let (window_start, window_end, summary) = fetch_activity_summary(&app, hours).await?;

    let (aggregates, excluded_count) = if summary.data_status == "ok" && summary.total_frames > 0 {
        sanitize(&summary)
    } else {
        (Vec::new(), 0)
    };

    // Persist to the single-writer aggregate table.
    let pool = cascade_pool(&app).await?;
    let rows: Vec<PrivacyAggregateInput> = aggregates
        .iter()
        .map(|a| PrivacyAggregateInput {
            app: a.app.clone(),
            category: a.category.clone(),
            duration_min: a.duration_min,
            context_switches: a.context_switches,
            noised: a.noised,
        })
        .collect();
    replace_privacy_aggregates(&pool, &window_start, &window_end, &rows)
        .await
        .map_err(|e| format!("store privacy aggregates: {e}"))?;

    let mut report = CascadePrivacyReport {
        generated_at: Utc::now().to_rfc3339(),
        window_start,
        window_end,
        hours_analyzed: hours,
        aggregates,
        excluded_count,
        shared_fields: vec![
            "app".into(),
            "category".into(),
            "durationMin".into(),
            "contextSwitches".into(),
        ],
        outbox_path: String::new(),
    };
    report.outbox_path = write_json_outbox(&app, PRIVACY_OUTBOX_DIR, &report)?;
    Ok(report)
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_list_privacy_aggregates(
    app: tauri::AppHandle,
    window_start: String,
    window_end: String,
) -> Result<Vec<CascadePrivacyAggregate>, String> {
    let pool = cascade_pool(&app).await?;
    let records = list_privacy_aggregates(&pool, &window_start, &window_end)
        .await
        .map_err(|e| format!("list privacy aggregates: {e}"))?;
    Ok(records
        .into_iter()
        .map(|r| CascadePrivacyAggregate {
            app: r.app,
            category: r.category,
            duration_min: r.duration_min,
            context_switches: r.context_switches,
            noised: r.noised,
        })
        .collect())
}

// ════════════════════════════════════════════════════════════════════
// Agent #2 — Waste Detector (LLM, reads ONLY aggregator output)
// ════════════════════════════════════════════════════════════════════

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
    pub tier: String,
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
    pub model: String,
    pub cost_usd: f64,
    pub outbox_path: String,
    pub suggestions: Vec<CascadeManagerSuggestion>,
}

// Shape the detector model must return.
#[derive(Debug, Deserialize)]
struct DetectorOutput {
    suggestions: Vec<DetectorSuggestion>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DetectorSuggestion {
    #[serde(default, deserialize_with = "de_null_string")]
    kind: String,
    #[serde(default, deserialize_with = "de_null_string")]
    title: String,
    #[serde(default, deserialize_with = "de_null_string")]
    summary: String,
    #[serde(default = "default_tier", deserialize_with = "de_null_string")]
    tier: String,
    #[serde(default, deserialize_with = "de_null_string")]
    suggested_agent_kind: String,
    #[serde(default, deserialize_with = "de_null_string")]
    suggested_agent_purpose: String,
    #[serde(default, deserialize_with = "de_null_f64")]
    severity_score: f64,
    #[serde(default, deserialize_with = "de_null_f64")]
    confidence: f64,
    #[serde(default)]
    evidence: Vec<CascadeManagerEvidence>,
}
fn default_tier() -> String {
    "suggest".to_string()
}

/// Models sometimes emit `null` for a string/number/bool field. Coerce null (and a
/// missing key) to the type's default rather than failing the whole parse.
fn de_null_string<'de, D>(d: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(Option::<String>::deserialize(d)?.unwrap_or_default())
}
fn de_null_f64<'de, D>(d: D) -> Result<f64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(Option::<f64>::deserialize(d)?.unwrap_or(0.0))
}
fn de_null_bool<'de, D>(d: D) -> Result<bool, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(Option::<bool>::deserialize(d)?.unwrap_or(false))
}

fn detector_system_prompt() -> String {
    // No preset pattern/agent taxonomy. The detector reads the ACTUAL on-screen
    // content from the Rewind recording and names whatever recurring toil it can
    // literally see, proposing a bespoke agent for exactly that.
    "You are Cascade's Waste Detector. You are given a chronological digest of what the employee \
actually did on screen over a recent window — window titles and on-screen text (OCR) from the Rewind \
recording. Sensitive apps (banking, health, legal, dating, private browsing) were already removed.\n\n\
From this REAL activity, find SPECIFIC, RECURRING things this person does that a software agent could \
take off their plate — concrete repetitive workflows you can SEE in the content (e.g. \"rewrites the \
same standup recap each morning from terminal history\", \"copies figures from a sheet into a doc\"), \
NOT personality judgments and NOT forced into preset categories. Distinguish genuine TOIL (repetitive, \
mechanical, low-judgment) from normal creative/deep work — only the former should become an agent. \
For each finding, propose a BESPOKE helper agent built for exactly that task.\n\n\
HARD RULES:\n\
- Surface at most 6 findings. Fewer is better; only flag what the content clearly supports.\n\
- Only surface a workflow if it looks likely to recur as part of the person's ongoing routine, queue, or schedule. \
If it looks one-off, exploratory, or like troubleshooting, omit it.\n\
- Only surface work that a constrained browser/background agent could actually execute using the same sites, \
apps, and steps visible in the recording. If you cannot describe a concrete agent action path, omit it.\n\
- `kind`: a short kebab-case slug YOU invent naming the observed behavior. Do NOT use a fixed list.\n\
- `suggestedAgentKind`: a short kebab-case slug for the bespoke agent you'd build (e.g. \
\"daily-standup-drafter\"). Invent it to fit the finding.\n\
- `suggestedAgentPurpose`: ONE plain sentence — what the agent would actually DO to remove this \
specific toil, and in which app the employee already does it. It must read like a task the agent can repeatedly run.\n\
- `tier`: info | suggest | urgent. Reserve `urgent` for clear, costly, frequent toil.\n\
- Never use evaluative language about the person (\"unfocused\", \"wasted time\"). Describe the workflow only.\n\
- `evidence` items must quote/cite what you actually saw (app, window, or a short snippet). No invented facts.\n\
- severityScore and confidence are floats 0..1.\n\n\
Return ONLY JSON: {\"suggestions\":[{\"kind\":...,\"title\":...,\"summary\":...,\"tier\":...,\
\"suggestedAgentKind\":...,\"suggestedAgentPurpose\":...,\"severityScore\":0.0,\"confidence\":0.0,\
\"evidence\":[{\"label\":...,\"value\":...}]}]}"
        .to_string()
}

fn detector_user_prompt(digest: &str, hours: u32, frames: usize, excluded_count: u32) -> String {
    format!(
        "Recorded window: last {hours} hours ({frames} screens analyzed, {excluded_count} sensitive \
screens excluded before you saw anything).\n\n\
WHAT THE EMPLOYEE DID ON SCREEN (chronological — [time] App — Window, then on-screen text):\n{digest}\n\n\
Surface the recurring, automatable workflows this REAL activity shows."
    )
}

fn slugify_kind(raw: &str) -> String {
    let slug = raw
        .trim()
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect::<String>();
    let slug = slug.trim_matches('-').to_string();
    if slug.is_empty() {
        "automatable-task".to_string()
    } else {
        slug.chars().take(60).collect()
    }
}

fn normalize_suggestion(s: DetectorSuggestion) -> CascadeManagerSuggestion {
    // No taxonomy clamp — the kind/agent are whatever the detector named for
    // this specific person. We only sanitize the slug shape + bound the scores,
    // and surface the proposed automation as the first evidence row.
    let tier = match s.tier.as_str() {
        "info" | "suggest" | "urgent" => s.tier,
        _ => "suggest".to_string(),
    };
    let mut evidence = Vec::new();
    if !s.suggested_agent_purpose.trim().is_empty() {
        evidence.push(CascadeManagerEvidence {
            label: "proposed automation".to_string(),
            value: sanitize_detector_text(s.suggested_agent_purpose.trim(), 220),
        });
    }
    evidence.extend(sanitize_detector_evidence(s.evidence));
    CascadeManagerSuggestion {
        id: None,
        kind: slugify_kind(&s.kind),
        title: sanitize_detector_text(&s.title, 120),
        summary: sanitize_detector_text(&s.summary, 240),
        tier,
        evidence,
        suggested_agent_kind: slugify_kind(&s.suggested_agent_kind),
        severity_score: s.severity_score.clamp(0.0, 1.0),
        confidence: s.confidence.clamp(0.0, 1.0),
        status: "pending".to_string(),
        created_at: None,
    }
}

/// How the detector grounds each surfaced suggestion. The manual command grounds
/// PER suggestion against the live Rewind; the scheduled detector grounds against
/// a single WorkflowGrounding merged from the stored daily summaries, so it never
/// re-reads raw frames.
enum GroundingMode<'a> {
    LivePerSuggestion { hours: u32, max_frames: u32 },
    Fixed(&'a WorkflowGrounding),
}

/// Run the waste-detector model over a prepared user prompt and return normalized
/// suggestions (not yet grounded/filtered/persisted) plus token usage. The system
/// prompt is shared; only the user prompt differs (live window vs cross-day).
async fn run_detector_llm(
    user_prompt: String,
) -> Result<(Vec<CascadeManagerSuggestion>, LlmResult), String> {
    let call = LlmCall {
        model: MODEL_OPUS,
        system: detector_system_prompt(),
        user: user_prompt,
        temperature: 0.2,
        max_tokens: 2000,
    };
    let (output, usage) = call_anthropic_json::<DetectorOutput>(&call).await?;
    let normalized = output
        .suggestions
        .into_iter()
        .map(normalize_suggestion)
        .collect();
    Ok((normalized, usage))
}

/// Ground, filter, rank, and cap a batch of normalized suggestions. Shared by the
/// manual command and the scheduled detector — only the grounding source differs.
async fn assemble_suggestions(
    app: &tauri::AppHandle,
    raw: Vec<CascadeManagerSuggestion>,
    mode: GroundingMode<'_>,
) -> Vec<CascadeManagerSuggestion> {
    let mut out = Vec::new();
    for mut suggestion in raw {
        let grounding = match &mode {
            GroundingMode::LivePerSuggestion { hours, max_frames } => {
                let query = format!("{} {}", suggestion.title, suggestion.summary);
                fetch_rewind_grounding(app, *hours, &query, *max_frames)
                    .await
                    .unwrap_or_default()
            }
            GroundingMode::Fixed(g) => (*g).clone(),
        };
        if !should_keep_manager_suggestion(&suggestion, &grounding) {
            continue;
        }
        add_grounding_evidence(&mut suggestion, &grounding);
        suggestion.evidence = sanitize_detector_evidence(suggestion.evidence);
        out.push(suggestion);
    }
    out.sort_by(|a, b| {
        cmp_f64_desc(a.severity_score, b.severity_score)
            .then_with(|| cmp_f64_desc(a.confidence, b.confidence))
    });
    out.truncate(6);
    out
}

/// Agent #2. Runs the privacy aggregator (#5) first, then asks Opus to surface
/// patterns over the sanitized output only. Persists suggestions + the run.
#[tauri::command]
#[specta::specta]
pub async fn cascade_generate_manager_suggestions(
    app: tauri::AppHandle,
    hours: Option<u32>,
) -> Result<CascadeManagerSuggestionBatch, String> {
    require_anthropic_key_for("generating manager suggestions")?;
    let hours = hours.unwrap_or(8).clamp(1, 24);

    // Surface the Cascade floating box while detection runs so it's visible the
    // moment the manager clicks "Refresh signals". Uses spec_id -1 (the detector).
    #[cfg(target_os = "macos")]
    crate::cascade_computer::box_begin(
        &app,
        -1,
        "Cascade Detector",
        "Reading your Rewind recording",
    );

    // Read the Rewind: what the employee ACTUALLY did on screen (window titles +
    // OCR), sensitive apps dropped. This is the detector's real input now.
    let (mut digest, frames, excluded) = fetch_rewind_digest(&app, hours, 400).await?;
    // Add the employee's ACTUAL recorded steps (clicks/typing/app switches) so the
    // detector grounds its proposal in the real workflow and the generated spec
    // carries that step sequence for the agent to later follow. General: whatever
    // `ui_events` recorded, no per-app handling.
    if let Ok(steps) = fetch_rewind_steps(&app, hours, 400, false).await {
        if !steps.trim().is_empty() {
            digest.push_str(&format!(
                "\n\nRECORDED STEPS THE EMPLOYEE TOOK (clicks/typing/app switches, in order):\n{steps}"
            ));
        }
    }
    // Keep the privacy aggregates table fresh for the dashboards (non-fatal).
    let (window_start, window_end) =
        match cascade_run_privacy_aggregation(app.clone(), Some(hours)).await {
            Ok(r) => (r.window_start, r.window_end),
            Err(_) => {
                let end = Utc::now();
                (
                    (end - Duration::hours(hours as i64)).to_rfc3339(),
                    end.to_rfc3339(),
                )
            }
        };

    #[cfg(target_os = "macos")]
    crate::cascade_computer::box_step(
        &app,
        -1,
        "Cascade Detector",
        "Rewind",
        &format!("Read {frames} screens from your recording — finding repetitive work…"),
        1,
    );

    let mut batch = CascadeManagerSuggestionBatch {
        generated_at: Utc::now().to_rfc3339(),
        window_start: window_start.clone(),
        window_end: window_end.clone(),
        hours_analyzed: hours,
        delivery_mode: "local_outbox".to_string(),
        model: MODEL_OPUS.to_string(),
        cost_usd: 0.0,
        outbox_path: String::new(),
        suggestions: Vec::new(),
    };

    if digest.trim().is_empty() {
        batch.outbox_path = write_json_outbox(&app, MANAGER_OUTBOX_DIR, &batch)?;
        #[cfg(target_os = "macos")]
        crate::cascade_computer::box_end(
            &app,
            -1,
            "Cascade Detector",
            "Detection",
            "Nothing recorded to analyze yet — let the Rewind capture some work first.",
        );
        return Ok(batch);
    }

    let (normalized, usage) =
        run_detector_llm(detector_user_prompt(&digest, hours, frames, excluded)).await?;
    batch.cost_usd = usage.cost_usd;
    let mut suggestions = assemble_suggestions(
        &app,
        normalized,
        GroundingMode::LivePerSuggestion {
            hours,
            max_frames: 250,
        },
    )
    .await;

    // Persist run + suggestions.
    let pool = cascade_pool(&app).await?;
    let run_id = create_detection_run(
        &pool,
        DETECTOR_NAME,
        &window_start,
        &window_end,
        &serde_json::json!({
            "model": MODEL_OPUS,
            "framesAnalyzed": frames,
            "excludedCount": excluded,
            "suggestionCount": suggestions.len(),
            "costUsd": usage.cost_usd,
        })
        .to_string(),
    )
    .await
    .map_err(|e| format!("create detection run: {e}"))?;

    for s in suggestions.iter_mut() {
        // Fold the tier into evidence so it survives without a schema change.
        let mut evidence = vec![CascadeManagerEvidence {
            label: "tier".to_string(),
            value: s.tier.clone(),
        }];
        evidence.extend(s.evidence.clone());
        let id = insert_manager_suggestion(
            &pool,
            run_id,
            &ManagerSuggestionInput {
                kind: s.kind.clone(),
                title: s.title.clone(),
                summary: s.summary.clone(),
                evidence_json: serde_json::to_string(&evidence)
                    .map_err(|e| format!("serialize evidence: {e}"))?,
                suggested_agent_kind: s.suggested_agent_kind.clone(),
                severity_score: s.severity_score,
                confidence: s.confidence,
            },
        )
        .await
        .map_err(|e| format!("insert suggestion: {e}"))?;
        s.id = Some(id);
        s.created_at = Some(Utc::now().to_rfc3339());
        s.evidence = evidence;
    }

    #[cfg(target_os = "macos")]
    crate::cascade_computer::box_end(
        &app,
        -1,
        "Cascade Detector",
        "Detection",
        &format!(
            "Found {} pattern(s) to review in Manager.",
            suggestions.len()
        ),
    );

    batch.suggestions = suggestions;
    batch.outbox_path = write_json_outbox(&app, MANAGER_OUTBOX_DIR, &batch)?;
    Ok(batch)
}

// ── Stage A · daily Rewind summarizer ("the Rewind agent") ──────────────────
// Once per day, draft a COMPACT, workflow-focused summary of that day from the
// Rewind and store ONE row per day. These compact rows — not 72h of raw frames —
// are what the scheduled detector reads for cross-day consistency.

const DETECTOR_NAME_SCHEDULED: &str = "cascade-waste-detector-scheduled-v1";

fn summarizer_system_prompt() -> String {
    "You are Cascade's Rewind summarizer. You are given a chronological digest of \
what ONE employee did on screen during a SINGLE day — window titles and on-screen \
text (OCR) from the Rewind recording; sensitive apps were already removed. Write a \
COMPACT factual summary (at most ~180 words) of what they actually worked on that \
day, focused on RECURRING, concrete workflows and the specific apps/sites/steps \
involved — the kind of repeatable task an agent could later take over. Plain prose, \
no headings, no preamble. Never evaluate the person (\"unfocused\", \"wasted time\"); \
describe the work only. If little happened, say so in one line."
        .to_string()
}

fn summarizer_user_prompt(day: &str, digest: &str, used: usize, excluded: u32) -> String {
    format!(
        "Day: {day} ({used} screens summarized, {excluded} sensitive screens excluded).\n\n\
WHAT THE EMPLOYEE DID ON SCREEN (chronological — [time] App — Window, then OCR text):\n{digest}\n\n\
Write the compact daily workflow summary."
    )
}

/// Local calendar day → [start, end) as UTC instants.
fn local_day_bounds(date: NaiveDate) -> (DateTime<Utc>, DateTime<Utc>) {
    let to_utc = |n: chrono::NaiveDateTime| {
        Local
            .from_local_datetime(&n)
            .earliest()
            .map(|dt| dt.with_timezone(&Utc))
            .unwrap_or_else(|| Utc.from_utc_datetime(&n))
    };
    let start = date.and_hms_opt(0, 0, 0).unwrap();
    let end = date
        .succ_opt()
        .unwrap_or(date)
        .and_hms_opt(0, 0, 0)
        .unwrap();
    (to_utc(start), to_utc(end))
}

/// Age in hours of a SQLite `CURRENT_TIMESTAMP` ('YYYY-MM-DD HH:MM:SS', UTC) or an
/// rfc3339 string. None if unparseable.
fn sqlite_ts_age_hours(ts: &str) -> Option<f64> {
    let naive = chrono::NaiveDateTime::parse_from_str(ts, "%Y-%m-%d %H:%M:%S")
        .ok()
        .or_else(|| DateTime::parse_from_rfc3339(ts).ok().map(|d| d.naive_utc()))?;
    let then = Utc.from_utc_datetime(&naive);
    Some((Utc::now() - then).num_seconds() as f64 / 3600.0)
}

/// Draft (or re-draft) the compact summary for one local calendar `date`.
async fn draft_daily_summary(app: &tauri::AppHandle, date: NaiveDate) -> Result<(), String> {
    let (start, end) = local_day_bounds(date);
    let frames = fetch_rewind_frames_range(app, start, end, 600).await?;
    if frames.is_empty() {
        return Ok(()); // nothing recorded for this day — don't store an empty row
    }
    let (digest, used, excluded) = build_digest_from_frames(&frames);
    if digest.trim().is_empty() {
        return Ok(());
    }
    let grounding = derive_rewind_grounding(&frames, "");
    let day = date.format("%Y-%m-%d").to_string();

    let call = LlmCall {
        model: MODEL_OPUS,
        system: summarizer_system_prompt(),
        user: summarizer_user_prompt(&day, &digest, used, excluded),
        temperature: 0.2,
        max_tokens: 700,
    };
    let summary_text = call_anthropic(&call).await?.text.trim().to_string();
    if summary_text.is_empty() {
        return Ok(());
    }
    let grounding_json = serde_json::to_string(&grounding).unwrap_or_else(|_| "{}".to_string());
    let apps_json =
        serde_json::to_string(&grounding.observed_apps).unwrap_or_else(|_| "[]".to_string());

    let pool = cascade_pool(app).await?;
    upsert_daily_summary(&pool, &day, &summary_text, &grounding_json, &apps_json)
        .await
        .map_err(|e| format!("upsert daily summary: {e}"))?;
    eprintln!("[cascade-rewind] drafted daily summary for {day} ({used} screens)");
    Ok(())
}

// ── Stage B · scheduled consistency detector ────────────────────────────────

fn scheduled_detector_user_prompt(digest: &str, days: usize) -> String {
    format!(
        "Below are compact day-by-day summaries of what the employee did over the last {days} day(s), \
each drafted from the Rewind. Every '=== <date> ===' block is one day.\n\n{digest}\n\n\
Surface ONLY workflows that recur CONSISTENTLY ACROSS MULTIPLE DAYS — the repetitive toil this person \
does day after day that a constrained agent could take over using the same apps/sites. Ignore anything \
that appears on only a single day or looks one-off."
    )
}

/// Union one day's grounding into the running merged grounding. Stage B grounds
/// every suggestion from the stored summaries' grounding, never re-reading frames.
fn merge_groundings(into: &mut WorkflowGrounding, from: &WorkflowGrounding) {
    if from.execution_mode == "browser" {
        into.execution_mode = "browser".to_string();
    }
    if into.primary_url.trim().is_empty() {
        into.primary_url = from.primary_url.clone();
    }
    if into.completion_pattern.trim().is_empty() {
        into.completion_pattern = from.completion_pattern.clone();
    }
    for h in &from.target_hosts {
        if !into.target_hosts.iter().any(|e| e.eq_ignore_ascii_case(h)) {
            into.target_hosts.push(h.clone());
        }
    }
    for a in &from.observed_apps {
        if !into.observed_apps.iter().any(|e| e.eq_ignore_ascii_case(a)) {
            into.observed_apps.push(a.clone());
        }
    }
    for w in &from.observed_workflow {
        if !into
            .observed_workflow
            .iter()
            .any(|e| e.eq_ignore_ascii_case(w))
        {
            into.observed_workflow.push(w.clone());
        }
    }
}

/// Stage B run: detect patterns consistent across the last 3 daily summaries,
/// dedup against already-surfaced suggestions, insert only genuinely new ones, and
/// notify. Returns the number of NEW suggestions sent to the manager.
pub(crate) async fn run_scheduled_detection(app: &tauri::AppHandle) -> Result<usize, String> {
    let pool = cascade_pool(app).await?;
    let summaries = list_recent_daily_summaries(&pool, 3)
        .await
        .map_err(|e| format!("list daily summaries: {e}"))?;
    if summaries.is_empty() {
        return Ok(0);
    }

    // Oldest-first digest + merged grounding from the stored summaries.
    let mut digest = String::new();
    let mut merged = WorkflowGrounding::default();
    for s in summaries.iter().rev() {
        digest.push_str(&format!("=== {} ===\n{}\n\n", s.day, s.summary_text.trim()));
        if let Ok(g) = serde_json::from_str::<WorkflowGrounding>(&s.grounding_json) {
            merge_groundings(&mut merged, &g);
        }
    }
    let digest = digest.trim().to_string();
    if digest.is_empty() {
        return Ok(0);
    }

    let (normalized, _usage) =
        run_detector_llm(scheduled_detector_user_prompt(&digest, summaries.len())).await?;
    let detected = assemble_suggestions(app, normalized, GroundingMode::Fixed(&merged)).await;
    if detected.is_empty() {
        return Ok(0);
    }

    // Dedup against existing suggestions (any status) by kind / agent-kind slug, so
    // the same consistent pattern is surfaced and notified ONCE, not every cycle.
    let existing = cascade_list_manager_suggestions(app.clone(), None, Some(100))
        .await
        .unwrap_or_default();
    let existing_keys: HashSet<String> = existing
        .iter()
        .flat_map(|s| [s.kind.clone(), s.suggested_agent_kind.clone()])
        .collect();
    let fresh: Vec<CascadeManagerSuggestion> = detected
        .into_iter()
        .filter(|s| {
            !existing_keys.contains(&s.kind) && !existing_keys.contains(&s.suggested_agent_kind)
        })
        .collect();
    if fresh.is_empty() {
        return Ok(0);
    }

    let now = Utc::now().to_rfc3339();
    let window_start = summaries
        .last()
        .map(|s| s.day.clone())
        .unwrap_or_else(|| now.clone());
    let run_id = create_detection_run(
        &pool,
        DETECTOR_NAME_SCHEDULED,
        &window_start,
        &now,
        &serde_json::json!({ "scheduled": true, "days": summaries.len(), "new": fresh.len() })
            .to_string(),
    )
    .await
    .map_err(|e| format!("create detection run: {e}"))?;

    let count = fresh.len();
    for s in &fresh {
        let mut evidence = vec![CascadeManagerEvidence {
            label: "tier".to_string(),
            value: s.tier.clone(),
        }];
        evidence.extend(s.evidence.clone());
        insert_manager_suggestion(
            &pool,
            run_id,
            &ManagerSuggestionInput {
                kind: s.kind.clone(),
                title: s.title.clone(),
                summary: s.summary.clone(),
                evidence_json: serde_json::to_string(&evidence)
                    .unwrap_or_else(|_| "[]".to_string()),
                suggested_agent_kind: s.suggested_agent_kind.clone(),
                severity_score: s.severity_score,
                confidence: s.confidence,
            },
        )
        .await
        .map_err(|e| format!("insert suggestion: {e}"))?;
    }

    fire_notification(
        "Cascade found repetitive work",
        &format!("{count} new pattern(s) ready to review in Manager"),
    );
    eprintln!("[cascade-agent] scheduled detection surfaced {count} new pattern(s)");
    Ok(count)
}

// ── Scheduler · daily summary + 4h detector, key-gated, restart-safe ─────────

/// Ensure the last 3 local days have a daily summary: past days are drafted once
/// and frozen; "today" is re-drafted when its summary is older than ~4h.
async fn ensure_daily_summaries(app: &tauri::AppHandle) -> Result<(), String> {
    let pool = cascade_pool(app).await?;
    let recent = list_recent_daily_summaries(&pool, 6)
        .await
        .map_err(|e| format!("list daily summaries: {e}"))?;
    let by_day: HashMap<String, String> =
        recent.into_iter().map(|r| (r.day, r.updated_at)).collect();

    let today = Local::now().date_naive();
    for back in 0..3i64 {
        let date = today - Duration::days(back);
        let day = date.format("%Y-%m-%d").to_string();
        let need = match by_day.get(&day) {
            None => true,
            Some(updated) => {
                back == 0
                    && sqlite_ts_age_hours(updated)
                        .map(|h| h > 4.0)
                        .unwrap_or(true)
            }
        };
        if need {
            if let Err(e) = draft_daily_summary(app, date).await {
                eprintln!("[cascade-rewind] draft daily summary {day} failed: {e}");
            }
        }
    }
    Ok(())
}

/// Whether the 4h detector should run now: ≥4h since the last detection AND a daily
/// summary has been (re)drafted since then (else nothing new to look at).
async fn should_run_scheduled_detection(app: &tauri::AppHandle) -> Result<bool, String> {
    let pool = cascade_pool(app).await?;
    let Some(last_sum) = last_daily_summary_at(&pool)
        .await
        .map_err(|e| format!("last summary: {e}"))?
    else {
        return Ok(false); // nothing to detect over yet
    };
    match last_detection_run_at(&pool)
        .await
        .map_err(|e| format!("last detection: {e}"))?
    {
        None => Ok(true),
        Some(det) => {
            let age_ok = sqlite_ts_age_hours(&det).map(|h| h >= 4.0).unwrap_or(true);
            Ok(age_ok && last_sum.as_str() > det.as_str())
        }
    }
}

/// Spawn the always-on background loop: daily Rewind summaries + the 4h consistency
/// detector. Key-gated (idle without an Anthropic key) and restart-safe (cadence is
/// computed from DB timestamps, not in-memory timers). Called once from setup().
pub fn spawn_background_schedulers(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        // Let the app + recording server settle before the first tick.
        tokio::time::sleep(std::time::Duration::from_secs(90)).await;
        loop {
            if crate::cascade_llm::read_anthropic_key().is_ok() {
                if let Err(e) = ensure_daily_summaries(&app).await {
                    eprintln!("[cascade-agent] daily summary tick failed: {e}");
                }
                match should_run_scheduled_detection(&app).await {
                    Ok(true) => {
                        if let Err(e) = run_scheduled_detection(&app).await {
                            eprintln!("[cascade-agent] scheduled detection failed: {e}");
                        }
                    }
                    Ok(false) => {}
                    Err(e) => eprintln!("[cascade-agent] detection gate failed: {e}"),
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(1800)).await; // 30 min
        }
    });
}

fn parse_evidence(json: &str) -> Vec<CascadeManagerEvidence> {
    serde_json::from_str(json).unwrap_or_default()
}

fn tier_from_evidence(evidence: &[CascadeManagerEvidence]) -> String {
    evidence
        .iter()
        .find(|e| e.label == "tier")
        .map(|e| e.value.clone())
        .unwrap_or_else(|| "suggest".to_string())
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

    Ok(records
        .into_iter()
        .map(|record| {
            let evidence = parse_evidence(&record.evidence_json);
            CascadeManagerSuggestion {
                tier: tier_from_evidence(&evidence),
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
            }
        })
        .collect())
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

// ════════════════════════════════════════════════════════════════════
// Agent #3 — Agent Generator (LLM, produces a typed reviewable spec)
// ════════════════════════════════════════════════════════════════════

/// Capabilities a generated agent may declare. Deliberately VENDOR-NEUTRAL —
/// the agent does whatever work the detected pattern calls for (a recap, a
/// digest, a focus plan, a status draft, a reminder…), not a fixed
/// "send a Slack/Gmail message". Each maps to a real on-device implementation
/// in the runtime (see `execute_tool`). Anything off this list — especially
/// shell/exec — is rejected at validation time.
const TOOL_WHITELIST: &[&str] = &[
    "read.activity",    // read the employee's recent sanitized activity (input)
    "analyze.patterns", // LLM reasoning over the inputs
    "summarize.text",   // LLM summary / recap content
    "browser.use",      // work inside the same website/tool the employee used
    "artifact.write",   // write a real deliverable document (recap/digest/plan/checklist)
    "draft.message",    // draft a message the employee can review + send themselves
    "task.create",      // create a task/checklist item as a real artifact
    "reminder.set",     // set a reminder as a real artifact
    "notify.local",     // a real macOS notification to the employee
];

/// Capabilities that produce an outward-facing / committing work product →
/// supervised (require employee approval) on an agent's first 3 live runs.
/// Pure analysis, reads, and local notifications auto-run.
const MUTATING_TOOLS: &[&str] = &[
    "artifact.write",
    "draft.message",
    "task.create",
    "reminder.set",
];

const MAX_PER_EXEC_COST_USD: f64 = 0.10;

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct RequiredInput {
    #[serde(default, deserialize_with = "de_null_string")]
    pub source: String,
    #[serde(default)]
    pub fields: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowStep {
    #[serde(default)]
    pub step: i64,
    #[serde(default, deserialize_with = "de_null_string")]
    pub action: String,
    /// Which capability this step invokes at runtime (from the whitelist), or
    /// null for a pure reasoning/decision step whose output feeds later steps.
    #[serde(default)]
    pub tool: Option<String>,
    #[serde(default)]
    pub decision_point: Option<String>,
    #[serde(default)]
    pub approval_required: bool,
}

fn default_execution_mode() -> String {
    "background".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AgentSpecDoc {
    #[serde(default, deserialize_with = "de_null_string")]
    pub name: String,
    #[serde(default, deserialize_with = "de_null_string")]
    pub task_description: String,
    #[serde(default, deserialize_with = "de_null_string")]
    pub rationale: String,
    #[serde(
        default = "default_execution_mode",
        deserialize_with = "de_null_string"
    )]
    pub execution_mode: String,
    #[serde(default, deserialize_with = "de_null_string")]
    pub target_url: String,
    #[serde(default)]
    pub target_hosts: Vec<String>,
    #[serde(default)]
    pub observed_apps: Vec<String>,
    #[serde(default)]
    pub observed_workflow: Vec<String>,
    #[serde(default, deserialize_with = "de_null_string")]
    pub completion_pattern: String,
    #[serde(default)]
    pub required_inputs: Vec<RequiredInput>,
    #[serde(default)]
    pub workflow: Vec<WorkflowStep>,
    #[serde(default)]
    pub tools: Vec<String>,
    #[serde(default)]
    pub failure_conditions: Vec<String>,
    #[serde(default)]
    pub approval_points: Vec<String>,
    #[serde(default, deserialize_with = "de_null_string")]
    pub rollback_path: String,
    #[serde(default, deserialize_with = "de_null_f64")]
    pub estimated_cost_usd: f64,
    #[serde(default, deserialize_with = "de_null_f64")]
    pub estimated_time_saved_min: f64,
    /// How often the deployed agent should run itself, in minutes. The runtime
    /// clamps to >= 60. Default daily when the model omits it.
    #[serde(default = "default_schedule_minutes")]
    pub schedule_minutes: i64,
}

fn default_schedule_minutes() -> i64 {
    1440
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CascadeAgentSpecView {
    pub id: i64,
    pub suggestion_id: i64,
    pub name: String,
    pub status: String,
    pub validation_status: String,
    pub validation_notes: Option<String>,
    pub est_cost_usd: f64,
    pub est_time_saved_min: f64,
    pub employee_approved: bool,
    pub manager_approved: bool,
    pub created_at: String,
    pub spec: AgentSpecDoc,
}

fn generator_system_prompt() -> String {
    format!(
        "You are Cascade's Agent Generator. Given a single detected workflow-waste pattern, produce \
ONE deterministic, reviewable agent specification that will ACTUALLY DO WORK to address THAT \
specific pattern. The agent is generic: design whatever real deliverable fits the pattern — a \
meeting recap, a batched-comms digest, a focus plan, a status draft, a reminder. It is NOT \
necessarily a message; do whatever the pattern calls for. The spec is reviewed, sandbox-tested, \
and dual-approved before it runs, then it runs on its own on a schedule.\n\n\
AVAILABLE CAPABILITIES (vendor-neutral; each does real on-device work):\n\
- read.activity — read the employee's recent sanitized activity (the agent's input)\n\
- analyze.patterns — reason over the inputs to decide what to produce\n\
- summarize.text — produce recap/summary content\n\
- browser.use — work inside the SAME website/tool the employee already used, following the observed workflow and target URL/hosts\n\
- artifact.write — write a real deliverable document the employee will use\n\
- draft.message — draft a message the employee can review and send THEMSELVES\n\
- task.create — create a task/checklist item as a real artifact\n\
- reminder.set — set a reminder as a real artifact\n\
- notify.local — send the employee a real notification\n\n\
HARD RULES (a violated rule means the spec is rejected — follow all):\n\
- `tools` may ONLY contain capabilities from the list above. NEVER invent tools. NEVER request shell/exec/network/file-system access.\n\
- EVERY workflow step must set `tool` to one of those capabilities, OR null for a pure reasoning step. The agent does the work BY running these steps in order — make the workflow concrete and runnable, not abstract.\n\
- If the observed workflow clearly happens inside a website/tool the employee already uses, set `executionMode` to `browser`, include at least one `browser.use` step, keep `targetUrl`/`targetHosts` tied to the observed tool, and DO NOT swap in a different app.\n\
- If the work is not tied to interacting with a website/tool, set `executionMode` to `background` and do not use `browser.use`.\n\
- The workflow must be linear or branch only on schema-checkable conditions — never \"the agent decides what to do next\".\n\
- Every step whose tool produces an outward-facing/committing artifact (artifact.write, draft.message, task.create, reminder.set) MUST have approvalRequired=true AND a matching entry in `approvalPoints`.\n\
- `rollbackPath` is REQUIRED — describe how to undo the agent's outputs (delete the artifact, dismiss the reminder).\n\
- `estimatedCostUsd` must be realistic per-execution and SHOULD be <= {:.2}.\n\
- `scheduleMinutes`: how often it should run itself (>= 60). Most agents are daily (1440) or a few times a day.\n\
- `taskDescription` is one plain-English sentence (readable, no jargon).\n\
- `requiredInputs[].source` should reference Cascade data the agent reads, e.g. \"cascade_rewind_digest\", \"cascade_rewind_workflow\", \"cascade_rewind_tools\".\n\n\
Return ONLY JSON with EXACTLY these camelCase keys:\n\
{{\"name\":str,\"taskDescription\":str,\"rationale\":str,\"executionMode\":\"background\"|\"browser\",\
\"targetUrl\":str,\"targetHosts\":[str],\"observedApps\":[str],\"observedWorkflow\":[str],\"completionPattern\":str,\
\"requiredInputs\":[{{\"source\":str,\"fields\":[str]}}],\
\"workflow\":[{{\"step\":int,\"action\":str,\"tool\":str|null,\"decisionPoint\":str|null,\"approvalRequired\":bool}}],\
\"tools\":[str],\"failureConditions\":[str],\"approvalPoints\":[str],\"rollbackPath\":str,\
\"estimatedCostUsd\":number,\"estimatedTimeSavedMin\":number,\"scheduleMinutes\":int}}",
        MAX_PER_EXEC_COST_USD
    )
}

fn generator_user_prompt(s: &CascadeManagerSuggestion, grounding: &WorkflowGrounding) -> String {
    let evidence = s
        .evidence
        .iter()
        .map(|e| format!("- {}: {}", e.label, e.value))
        .collect::<Vec<_>>()
        .join("\n");
    let observed_workflow = if grounding.observed_workflow.is_empty() {
        "(not enough exact steps recovered from Rewind)".to_string()
    } else {
        grounding
            .observed_workflow
            .iter()
            .map(|step| format!("- {step}"))
            .collect::<Vec<_>>()
            .join("\n")
    };
    format!(
        "Observed behavior (kind): {}\nTitle: {}\nWhat the person keeps doing: {}\n\
Proposed bespoke agent slug: {}\nSeverity: {:.2}  Confidence: {:.2}\nSignals:\n{}\n\n\
OBSERVED TOOL GROUNDING FROM THE REWIND:\n\
- execution mode hint: {}\n\
- starting url: {}\n\
- target hosts: {}\n\
- apps used: {}\n\
- how they finished it: {}\n\
- observed workflow:\n{}\n\n\
Design a BESPOKE agent for THIS specific recurring task — not a generic template. Its workflow \
should concretely remove this exact toil using the least intrusive, most reversible steps.",
        s.kind,
        s.title,
        s.summary,
        s.suggested_agent_kind,
        s.severity_score,
        s.confidence,
        evidence,
        grounding.execution_mode,
        if grounding.primary_url.is_empty() {
            "(none recovered)"
        } else {
            &grounding.primary_url
        },
        if grounding.target_hosts.is_empty() {
            "(none recovered)".to_string()
        } else {
            grounding.target_hosts.join(", ")
        },
        if grounding.observed_apps.is_empty() {
            "(none recovered)".to_string()
        } else {
            grounding.observed_apps.join(", ")
        },
        if grounding.completion_pattern.is_empty() {
            "(none recovered)".to_string()
        } else {
            grounding.completion_pattern.clone()
        },
        observed_workflow
    )
}

/// Returns (status, notes). status is "valid" or "invalid".
fn validate_spec(doc: &AgentSpecDoc) -> (String, Option<String>) {
    let mut problems: Vec<String> = Vec::new();
    let execution_mode = doc.execution_mode.trim().to_lowercase();

    if doc.workflow.is_empty() {
        problems.push("workflow is empty".into());
    }
    if doc.rollback_path.trim().is_empty() {
        problems.push("missing rollback path".into());
    }
    if doc.task_description.trim().is_empty() {
        problems.push("missing task description".into());
    }
    if !matches!(execution_mode.as_str(), "background" | "browser") {
        problems.push("executionMode must be `background` or `browser`".into());
    }

    // Tool whitelist + no shell.
    for t in &doc.tools {
        let tl = t.to_lowercase();
        if tl.contains("shell") || tl.contains("exec") || tl.contains("bash") {
            problems.push(format!("forbidden tool: {t}"));
        } else if !TOOL_WHITELIST.contains(&t.as_str()) {
            problems.push(format!("tool not in whitelist: {t}"));
        }
    }

    // Per-step tools must also be whitelisted, and a mutating step must be
    // marked approvalRequired so the runtime's supervision gate engages.
    for step in &doc.workflow {
        if let Some(t) = &step.tool {
            if !TOOL_WHITELIST.contains(&t.as_str()) {
                problems.push(format!("step {} uses non-whitelisted tool: {t}", step.step));
            } else if MUTATING_TOOLS.contains(&t.as_str()) && !step.approval_required {
                problems.push(format!(
                    "step {} produces a committing artifact ({t}) but is not marked approvalRequired",
                    step.step
                ));
            }
        }
    }

    // Mutating tool requires at least one approval point.
    let has_mutating = doc
        .tools
        .iter()
        .any(|t| MUTATING_TOOLS.contains(&t.as_str()))
        || doc.workflow.iter().any(|s| {
            s.tool
                .as_deref()
                .map(|t| MUTATING_TOOLS.contains(&t))
                .unwrap_or(false)
        });
    if has_mutating && doc.approval_points.is_empty() {
        problems.push("state-mutating tools declared but no approval points".into());
    }

    let has_browser_step = doc
        .workflow
        .iter()
        .any(|s| s.tool.as_deref() == Some("browser.use"));
    if execution_mode == "browser" {
        if doc.target_url.trim().is_empty() && doc.target_hosts.is_empty() {
            problems.push("browser execution requires targetUrl or targetHosts".into());
        }
        if let Some(host) = host_from_url(&doc.target_url) {
            if !is_candidate_target_host(&host) {
                problems.push("targetUrl points to search, local, or sensitive host".into());
            }
            if !doc.target_hosts.is_empty() && !host_matches_any(&host, &doc.target_hosts) {
                problems.push("targetUrl host does not match targetHosts".into());
            }
        } else if !doc.target_url.trim().is_empty() {
            problems.push("targetUrl is not a valid URL or host".into());
        }
        for host in &doc.target_hosts {
            if !is_candidate_target_host(host) {
                problems.push(format!(
                    "targetHosts includes search, local, or sensitive host: {host}"
                ));
            }
        }
        if !has_browser_step {
            problems.push("browser execution requires at least one browser.use step".into());
        }
    } else if has_browser_step {
        problems.push("browser.use steps require executionMode=browser".into());
    }

    // Cost cap.
    if doc.estimated_cost_usd > MAX_PER_EXEC_COST_USD {
        problems.push(format!(
            "estimated per-exec cost ${:.3} exceeds cap ${:.2}",
            doc.estimated_cost_usd, MAX_PER_EXEC_COST_USD
        ));
    }

    if problems.is_empty() {
        ("valid".to_string(), None)
    } else {
        ("invalid".to_string(), Some(problems.join("; ")))
    }
}

async fn load_suggestion(
    app: &tauri::AppHandle,
    suggestion_id: i64,
) -> Result<CascadeManagerSuggestion, String> {
    let all = cascade_list_manager_suggestions(app.clone(), None, Some(100)).await?;
    all.into_iter()
        .find(|s| s.id == Some(suggestion_id))
        .ok_or_else(|| format!("suggestion {suggestion_id} not found"))
}

fn spec_view(record: cascade_schema::AgentSpecRecord) -> Result<CascadeAgentSpecView, String> {
    let spec: AgentSpecDoc = serde_json::from_str(&record.spec_json)
        .map_err(|e| format!("parse stored spec {}: {e}", record.id))?;
    Ok(CascadeAgentSpecView {
        id: record.id,
        suggestion_id: record.suggestion_id,
        name: record.name,
        status: record.status,
        validation_status: record.validation_status,
        validation_notes: record.validation_notes,
        est_cost_usd: record.est_cost_usd,
        est_time_saved_min: record.est_time_saved_min,
        employee_approved: record.employee_approved,
        manager_approved: record.manager_approved,
        created_at: record.created_at,
        spec,
    })
}

/// Agent #3. Generate a structured, validated spec for a detected pattern and
/// persist it in `generated` status (Agent #4 owns everything after).
#[tauri::command]
#[specta::specta]
pub async fn cascade_generate_agent_spec(
    app: tauri::AppHandle,
    suggestion_id: i64,
) -> Result<CascadeAgentSpecView, String> {
    require_anthropic_key_for("generating a Cascade agent spec")?;
    let suggestion = load_suggestion(&app, suggestion_id).await?;
    let grounding_query = format!("{} {}", suggestion.title, suggestion.summary);
    let grounding = fetch_rewind_grounding(&app, 24, &grounding_query, 300)
        .await
        .unwrap_or_default();

    let call = LlmCall {
        model: MODEL_OPUS,
        system: generator_system_prompt(),
        user: generator_user_prompt(&suggestion, &grounding),
        temperature: 0.1,
        max_tokens: 2500,
    };
    let (mut doc, _usage) = call_anthropic_json::<AgentSpecDoc>(&call).await?;
    merge_grounding_into_spec(&mut doc, &grounding);
    let (validation_status, validation_notes) = validate_spec(&doc);

    let spec_json = serde_json::to_string(&doc).map_err(|e| format!("serialize spec: {e}"))?;
    let pool = cascade_pool(&app).await?;
    let spec_id = insert_agent_spec(
        &pool,
        &AgentSpecInput {
            suggestion_id,
            name: doc.name.clone(),
            spec_json,
            est_cost_usd: doc.estimated_cost_usd,
            est_time_saved_min: doc.estimated_time_saved_min,
            validation_status: validation_status.clone(),
            validation_notes: validation_notes.clone(),
        },
    )
    .await
    .map_err(|e| format!("insert agent spec: {e}"))?;

    append_audit(
        &pool,
        Some(spec_id),
        None,
        "system",
        "spec_generated",
        &serde_json::json!({ "validation": validation_status, "notes": validation_notes })
            .to_string(),
    )
    .await
    .map_err(|e| format!("audit: {e}"))?;

    let record = get_agent_spec(&pool, spec_id)
        .await
        .map_err(|e| format!("reload spec: {e}"))?
        .ok_or("spec vanished after insert")?;
    spec_view(record)
}

/// Seed a ready-to-run demo agent (already deployed + dual-approved) so the
/// deployment lifecycle, "Run now", "Watch it work", and the live floating box
/// can be tested without waiting for the detector to surface a real pattern.
#[tauri::command]
#[specta::specta]
pub async fn cascade_seed_demo_agent(
    app: tauri::AppHandle,
) -> Result<CascadeAgentSpecView, String> {
    require_anthropic_key_for("generating a demo Cascade agent")?;
    // 1. Get a real suggestion from the Detector (#2). Reuse the latest one if
    //    present, else run detection over the employee's real activity.
    let mut suggestions = cascade_list_manager_suggestions(app.clone(), None, Some(10)).await?;
    if suggestions.is_empty() {
        let batch = cascade_generate_manager_suggestions(app.clone(), Some(8)).await?;
        suggestions = batch.suggestions;
    }

    let suggestion_id = match suggestions.into_iter().find_map(|s| s.id) {
        Some(id) => id,
        None => {
            // Detector surfaced nothing actionable. Seed ONE minimal, real
            // suggestion grounded in the employee's most-used app, so the
            // Generator (#3) still works from genuine activity — not a fixture.
            let pool = cascade_pool(&app).await?;
            let now = Utc::now().to_rfc3339();
            let run_id = create_detection_run(
                &pool,
                "demo-seed-from-activity",
                &now,
                &now,
                "{\"seed\":true}",
            )
            .await
            .map_err(|e| format!("seed detection run: {e}"))?;
            let top_app = preferred_notes_app(&app)
                .await
                .unwrap_or_else(|| "your notes app".to_string());
            let evidence = serde_json::to_string(&vec![CascadeManagerEvidence {
                label: "most-used notes/docs app".to_string(),
                value: top_app.clone(),
            }])
            .unwrap_or_else(|_| "[]".to_string());
            insert_manager_suggestion(
                &pool,
                run_id,
                &ManagerSuggestionInput {
                    kind: slugify_kind(&format!("recurring-notes-in-{top_app}")),
                    title: format!("Recurring note-taking in {top_app}"),
                    summary: format!(
                        "The employee regularly works in {top_app}; a helper could draft recap notes there so they don't have to."
                    ),
                    evidence_json: evidence,
                    suggested_agent_kind: "notes-recap".to_string(),
                    severity_score: 0.55,
                    confidence: 0.8,
                },
            )
            .await
            .map_err(|e| format!("seed suggestion: {e}"))?
        }
    };

    // 2. Generate the spec via the REAL Generator (#3, Opus) — this is the spec
    //    being created by the workflow, not hand-written.
    let spec = cascade_generate_agent_spec(app.clone(), suggestion_id).await?;

    // 3. Deploy it (dual-approved) so it lands in Running and is testable.
    let pool = cascade_pool(&app).await?;
    update_agent_spec_status(&pool, spec.id, "deployed", Some(true), Some(true))
        .await
        .map_err(|e| format!("deploy spec: {e}"))?;
    let _ = update_manager_suggestion_status(&pool, suggestion_id, "deployed").await;
    let _ = append_audit(
        &pool,
        Some(spec.id),
        None,
        "system",
        "deployed_via_workflow",
        "{}",
    )
    .await;

    let record = get_agent_spec(&pool, spec.id)
        .await
        .map_err(|e| format!("reload spec: {e}"))?
        .ok_or("spec vanished")?;
    spec_view(record)
}

/// Seed a daily-recap agent the way the product is meant to work: hand the task
/// to the Waste Detector (#2) as a signal, then let the real Agent Generator (#3)
/// build the spec from it. We do NOT hand-write or deploy the spec — the agent
/// that lands in Review was genuinely CREATED by the pipeline, which is the whole
/// point of this button. The destination is inferred from the employee's recent
/// notes/docs activity instead of being fixed to one vendor.
#[tauri::command]
#[specta::specta]
pub async fn cascade_seed_daily_recap_agent(
    app: tauri::AppHandle,
) -> Result<CascadeAgentSpecView, String> {
    require_anthropic_key_for("generating the daily recap Cascade agent")?;
    let pool = cascade_pool(&app).await?;
    let preferred_notes = preferred_notes_app(&app)
        .await
        .unwrap_or_else(|| "the notes or docs app they already use".to_string());
    let seed_slug = slugify_kind(&format!("daily-recap-in-{preferred_notes}"));

    // 1. Give the info to the Waste Detector (#2): record a detection run and a
    //    suggestion describing the task, exactly as if the detector had surfaced
    //    it from the Rewind. This is the pipeline's real entry point — everything
    //    after here is the standard workflow, nothing hand-built.
    let now = Utc::now().to_rfc3339();
    let run_id = create_detection_run(
        &pool,
        "daily-recap-seed",
        &now,
        &now,
        &serde_json::json!({ "seed": "daily-recap", "preferredNotesApp": preferred_notes })
            .to_string(),
    )
    .await
    .map_err(|e| format!("seed detection run: {e}"))?;
    let evidence = serde_json::to_string(&vec![
        CascadeManagerEvidence {
            label: "what they do".to_string(),
            value: "Reviews the day's work in the Rewind and writes the recap by hand".to_string(),
        },
        CascadeManagerEvidence {
            label: "where the recap should land".to_string(),
            value: preferred_notes.clone(),
        },
    ])
    .unwrap_or_else(|_| "[]".to_string());
    let suggestion_id = insert_manager_suggestion(
        &pool,
        run_id,
        &ManagerSuggestionInput {
            kind: seed_slug,
            title: format!("Daily recap in {preferred_notes}"),
            summary:
                "Look at what the employee did today (from the Rewind) and write it up as a dated \
daily recap in the notes or docs tool they already use, so they don't have to stop and write it themselves."
                    .to_string(),
            evidence_json: evidence,
            suggested_agent_kind: "daily-recap".to_string(),
            severity_score: 0.55,
            confidence: 0.85,
        },
    )
    .await
    .map_err(|e| format!("seed suggestion: {e}"))?;

    // 2. Let the agent handle it from there: run the REAL Generator (#3, Opus) on
    //    that suggestion. It produces the spec (status `generated` → Review stage).
    //    We DON'T deploy — it runs through review → sandbox → approval → deploy →
    //    run on its own, so the full agent-creation workflow is exercised.
    let spec = cascade_generate_agent_spec(app.clone(), suggestion_id).await?;

    let _ = update_manager_suggestion_status(&pool, suggestion_id, "sent").await;
    let _ = append_audit(
        &pool,
        Some(spec.id),
        None,
        "system",
        "seeded_via_detector",
        "{\"seed\":\"daily-recap\"}",
    )
    .await;

    Ok(spec)
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_list_agent_specs(
    app: tauri::AppHandle,
    limit: Option<u32>,
) -> Result<Vec<CascadeAgentSpecView>, String> {
    let pool = cascade_pool(&app).await?;
    let records = list_agent_specs(&pool, limit.unwrap_or(50).clamp(1, 200) as i64)
        .await
        .map_err(|e| format!("list specs: {e}"))?;
    records.into_iter().map(spec_view).collect()
}

// ════════════════════════════════════════════════════════════════════
// Agent #4 — Deployment & Runtime Monitor
// ════════════════════════════════════════════════════════════════════

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SandboxModelOutput {
    #[serde(default, deserialize_with = "de_null_string")]
    status: String,
    #[serde(default, deserialize_with = "de_null_string")]
    summary: String,
    #[serde(default)]
    steps: Vec<SandboxModelStep>,
    #[serde(default, deserialize_with = "de_null_bool")]
    would_mutate: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SandboxStep {
    pub step: i64,
    pub tool: String,
    pub action: String,
    pub mocked_result: String,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SandboxModelStep {
    #[serde(default)]
    step: i64,
    #[serde(default, deserialize_with = "de_null_string")]
    tool: String,
    #[serde(default, deserialize_with = "de_null_string")]
    action: String,
    #[serde(default, deserialize_with = "de_null_string")]
    mocked_result: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Anomaly {
    pub kind: String,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CascadeAgentRun {
    pub id: i64,
    pub spec_id: i64,
    pub mode: String,
    pub status: String,
    pub summary: String,
    pub steps: Vec<SandboxStep>,
    pub anomalies: Vec<Anomaly>,
    pub cost_usd: f64,
    pub duration_ms: i64,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CascadeAuditEntry {
    pub id: i64,
    pub actor: String,
    pub action: String,
    pub detail: String,
    pub created_at: String,
}

fn sandbox_system_prompt() -> String {
    "You are Cascade's sandbox executor (Agent #4). You are given an agent spec plus Rewind-grounded \
context about how the employee actually did this task. Simulate ONE execution to judge whether the agent \
is SAFE and its WORKFLOW is SOUND — NOT whether live data happens to be present right now.\n\n\
ALL external tool calls are MOCKED. Treat each mocked call as SUCCEEDING with PLAUSIBLE, representative \
results for this task: a browse/read step returns the kind of pages/records/items it would realistically \
find, with reasonable example values. Specific live details (URLs, IDs, counts, due dates, exact contents) \
are NOT available in the sandbox and are resolved at real run time — so DO NOT fail the run just because the \
spec, digest, or grounding is missing a target URL, course/record ID, count, or other live value. Assume \
sensible values and continue. Never claim a real email was sent or a real change was made; describe the \
mocked result.\n\n\
Return status \"failed\" ONLY for a genuine spec or SAFETY problem, such as: a step uses a tool the spec did \
NOT declare; the run would make a destructive or irreversible EXTERNAL change (send, delete, post publicly, \
pay, submit, change account/security settings) with no matching approval point; or the declared workflow is \
internally contradictory and cannot work even given good data. A read-only or information-gathering agent \
that merely lacks live data in the mock is status \"success\". Set wouldMutate true only if the run would \
actually change external state.\n\n\
Return ONLY JSON: {\"status\":\"success\"|\"failed\",\"summary\":str,\
\"steps\":[{\"step\":int,\"tool\":str,\"action\":str,\"mockedResult\":str}],\"wouldMutate\":bool}"
        .to_string()
}

fn sandbox_user_prompt(doc: &AgentSpecDoc, rewind: &str, grounding: &WorkflowGrounding) -> String {
    let spec = serde_json::to_string_pretty(doc).unwrap_or_default();
    let workflow = if grounding.observed_workflow.is_empty() {
        "[]".to_string()
    } else {
        serde_json::to_string_pretty(&grounding.observed_workflow)
            .unwrap_or_else(|_| "[]".to_string())
    };
    format!(
        "AGENT SPEC:\n{spec}\n\nREWIND DIGEST (mock input):\n{}\n\nOBSERVED TOOL GROUNDING:\n\
- executionMode: {}\n\
- targetUrl: {}\n\
- targetHosts: {}\n\
- observedApps: {}\n\
- completionPattern: {}\n\
- observedWorkflow: {}\n\n\
Simulate one run. Use only the spec's declared tools.",
        if rewind.trim().is_empty() {
            "(nothing recorded yet)"
        } else {
            rewind
        },
        grounding.execution_mode,
        if grounding.primary_url.is_empty() {
            "(none recovered)"
        } else {
            &grounding.primary_url
        },
        if grounding.target_hosts.is_empty() {
            "[]".to_string()
        } else {
            grounding.target_hosts.join(", ")
        },
        if grounding.observed_apps.is_empty() {
            "[]".to_string()
        } else {
            grounding.observed_apps.join(", ")
        },
        if grounding.completion_pattern.is_empty() {
            "(none recovered)".to_string()
        } else {
            grounding.completion_pattern.clone()
        },
        workflow
    )
}

/// Compare the simulated run against the declared spec to flag scope creep,
/// missing approvals, and over-long executions.
fn detect_anomalies(doc: &AgentSpecDoc, out: &SandboxModelOutput) -> Vec<Anomaly> {
    let mut anomalies = Vec::new();
    let declared: Vec<String> = doc.tools.iter().map(|t| t.to_lowercase()).collect();
    for step in &out.steps {
        let tool = step.tool.trim().to_lowercase();
        if tool.is_empty() {
            continue;
        }
        if !declared.contains(&tool) {
            anomalies.push(Anomaly {
                kind: "scope_creep".to_string(),
                detail: format!("step used undeclared tool '{}'", step.tool),
            });
        }
    }
    if out.would_mutate && doc.approval_points.is_empty() {
        anomalies.push(Anomaly {
            kind: "missing_approval".to_string(),
            detail: "run would mutate external state but spec declares no approval points"
                .to_string(),
        });
    }
    if out.steps.len() as i64 > (doc.workflow.len() as i64) * 3 {
        anomalies.push(Anomaly {
            kind: "excessive_steps".to_string(),
            detail: format!(
                "run produced {} steps vs {} declared workflow steps",
                out.steps.len(),
                doc.workflow.len()
            ),
        });
    }
    anomalies
}

/// Agent #4 sandbox test. Runs the spec against the last 30 days of sanitized
/// aggregates with all tools mocked, detects anomalies, records the run + audit,
/// and advances the spec to sandbox_passed / sandbox_failed.
#[tauri::command]
#[specta::specta]
pub async fn cascade_sandbox_test(
    app: tauri::AppHandle,
    spec_id: i64,
) -> Result<CascadeAgentRun, String> {
    require_anthropic_key_for("running a Cascade sandbox test")?;
    let pool = cascade_pool(&app).await?;
    let record = get_agent_spec(&pool, spec_id)
        .await
        .map_err(|e| format!("load spec: {e}"))?
        .ok_or_else(|| format!("spec {spec_id} not found"))?;
    let doc: AgentSpecDoc =
        serde_json::from_str(&record.spec_json).map_err(|e| format!("parse spec: {e}"))?;

    if record.validation_status != "valid" {
        return Err(format!(
            "spec failed generation-time validation, cannot sandbox: {}",
            record.validation_notes.unwrap_or_default()
        ));
    }

    let rewind = fetch_rewind_digest(&app, 24, 400)
        .await
        .map(|(digest, _, _)| digest)
        .unwrap_or_default();
    let grounding = fetch_rewind_grounding(&app, 24, &doc.task_description, 400)
        .await
        .unwrap_or_default();

    let call = LlmCall {
        model: MODEL_SONNET,
        system: sandbox_system_prompt(),
        user: sandbox_user_prompt(&doc, &rewind, &grounding),
        temperature: 0.0,
        // The sandbox sim emits one mocked step (with a result blurb) per workflow
        // step, so the JSON grows with the spec. 1800 truncated longer specs mid-
        // object → "unbalanced JSON". Give it room for a full multi-step run.
        max_tokens: 4000,
    };
    let (out, usage) = call_anthropic_json::<SandboxModelOutput>(&call).await?;

    let anomalies = detect_anomalies(&doc, &out);
    let steps: Vec<SandboxStep> = out
        .steps
        .iter()
        .enumerate()
        .map(|(i, s)| SandboxStep {
            step: if s.step > 0 { s.step } else { (i + 1) as i64 },
            tool: s.tool.clone(),
            action: s.action.clone(),
            mocked_result: s.mocked_result.clone(),
        })
        .collect();

    let passed = anomalies.is_empty() && out.status == "success";
    let run_status = if !anomalies.is_empty() {
        "flagged"
    } else if out.status == "success" {
        "success"
    } else {
        "failed"
    };

    let run_id = insert_agent_run(
        &pool,
        &AgentRunInput {
            spec_id,
            mode: "sandbox".to_string(),
            status: run_status.to_string(),
            summary: out.summary.clone(),
            steps_json: serde_json::to_string(&steps).unwrap_or_else(|_| "[]".to_string()),
            anomalies_json: serde_json::to_string(&anomalies).unwrap_or_else(|_| "[]".to_string()),
            cost_usd: usage.cost_usd,
            duration_ms: 0,
        },
    )
    .await
    .map_err(|e| format!("insert run: {e}"))?;

    let next_status = if passed {
        "sandbox_passed"
    } else {
        "sandbox_failed"
    };
    update_agent_spec_status(&pool, spec_id, next_status, None, None)
        .await
        .map_err(|e| format!("advance spec: {e}"))?;

    append_audit(
        &pool,
        Some(spec_id),
        Some(run_id),
        "employee",
        "sandbox_test",
        &serde_json::json!({
            "result": next_status,
            "anomalies": anomalies.len(),
            "wouldMutate": out.would_mutate,
        })
        .to_string(),
    )
    .await
    .map_err(|e| format!("audit: {e}"))?;

    Ok(CascadeAgentRun {
        id: run_id,
        spec_id,
        mode: "sandbox".to_string(),
        status: run_status.to_string(),
        summary: out.summary,
        steps,
        anomalies,
        cost_usd: usage.cost_usd,
        duration_ms: 0,
        created_at: Utc::now().to_rfc3339(),
    })
}

/// Lifecycle transition for a generated spec (Agent #4). Enforces dual approval
/// before deploy; every transition is audit-logged.
#[tauri::command]
#[specta::specta]
pub async fn cascade_transition_agent_spec(
    app: tauri::AppHandle,
    spec_id: i64,
    action: String,
) -> Result<CascadeAgentSpecView, String> {
    let pool = cascade_pool(&app).await?;
    let record = get_agent_spec(&pool, spec_id)
        .await
        .map_err(|e| format!("load spec: {e}"))?
        .ok_or_else(|| format!("spec {spec_id} not found"))?;

    let (next_status, emp, mgr, actor): (&str, Option<bool>, Option<bool>, &str) =
        match action.as_str() {
            // Manager sends the (valid) generated spec down to the employee.
            "send_to_employee" => {
                if record.validation_status != "valid" {
                    return Err("cannot send an invalid spec to the employee".to_string());
                }
                ("review", None, Some(true), "manager")
            }
            "approve_employee" => (record.status.as_str(), Some(true), None, "employee"),
            "approve_manager" => (record.status.as_str(), None, Some(true), "manager"),
            // Deploy requires BOTH approvals and a passed sandbox.
            "deploy" => {
                let emp_ok = record.employee_approved;
                let mgr_ok = record.manager_approved;
                if !(emp_ok && mgr_ok) {
                    return Err("deploy requires both employee and manager approval".to_string());
                }
                if record.status != "sandbox_passed" && record.status != "approved" {
                    return Err("deploy requires a passed sandbox test first".to_string());
                }
                ("deployed", None, None, "employee")
            }
            "pause" => ("paused", None, None, "employee"),
            "resume" => ("deployed", None, None, "employee"),
            "reject" => ("rejected", None, None, "employee"),
            other => return Err(format!("unknown transition: {other}")),
        };

    update_agent_spec_status(&pool, spec_id, next_status, emp, mgr)
        .await
        .map_err(|e| format!("transition: {e}"))?;

    // Keep the underlying suggestion's status roughly in sync for the dashboard.
    let suggestion_status = match next_status {
        "review" => Some("sent"),
        "deployed" => Some("deployed"),
        "rejected" => Some("rejected"),
        _ => None,
    };
    if let Some(ss) = suggestion_status {
        let _ = update_manager_suggestion_status(&pool, record.suggestion_id, ss).await;
    }

    append_audit(
        &pool,
        Some(spec_id),
        None,
        actor,
        &format!("transition:{action}"),
        &serde_json::json!({ "to": next_status }).to_string(),
    )
    .await
    .map_err(|e| format!("audit: {e}"))?;

    let updated = get_agent_spec(&pool, spec_id)
        .await
        .map_err(|e| format!("reload spec: {e}"))?
        .ok_or("spec vanished")?;
    spec_view(updated)
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_list_agent_runs(
    app: tauri::AppHandle,
    spec_id: i64,
    limit: Option<u32>,
) -> Result<Vec<CascadeAgentRun>, String> {
    let pool = cascade_pool(&app).await?;
    let records = list_agent_runs(&pool, spec_id, limit.unwrap_or(20).clamp(1, 100) as i64)
        .await
        .map_err(|e| format!("list runs: {e}"))?;
    Ok(records
        .into_iter()
        .map(|r| CascadeAgentRun {
            id: r.id,
            spec_id: r.spec_id,
            mode: r.mode,
            status: r.status,
            summary: r.summary,
            steps: serde_json::from_str(&r.steps_json).unwrap_or_default(),
            anomalies: serde_json::from_str(&r.anomalies_json).unwrap_or_default(),
            cost_usd: r.cost_usd,
            duration_ms: r.duration_ms,
            created_at: r.created_at,
        })
        .collect())
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_list_audit(
    app: tauri::AppHandle,
    spec_id: i64,
    limit: Option<u32>,
) -> Result<Vec<CascadeAuditEntry>, String> {
    let pool = cascade_pool(&app).await?;
    let records = list_audit(&pool, spec_id, limit.unwrap_or(50).clamp(1, 200) as i64)
        .await
        .map_err(|e| format!("list audit: {e}"))?;
    Ok(records
        .into_iter()
        .map(|r| CascadeAuditEntry {
            id: r.id,
            actor: r.actor,
            action: r.action,
            detail: r.detail_json,
            created_at: r.created_at,
        })
        .collect())
}

// ════════════════════════════════════════════════════════════════════
// Agent #4 — Steady-state runtime: deployed agents actually do the work
// ════════════════════════════════════════════════════════════════════
//
// A deployed agent runs its declared workflow, step by step, for real. Each
// step invokes a capability (`execute`/`commit_side_effect`) that produces a
// real, on-device work product tailored to the detected pattern — a recap, a
// digest, a focus plan, a draft, a reminder, a notification. Every action is
// recorded in `cascade_agent_actions` (attributable + reversible). On an
// agent's first 3 live runs, every committing step is staged for the
// employee's approval before it happens. A misbehaving run auto-pauses the
// agent. Runs happen on the agent's schedule (autonomous) or on demand.

const MAX_RUNTIME_STEPS: usize = 8;
const AGENT_OUTPUTS_DIR: &str = "cascade-agent-outputs";

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CascadeAgentAction {
    pub id: i64,
    pub run_id: i64,
    pub spec_id: i64,
    pub step: i64,
    pub tool: String,
    pub summary: String,
    pub content: Option<String>,
    pub artifact_path: Option<String>,
    pub reversible: bool,
    pub mutating: bool,
    pub state: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CascadeRunResult {
    pub run_id: i64,
    pub spec_id: i64,
    pub status: String,
    pub summary: String,
    pub supervised: bool,
    pub pending_count: i64,
    pub cost_usd: f64,
    pub anomalies: Vec<Anomaly>,
    pub actions: Vec<CascadeAgentAction>,
}

fn agent_outputs_dir(app: &tauri::AppHandle, spec_id: i64) -> Result<PathBuf, String> {
    let dir = cascade_data_dir(app)?
        .join(AGENT_OUTPUTS_DIR)
        .join(format!("spec-{spec_id}"));
    fs::create_dir_all(&dir).map_err(|e| format!("create agent output dir: {e}"))?;
    Ok(dir)
}

fn slug(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_string()
}

fn is_mutating_tool(tool: &str) -> bool {
    MUTATING_TOOLS.contains(&tool)
}

/// Friendly label for the deliverable a capability produces (box result card).
fn deliverable_title(tool: &str) -> &'static str {
    match tool {
        "artifact.write" => "Document",
        "draft.message" => "Draft message",
        "task.create" => "Task",
        "reminder.set" => "Reminder",
        "summarize.text" => "Summary",
        "notify.local" => "Notification",
        _ => "Result",
    }
}

/// A real macOS notification. This genuinely acts (the employee sees it).
fn fire_notification(title: &str, body: &str) {
    #[cfg(target_os = "macos")]
    {
        let clean = |s: &str| s.replace('"', "'").replace('\n', " ");
        let script = format!(
            "display notification \"{}\" with title \"{}\"",
            clean(body).chars().take(220).collect::<String>(),
            clean(title).chars().take(80).collect::<String>(),
        );
        let _ = std::process::Command::new("osascript")
            .args(["-e", &script])
            .output();
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (title, body);
    }
}

fn applescript_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}
fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Derive a note title from the first usable line of the produced content.
fn first_line_title(content: &str) -> String {
    for line in content.lines() {
        let t = line.trim().trim_start_matches('#').trim();
        if !t.is_empty() && !t.starts_with("<!--") {
            return t.chars().take(80).collect();
        }
    }
    "Cascade note".to_string()
}

/// Create a REAL Apple Note (zero setup, native macOS). Body is simple HTML.
fn apple_notes_create(title: &str, content: &str) -> Result<(), String> {
    let body_html = format!(
        "<div><b>{}</b></div>{}",
        html_escape(title),
        content
            .lines()
            .filter(|l| !l.trim_start().starts_with("<!--"))
            .map(|l| format!("<div>{}</div>", html_escape(l)))
            .collect::<String>()
    );
    let script = format!(
        "tell application \"Notes\" to make new note with properties {{name:\"{}\", body:\"{}\"}}",
        applescript_escape(title),
        applescript_escape(&body_html),
    );
    let out = std::process::Command::new("osascript")
        .args(["-e", &script])
        .output()
        .map_err(|e| format!("apple notes: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "apple notes failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(())
}

/// The Obsidian vault path (most-recently-opened), parsed from obsidian.json.
fn obsidian_vault() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let cfg = PathBuf::from(home).join("Library/Application Support/obsidian/obsidian.json");
    let text = fs::read_to_string(&cfg).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let vaults = v.get("vaults")?.as_object()?;
    let mut first: Option<String> = None;
    for (_, val) in vaults {
        if let Some(p) = val.get("path").and_then(|p| p.as_str()) {
            if val.get("open").and_then(|o| o.as_bool()).unwrap_or(false) {
                return Some(PathBuf::from(p));
            }
            first.get_or_insert_with(|| p.to_string());
        }
    }
    first.map(PathBuf::from)
}

/// Write a note into the Obsidian vault (a Cascade/ folder). Returns
/// (path, "url:obsidian://…" open ref).
fn obsidian_write(title: &str, content: &str) -> Result<(String, String), String> {
    let vault = obsidian_vault().ok_or("no Obsidian vault found")?;
    let dir = vault.join("Cascade");
    fs::create_dir_all(&dir).map_err(|e| format!("create vault folder: {e}"))?;
    let fname = format!("{}.md", slug(title));
    let path = dir.join(&fname);
    let clean: String = content
        .lines()
        .filter(|l| !l.trim_start().starts_with("<!--"))
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(&path, &clean).map_err(|e| format!("write vault note: {e}"))?;
    let rel = format!("Cascade/{fname}");
    let vault_name = vault.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let open = format!(
        "url:obsidian://open?vault={}&file={}",
        urlencoding::encode(vault_name),
        urlencoding::encode(&rel)
    );
    Ok((path.display().to_string(), open))
}

/// Is a process whose name matches `pattern` (case-insensitive) running now?
fn app_running(pattern: &str) -> bool {
    std::process::Command::new("pgrep")
        .args(["-i", pattern])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

#[derive(Debug, Clone)]
enum DeliveryTarget {
    Obsidian,
    AppleNotes,
    LocalFile { preferred_app: Option<String> },
}

/// Which destination to deliver the recap into. Strongest signal first: a notes
/// app with an integration we can actually write to, then a neutral local file.
/// Browser/native agents can still operate other tools directly; this headless
/// path must not pretend it can write to an app it has no integration for.
async fn resolve_delivery_target(app: &tauri::AppHandle) -> DeliveryTarget {
    if obsidian_vault().is_some() && app_running("obsidian") {
        return DeliveryTarget::Obsidian;
    }

    let preferred = preferred_notes_app(app).await;
    if let Some(a) = preferred.as_deref() {
        let lower = a.to_lowercase();
        if lower.contains("obsidian") && obsidian_vault().is_some() {
            return DeliveryTarget::Obsidian;
        }
        if lower == "notes" || lower.contains("apple notes") {
            return DeliveryTarget::AppleNotes;
        }
    }

    if app_running("notes") {
        return DeliveryTarget::AppleNotes;
    }

    DeliveryTarget::LocalFile {
        preferred_app: preferred,
    }
}

/// What a committed step produced + how the box opens it.
#[derive(Default, Clone)]
pub struct Delivered {
    /// Local file path (for rollback); None for app-native targets.
    pub path: Option<String>,
    /// Where it landed, for display/open buttons.
    pub app_label: String,
    /// Open reference for the box: "app:Notes", "url:…", or "path:…".
    pub open_ref: Option<String>,
}

fn write_local_record(
    app: &tauri::AppHandle,
    spec_id: i64,
    run_id: i64,
    step: i64,
    tool: &str,
    agent_name: &str,
    content: &str,
) -> Result<String, String> {
    let dir = agent_outputs_dir(app, spec_id)?;
    let ext = if tool == "draft.message" { "txt" } else { "md" };
    let fname = format!("run{run_id}-step{step}-{}.{ext}", slug(tool));
    let path = dir.join(fname);
    let header =
        format!("<!-- Cascade agent: {agent_name} · {tool} · run {run_id} step {step} -->\n\n");
    fs::write(&path, format!("{header}{content}")).map_err(|e| format!("write artifact: {e}"))?;
    Ok(path.display().to_string())
}

/// Perform the real side effect for a committing step. The primary deliverable
/// (`artifact.write`) lands through a writable integration resolved from the
/// employee's activity, falling back to a local file when no such integration is
/// available.
fn commit_side_effect(
    app: &tauri::AppHandle,
    spec_id: i64,
    run_id: i64,
    step: i64,
    tool: &str,
    agent_name: &str,
    content: &str,
    target: DeliveryTarget,
) -> Result<Delivered, String> {
    match tool {
        "artifact.write" => {
            let title = first_line_title(content);
            match target {
                DeliveryTarget::Obsidian => {
                    if let Ok((path, open)) = obsidian_write(&title, content) {
                        return Ok(Delivered {
                            path: Some(path),
                            app_label: "Obsidian".into(),
                            open_ref: Some(open),
                        });
                    }
                    let path =
                        write_local_record(app, spec_id, run_id, step, tool, agent_name, content)?;
                    Ok(Delivered {
                        path: Some(path.clone()),
                        app_label: "File".into(),
                        open_ref: Some(format!("path:{path}")),
                    })
                }
                DeliveryTarget::AppleNotes => match apple_notes_create(&title, content) {
                    Ok(()) => Ok(Delivered {
                        path: None,
                        app_label: "Apple Notes".into(),
                        open_ref: Some("app:Notes".into()),
                    }),
                    Err(_) => {
                        let path = write_local_record(
                            app, spec_id, run_id, step, tool, agent_name, content,
                        )?;
                        Ok(Delivered {
                            path: Some(path.clone()),
                            app_label: "File".into(),
                            open_ref: Some(format!("path:{path}")),
                        })
                    }
                },
                DeliveryTarget::LocalFile { preferred_app } => {
                    let path =
                        write_local_record(app, spec_id, run_id, step, tool, agent_name, content)?;
                    let app_label = preferred_app
                        .filter(|name| !name.trim().is_empty())
                        .map(|name| format!("File for {name}"))
                        .unwrap_or_else(|| "File".to_string());
                    Ok(Delivered {
                        path: Some(path.clone()),
                        app_label,
                        open_ref: Some(format!("path:{path}")),
                    })
                }
            }
        }
        "draft.message" | "task.create" | "reminder.set" => {
            let path = write_local_record(app, spec_id, run_id, step, tool, agent_name, content)?;
            if tool == "reminder.set" {
                fire_notification(&format!("Cascade reminder · {agent_name}"), content);
            }
            Ok(Delivered {
                path: Some(path.clone()),
                app_label: "File".into(),
                open_ref: Some(format!("path:{path}")),
            })
        }
        "notify.local" => {
            fire_notification(&format!("Cascade · {agent_name}"), content);
            Ok(Delivered {
                app_label: "Notification".into(),
                ..Default::default()
            })
        }
        // read.activity / analyze.patterns / summarize.text have no side effect.
        _ => Ok(Delivered::default()),
    }
}

/// Deliver a real recap/document through Cascade's normal write path:
/// Obsidian if that's where the employee is working, else Apple Notes, else a
/// file fallback so browser-only agents can still land useful output.
pub(crate) async fn deliver_artifact_write(
    app: &tauri::AppHandle,
    spec_id: i64,
    run_id: i64,
    step: i64,
    agent_name: &str,
    content: &str,
) -> Result<Delivered, String> {
    let target = resolve_delivery_target(app).await;
    commit_side_effect(
        app,
        spec_id,
        run_id,
        step,
        "artifact.write",
        agent_name,
        content,
        target,
    )
}

fn runtime_step_system_prompt(agent_name: &str, task: &str, today: &str) -> String {
    format!(
        "You are \"{agent_name}\", a deployed Cascade helper agent. Your job: {task}\n\
Today's date is {today}. The activity data you are given covers roughly the last 24 hours up to now. \
Use ONLY this real date — never invent or guess a date, and do not assume the data is from a specific \
prior day unless the timestamps say so.\n\
You are executing ONE step of your workflow. Produce ONLY the actual work product for this step — \
the real deliverable text (a recap, digest, plan, draft, task list, or notification body), with no \
preamble, no meta-commentary, no markdown fences. Ground it in the employee's real recent activity \
and the outputs of earlier steps. Be concise and immediately useful. If this step is a notification, \
output a single short sentence."
    )
}

fn runtime_step_user_prompt(step: &WorkflowStep, rewind: &str, context: &str) -> String {
    format!(
        "STEP {} — {}\nCapability: {}\n\nWHAT THE EMPLOYEE ACTUALLY DID ON SCREEN (from the Rewind — \
[time] App — Window, then on-screen text):\n{}\n\nOUTPUTS OF EARLIER STEPS:\n{}\n\n\
Produce this step's work product now, grounded in the REAL activity above.",
        step.step,
        step.action,
        step.tool.as_deref().unwrap_or("analyze.patterns"),
        if rewind.trim().is_empty() { "(nothing recorded yet)" } else { rewind },
        if context.is_empty() { "(none yet)" } else { context }
    )
}

fn is_browser_execution(doc: &AgentSpecDoc) -> bool {
    doc.execution_mode.eq_ignore_ascii_case("browser")
        || doc
            .workflow
            .iter()
            .any(|step| step.tool.as_deref() == Some("browser.use"))
}

fn action_view(a: cascade_schema::AgentActionRecord) -> CascadeAgentAction {
    CascadeAgentAction {
        id: a.id,
        run_id: a.run_id,
        spec_id: a.spec_id,
        step: a.step,
        tool: a.tool,
        summary: a.summary,
        content: a.content,
        artifact_path: a.artifact_path,
        reversible: a.reversible,
        mutating: a.mutating,
        state: a.state,
        created_at: a.created_at,
    }
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_list_agent_actions(
    app: tauri::AppHandle,
    spec_id: i64,
    limit: Option<u32>,
) -> Result<Vec<CascadeAgentAction>, String> {
    let pool = cascade_pool(&app).await?;
    let rows = list_actions_for_spec(&pool, spec_id, limit.unwrap_or(40).clamp(1, 200) as i64)
        .await
        .map_err(|e| format!("list actions: {e}"))?;
    Ok(rows.into_iter().map(action_view).collect())
}

/// Approve a staged (pending) action — the side effect happens now.
#[tauri::command]
#[specta::specta]
pub async fn cascade_approve_action(
    app: tauri::AppHandle,
    action_id: i64,
) -> Result<CascadeAgentAction, String> {
    let pool = cascade_pool(&app).await?;
    let action = get_agent_action(&pool, action_id)
        .await
        .map_err(|e| format!("load action: {e}"))?
        .ok_or_else(|| format!("action {action_id} not found"))?;
    if action.state != "pending" {
        return Err(format!("action is not pending (state: {})", action.state));
    }
    let spec = get_agent_spec(&pool, action.spec_id)
        .await
        .map_err(|e| format!("load spec: {e}"))?
        .ok_or("spec not found")?;
    let content = action.content.clone().unwrap_or_default();
    let target = resolve_delivery_target(&app).await;
    let _ = commit_side_effect(
        &app,
        action.spec_id,
        action.run_id,
        action.step,
        &action.tool,
        &spec.name,
        &content,
        target,
    )?;
    update_agent_action_state(&pool, action_id, "committed")
        .await
        .map_err(|e| format!("commit action: {e}"))?;
    append_audit(
        &pool,
        Some(action.spec_id),
        Some(action.run_id),
        "employee",
        "approve_action",
        &serde_json::json!({ "actionId": action_id, "tool": action.tool }).to_string(),
    )
    .await
    .map_err(|e| format!("audit: {e}"))?;
    let updated = get_agent_action(&pool, action_id)
        .await
        .map_err(|e| format!("reload: {e}"))?
        .ok_or("action vanished")?;
    Ok(action_view(updated))
}

#[tauri::command]
#[specta::specta]
pub async fn cascade_reject_action(app: tauri::AppHandle, action_id: i64) -> Result<(), String> {
    let pool = cascade_pool(&app).await?;
    let action = get_agent_action(&pool, action_id)
        .await
        .map_err(|e| format!("load action: {e}"))?
        .ok_or_else(|| format!("action {action_id} not found"))?;
    update_agent_action_state(&pool, action_id, "rejected")
        .await
        .map_err(|e| format!("reject: {e}"))?;
    append_audit(
        &pool,
        Some(action.spec_id),
        Some(action.run_id),
        "employee",
        "reject_action",
        &serde_json::json!({ "actionId": action_id }).to_string(),
    )
    .await
    .map_err(|e| format!("audit: {e}"))?;
    Ok(())
}

/// One-click undo of a committed, reversible action — deletes the artifact.
#[tauri::command]
#[specta::specta]
pub async fn cascade_rollback_action(app: tauri::AppHandle, action_id: i64) -> Result<(), String> {
    let pool = cascade_pool(&app).await?;
    let action = get_agent_action(&pool, action_id)
        .await
        .map_err(|e| format!("load action: {e}"))?
        .ok_or_else(|| format!("action {action_id} not found"))?;
    if !action.reversible {
        return Err("this action is not reversible".to_string());
    }
    if action.state != "committed" {
        return Err(format!(
            "only committed actions can be rolled back (state: {})",
            action.state
        ));
    }
    if let Some(path) = &action.artifact_path {
        let _ = fs::remove_file(path);
    }
    update_agent_action_state(&pool, action_id, "rolled_back")
        .await
        .map_err(|e| format!("rollback: {e}"))?;
    append_audit(
        &pool,
        Some(action.spec_id),
        Some(action.run_id),
        "employee",
        "rollback_action",
        &serde_json::json!({ "actionId": action_id, "artifact": action.artifact_path }).to_string(),
    )
    .await
    .map_err(|e| format!("audit: {e}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_is_filesystem_safe() {
        assert_eq!(slug("Inbox Batcher!"), "inbox-batcher");
        assert_eq!(slug("artifact.write"), "artifact-write");
    }

    #[test]
    fn mutating_classification() {
        assert!(is_mutating_tool("artifact.write"));
        assert!(is_mutating_tool("draft.message"));
        assert!(!is_mutating_tool("read.activity"));
        assert!(!is_mutating_tool("notify.local"));
    }

    #[test]
    fn dp_jitter_leaves_large_counts_alone() {
        let (v, noised) = dp_jitter("Slack", 42);
        assert_eq!(v, 42);
        assert!(!noised);
    }

    #[test]
    fn dp_jitter_perturbs_small_counts_deterministically() {
        let (a, noised_a) = dp_jitter("Cursor", 3);
        let (b, noised_b) = dp_jitter("Cursor", 3);
        assert_eq!(a, b); // stable per app+window
        assert!(noised_a && noised_b);
        assert!(a >= 0);
    }

    #[test]
    fn sensitive_apps_are_dropped() {
        let summary = ActivitySummaryResponse {
            data_status: "ok".into(),
            total_frames: 100,
            apps: vec![],
            windows: vec![
                ActivityWindow {
                    app_name: "Chase Bank".into(),
                    window_name: "Accounts".into(),
                    minutes: 20.0,
                },
                ActivityWindow {
                    app_name: "Cursor".into(),
                    window_name: "main.rs".into(),
                    minutes: 50.0,
                },
                ActivityWindow {
                    app_name: "Arc".into(),
                    window_name: "Incognito — research".into(),
                    minutes: 15.0,
                },
            ],
        };
        let (aggs, excluded) = sanitize(&summary);
        assert_eq!(excluded, 2); // bank + incognito window
        assert_eq!(aggs.len(), 1);
        assert_eq!(aggs[0].app, "Cursor");
        assert_eq!(aggs[0].category, "coding");
    }

    #[test]
    fn validate_rejects_shell_and_missing_rollback() {
        let doc = AgentSpecDoc {
            name: "x".into(),
            task_description: "do a thing".into(),
            rationale: "r".into(),
            execution_mode: default_execution_mode(),
            target_url: String::new(),
            target_hosts: vec![],
            observed_apps: vec![],
            observed_workflow: vec![],
            completion_pattern: String::new(),
            required_inputs: vec![],
            workflow: vec![WorkflowStep {
                step: 1,
                action: "run".into(),
                tool: None,
                decision_point: None,
                approval_required: false,
            }],
            tools: vec!["shell.exec".into()],
            failure_conditions: vec![],
            approval_points: vec![],
            rollback_path: "".into(),
            estimated_cost_usd: 0.5,
            estimated_time_saved_min: 10.0,
            schedule_minutes: 1440,
        };
        let (status, notes) = validate_spec(&doc);
        assert_eq!(status, "invalid");
        let notes = notes.unwrap();
        assert!(notes.contains("forbidden tool"));
        assert!(notes.contains("rollback"));
        assert!(notes.contains("cap"));
    }

    #[test]
    fn validate_accepts_clean_spec() {
        let doc = AgentSpecDoc {
            name: "Inbox batcher".into(),
            task_description: "Batch low-priority email into a daily digest.".into(),
            rationale: "Reduces context switching.".into(),
            execution_mode: default_execution_mode(),
            target_url: String::new(),
            target_hosts: vec![],
            observed_apps: vec![],
            observed_workflow: vec![],
            completion_pattern: String::new(),
            required_inputs: vec![RequiredInput {
                source: "cascade_privacy_aggregates".into(),
                fields: vec!["app".into(), "durationMin".into()],
            }],
            workflow: vec![
                WorkflowStep {
                    step: 1,
                    action: "Read recent activity and identify low-priority comms".into(),
                    tool: Some("read.activity".into()),
                    decision_point: None,
                    approval_required: false,
                },
                WorkflowStep {
                    step: 2,
                    action: "Write a batched digest document".into(),
                    tool: Some("artifact.write".into()),
                    decision_point: None,
                    approval_required: true,
                },
            ],
            tools: vec!["read.activity".into(), "artifact.write".into()],
            failure_conditions: vec!["no activity in window".into()],
            approval_points: vec!["before writing the digest".into()],
            rollback_path: "delete the digest document".into(),
            estimated_cost_usd: 0.02,
            estimated_time_saved_min: 45.0,
            schedule_minutes: 1440,
        };
        let (status, notes) = validate_spec(&doc);
        assert_eq!(status, "valid", "notes: {:?}", notes);
    }

    #[test]
    fn anomaly_flags_undeclared_tool() {
        let doc = AgentSpecDoc {
            name: "x".into(),
            task_description: "t".into(),
            rationale: "r".into(),
            execution_mode: default_execution_mode(),
            target_url: String::new(),
            target_hosts: vec![],
            observed_apps: vec![],
            observed_workflow: vec![],
            completion_pattern: String::new(),
            required_inputs: vec![],
            workflow: vec![WorkflowStep {
                step: 1,
                action: "a".into(),
                tool: Some("read.activity".into()),
                decision_point: None,
                approval_required: false,
            }],
            tools: vec!["read.activity".into()],
            failure_conditions: vec![],
            approval_points: vec![],
            rollback_path: "noop".into(),
            estimated_cost_usd: 0.01,
            estimated_time_saved_min: 5.0,
            schedule_minutes: 1440,
        };
        let out = SandboxModelOutput {
            status: "success".into(),
            summary: "s".into(),
            would_mutate: true,
            steps: vec![SandboxModelStep {
                step: 1,
                tool: "task.create".into(),
                action: "created a task".into(),
                mocked_result: "ok".into(),
            }],
        };
        let anomalies = detect_anomalies(&doc, &out);
        let kinds: Vec<&str> = anomalies.iter().map(|a| a.kind.as_str()).collect();
        assert!(kinds.contains(&"scope_creep"));
        assert!(kinds.contains(&"missing_approval"));
    }

    #[test]
    fn sandbox_output_accepts_nullable_model_strings() {
        let out: SandboxModelOutput = serde_json::from_value(serde_json::json!({
            "status": "success",
            "summary": null,
            "wouldMutate": null,
            "steps": [{
                "step": 1,
                "tool": "read.activity",
                "action": null,
                "mockedResult": null
            }]
        }))
        .expect("sandbox output should tolerate null strings from the model");

        assert_eq!(out.summary, "");
        assert!(!out.would_mutate);
        assert_eq!(out.steps[0].action, "");
        assert_eq!(out.steps[0].mocked_result, "");
    }
}
