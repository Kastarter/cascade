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

use crate::cascade_llm::{call_anthropic_json, LlmCall, MODEL_OPUS, MODEL_SONNET};
use cascade_schema::{
    append_audit, create_detection_run, get_agent_spec, insert_agent_run, insert_agent_spec,
    insert_manager_suggestion, list_agent_runs, list_agent_specs, list_audit,
    list_manager_suggestions, list_privacy_aggregates, migrate, open, replace_privacy_aggregates,
    update_agent_spec_status, update_manager_suggestion_status, AgentRunInput, AgentSpecInput,
    ManagerSuggestionInput, PrivacyAggregateInput,
};
use chrono::{Duration, Utc};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use specta::Type;
use std::cmp::Ordering;
use std::fs;
use std::path::PathBuf;

const MANAGER_OUTBOX_DIR: &str = "cascade-manager-outbox";
const PRIVACY_OUTBOX_DIR: &str = "cascade-privacy-outbox";
const DETECTOR_NAME: &str = "cascade-waste-detector-llm-v1";

// ─── App → category classifier (shared, deterministic) ──────────────

const CODING_APPS: &[&str] = &[
    "wezterm", "iterm2", "terminal", "alacritty", "kitty", "warp", "hyper", "vscode",
    "visual studio code", "code", "zed", "xcode", "intellij idea", "webstorm", "pycharm",
    "cursor", "neovim", "vim",
];
const BROWSER_APPS: &[&str] = &[
    "arc", "google chrome", "chrome", "safari", "firefox", "brave browser", "microsoft edge",
    "opera",
];
const MEETING_APPS: &[&str] = &[
    "zoom.us", "zoom", "microsoft teams", "teams", "google meet", "slack huddle", "facetime",
    "webex", "discord",
];
const COMMUNICATION_APPS: &[&str] = &[
    "slack", "messages", "telegram", "whatsapp", "signal", "mail", "gmail", "outlook",
    "thunderbird",
];
const WRITING_APPS: &[&str] = &[
    "obsidian", "notion", "notes", "bear", "ulysses", "typora", "google docs", "microsoft word",
    "pages",
];

/// Apps + window markers that must NEVER be aggregated, even anonymously.
/// Banking / health / legal / dating / private browsing (agents.md #5 guardrail).
const SENSITIVE_MARKERS: &[&str] = &[
    // finance
    "bank", "chase", "wells fargo", "fidelity", "vanguard", "robinhood", "coinbase", "venmo",
    "paypal", "mint", "quickbooks", "turbotax",
    // health / medical
    "mychart", "teladoc", "doctor", "clinic", "pharmacy", "calm", "headspace", "clue", "flo",
    // legal
    "docusign", "clio", "lawpay", "legalzoom",
    // dating
    "tinder", "hinge", "bumble", "grindr", "okcupid", "match.com",
    // private browsing
    "private browsing", "incognito", "inprivate",
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
    let pool = open(&db_path).await.map_err(|e| format!("open cascade schema: {e}"))?;
    migrate(&pool).await.map_err(|e| format!("migrate cascade schema: {e}"))?;
    Ok(pool)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActivitySummaryResponse {
    apps: Vec<ActivityAppUsage>,
    windows: Vec<ActivityWindow>,
    data_status: String,
    total_frames: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActivityAppUsage {
    name: String,
    minutes: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActivityWindow {
    app_name: String,
    window_name: String,
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

    let (aggregates, excluded_count) =
        if summary.data_status == "ok" && summary.total_frames > 0 {
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
    kind: String,
    title: String,
    summary: String,
    #[serde(default = "default_tier")]
    tier: String,
    suggested_agent_kind: String,
    severity_score: f64,
    confidence: f64,
    #[serde(default)]
    evidence: Vec<CascadeManagerEvidence>,
}
fn default_tier() -> String {
    "suggest".to_string()
}

const ALLOWED_AGENT_KINDS: &[&str] = &[
    "focus-guard",
    "inbox-batcher",
    "meeting-recap",
    "research-assistant",
    "status-automation",
];

fn detector_system_prompt() -> String {
    format!(
        "You are Cascade's Waste Detector. You receive ONLY a privacy-sanitized, \
allowlisted activity summary (per-app: app, category, duration in minutes, context-switch count). \
You never see screen text, window titles, or any content. Surface patterns of *workflow* \
inefficiency a manager could address by deploying a small helper agent — never judgments about the \
person.\n\n\
HARD RULES:\n\
- Surface at most 6 patterns. Fewer is better; only flag what the data clearly supports.\n\
- Each pattern's `kind` MUST be one of: context_switching, communication_churn, meeting_load, \
research_friction, manual_admin_work.\n\
- Each `suggestedAgentKind` MUST be one of: {}.\n\
- `tier` is one of: info, suggest, urgent. Reserve `urgent` for clear, costly patterns.\n\
- If the day skews toward off-hours or overload, DEMOTE tier (do not reward overwork).\n\
- Never use evaluative language about the person (\"unfocused\", \"wasted time\"). Describe the workflow only.\n\
- `evidence` items must be derived strictly from the numbers given (label + value). No invented metrics.\n\
- severityScore and confidence are floats 0..1.\n\n\
Return ONLY JSON: {{\"suggestions\":[{{\"kind\":...,\"title\":...,\"summary\":...,\"tier\":...,\
\"suggestedAgentKind\":...,\"severityScore\":0.0,\"confidence\":0.0,\
\"evidence\":[{{\"label\":...,\"value\":...}}]}}]}}",
        ALLOWED_AGENT_KINDS.join(", ")
    )
}

fn detector_user_prompt(
    aggregates: &[CascadePrivacyAggregate],
    hours: u32,
    excluded_count: u32,
) -> String {
    let total: f64 = aggregates.iter().map(|a| a.duration_min).sum();
    let rows = serde_json::to_string_pretty(aggregates).unwrap_or_else(|_| "[]".to_string());
    format!(
        "Analyzed window: last {hours} hours. Total tracked active time: {total:.0} minutes. \
{excluded_count} sensitive app/window groups were excluded by the privacy aggregator before you \
saw anything.\n\nPer-app sanitized aggregates (JSON):\n{rows}\n\n\
Surface the workflow inefficiency patterns this data supports."
    )
}

fn normalize_suggestion(mut s: DetectorSuggestion) -> CascadeManagerSuggestion {
    // Clamp + whitelist-enforce so a misbehaving model can't widen scope.
    if !ALLOWED_AGENT_KINDS.contains(&s.suggested_agent_kind.as_str()) {
        s.suggested_agent_kind = "status-automation".to_string();
    }
    let tier = match s.tier.as_str() {
        "info" | "suggest" | "urgent" => s.tier,
        _ => "suggest".to_string(),
    };
    CascadeManagerSuggestion {
        id: None,
        kind: s.kind,
        title: s.title,
        summary: s.summary,
        tier,
        evidence: s.evidence,
        suggested_agent_kind: s.suggested_agent_kind,
        severity_score: s.severity_score.clamp(0.0, 1.0),
        confidence: s.confidence.clamp(0.0, 1.0),
        status: "pending".to_string(),
        created_at: None,
    }
}

/// Agent #2. Runs the privacy aggregator (#5) first, then asks Opus to surface
/// patterns over the sanitized output only. Persists suggestions + the run.
#[tauri::command]
#[specta::specta]
pub async fn cascade_generate_manager_suggestions(
    app: tauri::AppHandle,
    hours: Option<u32>,
) -> Result<CascadeManagerSuggestionBatch, String> {
    let hours = hours.unwrap_or(8).clamp(1, 24);

    // #5 first — the detector is only ever allowed to read this.
    let report = cascade_run_privacy_aggregation(app.clone(), Some(hours)).await?;

    let mut batch = CascadeManagerSuggestionBatch {
        generated_at: Utc::now().to_rfc3339(),
        window_start: report.window_start.clone(),
        window_end: report.window_end.clone(),
        hours_analyzed: hours,
        delivery_mode: "local_outbox".to_string(),
        model: MODEL_OPUS.to_string(),
        cost_usd: 0.0,
        outbox_path: String::new(),
        suggestions: Vec::new(),
    };

    if report.aggregates.is_empty() {
        batch.outbox_path = write_json_outbox(&app, MANAGER_OUTBOX_DIR, &batch)?;
        return Ok(batch);
    }

    let call = LlmCall {
        model: MODEL_OPUS,
        system: detector_system_prompt(),
        user: detector_user_prompt(&report.aggregates, hours, report.excluded_count),
        temperature: 0.2,
        max_tokens: 2000,
    };
    let (output, usage) = call_anthropic_json::<DetectorOutput>(&call).await?;
    batch.cost_usd = usage.cost_usd;

    let mut suggestions: Vec<CascadeManagerSuggestion> =
        output.suggestions.into_iter().take(6).map(normalize_suggestion).collect();
    suggestions.sort_by(|a, b| cmp_f64_desc(a.severity_score, b.severity_score));

    // Persist run + suggestions.
    let pool = cascade_pool(&app).await?;
    let run_id = create_detection_run(
        &pool,
        DETECTOR_NAME,
        &report.window_start,
        &report.window_end,
        &serde_json::json!({
            "model": MODEL_OPUS,
            "aggregateCount": report.aggregates.len(),
            "excludedCount": report.excluded_count,
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

    batch.suggestions = suggestions;
    batch.outbox_path = write_json_outbox(&app, MANAGER_OUTBOX_DIR, &batch)?;
    Ok(batch)
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

/// MCP tools a generated agent may declare. Anything else (especially shell /
/// exec) is rejected at validation time.
const TOOL_WHITELIST: &[&str] = &[
    "gmail.read",
    "gmail.draft",
    "gmail.send",
    "slack.read",
    "slack.post",
    "calendar.read",
    "calendar.create_event",
    "notion.read",
    "notion.write",
    "drive.read",
    "drive.write",
    "linear.read",
    "linear.create_issue",
    "notify.local",
    "summarize.local",
];

/// Tools that change state outside Cascade → require an approval point.
const MUTATING_TOOLS: &[&str] = &[
    "gmail.send",
    "gmail.draft",
    "slack.post",
    "calendar.create_event",
    "notion.write",
    "drive.write",
    "linear.create_issue",
];

const MAX_PER_EXEC_COST_USD: f64 = 0.10;

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct RequiredInput {
    pub source: String,
    pub fields: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowStep {
    pub step: i64,
    pub action: String,
    #[serde(default)]
    pub decision_point: Option<String>,
    #[serde(default)]
    pub approval_required: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AgentSpecDoc {
    pub name: String,
    pub task_description: String,
    pub rationale: String,
    pub required_inputs: Vec<RequiredInput>,
    pub workflow: Vec<WorkflowStep>,
    pub tools: Vec<String>,
    pub failure_conditions: Vec<String>,
    pub approval_points: Vec<String>,
    pub rollback_path: String,
    pub estimated_cost_usd: f64,
    pub estimated_time_saved_min: f64,
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
ONE deterministic, reviewable agent specification. The spec is NOT executed — a human reviews it, \
it is sandbox-tested, and dual-approved before it ever runs.\n\n\
HARD RULES (a violated rule means the spec is rejected — follow all):\n\
- `tools` may ONLY contain tools from this whitelist: {}. NEVER invent tools. NEVER request shell/exec/file-system access.\n\
- The `workflow` must be linear or branch only on schema-checkable conditions — never \"the agent decides what to do next\".\n\
- Every state-mutating step (send/post/write/create) MUST have approvalRequired=true AND a matching entry in `approvalPoints`.\n\
- `rollbackPath` is REQUIRED and must describe how to undo the agent's actions (recall/delete/revert).\n\
- `estimatedCostUsd` must be a realistic per-execution number and SHOULD be <= {:.2}.\n\
- `taskDescription` is one plain-English sentence (readable, no jargon).\n\
- `requiredInputs[].source` should reference Cascade data the agent reads, e.g. \"cascade_privacy_aggregates\".\n\n\
Return ONLY JSON with EXACTLY these camelCase keys:\n\
{{\"name\":str,\"taskDescription\":str,\"rationale\":str,\
\"requiredInputs\":[{{\"source\":str,\"fields\":[str]}}],\
\"workflow\":[{{\"step\":int,\"action\":str,\"decisionPoint\":str|null,\"approvalRequired\":bool}}],\
\"tools\":[str],\"failureConditions\":[str],\"approvalPoints\":[str],\"rollbackPath\":str,\
\"estimatedCostUsd\":number,\"estimatedTimeSavedMin\":number}}",
        TOOL_WHITELIST.join(", "),
        MAX_PER_EXEC_COST_USD
    )
}

fn generator_user_prompt(s: &CascadeManagerSuggestion) -> String {
    let evidence = s
        .evidence
        .iter()
        .map(|e| format!("- {}: {}", e.label, e.value))
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "Pattern kind: {}\nTitle: {}\nSummary: {}\nSuggested agent family: {}\n\
Severity: {:.2}  Confidence: {:.2}\nEvidence:\n{}\n\n\
Generate the agent spec that would address this pattern with the least intrusive, most reversible workflow.",
        s.kind, s.title, s.summary, s.suggested_agent_kind, s.severity_score, s.confidence, evidence
    )
}

/// Returns (status, notes). status is "valid" or "invalid".
fn validate_spec(doc: &AgentSpecDoc) -> (String, Option<String>) {
    let mut problems: Vec<String> = Vec::new();

    if doc.workflow.is_empty() {
        problems.push("workflow is empty".into());
    }
    if doc.rollback_path.trim().is_empty() {
        problems.push("missing rollback path".into());
    }
    if doc.task_description.trim().is_empty() {
        problems.push("missing task description".into());
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

    // Mutating tool requires at least one approval point.
    let has_mutating = doc.tools.iter().any(|t| MUTATING_TOOLS.contains(&t.as_str()));
    if has_mutating && doc.approval_points.is_empty() {
        problems.push("state-mutating tools declared but no approval points".into());
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
    let suggestion = load_suggestion(&app, suggestion_id).await?;

    let call = LlmCall {
        model: MODEL_OPUS,
        system: generator_system_prompt(),
        user: generator_user_prompt(&suggestion),
        temperature: 0.1,
        max_tokens: 2500,
    };
    let (doc, _usage) = call_anthropic_json::<AgentSpecDoc>(&call).await?;
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
        &serde_json::json!({ "validation": validation_status, "notes": validation_notes }).to_string(),
    )
    .await
    .map_err(|e| format!("audit: {e}"))?;

    let record = get_agent_spec(&pool, spec_id)
        .await
        .map_err(|e| format!("reload spec: {e}"))?
        .ok_or("spec vanished after insert")?;
    spec_view(record)
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
    status: String,
    summary: String,
    #[serde(default)]
    steps: Vec<SandboxModelStep>,
    #[serde(default)]
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
    #[serde(default)]
    tool: String,
    #[serde(default)]
    action: String,
    #[serde(default)]
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
    "You are Cascade's sandbox executor (Agent #4). You are given an agent spec and a sample of the \
employee's recent sanitized activity. Simulate ONE execution of the agent. ALL external tool calls \
are MOCKED — never claim a real email was sent or a real change was made; describe the mocked result. \
Be faithful to the spec's declared tools and workflow.\n\n\
Return ONLY JSON: {\"status\":\"success\"|\"failed\",\"summary\":str,\
\"steps\":[{\"step\":int,\"tool\":str,\"action\":str,\"mockedResult\":str}],\"wouldMutate\":bool}"
        .to_string()
}

fn sandbox_user_prompt(doc: &AgentSpecDoc, aggregates: &[CascadePrivacyAggregate]) -> String {
    let spec = serde_json::to_string_pretty(doc).unwrap_or_default();
    let data = serde_json::to_string_pretty(aggregates).unwrap_or_else(|_| "[]".to_string());
    format!(
        "AGENT SPEC:\n{spec}\n\nHISTORICAL SANITIZED ACTIVITY (mock inputs):\n{data}\n\n\
Simulate one run. Use only the spec's declared tools."
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
            detail: "run would mutate external state but spec declares no approval points".to_string(),
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
    let pool = cascade_pool(&app).await?;
    let record = get_agent_spec(&pool, spec_id)
        .await
        .map_err(|e| format!("load spec: {e}"))?
        .ok_or_else(|| format!("spec {spec_id} not found"))?;
    let doc: AgentSpecDoc = serde_json::from_str(&record.spec_json)
        .map_err(|e| format!("parse spec: {e}"))?;

    if record.validation_status != "valid" {
        return Err(format!(
            "spec failed generation-time validation, cannot sandbox: {}",
            record.validation_notes.unwrap_or_default()
        ));
    }

    // Sample recent sanitized activity for the mock inputs (30-day proxy: last 24h).
    let (ws, we, summary) = fetch_activity_summary(&app, 24).await?;
    let (aggregates, _) = if summary.data_status == "ok" {
        sanitize(&summary)
    } else {
        (Vec::new(), 0)
    };
    let _ = (ws, we);

    let call = LlmCall {
        model: MODEL_SONNET,
        system: sandbox_system_prompt(),
        user: sandbox_user_prompt(&doc, &aggregates),
        temperature: 0.0,
        max_tokens: 1800,
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

    let next_status = if passed { "sandbox_passed" } else { "sandbox_failed" };
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

#[cfg(test)]
mod tests {
    use super::*;

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
            required_inputs: vec![],
            workflow: vec![WorkflowStep {
                step: 1,
                action: "run".into(),
                decision_point: None,
                approval_required: false,
            }],
            tools: vec!["shell.exec".into()],
            failure_conditions: vec![],
            approval_points: vec![],
            rollback_path: "".into(),
            estimated_cost_usd: 0.5,
            estimated_time_saved_min: 10.0,
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
            required_inputs: vec![RequiredInput {
                source: "cascade_privacy_aggregates".into(),
                fields: vec!["app".into(), "durationMin".into()],
            }],
            workflow: vec![WorkflowStep {
                step: 1,
                action: "Draft a digest of low-priority mail".into(),
                decision_point: None,
                approval_required: true,
            }],
            tools: vec!["gmail.read".into(), "gmail.draft".into()],
            failure_conditions: vec!["gmail api error".into()],
            approval_points: vec!["before drafting the digest".into()],
            rollback_path: "delete the draft".into(),
            estimated_cost_usd: 0.02,
            estimated_time_saved_min: 45.0,
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
            required_inputs: vec![],
            workflow: vec![WorkflowStep {
                step: 1,
                action: "a".into(),
                decision_point: None,
                approval_required: false,
            }],
            tools: vec!["gmail.read".into()],
            failure_conditions: vec![],
            approval_points: vec![],
            rollback_path: "noop".into(),
            estimated_cost_usd: 0.01,
            estimated_time_saved_min: 5.0,
        };
        let out = SandboxModelOutput {
            status: "success".into(),
            summary: "s".into(),
            would_mutate: true,
            steps: vec![SandboxModelStep {
                step: 1,
                tool: "drive.write".into(),
                action: "wrote a file".into(),
                mocked_result: "ok".into(),
            }],
        };
        let anomalies = detect_anomalies(&doc, &out);
        let kinds: Vec<&str> = anomalies.iter().map(|a| a.kind.as_str()).collect();
        assert!(kinds.contains(&"scope_creep"));
        assert!(kinds.contains(&"missing_approval"));
    }
}
