-- Cascade Agent #4 steady-state runtime.
-- Every action a deployed agent actually takes is recorded here — the
-- accountability + reversibility ledger. Additive, CREATE ... IF NOT EXISTS.

CREATE TABLE IF NOT EXISTS cascade_agent_actions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id         INTEGER NOT NULL,
    spec_id        INTEGER NOT NULL,
    step           INTEGER NOT NULL,
    tool           TEXT NOT NULL,          -- capability invoked (read.activity, artifact.write, ...)
    summary        TEXT NOT NULL,          -- human-readable: what the agent did
    content        TEXT,                   -- produced work product (digest/draft/recap text), if any
    artifact_path  TEXT,                   -- real file on disk, if the action wrote one
    reversible     INTEGER NOT NULL DEFAULT 0,
    mutating       INTEGER NOT NULL DEFAULT 0,
    -- committed: the side effect happened. pending: staged, awaiting employee approval
    -- (first-3-runs supervision of mutating steps). rejected / rolled_back: undone.
    state          TEXT NOT NULL DEFAULT 'committed',
    created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (run_id) REFERENCES cascade_agent_runs(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_cascade_agent_actions_run
    ON cascade_agent_actions(run_id, step);
CREATE INDEX IF NOT EXISTS idx_cascade_agent_actions_spec
    ON cascade_agent_actions(spec_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cascade_agent_actions_state
    ON cascade_agent_actions(state);
