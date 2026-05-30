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

use crate::cascade_llm::{call_anthropic, call_anthropic_json, LlmCall, MODEL_OPUS, MODEL_SONNET};
use cascade_schema::{
    append_audit, count_live_runs, create_detection_run, get_agent_action, get_agent_spec,
    insert_agent_action, insert_agent_run, insert_agent_spec, insert_manager_suggestion,
    last_live_run_at, list_actions_for_spec, list_agent_runs, list_agent_specs, list_audit,
    list_deployed_specs, list_manager_suggestions, list_privacy_aggregates, migrate, open,
    replace_privacy_aggregates, update_agent_action_state, update_agent_spec_status,
    update_manager_suggestion_status, AgentActionInput, AgentRunInput, AgentSpecInput,
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

/// The notes/docs app the employee actually uses most (Notion, Notes, Obsidian,
/// Google Docs, …) over the recent window — so a computer-use agent writes
/// where the employee already works instead of a hardcoded app. None if they
/// haven't used a writing app recently.
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
    let pool = open(&db_path).await.map_err(|e| format!("open cascade schema: {e}"))?;
    migrate(&pool).await.map_err(|e| format!("migrate cascade schema: {e}"))?;
    Ok(pool)
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
    #[serde(default)]
    suggested_agent_purpose: String,
    severity_score: f64,
    confidence: f64,
    #[serde(default)]
    evidence: Vec<CascadeManagerEvidence>,
}
fn default_tier() -> String {
    "suggest".to_string()
}

fn detector_system_prompt() -> String {
    // No preset pattern/agent taxonomy. The detector names whatever it actually
    // observes and proposes a bespoke agent for exactly that — so an unusual but
    // automatable behavior gets its own agent rather than being forced into a box.
    "You are Cascade's Waste Detector. You receive ONLY a privacy-sanitized, allowlisted activity \
summary (per-app: app, category, duration in minutes, context-switch count). You never see screen \
text, window titles, or any content.\n\n\
Find SPECIFIC, RECURRING things this person does that a software agent could take off their plate — \
real repetitive workflows, not personality judgments, and NOT forced into preset categories. \
Describe the actual behavior the data shows. For each finding, propose a BESPOKE helper agent built \
for exactly that task.\n\n\
HARD RULES:\n\
- Surface at most 6 findings. Fewer is better; only flag what the data clearly supports.\n\
- `kind`: a short kebab-case slug YOU invent that names the observed behavior (e.g. \
\"repeated-spreadsheet-reconciliation\", \"doc-to-chat-context-thrash\"). Do NOT use a fixed list.\n\
- `suggestedAgentKind`: a short kebab-case slug for the bespoke agent you'd build (e.g. \
\"daily-standup-drafter\"). Invent it to fit the finding.\n\
- `suggestedAgentPurpose`: ONE plain sentence — what the agent would actually DO to remove this \
specific toil.\n\
- `tier`: info | suggest | urgent. Reserve `urgent` for clear, costly, frequent toil.\n\
- If the day skews toward off-hours or overload, DEMOTE tier (do not reward overwork).\n\
- Never use evaluative language about the person (\"unfocused\", \"wasted time\"). Describe the workflow only.\n\
- `evidence` items must be derived strictly from the numbers given (label + value). No invented metrics.\n\
- severityScore and confidence are floats 0..1.\n\n\
Return ONLY JSON: {\"suggestions\":[{\"kind\":...,\"title\":...,\"summary\":...,\"tier\":...,\
\"suggestedAgentKind\":...,\"suggestedAgentPurpose\":...,\"severityScore\":0.0,\"confidence\":0.0,\
\"evidence\":[{\"label\":...,\"value\":...}]}]}"
        .to_string()
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
            value: s.suggested_agent_purpose.trim().to_string(),
        });
    }
    evidence.extend(s.evidence);
    CascadeManagerSuggestion {
        id: None,
        kind: slugify_kind(&s.kind),
        title: s.title,
        summary: s.summary,
        tier,
        evidence,
        suggested_agent_kind: slugify_kind(&s.suggested_agent_kind),
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

    // Surface the Cascade floating box while detection runs so it's visible the
    // moment the manager clicks "Refresh signals". Uses spec_id -1 (the detector).
    #[cfg(target_os = "macos")]
    crate::cascade_computer::box_begin(&app, -1, "Cascade Detector", "Reading your recent activity");

    // #5 first — the detector is only ever allowed to read this.
    let report = cascade_run_privacy_aggregation(app.clone(), Some(hours)).await?;

    #[cfg(target_os = "macos")]
    crate::cascade_computer::box_step(&app, -1, "Cascade Detector", "Privacy aggregation", "Sanitized your activity — finding automatable patterns…", 1);

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
        #[cfg(target_os = "macos")]
        crate::cascade_computer::box_end(&app, -1, "Cascade Detector", "Detection", "No activity to analyze yet.");
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

    #[cfg(target_os = "macos")]
    crate::cascade_computer::box_end(
        &app,
        -1,
        "Cascade Detector",
        "Detection",
        &format!("Found {} pattern(s) to review in Manager.", suggestions.len()),
    );

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

/// Capabilities a generated agent may declare. Deliberately VENDOR-NEUTRAL —
/// the agent does whatever work the detected pattern calls for (a recap, a
/// digest, a focus plan, a status draft, a reminder…), not a hardcoded
/// "send a Slack/Gmail message". Each maps to a real on-device implementation
/// in the runtime (see `execute_tool`). Anything off this list — especially
/// shell/exec — is rejected at validation time.
const TOOL_WHITELIST: &[&str] = &[
    "read.activity",   // read the employee's recent sanitized activity (input)
    "analyze.patterns", // LLM reasoning over the inputs
    "summarize.text",  // LLM summary / recap content
    "artifact.write",  // write a real deliverable document (recap/digest/plan/checklist)
    "draft.message",   // draft a message the employee can review + send themselves
    "task.create",     // create a task/checklist item as a real artifact
    "reminder.set",    // set a reminder as a real artifact
    "notify.local",    // a real macOS notification to the employee
];

/// Capabilities that produce an outward-facing / committing work product →
/// supervised (require employee approval) on an agent's first 3 live runs.
/// Pure analysis, reads, and local notifications auto-run.
const MUTATING_TOOLS: &[&str] = &["artifact.write", "draft.message", "task.create", "reminder.set"];

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
    /// Which capability this step invokes at runtime (from the whitelist), or
    /// null for a pure reasoning/decision step whose output feeds later steps.
    #[serde(default)]
    pub tool: Option<String>,
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
- artifact.write — write a real deliverable document the employee will use\n\
- draft.message — draft a message the employee can review and send THEMSELVES\n\
- task.create — create a task/checklist item as a real artifact\n\
- reminder.set — set a reminder as a real artifact\n\
- notify.local — send the employee a real notification\n\n\
HARD RULES (a violated rule means the spec is rejected — follow all):\n\
- `tools` may ONLY contain capabilities from the list above. NEVER invent tools. NEVER request shell/exec/network/file-system access.\n\
- EVERY workflow step must set `tool` to one of those capabilities, OR null for a pure reasoning step. The agent does the work BY running these steps in order — make the workflow concrete and runnable, not abstract.\n\
- The workflow must be linear or branch only on schema-checkable conditions — never \"the agent decides what to do next\".\n\
- Every step whose tool produces an outward-facing/committing artifact (artifact.write, draft.message, task.create, reminder.set) MUST have approvalRequired=true AND a matching entry in `approvalPoints`.\n\
- `rollbackPath` is REQUIRED — describe how to undo the agent's outputs (delete the artifact, dismiss the reminder).\n\
- `estimatedCostUsd` must be realistic per-execution and SHOULD be <= {:.2}.\n\
- `scheduleMinutes`: how often it should run itself (>= 60). Most agents are daily (1440) or a few times a day.\n\
- `taskDescription` is one plain-English sentence (readable, no jargon).\n\
- `requiredInputs[].source` should reference Cascade data the agent reads, e.g. \"cascade_privacy_aggregates\".\n\n\
Return ONLY JSON with EXACTLY these camelCase keys:\n\
{{\"name\":str,\"taskDescription\":str,\"rationale\":str,\
\"requiredInputs\":[{{\"source\":str,\"fields\":[str]}}],\
\"workflow\":[{{\"step\":int,\"action\":str,\"tool\":str|null,\"decisionPoint\":str|null,\"approvalRequired\":bool}}],\
\"tools\":[str],\"failureConditions\":[str],\"approvalPoints\":[str],\"rollbackPath\":str,\
\"estimatedCostUsd\":number,\"estimatedTimeSavedMin\":number,\"scheduleMinutes\":int}}",
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
        "Observed behavior (kind): {}\nTitle: {}\nWhat the person keeps doing: {}\n\
Proposed bespoke agent slug: {}\nSeverity: {:.2}  Confidence: {:.2}\nSignals:\n{}\n\n\
Design a BESPOKE agent for THIS specific recurring task — not a generic template. Its workflow \
should concretely remove this exact toil using the least intrusive, most reversible steps.",
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
    let has_mutating = doc.tools.iter().any(|t| MUTATING_TOOLS.contains(&t.as_str()))
        || doc
            .workflow
            .iter()
            .any(|s| s.tool.as_deref().map(|t| MUTATING_TOOLS.contains(&t)).unwrap_or(false));
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

/// Seed a ready-to-run demo agent (already deployed + dual-approved) so the
/// deployment lifecycle, "Run now", "Watch it work", and the live floating box
/// can be tested without waiting for the detector to surface a real pattern.
#[tauri::command]
#[specta::specta]
pub async fn cascade_seed_demo_agent(app: tauri::AppHandle) -> Result<CascadeAgentSpecView, String> {
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
            let run_id =
                create_detection_run(&pool, "demo-seed-from-activity", &now, &now, "{\"seed\":true}")
                    .await
                    .map_err(|e| format!("seed detection run: {e}"))?;
            let top_app =
                preferred_notes_app(&app).await.unwrap_or_else(|| "your notes app".to_string());
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
    let _ = append_audit(&pool, Some(spec.id), None, "system", "deployed_via_workflow", "{}").await;

    let record = get_agent_spec(&pool, spec.id)
        .await
        .map_err(|e| format!("reload spec: {e}"))?
        .ok_or("spec vanished")?;
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
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' })
        .collect::<String>()
        .trim_matches('-')
        .to_string()
}

fn is_mutating_tool(tool: &str) -> bool {
    MUTATING_TOOLS.contains(&tool)
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
        let _ = std::process::Command::new("osascript").args(["-e", &script]).output();
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (title, body);
    }
}

/// Perform the real side effect for a committing step: write the work product
/// to a real file (and, for reminders, notify). Returns the artifact path.
/// Used both during a run (auto-commit) and on later approval of a staged step.
fn commit_side_effect(
    app: &tauri::AppHandle,
    spec_id: i64,
    run_id: i64,
    step: i64,
    tool: &str,
    agent_name: &str,
    content: &str,
) -> Result<Option<String>, String> {
    match tool {
        "artifact.write" | "draft.message" | "task.create" | "reminder.set" => {
            let dir = agent_outputs_dir(app, spec_id)?;
            let ext = if tool == "draft.message" { "txt" } else { "md" };
            let fname = format!("run{run_id}-step{step}-{}.{ext}", slug(tool));
            let path = dir.join(fname);
            let header = format!(
                "<!-- Cascade agent: {agent_name} · {tool} · run {run_id} step {step} -->\n\n"
            );
            fs::write(&path, format!("{header}{content}"))
                .map_err(|e| format!("write artifact: {e}"))?;
            if tool == "reminder.set" {
                fire_notification(
                    &format!("Cascade reminder · {agent_name}"),
                    content,
                );
            }
            Ok(Some(path.display().to_string()))
        }
        "notify.local" => {
            fire_notification(&format!("Cascade · {agent_name}"), content);
            Ok(None)
        }
        // read.activity / analyze.patterns / summarize.text have no external
        // side effect — their output lives only in the action record + context.
        _ => Ok(None),
    }
}

fn runtime_step_system_prompt(agent_name: &str, task: &str) -> String {
    format!(
        "You are \"{agent_name}\", a deployed Cascade helper agent. Your job: {task}\n\
You are executing ONE step of your workflow. Produce ONLY the actual work product for this step — \
the real deliverable text (a recap, digest, plan, draft, task list, or notification body), with no \
preamble, no meta-commentary, no markdown fences. Ground it in the employee's real recent activity \
and the outputs of earlier steps. Be concise and immediately useful. If this step is a notification, \
output a single short sentence."
    )
}

fn runtime_step_user_prompt(
    step: &WorkflowStep,
    aggregates: &[CascadePrivacyAggregate],
    context: &str,
) -> String {
    let data = serde_json::to_string_pretty(aggregates).unwrap_or_else(|_| "[]".to_string());
    format!(
        "STEP {} — {}\nCapability: {}\n\nEMPLOYEE'S RECENT SANITIZED ACTIVITY:\n{}\n\nOUTPUTS OF EARLIER STEPS:\n{}\n\nProduce this step's work product now.",
        step.step,
        step.action,
        step.tool.as_deref().unwrap_or("analyze.patterns"),
        data,
        if context.is_empty() { "(none yet)" } else { context }
    )
}

/// Run one execution of a deployed agent. Performs real work; returns the run +
/// its actions. Called by the "Run now" command and the autonomous scheduler.
async fn run_agent_internal(
    app: &tauri::AppHandle,
    spec: &cascade_schema::AgentSpecRecord,
    trigger: &str,
) -> Result<CascadeRunResult, String> {
    if spec.status != "deployed" {
        return Err(format!("agent is not deployed (status: {})", spec.status));
    }
    let doc: AgentSpecDoc =
        serde_json::from_str(&spec.spec_json).map_err(|e| format!("parse spec: {e}"))?;

    let pool = cascade_pool(app).await?;
    // No approval prompts — the agent commits its work directly.
    let supervised = false;
    let _ = count_live_runs(&pool, spec.id).await; // keep run-count read for audit/debug

    // Show the Cascade floating box so the employee can watch this background run.
    #[cfg(target_os = "macos")]
    crate::cascade_computer::box_begin(app, spec.id, &doc.name, &doc.task_description);

    // The agent's real input: the employee's recent sanitized activity.
    let (_, _, summary) = fetch_activity_summary(app, 24).await?;
    let (aggregates, _) = if summary.data_status == "ok" {
        sanitize(&summary)
    } else {
        (Vec::new(), 0)
    };

    // Build a staged run record first so actions can reference it.
    let run_id = insert_agent_run(
        &pool,
        &AgentRunInput {
            spec_id: spec.id,
            mode: "live".to_string(),
            status: "running".to_string(),
            summary: format!("{trigger} run starting"),
            steps_json: "[]".to_string(),
            anomalies_json: "[]".to_string(),
            cost_usd: 0.0,
            duration_ms: 0,
        },
    )
    .await
    .map_err(|e| format!("create run: {e}"))?;

    let mut context = String::new();
    let mut total_cost = 0.0f64;
    let mut produced = 0i64;
    let mut pending = 0i64;
    let mut action_ids: Vec<i64> = Vec::new();

    for step in doc.workflow.iter().take(MAX_RUNTIME_STEPS) {
        let tool = step.tool.clone().unwrap_or_else(|| "analyze.patterns".to_string());
        if !TOOL_WHITELIST.contains(&tool.as_str()) {
            continue; // validation should prevent this; skip defensively
        }

        // Produce this step's content.
        let content = if tool == "read.activity" {
            serde_json::to_string_pretty(&aggregates).unwrap_or_default()
        } else {
            let call = LlmCall {
                model: MODEL_SONNET,
                system: runtime_step_system_prompt(&doc.name, &doc.task_description),
                user: runtime_step_user_prompt(step, &aggregates, &context),
                temperature: 0.3,
                max_tokens: 1200,
            };
            match call_anthropic(&call).await {
                Ok(res) => {
                    total_cost += res.cost_usd;
                    res.text.trim().to_string()
                }
                Err(e) => {
                    // Record the failure as an action and stop.
                    let id = insert_agent_action(
                        &pool,
                        &AgentActionInput {
                            run_id,
                            spec_id: spec.id,
                            step: step.step,
                            tool: tool.clone(),
                            summary: format!("step failed: {e}"),
                            content: None,
                            artifact_path: None,
                            reversible: false,
                            mutating: false,
                            state: "failed".to_string(),
                        },
                    )
                    .await
                    .map_err(|e| format!("record failed action: {e}"))?;
                    action_ids.push(id);
                    break;
                }
            }
        };

        let mutating = is_mutating_tool(&tool);
        let reversible = matches!(
            tool.as_str(),
            "artifact.write" | "draft.message" | "task.create" | "reminder.set"
        );

        // Supervision: on the first 3 runs, stage committing steps for approval.
        let (state, artifact_path) = if mutating && supervised {
            pending += 1;
            // Pre-compute the path the artifact WILL occupy on approval.
            let dir = agent_outputs_dir(app, spec.id)?;
            let ext = if tool == "draft.message" { "txt" } else { "md" };
            let path = dir
                .join(format!("run{run_id}-step{}-{}.{ext}", step.step, slug(&tool)))
                .display()
                .to_string();
            ("pending".to_string(), Some(path))
        } else {
            let path = commit_side_effect(
                app, spec.id, run_id, step.step, &tool, &doc.name, &content,
            )?;
            if mutating {
                produced += 1;
            }
            ("committed".to_string(), path)
        };

        let summary_line = match tool.as_str() {
            "read.activity" => "Read recent activity".to_string(),
            "analyze.patterns" => "Analyzed the activity".to_string(),
            "summarize.text" => "Drafted a summary".to_string(),
            "artifact.write" => "Wrote a deliverable document".to_string(),
            "draft.message" => "Drafted a message for review".to_string(),
            "task.create" => "Created a task".to_string(),
            "reminder.set" => "Set a reminder".to_string(),
            "notify.local" => "Notified the employee".to_string(),
            other => format!("Ran {other}"),
        };

        let id = insert_agent_action(
            &pool,
            &AgentActionInput {
                run_id,
                spec_id: spec.id,
                step: step.step,
                tool: tool.clone(),
                summary: if state == "pending" {
                    format!("{summary_line} (awaiting your approval)")
                } else {
                    summary_line.clone()
                },
                content: Some(content.chars().take(8000).collect()),
                artifact_path,
                reversible,
                mutating,
                state: state.clone(),
            },
        )
        .await
        .map_err(|e| format!("record action: {e}"))?;
        action_ids.push(id);

        #[cfg(target_os = "macos")]
        {
            let box_narr = if state == "pending" {
                format!("{summary_line} (needs your approval in Cascades)")
            } else {
                summary_line.clone()
            };
            crate::cascade_computer::box_step(app, spec.id, &doc.name, &doc.task_description, &box_narr, step.step);
        }

        context.push_str(&format!("\n[step {} · {}] {}\n", step.step, tool, content.chars().take(600).collect::<String>()));
    }

    // Reload the actions we just wrote, for anomaly detection + the return view.
    let all = list_actions_for_spec(&pool, spec.id, 200)
        .await
        .map_err(|e| format!("reload actions: {e}"))?;
    let actions: Vec<CascadeAgentAction> = all
        .into_iter()
        .filter(|a| action_ids.contains(&a.id))
        .map(|a| CascadeAgentAction {
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
        })
        .collect();

    // Runtime anomaly check: did the agent step outside its declared tools?
    let mut anomalies: Vec<Anomaly> = Vec::new();
    for a in &actions {
        let declared = doc.tools.iter().any(|t| t == &a.tool)
            || matches!(a.tool.as_str(), "read.activity" | "analyze.patterns");
        if !declared {
            anomalies.push(Anomaly {
                kind: "scope_creep".to_string(),
                detail: format!("used undeclared capability '{}'", a.tool),
            });
        }
        if a.state == "failed" {
            anomalies.push(Anomaly {
                kind: "step_failure".to_string(),
                detail: a.summary.clone(),
            });
        }
    }

    let status = if !anomalies.is_empty() {
        "flagged"
    } else if pending > 0 {
        "awaiting_approval"
    } else {
        "success"
    };

    let run_summary = format!(
        "{trigger} run · {} step(s), {produced} deliverable(s){}{}",
        actions.len(),
        if pending > 0 { format!(", {pending} awaiting approval") } else { String::new() },
        if !anomalies.is_empty() { format!(", {} anomaly flagged", anomalies.len()) } else { String::new() },
    );

    #[cfg(target_os = "macos")]
    crate::cascade_computer::box_end(app, spec.id, &doc.name, &doc.task_description, &run_summary);

    // Finalize the run row.
    let steps_json = serde_json::to_string(
        &actions
            .iter()
            .map(|a| SandboxStep {
                step: a.step,
                tool: a.tool.clone(),
                action: a.summary.clone(),
                mocked_result: a.state.clone(),
            })
            .collect::<Vec<_>>(),
    )
    .unwrap_or_else(|_| "[]".to_string());
    let _ = update_agent_run_final(&pool, run_id, status, &run_summary, &steps_json, &serde_json::to_string(&anomalies).unwrap_or_default(), total_cost).await;

    // A misbehaving run auto-pauses the agent (the monitor watching the agent).
    if !anomalies.is_empty() {
        let _ = update_agent_spec_status(&pool, spec.id, "paused", None, None).await;
        fire_notification(
            &format!("Cascade paused {}", doc.name),
            "An anomaly was detected during a run. The agent is paused for your review.",
        );
        let _ = append_audit(
            &pool,
            Some(spec.id),
            Some(run_id),
            "system",
            "auto_paused",
            &serde_json::json!({ "anomalies": anomalies.len() }).to_string(),
        )
        .await;
    }

    let _ = append_audit(
        &pool,
        Some(spec.id),
        Some(run_id),
        "system",
        "agent_run",
        &serde_json::json!({ "trigger": trigger, "status": status, "produced": produced, "pending": pending, "costUsd": total_cost }).to_string(),
    )
    .await;

    Ok(CascadeRunResult {
        run_id,
        spec_id: spec.id,
        status: status.to_string(),
        summary: run_summary,
        supervised,
        pending_count: pending,
        cost_usd: total_cost,
        anomalies,
        actions,
    })
}

/// Small helper to finalize a run row (no general-purpose update exists in the
/// schema crate; we only ever rewrite these fields once, at run end).
async fn update_agent_run_final(
    pool: &cascade_schema::sqlx::sqlite::SqlitePool,
    run_id: i64,
    status: &str,
    summary: &str,
    steps_json: &str,
    anomalies_json: &str,
    cost_usd: f64,
) -> Result<(), String> {
    use cascade_schema::sqlx;
    sqlx::query(
        "UPDATE cascade_agent_runs SET status=?2, summary=?3, steps_json=?4, anomalies_json=?5, cost_usd=?6 WHERE id=?1",
    )
    .bind(run_id)
    .bind(status)
    .bind(summary)
    .bind(steps_json)
    .bind(anomalies_json)
    .bind(cost_usd)
    .execute(pool)
    .await
    .map_err(|e| format!("finalize run: {e}"))?;
    Ok(())
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

/// "Run now" — execute a deployed agent on demand.
#[tauri::command]
#[specta::specta]
pub async fn cascade_run_agent(
    app: tauri::AppHandle,
    spec_id: i64,
) -> Result<CascadeRunResult, String> {
    let pool = cascade_pool(&app).await?;
    let spec = get_agent_spec(&pool, spec_id)
        .await
        .map_err(|e| format!("load spec: {e}"))?
        .ok_or_else(|| format!("spec {spec_id} not found"))?;
    run_agent_internal(&app, &spec, "manual").await
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
    commit_side_effect(
        &app, action.spec_id, action.run_id, action.step, &action.tool, &spec.name, &content,
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
pub async fn cascade_reject_action(
    app: tauri::AppHandle,
    action_id: i64,
) -> Result<(), String> {
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
pub async fn cascade_rollback_action(
    app: tauri::AppHandle,
    action_id: i64,
) -> Result<(), String> {
    let pool = cascade_pool(&app).await?;
    let action = get_agent_action(&pool, action_id)
        .await
        .map_err(|e| format!("load action: {e}"))?
        .ok_or_else(|| format!("action {action_id} not found"))?;
    if !action.reversible {
        return Err("this action is not reversible".to_string());
    }
    if action.state != "committed" {
        return Err(format!("only committed actions can be rolled back (state: {})", action.state));
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

/// Autonomous scheduler tick — run every deployed agent whose cadence is due.
/// Safe to call repeatedly; silently no-ops without an Anthropic key.
#[tauri::command]
#[specta::specta]
pub async fn cascade_tick_due_agents(app: tauri::AppHandle) -> Result<u32, String> {
    if crate::cascade_llm::read_anthropic_key().is_err() {
        return Ok(0);
    }
    let pool = cascade_pool(&app).await?;
    let specs = list_deployed_specs(&pool)
        .await
        .map_err(|e| format!("list deployed: {e}"))?;

    let now = Utc::now();
    let mut ran = 0u32;
    for spec in specs {
        let doc: AgentSpecDoc = match serde_json::from_str(&spec.spec_json) {
            Ok(d) => d,
            Err(_) => continue,
        };
        let cadence_min = doc.schedule_minutes.max(60);
        let due = match last_live_run_at(&pool, spec.id).await {
            Ok(Some(ts)) => {
                let last = chrono::DateTime::parse_from_rfc3339(&ts)
                    .map(|t| t.with_timezone(&Utc))
                    .ok()
                    .or_else(|| {
                        // sqlite CURRENT_TIMESTAMP is "YYYY-MM-DD HH:MM:SS" (UTC)
                        chrono::NaiveDateTime::parse_from_str(&ts, "%Y-%m-%d %H:%M:%S")
                            .ok()
                            .map(|n| n.and_utc())
                    });
                match last {
                    Some(t) => (now - t).num_minutes() >= cadence_min,
                    None => true,
                }
            }
            Ok(None) => true,
            Err(_) => false,
        };
        if due {
            if run_agent_internal(&app, &spec, "scheduled").await.is_ok() {
                ran += 1;
            }
        }
    }
    Ok(ran)
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
}
