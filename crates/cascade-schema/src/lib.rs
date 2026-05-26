// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Sidecar tables that live alongside Screenpipe's frames/ocr_text/audio_chunks tables
// in the same SQLite file. Forward-compat for Layer 2 (tagging, entity extraction,
// classification). M6 in plan.md.

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
    sqlx::migrate!("./migrations").run(pool).await?;
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
}
