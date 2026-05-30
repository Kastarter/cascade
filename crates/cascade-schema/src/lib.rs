// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Sidecar tables that live alongside Screenpipe's frames/ocr_text/audio_chunks tables
// in the same SQLite file. Forward-compat for Layer 2 (tagging, entity extraction,
// classification). M6 in plan.md.

pub use sqlx;

use serde::{Deserialize, Serialize};
use sqlx::sqlite::{SqlitePool, SqlitePoolOptions};
use sqlx::Row;
use std::path::Path;

#[derive(Debug, thiserror::Error)]
pub enum CascadeSchemaError {
    #[error("sqlx: {0}")]
    Sqlx(#[from] sqlx::Error),
    #[error("migrate: {0}")]
    Migrate(#[from] sqlx::migrate::MigrateError),
}

pub type Result<T> = std::result::Result<T, CascadeSchemaError>;

#[derive(Debug, Clone, Copy)]
pub enum TagSource {
    Manual,
    Classifier,
    Agent,
}

impl TagSource {
    fn as_str(self) -> &'static str {
        match self {
            TagSource::Manual => "manual",
            TagSource::Classifier => "classifier",
            TagSource::Agent => "agent",
        }
    }
}

pub async fn open(db_path: &Path) -> Result<SqlitePool> {
    let url = format!("sqlite://{}", db_path.display());
    let pool = SqlitePoolOptions::new()
        .max_connections(4)
        .connect(&url)
        .await?;
    sqlx::query("PRAGMA foreign_keys = ON").execute(&pool).await?;
    Ok(pool)
}

pub async fn migrate(pool: &SqlitePool) -> Result<()> {
    // We share the SQLite database with Screenpipe, which uses sqlx::migrate
    // with the default `_sqlx_migrations` table. If we run our own migrator
    // against the same table it refuses to proceed — sees rows from
    // Screenpipe's migrations (e.g. 20240703111257) that aren't in our
    // ./migrations dir and errors with "previously applied but missing in
    // the resolved migrations".
    //
    // Workaround: bypass the migrator entirely and execute each SQL file
    // directly. All Cascade migrations are `CREATE ... IF NOT EXISTS`, so
    // re-execution is safe and idempotent. Trade-off: no UP/DOWN, no version
    // history for Cascade tables. Acceptable since our schema is always
    // additive (sidecar tables, never modify Screenpipe's).
    let sql_files = [
        include_str!("../migrations/0001_init.sql"),
        include_str!("../migrations/0002_manager_suggestions.sql"),
        include_str!("../migrations/0003_layer2_agents.sql"),
        include_str!("../migrations/0004_agent_runtime.sql"),
    ];

    for sql in sql_files {
        // Strip `--` line comments first. We can't rely on `starts_with("--")`
        // per-statement because comments at the file head end up prefixed onto
        // the first real CREATE statement after splitting on `;`. Inline
        // comments inside column definitions also need stripping. Note: this
        // assumes `--` never appears inside a string literal — true for our
        // migrations, would break for arbitrary SQL.
        let stripped: String = sql
            .lines()
            .map(|line| match line.find("--") {
                Some(idx) => &line[..idx],
                None => line,
            })
            .collect::<Vec<_>>()
            .join("\n");

        for stmt in stripped.split(';') {
            let trimmed = stmt.trim();
            if trimmed.is_empty() {
                continue;
            }
            sqlx::query(trimmed).execute(pool).await?;
        }
    }
    Ok(())
}

pub async fn tag_event(
    pool: &SqlitePool,
    frame_id: i64,
    tag: &str,
    source: TagSource,
    confidence: Option<f64>,
) -> Result<i64> {
    let row = sqlx::query(
        "INSERT INTO cascade_event_tags (frame_id, tag, source, confidence) \
         VALUES (?1, ?2, ?3, ?4) RETURNING id",
    )
    .bind(frame_id)
    .bind(tag)
    .bind(source.as_str())
    .bind(confidence)
    .fetch_one(pool)
    .await?;
    Ok(row.get::<i64, _>("id"))
}

pub async fn tags_for_frame(pool: &SqlitePool, frame_id: i64) -> Result<Vec<String>> {
    let rows = sqlx::query("SELECT tag FROM cascade_event_tags WHERE frame_id = ?1 ORDER BY id")
        .bind(frame_id)
        .fetch_all(pool)
        .await?;
    Ok(rows.into_iter().map(|r| r.get::<String, _>("tag")).collect())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManagerSuggestionInput {
    pub kind: String,
    pub title: String,
    pub summary: String,
    pub evidence_json: String,
    pub suggested_agent_kind: String,
    pub severity_score: f64,
    pub confidence: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManagerSuggestionRecord {
    pub id: i64,
    pub detection_run_id: i64,
    pub kind: String,
    pub title: String,
    pub summary: String,
    pub evidence_json: String,
    pub suggested_agent_kind: String,
    pub severity_score: f64,
    pub confidence: f64,
    pub status: String,
    pub created_at: String,
    pub sent_at: Option<String>,
    pub reviewed_at: Option<String>,
}

pub async fn create_detection_run(
    pool: &SqlitePool,
    detector_name: &str,
    window_start: &str,
    window_end: &str,
    signals_json: &str,
) -> Result<i64> {
    let row = sqlx::query(
        "INSERT INTO cascade_detection_runs (detector_name, window_start, window_end, signals_json) \
         VALUES (?1, ?2, ?3, ?4) RETURNING id",
    )
    .bind(detector_name)
    .bind(window_start)
    .bind(window_end)
    .bind(signals_json)
    .fetch_one(pool)
    .await?;
    Ok(row.get::<i64, _>("id"))
}

pub async fn insert_manager_suggestion(
    pool: &SqlitePool,
    detection_run_id: i64,
    suggestion: &ManagerSuggestionInput,
) -> Result<i64> {
    let row = sqlx::query(
        "INSERT INTO cascade_manager_suggestions (
            detection_run_id, kind, title, summary, evidence_json,
            suggested_agent_kind, severity_score, confidence
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) RETURNING id",
    )
    .bind(detection_run_id)
    .bind(&suggestion.kind)
    .bind(&suggestion.title)
    .bind(&suggestion.summary)
    .bind(&suggestion.evidence_json)
    .bind(&suggestion.suggested_agent_kind)
    .bind(suggestion.severity_score)
    .bind(suggestion.confidence)
    .fetch_one(pool)
    .await?;
    Ok(row.get::<i64, _>("id"))
}

pub async fn list_manager_suggestions(
    pool: &SqlitePool,
    status: Option<&str>,
    limit: i64,
) -> Result<Vec<ManagerSuggestionRecord>> {
    let rows = if let Some(status) = status {
        sqlx::query(
            "SELECT id, detection_run_id, kind, title, summary, evidence_json,
                    suggested_agent_kind, severity_score, confidence, status,
                    created_at, sent_at, reviewed_at
             FROM cascade_manager_suggestions
             WHERE status = ?1
             ORDER BY created_at DESC
             LIMIT ?2",
        )
        .bind(status)
        .bind(limit)
        .fetch_all(pool)
        .await?
    } else {
        sqlx::query(
            "SELECT id, detection_run_id, kind, title, summary, evidence_json,
                    suggested_agent_kind, severity_score, confidence, status,
                    created_at, sent_at, reviewed_at
             FROM cascade_manager_suggestions
             ORDER BY created_at DESC
             LIMIT ?1",
        )
        .bind(limit)
        .fetch_all(pool)
        .await?
    };

    Ok(rows
        .into_iter()
        .map(|row| ManagerSuggestionRecord {
            id: row.get("id"),
            detection_run_id: row.get("detection_run_id"),
            kind: row.get("kind"),
            title: row.get("title"),
            summary: row.get("summary"),
            evidence_json: row.get("evidence_json"),
            suggested_agent_kind: row.get("suggested_agent_kind"),
            severity_score: row.get("severity_score"),
            confidence: row.get("confidence"),
            status: row.get("status"),
            created_at: row.get("created_at"),
            sent_at: row.get("sent_at"),
            reviewed_at: row.get("reviewed_at"),
        })
        .collect())
}

pub async fn update_manager_suggestion_status(
    pool: &SqlitePool,
    suggestion_id: i64,
    status: &str,
) -> Result<()> {
    sqlx::query(
        "UPDATE cascade_manager_suggestions
         SET status = ?2,
             reviewed_at = CASE
                 WHEN ?2 IN ('approved', 'rejected', 'deployed') THEN CURRENT_TIMESTAMP
                 ELSE reviewed_at
             END,
             sent_at = CASE
                 WHEN ?2 = 'sent' THEN CURRENT_TIMESTAMP
                 ELSE sent_at
             END
         WHERE id = ?1",
    )
    .bind(suggestion_id)
    .bind(status)
    .execute(pool)
    .await?;
    Ok(())
}

// ─── Agent #5 · Privacy Aggregator ──────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrivacyAggregateInput {
    pub app: String,
    pub category: String,
    pub duration_min: f64,
    pub context_switches: i64,
    pub noised: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrivacyAggregateRecord {
    pub id: i64,
    pub window_start: String,
    pub window_end: String,
    pub app: String,
    pub category: String,
    pub duration_min: f64,
    pub context_switches: i64,
    pub noised: bool,
    pub created_at: String,
}

/// Replace the stored aggregate set for a window. The aggregator is the single
/// writer; re-running it for the same window supersedes the prior snapshot.
pub async fn replace_privacy_aggregates(
    pool: &SqlitePool,
    window_start: &str,
    window_end: &str,
    rows: &[PrivacyAggregateInput],
) -> Result<()> {
    let mut tx = pool.begin().await?;
    sqlx::query("DELETE FROM cascade_privacy_aggregates WHERE window_start = ?1 AND window_end = ?2")
        .bind(window_start)
        .bind(window_end)
        .execute(&mut *tx)
        .await?;
    for row in rows {
        sqlx::query(
            "INSERT INTO cascade_privacy_aggregates
                (window_start, window_end, app, category, duration_min, context_switches, noised)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        )
        .bind(window_start)
        .bind(window_end)
        .bind(&row.app)
        .bind(&row.category)
        .bind(row.duration_min)
        .bind(row.context_switches)
        .bind(row.noised as i64)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(())
}

pub async fn list_privacy_aggregates(
    pool: &SqlitePool,
    window_start: &str,
    window_end: &str,
) -> Result<Vec<PrivacyAggregateRecord>> {
    let rows = sqlx::query(
        "SELECT id, window_start, window_end, app, category, duration_min,
                context_switches, noised, created_at
         FROM cascade_privacy_aggregates
         WHERE window_start = ?1 AND window_end = ?2
         ORDER BY duration_min DESC",
    )
    .bind(window_start)
    .bind(window_end)
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|row| PrivacyAggregateRecord {
            id: row.get("id"),
            window_start: row.get("window_start"),
            window_end: row.get("window_end"),
            app: row.get("app"),
            category: row.get("category"),
            duration_min: row.get("duration_min"),
            context_switches: row.get("context_switches"),
            noised: row.get::<i64, _>("noised") != 0,
            created_at: row.get("created_at"),
        })
        .collect())
}

// ─── Agent #3 · Generated specs ─────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentSpecInput {
    pub suggestion_id: i64,
    pub name: String,
    pub spec_json: String,
    pub est_cost_usd: f64,
    pub est_time_saved_min: f64,
    pub validation_status: String,
    pub validation_notes: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentSpecRecord {
    pub id: i64,
    pub suggestion_id: i64,
    pub name: String,
    pub spec_json: String,
    pub est_cost_usd: f64,
    pub est_time_saved_min: f64,
    pub validation_status: String,
    pub validation_notes: Option<String>,
    pub status: String,
    pub employee_approved: bool,
    pub manager_approved: bool,
    pub created_at: String,
    pub updated_at: String,
}

pub async fn insert_agent_spec(pool: &SqlitePool, spec: &AgentSpecInput) -> Result<i64> {
    // A suggestion gets at most one live spec — regenerating supersedes the old.
    sqlx::query("DELETE FROM cascade_agent_specs WHERE suggestion_id = ?1")
        .bind(spec.suggestion_id)
        .execute(pool)
        .await?;
    let row = sqlx::query(
        "INSERT INTO cascade_agent_specs
            (suggestion_id, name, spec_json, est_cost_usd, est_time_saved_min,
             validation_status, validation_notes)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) RETURNING id",
    )
    .bind(spec.suggestion_id)
    .bind(&spec.name)
    .bind(&spec.spec_json)
    .bind(spec.est_cost_usd)
    .bind(spec.est_time_saved_min)
    .bind(&spec.validation_status)
    .bind(&spec.validation_notes)
    .fetch_one(pool)
    .await?;
    Ok(row.get::<i64, _>("id"))
}

fn map_spec_record(row: &sqlx::sqlite::SqliteRow) -> AgentSpecRecord {
    AgentSpecRecord {
        id: row.get("id"),
        suggestion_id: row.get("suggestion_id"),
        name: row.get("name"),
        spec_json: row.get("spec_json"),
        est_cost_usd: row.get("est_cost_usd"),
        est_time_saved_min: row.get("est_time_saved_min"),
        validation_status: row.get("validation_status"),
        validation_notes: row.get("validation_notes"),
        status: row.get("status"),
        employee_approved: row.get::<i64, _>("employee_approved") != 0,
        manager_approved: row.get::<i64, _>("manager_approved") != 0,
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}

const SPEC_COLS: &str = "id, suggestion_id, name, spec_json, est_cost_usd, est_time_saved_min, \
     validation_status, validation_notes, status, employee_approved, manager_approved, \
     created_at, updated_at";

pub async fn get_agent_spec(pool: &SqlitePool, spec_id: i64) -> Result<Option<AgentSpecRecord>> {
    let sql = format!("SELECT {SPEC_COLS} FROM cascade_agent_specs WHERE id = ?1");
    let row = sqlx::query(&sql).bind(spec_id).fetch_optional(pool).await?;
    Ok(row.map(|r| map_spec_record(&r)))
}

pub async fn list_agent_specs(pool: &SqlitePool, limit: i64) -> Result<Vec<AgentSpecRecord>> {
    let sql =
        format!("SELECT {SPEC_COLS} FROM cascade_agent_specs ORDER BY created_at DESC LIMIT ?1");
    let rows = sqlx::query(&sql).bind(limit).fetch_all(pool).await?;
    Ok(rows.iter().map(map_spec_record).collect())
}

/// Update a spec's lifecycle status and (optionally) approval flags. Passing
/// `None` for an approval flag leaves it untouched.
pub async fn update_agent_spec_status(
    pool: &SqlitePool,
    spec_id: i64,
    status: &str,
    employee_approved: Option<bool>,
    manager_approved: Option<bool>,
) -> Result<()> {
    sqlx::query(
        "UPDATE cascade_agent_specs
         SET status = ?2,
             employee_approved = CASE WHEN ?3 >= 0 THEN ?3 ELSE employee_approved END,
             manager_approved = CASE WHEN ?4 >= 0 THEN ?4 ELSE manager_approved END,
             updated_at = CURRENT_TIMESTAMP
         WHERE id = ?1",
    )
    .bind(spec_id)
    .bind(status)
    .bind(employee_approved.map(|v| v as i64).unwrap_or(-1))
    .bind(manager_approved.map(|v| v as i64).unwrap_or(-1))
    .execute(pool)
    .await?;
    Ok(())
}

// ─── Agent #4 · Runs + audit log ────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentRunInput {
    pub spec_id: i64,
    pub mode: String,
    pub status: String,
    pub summary: String,
    pub steps_json: String,
    pub anomalies_json: String,
    pub cost_usd: f64,
    pub duration_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentRunRecord {
    pub id: i64,
    pub spec_id: i64,
    pub mode: String,
    pub status: String,
    pub summary: String,
    pub steps_json: String,
    pub anomalies_json: String,
    pub cost_usd: f64,
    pub duration_ms: i64,
    pub created_at: String,
}

pub async fn insert_agent_run(pool: &SqlitePool, run: &AgentRunInput) -> Result<i64> {
    let row = sqlx::query(
        "INSERT INTO cascade_agent_runs
            (spec_id, mode, status, summary, steps_json, anomalies_json, cost_usd, duration_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) RETURNING id",
    )
    .bind(run.spec_id)
    .bind(&run.mode)
    .bind(&run.status)
    .bind(&run.summary)
    .bind(&run.steps_json)
    .bind(&run.anomalies_json)
    .bind(run.cost_usd)
    .bind(run.duration_ms)
    .fetch_one(pool)
    .await?;
    Ok(row.get::<i64, _>("id"))
}

pub async fn list_agent_runs(
    pool: &SqlitePool,
    spec_id: i64,
    limit: i64,
) -> Result<Vec<AgentRunRecord>> {
    let rows = sqlx::query(
        "SELECT id, spec_id, mode, status, summary, steps_json, anomalies_json,
                cost_usd, duration_ms, created_at
         FROM cascade_agent_runs
         WHERE spec_id = ?1
         ORDER BY created_at DESC
         LIMIT ?2",
    )
    .bind(spec_id)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|row| AgentRunRecord {
            id: row.get("id"),
            spec_id: row.get("spec_id"),
            mode: row.get("mode"),
            status: row.get("status"),
            summary: row.get("summary"),
            steps_json: row.get("steps_json"),
            anomalies_json: row.get("anomalies_json"),
            cost_usd: row.get("cost_usd"),
            duration_ms: row.get("duration_ms"),
            created_at: row.get("created_at"),
        })
        .collect())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEntry {
    pub id: i64,
    pub spec_id: Option<i64>,
    pub run_id: Option<i64>,
    pub actor: String,
    pub action: String,
    pub detail_json: String,
    pub created_at: String,
}

/// Append-only. There is no update/delete path for the audit log by design.
pub async fn append_audit(
    pool: &SqlitePool,
    spec_id: Option<i64>,
    run_id: Option<i64>,
    actor: &str,
    action: &str,
    detail_json: &str,
) -> Result<i64> {
    let row = sqlx::query(
        "INSERT INTO cascade_audit_log (spec_id, run_id, actor, action, detail_json)
         VALUES (?1, ?2, ?3, ?4, ?5) RETURNING id",
    )
    .bind(spec_id)
    .bind(run_id)
    .bind(actor)
    .bind(action)
    .bind(detail_json)
    .fetch_one(pool)
    .await?;
    Ok(row.get::<i64, _>("id"))
}

pub async fn list_audit(pool: &SqlitePool, spec_id: i64, limit: i64) -> Result<Vec<AuditEntry>> {
    let rows = sqlx::query(
        "SELECT id, spec_id, run_id, actor, action, detail_json, created_at
         FROM cascade_audit_log
         WHERE spec_id = ?1
         ORDER BY created_at DESC, id DESC
         LIMIT ?2",
    )
    .bind(spec_id)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|row| AuditEntry {
            id: row.get("id"),
            spec_id: row.get("spec_id"),
            run_id: row.get("run_id"),
            actor: row.get("actor"),
            action: row.get("action"),
            detail_json: row.get("detail_json"),
            created_at: row.get("created_at"),
        })
        .collect())
}

// ─── Agent #4 · Runtime actions ledger ──────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentActionInput {
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentActionRecord {
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

fn map_action(row: &sqlx::sqlite::SqliteRow) -> AgentActionRecord {
    AgentActionRecord {
        id: row.get("id"),
        run_id: row.get("run_id"),
        spec_id: row.get("spec_id"),
        step: row.get("step"),
        tool: row.get("tool"),
        summary: row.get("summary"),
        content: row.get("content"),
        artifact_path: row.get("artifact_path"),
        reversible: row.get::<i64, _>("reversible") != 0,
        mutating: row.get::<i64, _>("mutating") != 0,
        state: row.get("state"),
        created_at: row.get("created_at"),
    }
}

const ACTION_COLS: &str =
    "id, run_id, spec_id, step, tool, summary, content, artifact_path, reversible, mutating, state, created_at";

pub async fn insert_agent_action(pool: &SqlitePool, action: &AgentActionInput) -> Result<i64> {
    let row = sqlx::query(
        "INSERT INTO cascade_agent_actions
            (run_id, spec_id, step, tool, summary, content, artifact_path, reversible, mutating, state)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) RETURNING id",
    )
    .bind(action.run_id)
    .bind(action.spec_id)
    .bind(action.step)
    .bind(&action.tool)
    .bind(&action.summary)
    .bind(&action.content)
    .bind(&action.artifact_path)
    .bind(action.reversible as i64)
    .bind(action.mutating as i64)
    .bind(&action.state)
    .fetch_one(pool)
    .await?;
    Ok(row.get::<i64, _>("id"))
}

pub async fn get_agent_action(pool: &SqlitePool, action_id: i64) -> Result<Option<AgentActionRecord>> {
    let sql = format!("SELECT {ACTION_COLS} FROM cascade_agent_actions WHERE id = ?1");
    let row = sqlx::query(&sql).bind(action_id).fetch_optional(pool).await?;
    Ok(row.map(|r| map_action(&r)))
}

pub async fn list_actions_for_spec(
    pool: &SqlitePool,
    spec_id: i64,
    limit: i64,
) -> Result<Vec<AgentActionRecord>> {
    let sql = format!(
        "SELECT {ACTION_COLS} FROM cascade_agent_actions WHERE spec_id = ?1 ORDER BY created_at DESC, id DESC LIMIT ?2"
    );
    let rows = sqlx::query(&sql).bind(spec_id).bind(limit).fetch_all(pool).await?;
    Ok(rows.iter().map(map_action).collect())
}

pub async fn update_agent_action_state(
    pool: &SqlitePool,
    action_id: i64,
    state: &str,
) -> Result<()> {
    sqlx::query("UPDATE cascade_agent_actions SET state = ?2 WHERE id = ?1")
        .bind(action_id)
        .bind(state)
        .execute(pool)
        .await?;
    Ok(())
}

/// Count completed live runs for a spec — used for the "first 3 runs are
/// supervised" rule. Sandbox runs don't count.
pub async fn count_live_runs(pool: &SqlitePool, spec_id: i64) -> Result<i64> {
    let row = sqlx::query(
        "SELECT COUNT(*) AS n FROM cascade_agent_runs WHERE spec_id = ?1 AND mode = 'live'",
    )
    .bind(spec_id)
    .fetch_one(pool)
    .await?;
    Ok(row.get::<i64, _>("n"))
}

pub async fn last_live_run_at(pool: &SqlitePool, spec_id: i64) -> Result<Option<String>> {
    let row = sqlx::query(
        "SELECT MAX(created_at) AS t FROM cascade_agent_runs WHERE spec_id = ?1 AND mode = 'live'",
    )
    .bind(spec_id)
    .fetch_one(pool)
    .await?;
    Ok(row.get::<Option<String>, _>("t"))
}

/// All specs currently in `deployed` status — the scheduler's work list.
pub async fn list_deployed_specs(pool: &SqlitePool) -> Result<Vec<AgentSpecRecord>> {
    let sql = format!(
        "SELECT {SPEC_COLS} FROM cascade_agent_specs WHERE status = 'deployed' ORDER BY created_at ASC"
    );
    let rows = sqlx::query(&sql).fetch_all(pool).await?;
    Ok(rows.iter().map(map_spec_record).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    // The frames table normally comes from Screenpipe. For unit-testing our schema
    // in isolation, we stub a minimal frames table so our FKs validate.
    async fn stub_frames(pool: &SqlitePool) -> Result<()> {
        sqlx::query("CREATE TABLE frames (id INTEGER PRIMARY KEY, timestamp TIMESTAMP)")
            .execute(pool)
            .await?;
        sqlx::query("INSERT INTO frames (id, timestamp) VALUES (1, CURRENT_TIMESTAMP)")
            .execute(pool)
            .await?;
        Ok(())
    }

    #[tokio::test]
    async fn tag_roundtrip() -> Result<()> {
        let dir = tempdir().unwrap();
        let db = dir.path().join("test.db");
        std::fs::File::create(&db).unwrap();

        let pool = open(&db).await?;
        stub_frames(&pool).await?;
        migrate(&pool).await?;

        let id = tag_event(&pool, 1, "deep_work", TagSource::Manual, Some(0.9)).await?;
        assert!(id > 0);

        let tags = tags_for_frame(&pool, 1).await?;
        assert_eq!(tags, vec!["deep_work".to_string()]);
        Ok(())
    }

    #[tokio::test]
    async fn fk_cascade_deletes_tags() -> Result<()> {
        let dir = tempdir().unwrap();
        let db = dir.path().join("test.db");
        std::fs::File::create(&db).unwrap();

        let pool = open(&db).await?;
        stub_frames(&pool).await?;
        migrate(&pool).await?;

        tag_event(&pool, 1, "deep_work", TagSource::Manual, None).await?;
        sqlx::query("DELETE FROM frames WHERE id = 1").execute(&pool).await?;

        let tags = tags_for_frame(&pool, 1).await?;
        assert!(tags.is_empty(), "expected FK cascade to remove tags");
        Ok(())
    }

    #[tokio::test]
    async fn manager_suggestions_roundtrip() -> Result<()> {
        let dir = tempdir().unwrap();
        let db = dir.path().join("test.db");
        std::fs::File::create(&db).unwrap();

        let pool = open(&db).await?;
        stub_frames(&pool).await?;
        migrate(&pool).await?;

        let run_id = create_detection_run(
            &pool,
            "waste-detector-v1",
            "2026-05-26T09:00:00Z",
            "2026-05-26T17:00:00Z",
            r#"{"totalMinutes": 180}"#,
        )
        .await?;

        let suggestion_id = insert_manager_suggestion(
            &pool,
            run_id,
            &ManagerSuggestionInput {
                kind: "context_switching".to_string(),
                title: "Heavy context switching".to_string(),
                summary: "Too many short windows".to_string(),
                evidence_json: r#"[{"label":"windows","value":"14"}]"#.to_string(),
                suggested_agent_kind: "focus-guard".to_string(),
                severity_score: 0.82,
                confidence: 0.74,
            },
        )
        .await?;
        assert!(suggestion_id > 0);

        let suggestions = list_manager_suggestions(&pool, Some("pending"), 10).await?;
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].kind, "context_switching");

        update_manager_suggestion_status(&pool, suggestion_id, "sent").await?;
        let sent = list_manager_suggestions(&pool, Some("sent"), 10).await?;
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0].id, suggestion_id);
        Ok(())
    }

    #[tokio::test]
    async fn privacy_aggregates_replace_is_idempotent() -> Result<()> {
        let dir = tempdir().unwrap();
        let db = dir.path().join("test.db");
        std::fs::File::create(&db).unwrap();
        let pool = open(&db).await?;
        stub_frames(&pool).await?;
        migrate(&pool).await?;

        let rows = vec![
            PrivacyAggregateInput {
                app: "Slack".into(),
                category: "communication".into(),
                duration_min: 42.0,
                context_switches: 18,
                noised: false,
            },
            PrivacyAggregateInput {
                app: "Cursor".into(),
                category: "coding".into(),
                duration_min: 95.0,
                context_switches: 4,
                noised: true,
            },
        ];
        replace_privacy_aggregates(&pool, "S", "E", &rows).await?;
        replace_privacy_aggregates(&pool, "S", "E", &rows).await?; // re-run must not duplicate

        let stored = list_privacy_aggregates(&pool, "S", "E").await?;
        assert_eq!(stored.len(), 2);
        assert_eq!(stored[0].app, "Cursor"); // ordered by duration desc
        assert!(stored[0].noised);
        Ok(())
    }

    #[tokio::test]
    async fn agent_spec_lifecycle_and_audit() -> Result<()> {
        let dir = tempdir().unwrap();
        let db = dir.path().join("test.db");
        std::fs::File::create(&db).unwrap();
        let pool = open(&db).await?;
        stub_frames(&pool).await?;
        migrate(&pool).await?;

        let run_id = create_detection_run(&pool, "d", "S", "E", "{}").await?;
        let suggestion_id = insert_manager_suggestion(
            &pool,
            run_id,
            &ManagerSuggestionInput {
                kind: "communication_churn".into(),
                title: "t".into(),
                summary: "s".into(),
                evidence_json: "[]".into(),
                suggested_agent_kind: "inbox-batcher".into(),
                severity_score: 0.6,
                confidence: 0.7,
            },
        )
        .await?;

        let spec_id = insert_agent_spec(
            &pool,
            &AgentSpecInput {
                suggestion_id,
                name: "Inbox batcher".into(),
                spec_json: r#"{"task":"batch inbox"}"#.into(),
                est_cost_usd: 0.03,
                est_time_saved_min: 45.0,
                validation_status: "valid".into(),
                validation_notes: None,
            },
        )
        .await?;
        assert!(spec_id > 0);

        // regeneration supersedes (only one spec per suggestion)
        let spec_id2 = insert_agent_spec(
            &pool,
            &AgentSpecInput {
                suggestion_id,
                name: "Inbox batcher v2".into(),
                spec_json: "{}".into(),
                est_cost_usd: 0.02,
                est_time_saved_min: 50.0,
                validation_status: "valid".into(),
                validation_notes: None,
            },
        )
        .await?;
        let all = list_agent_specs(&pool, 10).await?;
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].id, spec_id2);

        update_agent_spec_status(&pool, spec_id2, "approved", Some(true), Some(true)).await?;
        let spec = get_agent_spec(&pool, spec_id2).await?.unwrap();
        assert_eq!(spec.status, "approved");
        assert!(spec.employee_approved && spec.manager_approved);

        let run = insert_agent_run(
            &pool,
            &AgentRunInput {
                spec_id: spec_id2,
                mode: "sandbox".into(),
                status: "success".into(),
                summary: "ok".into(),
                steps_json: "[]".into(),
                anomalies_json: "[]".into(),
                cost_usd: 0.004,
                duration_ms: 1200,
            },
        )
        .await?;
        assert!(run > 0);
        let runs = list_agent_runs(&pool, spec_id2, 10).await?;
        assert_eq!(runs.len(), 1);

        append_audit(&pool, Some(spec_id2), Some(run), "employee", "sandbox_test", "{}").await?;
        let audit = list_audit(&pool, spec_id2, 10).await?;
        assert_eq!(audit.len(), 1);
        assert_eq!(audit[0].action, "sandbox_test");

        // ── runtime ledger ──
        assert_eq!(count_live_runs(&pool, spec_id2).await?, 0);
        let live = insert_agent_run(
            &pool,
            &AgentRunInput {
                spec_id: spec_id2,
                mode: "live".into(),
                status: "awaiting_approval".into(),
                summary: "did real work".into(),
                steps_json: "[]".into(),
                anomalies_json: "[]".into(),
                cost_usd: 0.01,
                duration_ms: 500,
            },
        )
        .await?;
        assert_eq!(count_live_runs(&pool, spec_id2).await?, 1);
        assert!(last_live_run_at(&pool, spec_id2).await?.is_some());

        let action_id = insert_agent_action(
            &pool,
            &AgentActionInput {
                run_id: live,
                spec_id: spec_id2,
                step: 1,
                tool: "artifact.write".into(),
                summary: "wrote a digest".into(),
                content: Some("# Digest".into()),
                artifact_path: Some("/tmp/x.md".into()),
                reversible: true,
                mutating: true,
                state: "pending".into(),
            },
        )
        .await?;
        let acts = list_actions_for_spec(&pool, spec_id2, 10).await?;
        assert_eq!(acts.len(), 1);
        assert_eq!(acts[0].state, "pending");
        update_agent_action_state(&pool, action_id, "committed").await?;
        assert_eq!(get_agent_action(&pool, action_id).await?.unwrap().state, "committed");

        update_agent_spec_status(&pool, spec_id2, "deployed", None, None).await?;
        let deployed = list_deployed_specs(&pool).await?;
        assert_eq!(deployed.len(), 1);
        assert_eq!(deployed[0].id, spec_id2);
        Ok(())
    }
}
