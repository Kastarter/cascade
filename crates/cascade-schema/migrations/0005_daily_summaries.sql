-- Cascade daily activity summaries.
-- One compact, workflow-focused row per calendar day, drafted from that day's
-- Rewind by the daily summarizer ("Rewind agent"). This is the DURABLE artifact
-- the waste detector reads for cross-day consistency — so we never store or
-- re-chew 72h of raw captures. Additive sidecar table; see lib.rs migrate().
CREATE TABLE IF NOT EXISTS cascade_daily_summaries (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    day            TEXT NOT NULL UNIQUE,
    summary_text   TEXT NOT NULL,
    grounding_json TEXT NOT NULL DEFAULT '{}',
    apps_json      TEXT NOT NULL DEFAULT '[]',
    created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_cascade_daily_summaries_day
    ON cascade_daily_summaries(day);
