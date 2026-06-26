# SEQ-26: Event Store Engineering for Cascade

## Overview

Cascade's hot path is already append-heavy: `RewindRecorder.process(frame:)` and `CascadeAppModel.captureNow()` create `RecordedContext`, then `CascadeStore.insert(_:)` writes one row into `recorded_context`; `InputRecorder.drain()` calls `CascadeStore.insertInputEvents(_:)`; FTS5 is maintained by triggers in `CascadeStore.migrate(_:)`. The current design is simple and correct, but it leaves performance on the table in four places:

- Every screen context insert prepares a fresh statement and commits independently.
- `insertInputEvents(_:)` wraps a transaction but still prepares/finalizes the same insert statement for every event.
- Heavy text (`ocr_text`, AX text, metadata JSON) lives in the row store and is mirrored into an FTS5 maintenance path.
- Retention pruning deletes rows from large tables instead of dropping or sealing time partitions.

The best product direction is not to replace SQLite. Keep SQLite as the hot, auditable local row store, but make it behave like a purpose-built append log: one writer actor, batched prepared statements, integer time keys, manual WAL checkpoints, small hot rows, compressed OCR side storage, and day/block metadata that lets recency and range queries skip most data.

## OSS Repos & Papers

| name | url | stars/venue | license | technique |
|---|---:|---:|---|---|
| SQLite | https://github.com/sqlite/sqlite / https://sqlite.org/wal.html | 9.9k stars; SQLite docs; PVLDB 2022 paper: https://www.vldb.org/pvldb/vol15/p3535-gaffney.pdf | Public domain | WAL gives sequential append writes and concurrent readers; tune `synchronous`, `wal_autocheckpoint`, manual checkpoints, and avoid unnecessary `AUTOINCREMENT`. |
| GRDB.swift | https://github.com/groue/GRDB.swift | 8.5k stars | MIT | Swift-native SQLite patterns: serialized write queue, explicit transactions, statement reuse, observation/read separation. Useful as a design reference even if Cascade keeps raw `sqlite3`. |
| DuckDB | https://github.com/duckdb/duckdb / https://dl.acm.org/doi/10.1145/3299869.3320212 | 39k stars; SIGMOD 2019 | MIT | Embedded OLAP beside SQLite: vectorized scans, Parquet reads, columnar cold analytics without running a service. |
| Apache Arrow | https://github.com/apache/arrow | 16.9k stars | Apache-2.0 | Columnar memory layout and IPC; a model for storing OCR/event sidecars as typed columns rather than JSON/text-heavy rows. |
| Apache Parquet | https://parquet.apache.org/docs/file-format/ | Apache project | Apache-2.0 | Row groups, page metadata, dictionary/RLE/delta string encodings, Zstandard compression, and page indexes for min/max skipping. |
| Polars | https://github.com/pola-rs/polars | 38.9k stars | MIT | Lazy scans, predicate pushdown, streaming larger-than-RAM analytics over Arrow/Parquet; good reference for offline Cascade analytics/export tools. |
| ClickHouse | https://github.com/ClickHouse/ClickHouse | 48.2k stars | Apache-2.0 | MergeTree-style partitioning by date, order-by time keys, sparse min/max indexes, materialized rollups for append-only events. |
| QuestDB | https://github.com/questdb/questdb | 17.1k stars | Apache-2.0 | WAL -> native columnar -> Parquet tiering; designated timestamp, time-ordered partitions, and low-latency ingestion with late/cold storage separation. |
| TimescaleDB | https://github.com/timescale/timescaledb | 23k stars | Mixed/unknown + Apache-2.0 files | Hypertables/chunks and compression policies: split hot row chunks from compressed cold chunks ordered by time and segmented by dimensions such as app/bundle. |
| KurrentDB / EventStoreDB | https://github.com/EventStore/EventStore | 5.8k stars | Kurrent License v1, not permissive OSS for current code | Append-only stream discipline: per-stream sequence numbers, immutable events, projections/read models rebuilt from logs. Use as an architecture reference, not a code source. |
| LFS: The Design and Implementation of a Log-Structured File System | https://people.eecs.berkeley.edu/~brewer/cs262/LFS.pdf | ACM TOCS 1992 | Paper | Segment append, checkpoints, segment summaries, cleaner policy. Maps directly to sealed daily Cascade segments. |
| C-Store: A Column-oriented DBMS | https://www.vldb.org/conf/2005/papers/p553-stonebraker.pdf | VLDB 2005 | Paper | Columnar storage, sorted projections, compression by type, and separating write-optimized from read-optimized stores. |
| Gorilla: A Fast, Scalable, In-Memory Time Series Database | https://www.vldb.org/pvldb/vol8/p1816-teller.pdf | PVLDB 2015 | Paper | Delta-of-delta timestamp compression and XOR/value compression. Useful for input-event coordinates, scroll deltas, and sampled metrics. |
| BTrDB: Optimizing Storage System for Time Series Processing | https://www.usenix.org/conference/fast16/technical-sessions/presentation/andersen | USENIX FAST 2016 | Paper | Time-partitioned tree with versioned aggregates; use for block summaries over event/context ranges, not as a dependency. |
| Dremel: Interactive Analysis of Web-Scale Datasets | https://research.google/pubs/dremel-interactive-analysis-of-web-scale-datasets-2/ | VLDB 2010 | Paper | Nested columnar representation, late materialization, and scanning only requested columns. Relevant to OCR/metadata sidecars. |

## Concrete Techniques to Adopt

- In `Sources/CascadeMemory/CascadeMemory.swift`, change `recorded_context.id INTEGER PRIMARY KEY AUTOINCREMENT` and `input_event.id INTEGER PRIMARY KEY AUTOINCREMENT` to plain `INTEGER PRIMARY KEY` for new databases. Cascade deletes old rows, not the max row, so normal rowid allocation preserves monotonic behavior while avoiding `sqlite_sequence` write overhead. Keep migrations non-destructive for existing databases.

- In `CascadeStore.migrate(_:)`, add hot-path PRAGMAs immediately after opening the DB: `PRAGMA busy_timeout=5000;`, `PRAGMA journal_mode=WAL;`, `PRAGMA synchronous=NORMAL;`, `PRAGMA temp_store=MEMORY;`, a bounded negative `cache_size`, and a conservative `mmap_size` for read-heavy search. SQLite documents WAL as faster in most scenarios, with concurrent readers/writers and sequential writes; it also documents that `synchronous=NORMAL` in WAL avoids per-commit syncs while staying consistent, at the cost of possible rollback after power loss.

- If audit durability must survive power loss, split audit durability from context throughput: move `audit_event` writes into a small `CascadeAudit.sqlite` opened with `synchronous=FULL`, while `recorded_context`, `input_event`, FTS, and embeddings use `synchronous=NORMAL`. This maps to `appendAudit(_:)`, `latestAuditHash()`, and `verifyAuditChain()`.

- Disable automatic checkpoints in `CascadeStore.migrate(_:)` with `PRAGMA wal_autocheckpoint=0;`, then add `CascadeStore.checkpoint(mode:)` using `sqlite3_wal_checkpoint_v2`. Call `PASSIVE` after every N inserted rows or when the WAL exceeds a size threshold, and call `TRUNCATE` when recording stops. SQLite's own WAL notes warn that default autocheckpoint makes the commit that crosses the threshold much slower; Cascade should move that work to idle/pause boundaries.

- Add a `ContextWriteBuffer` actor in `MacContextKit` and change `RewindRecorder.process(frame:)` to enqueue contexts rather than `await store.insert(context)` for every frame. Flush every 5-15 rows or 1 second with a new `CascadeStore.insertContexts(_:)` transaction. Keep `captureNow()` using single insert for explicit user capture.

- Rewrite `CascadeStore.insert(_:)` and `insertInputEvents(_:)` to prepare statements once per transaction. `insertInputEvents(_:)` currently starts a transaction but calls `withStatement(sql)` inside the event loop, so it still prepares/finalizes per event. Prepare once, bind/reset/clear for each row, then commit.

- Replace `captured_at TEXT` as the primary range key with `captured_ms INTEGER NOT NULL` for new rows, populated from `Date.timeIntervalSince1970 * 1000`. Keep `captured_at` for compatibility or as a generated/display column. Update `contextTimeline(since:)`, `inputEvents(between:and:)`, `recentContexts(limit:)`, and prune queries to use integer range predicates. This reduces index size and comparison cost.

- Add covering indexes matched to Cascade queries: `recorded_context(captured_ms DESC, id DESC)`, `recorded_context(app_name, captured_ms DESC)`, `input_event(captured_ms ASC, id ASC)`, and `input_event(bundle_identifier, captured_ms ASC, kind)`. The current single timestamp indexes help recency, but workflow mining and app-local review repeatedly filter by app/window/time.

- Add a `captured_day TEXT NOT NULL` column or generated column and a `day_partition` table with `day`, `min_ms`, `max_ms`, `row_count`, `ocr_bytes`, `frame_count`, `first_id`, `last_id`, and `sealed_at`. Update it inside the new batch insert path. Use it before scans in `contextTimeline(since:)`, `contentSamples(since:)`, retention pruning, and any future export job.

- Larger bet: shard hot data by day into `Cascade-YYYY-MM-DD.sqlite` plus `Cascade-index.sqlite`. `CascadeStore.defaultDatabasePath()` becomes a coordinator; today's database is writable, older day DBs are read-only attached on demand. Retention becomes file deletion, not large `DELETE FROM recorded_context` and FTS churn.

- Before full daily sharding, make `prune(olderThan:maxBytes:)` chunked. Delete old rows in bounded batches by `id`/`captured_ms`, checkpoint between chunks, then delete image files. This avoids one giant delete transaction expanding the WAL and blocking readers.

- Split `ocr_text` out of `recorded_context`. Create `context_text(context_id INTEGER PRIMARY KEY, codec TEXT, byte_count INTEGER, text_blob BLOB, excerpt TEXT)`. Compress full OCR/AX text with Apple's Compression framework (`COMPRESSION_LZFSE`) first; evaluate Zstandard later if a dependency is acceptable. Keep `recorded_context` as a narrow timeline row.

- Change `rewind_fts` from external-content over `recorded_context` to an explicit contentless-delete FTS5 table keyed by `context_id`, and insert tokens manually in the same `insertContexts(_:)` transaction. SQLite FTS5 supports contentless-delete tables with delete/update semantics; this lets Cascade remove raw full OCR from the row store while keeping search indexes.

- Add `ocr_excerpt` or use `context_text.excerpt` for UI/search previews so `searchContexts`, `contentSamples`, and citation chips do not decompress full OCR for every candidate. Full text should be loaded only in `moment(id:)`, `RecordSearchAnswerer.inspect_moment`, and grounded answer citation expansion.

- Add FTS maintenance hooks: set FTS5 `automerge` low during recording, run `INSERT INTO rewind_fts(rewind_fts) VALUES('optimize')` during idle/recording stop, and use contentless-delete `deletemerge` behavior to compact tombstones after retention. This maps to `CascadeStore.migrate(_:)`, `prune(...)`, and the new checkpoint/maintenance method.

- Implement a small block index inspired by Parquet page indexes: `context_block(block_id, day, first_id, last_id, min_ms, max_ms, row_count, min_app, max_app, ocr_bytes)`, one row per 2,048 or 4,096 contexts. `contextTimeline` and future range-heavy analytics can skip blocks using min/max before touching rows, and daily exports can map directly to row groups.

- For `input_event`, store repeated low-cardinality fields as dictionary IDs: `app_dictionary`, `window_dictionary`, `bundle_dictionary`, and reference integers in new event rows. This borrows Parquet dictionary encoding and QuestDB symbol-column practice; it will shrink event rows and indexes where the same app/window repeats thousands of times.

- For typed input bursts, store both the current coalesced text event and optional compressed deltas: add `input_event_batch(batch_id, start_ms, end_ms, app_id, event_count, codec, blob)`. Use Gorilla-style delta encoding for timestamps and coordinates when events are dense; keep the existing normalized table for audit/debug until the batch format is proven.

- Add a cold export path rather than a runtime dependency first: `CascadeStore.exportDayToParquet(day:)` can be a separate tool or build-time optional module that writes sealed days as Arrow/Parquet. Use ZSTD compression and page indexes so future Manager analytics can scan `captured_ms`, `app_name`, and counts without opening the hot SQLite DB.

- If an embedded analytics dependency becomes acceptable, prefer DuckDB over a server database. It has Swift code in-tree, a C API, and native Parquet/CSV scanning. Use it only for sealed/cold data and Manager analytics, never for the recorder write path.

- Model KurrentDB/EventStoreDB's immutable stream semantics inside SQLite: add a unified `event_log(seq INTEGER PRIMARY KEY, captured_ms, stream, type, payload_ref, hash)` that records capture, input, audit, workflow-detected, and agent-run events. Existing tables become read models/projections. This is a larger refactor, but it gives deterministic replay and better debugging of "what changed when".

## Quick Wins vs Larger Bets

Quick wins:

- Remove per-row prepare/finalize in `insertInputEvents(_:)`.
- Add `insertContexts(_:)` with a short transaction batch and statement reuse.
- Add `busy_timeout`, `synchronous=NORMAL`, explicit `wal_autocheckpoint` policy, and manual `PASSIVE`/`TRUNCATE` checkpoints.
- Add integer `captured_ms` columns and query/index them for new writes.
- Add app/time covering indexes for workflow mining and recency views.
- Chunk retention deletes and checkpoint between chunks.

Medium changes:

- Add `ContextWriteBuffer` between `RewindRecorder` and `CascadeStore`.
- Split compressed full OCR into `context_text` while keeping excerpts in the hot row/query path.
- Convert `rewind_fts` to contentless-delete + explicit insert/delete maintenance.
- Add `captured_day` plus `day_partition` manifest rows.
- Add FTS optimize/merge maintenance on recording stop.

Larger bets:

- Daily SQLite shard files with a coordinator DB; delete old shards for retention.
- Parquet/Arrow export for sealed days and Manager analytics.
- Optional DuckDB-powered cold analytics over sealed Parquet.
- Unified immutable `event_log` plus projection tables.
- Gorilla-style binary input batches for dense pointer/key event sequences.

## License/Attribution Notes

- SQLite is public domain, but the official project asks contributors to preserve public-domain status; use the system SQLite APIs already available on macOS rather than copying upstream source.
- GRDB.swift, DuckDB, and Polars are MIT; Apache Arrow, Apache Parquet, ClickHouse, and QuestDB are Apache-2.0. If code or file-format logic is copied rather than reimplemented from specs, preserve license text and notices.
- TimescaleDB's repository reports mixed/unknown plus Apache-2.0 files; use it only as an architectural reference unless legal review approves specific files.
- Current KurrentDB is under Kurrent License v1 with hosted-service restrictions; do not copy code. The safe takeaway is immutable stream/event-log architecture.
- Academic papers are design references, not code licenses. Cite them in developer docs if their algorithms shape Cascade-specific implementations.
