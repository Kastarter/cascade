CREATE TABLE IF NOT EXISTS cascade_detection_runs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    detector_name   TEXT NOT NULL,
    window_start    TIMESTAMP NOT NULL,
    window_end      TIMESTAMP NOT NULL,
    signals_json    TEXT NOT NULL,
    created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_cascade_detection_runs_window
    ON cascade_detection_runs(window_start, window_end);

CREATE TABLE IF NOT EXISTS cascade_manager_suggestions (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    detection_run_id        INTEGER NOT NULL,
    kind                    TEXT NOT NULL,
    title                   TEXT NOT NULL,
    summary                 TEXT NOT NULL,
    evidence_json           TEXT NOT NULL,
    suggested_agent_kind    TEXT NOT NULL,
    severity_score          REAL NOT NULL,
    confidence              REAL NOT NULL,
    status                  TEXT NOT NULL DEFAULT 'pending',
    created_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sent_at                 TIMESTAMP,
    reviewed_at             TIMESTAMP,
    FOREIGN KEY (detection_run_id) REFERENCES cascade_detection_runs(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_cascade_manager_suggestions_status
    ON cascade_manager_suggestions(status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_cascade_manager_suggestions_run
    ON cascade_manager_suggestions(detection_run_id);
