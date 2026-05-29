-- Cascade Layer 2 agent tables.
-- All additive sidecar tables (CREATE ... IF NOT EXISTS) so the comment-strip /
-- split-on-`;` migrator in lib.rs re-runs them idempotently.

-- Agent #5 Privacy Aggregator output. The ONLY representation of the
-- employee's day that any downstream LLM agent (#2, #3, #4) is allowed to read.
-- Allowlist columns only — no OCR text, no window titles past the app boundary.
CREATE TABLE IF NOT EXISTS cascade_privacy_aggregates (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    window_start      TIMESTAMP NOT NULL,
    window_end        TIMESTAMP NOT NULL,
    app               TEXT NOT NULL,
    category          TEXT NOT NULL,   -- coding|browser|meeting|communication|writing|other
    duration_min      REAL NOT NULL,
    context_switches  INTEGER NOT NULL DEFAULT 0,
    noised            INTEGER NOT NULL DEFAULT 0,  -- 1 if DP jitter was applied (count < 10)
    created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_cascade_privacy_aggregates_window
    ON cascade_privacy_aggregates(window_start, window_end);

-- Agent #3 Agent Generator output. A typed, manager/employee-reviewable spec —
-- NOT executable until it passes sandbox + dual approval (#4).
CREATE TABLE IF NOT EXISTS cascade_agent_specs (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    suggestion_id       INTEGER NOT NULL,
    name                TEXT NOT NULL,
    spec_json           TEXT NOT NULL,   -- full structured spec (see cascade_llm AgentSpec)
    est_cost_usd        REAL NOT NULL DEFAULT 0,
    est_time_saved_min  REAL NOT NULL DEFAULT 0,
    validation_status   TEXT NOT NULL DEFAULT 'valid',  -- valid | invalid
    validation_notes    TEXT,
    -- lifecycle owned by Agent #4:
    -- generated -> review -> sandbox_passed/sandbox_failed -> approved -> deployed -> paused -> rejected
    status              TEXT NOT NULL DEFAULT 'generated',
    employee_approved   INTEGER NOT NULL DEFAULT 0,
    manager_approved    INTEGER NOT NULL DEFAULT 0,
    created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (suggestion_id) REFERENCES cascade_manager_suggestions(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_cascade_agent_specs_status
    ON cascade_agent_specs(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cascade_agent_specs_suggestion
    ON cascade_agent_specs(suggestion_id);

-- Agent #4 execution records — every sandbox or live run of a deployed agent.
CREATE TABLE IF NOT EXISTS cascade_agent_runs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    spec_id         INTEGER NOT NULL,
    mode            TEXT NOT NULL,                 -- sandbox | live
    status          TEXT NOT NULL,                 -- success | failed | flagged
    summary         TEXT NOT NULL,
    steps_json      TEXT NOT NULL DEFAULT '[]',    -- "what would have happened" trace
    anomalies_json  TEXT NOT NULL DEFAULT '[]',    -- anomaly detector findings
    cost_usd        REAL NOT NULL DEFAULT 0,
    duration_ms     INTEGER NOT NULL DEFAULT 0,
    created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (spec_id) REFERENCES cascade_agent_specs(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_cascade_agent_runs_spec
    ON cascade_agent_runs(spec_id, created_at DESC);

-- Immutable audit log. Every lifecycle action on every spec/run is appended
-- here. The employee can export it; nothing in the app updates or deletes rows.
CREATE TABLE IF NOT EXISTS cascade_audit_log (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    spec_id      INTEGER,
    run_id       INTEGER,
    actor        TEXT NOT NULL,         -- employee | manager | system
    action       TEXT NOT NULL,
    detail_json  TEXT NOT NULL DEFAULT '{}',
    created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_cascade_audit_log_spec
    ON cascade_audit_log(spec_id, created_at DESC);
