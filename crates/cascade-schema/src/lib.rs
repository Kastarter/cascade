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
}
