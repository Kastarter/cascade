-- Cascade sidecar tables on the Screenpipe SQLite DB.
-- All Cascade tables prefixed `cascade_` to make ownership obvious.
-- Foreign keys point at Screenpipe's `frames.id` (BIGINT). ON DELETE CASCADE
-- so when Screenpipe prunes old frames, our extensions go with them.

CREATE TABLE IF NOT EXISTS cascade_event_tags (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    frame_id      INTEGER NOT NULL,
    tag           TEXT    NOT NULL,
    source        TEXT    NOT NULL DEFAULT 'manual', -- 'manual' | 'classifier' | 'agent'
    confidence    REAL,
    created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (frame_id) REFERENCES frames(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_cascade_event_tags_frame  ON cascade_event_tags(frame_id);
CREATE INDEX IF NOT EXISTS idx_cascade_event_tags_tag    ON cascade_event_tags(tag);

CREATE TABLE IF NOT EXISTS cascade_entity_extractions (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    frame_id      INTEGER NOT NULL,
    entity_type   TEXT    NOT NULL,   -- 'person' | 'project' | 'doc' | 'url' | 'app' | 'other'
    entity_value  TEXT    NOT NULL,
    span_start    INTEGER,            -- byte offset into ocr_text, nullable
    span_end      INTEGER,
    extractor     TEXT    NOT NULL,   -- model id or rule name
    confidence    REAL,
    created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (frame_id) REFERENCES frames(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_cascade_entity_frame  ON cascade_entity_extractions(frame_id);
CREATE INDEX IF NOT EXISTS idx_cascade_entity_value  ON cascade_entity_extractions(entity_value);

CREATE TABLE IF NOT EXISTS cascade_classifications (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    frame_id      INTEGER NOT NULL,
    category      TEXT    NOT NULL,   -- 'deep_work' | 'comms' | 'meeting' | 'browsing' | 'idle' | 'context_switch' | 'waste'
    productive    INTEGER NOT NULL,   -- 0 | 1
    classifier    TEXT    NOT NULL,
    confidence    REAL,
    created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (frame_id) REFERENCES frames(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_cascade_classifications_frame    ON cascade_classifications(frame_id);
CREATE INDEX IF NOT EXISTS idx_cascade_classifications_category ON cascade_classifications(category);
