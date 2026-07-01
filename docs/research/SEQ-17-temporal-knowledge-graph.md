# Sequence 17: Temporal Knowledge Graph and Entity Linking

## Overview

Cascade already records local work as flat moments in `recorded_context`, indexes them with `rewind_fts`, and answers through `RecordSearchAnswerer`. Sequence 04 covered embeddings, hybrid retrieval, and rank fusion, so this sequence focuses on the next memory layer: an on-device temporal graph that turns moments into entities and relationships.

The moat is not a generic GraphRAG import. It is a local work graph over people, projects, files, apps, URLs, tasks, and meetings, with every entity and relationship linked back to the recorded moment that produced it. The graph should live in the existing SQLite store, use bitemporal fields for "when it happened" versus "when Cascade learned it", and stay behind the same privacy boundary as recording: `PrivacyRules` drops sensitive moments, and `PIIDetector` redacts or blocks risky text before evidence enters graph tables.

The practical design is:

- Treat `recorded_context` rows as Graphiti-style episodes.
- Add canonical `graph_entity`, `graph_entity_alias`, `context_entity_link`, and `graph_edge` tables.
- Extract deterministic entities first from app/window metadata, file paths, URLs, dates, and Apple NaturalLanguage/DataDetectors.
- Use graph traversal as a new tool lane for `RecordSearchAnswerer`, not a replacement for FTS/vector search.
- Prefer SQLite recursive CTEs and optional closure tables over Neo4j/Kuzu/FalkorDB until local scale proves otherwise.

## OSS/Papers Table

| Source | URL | License | Technique | Cascade take |
| --- | --- | --- | --- | --- |
| Graphiti | https://github.com/getzep/graphiti | Apache-2.0 | Temporal context graph with entities, relationship facts, validity windows, provenance episodes, incremental ingestion, and hybrid semantic/keyword/graph retrieval. | Best conceptual fit. Copy the episode/entity/edge/provenance model, but avoid its graph backend dependency for the first local version. |
| Zep temporal KG paper | https://arxiv.org/abs/2501.13956 | Paper, N/A | Agent memory architecture built around Graphiti; emphasizes cross-session temporal reasoning and dynamic synthesis from conversational plus business data. | Validates graph memory for "who/what/when" questions. Use as evaluation inspiration, not as a hosted dependency. |
| Zep examples/integrations | https://github.com/getzep/zep | Apache-2.0 | Managed Zep integrations, ontology examples, benchmarks, and legacy CE archive; points users to Graphiti for OSS temporal KG core. | Useful for ontology and benchmark shapes. Managed Zep is not aligned with Cascade's local-first privacy model. |
| Cognee | https://github.com/topoteretes/cognee | Apache-2.0 | AI memory platform that ingests data, builds a self-hosted knowledge graph, and combines graph reasoning, vector embeddings, and ontology generation. | Good API vocabulary for `remember` / `recall` / `forget`, but heavier than Cascade needs. Borrow ontology-generation ideas later. |
| Mem0 | https://github.com/mem0ai/mem0 | Apache-2.0 | Long-term memory with ADD-only fact extraction, entity linking, BM25/semantic/entity fusion, and temporal reasoning. | Strong precedent for single-pass extraction and entity boosting. Cascade should reuse the idea with local extractors and SQLite tables. |
| Mem0 Graph Memory | https://docs.mem0.ai/open-source/features/graph-memory | Docs, N/A | Extracts entities, relationships, and timestamps on memory writes; stores vectors and graph edges together; returns related entities in a `relations` payload. | The search integration is directly useful: graph context enriches hits without necessarily reordering every result. |
| Microsoft GraphRAG | https://github.com/microsoft/graphrag | MIT | Pipeline to extract structured graph data from unstructured text, cluster communities, precompute community summaries, and answer global/local questions. | Good for larger-bet project/community summaries. Too batch-oriented and expensive for Cascade's live local recorder path. |
| GraphRAG paper | https://arxiv.org/abs/2404.16130 | Paper, N/A | Entity graph construction plus community summaries for query-focused summarization over private corpora. | Relevant for "show me everything about Acme" once Cascade has enough entity-linked moments to summarize a project neighborhood. |
| nano-graphrag | https://github.com/gusye1234/nano-graphrag | MIT | Compact GraphRAG implementation; explicit entity extraction prompt, graph storage interface, vector storage interface, local embedding examples, incremental insert. | Best code-reading reference for a small graph retrieval layer, but Cascade should implement the storage shape directly in Swift/SQLite. |
| Splink | https://github.com/moj-analytical-services/splink | MIT | Probabilistic record linkage/entity resolution over SQL backends for records without unique IDs. | Best model for deduping "Jane", "Jane D.", emails, contact names, and Slack/Mail names into one person entity. Use deterministic scoring first, then Splink-like probabilities. |
| Dedupe | https://github.com/dedupeio/dedupe | MIT | Fuzzy matching, deduplication, and entity resolution with learned matchers and blocking. | Useful as a reviewable merge workflow pattern. Cascade should start with deterministic candidate pairs and user-approved merges. |
| OpenNRE | https://github.com/thunlp/OpenNRE | MIT | Neural relation extraction toolkit that extracts relation triples between entity mentions from text. | Too heavy for the hot path, but validates the triple schema. Cascade can begin with deterministic relations and reserve LLM/ML relation extraction for background passes. |
| Bitemporal History | https://martinfowler.com/articles/bitemporal-history.html | Article, N/A | Models actual/valid time separately from record/transaction time; recommends append-only record history for retroactive corrections. | Directly maps to `valid_from`/`valid_to` and `recorded_from`/`recorded_to` on graph edges. |
| SQLite recursive CTEs | https://www.sqlite.org/lang_with.html | SQLite project docs | `WITH RECURSIVE` supports walking trees and graphs inside SQL. | Enough for depth-1 to depth-3 personal graph traversal without adding a graph DB. |
| Apple NLTagger | https://developer.apple.com/documentation/naturallanguage/nltagger | Apple SDK docs | On-device linguistic tagging, including name-type tagging through NaturalLanguage. | Use for local person, place, and organization candidates, with confidence and privacy gates. |
| Apple NSDataDetector | https://developer.apple.com/documentation/foundation/nsdatadetector | Apple SDK docs | On-device detection of links, dates, addresses, phone numbers, and other structured text patterns. | Already used by `PIIDetector`; extend the same path to extract URLs, dates, and contact-like signals for graph entities. |

## Concrete Graph Design For Cascade

### Minimal SQLite Schema

Add these migrations in `Sources/CascadeMemory/CascadeMemory.swift`, near the current `recorded_context`, `input_event`, `audit_event`, `agents`, and `context_embedding` tables.

```sql
CREATE TABLE IF NOT EXISTS graph_entity (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type TEXT NOT NULL,
    canonical_key TEXT NOT NULL,
    display_name TEXT NOT NULL,
    normalized_value TEXT,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    confidence REAL NOT NULL DEFAULT 1.0,
    source TEXT NOT NULL,
    pii_class TEXT,
    metadata_json TEXT,
    UNIQUE(type, canonical_key)
);

CREATE INDEX IF NOT EXISTS idx_graph_entity_type_key
    ON graph_entity(type, canonical_key);
CREATE INDEX IF NOT EXISTS idx_graph_entity_last_seen
    ON graph_entity(last_seen_at DESC);

CREATE TABLE IF NOT EXISTS graph_entity_alias (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_id INTEGER NOT NULL REFERENCES graph_entity(id) ON DELETE CASCADE,
    alias TEXT NOT NULL,
    alias_key TEXT NOT NULL,
    source TEXT NOT NULL,
    confidence REAL NOT NULL DEFAULT 1.0,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    UNIQUE(entity_id, alias_key)
);

CREATE INDEX IF NOT EXISTS idx_graph_entity_alias_key
    ON graph_entity_alias(alias_key);

CREATE TABLE IF NOT EXISTS context_entity_link (
    context_id INTEGER NOT NULL REFERENCES recorded_context(id) ON DELETE CASCADE,
    entity_id INTEGER NOT NULL REFERENCES graph_entity(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    extractor TEXT NOT NULL,
    evidence_text TEXT,
    span_start INTEGER,
    span_end INTEGER,
    confidence REAL NOT NULL DEFAULT 1.0,
    created_at TEXT NOT NULL,
    PRIMARY KEY(context_id, entity_id, role, extractor, span_start)
);

CREATE INDEX IF NOT EXISTS idx_context_entity_link_entity
    ON context_entity_link(entity_id, context_id);

CREATE TABLE IF NOT EXISTS graph_edge (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    subject_entity_id INTEGER NOT NULL REFERENCES graph_entity(id) ON DELETE CASCADE,
    predicate TEXT NOT NULL,
    object_entity_id INTEGER NOT NULL REFERENCES graph_entity(id) ON DELETE CASCADE,
    valid_from TEXT,
    valid_to TEXT,
    recorded_from TEXT NOT NULL,
    recorded_to TEXT,
    confidence REAL NOT NULL DEFAULT 1.0,
    provenance_context_id INTEGER REFERENCES recorded_context(id) ON DELETE SET NULL,
    provenance_input_event_id INTEGER REFERENCES input_event(id) ON DELETE SET NULL,
    extractor TEXT NOT NULL,
    metadata_json TEXT
);

CREATE INDEX IF NOT EXISTS idx_graph_edge_subject_time
    ON graph_edge(subject_entity_id, predicate, valid_from, valid_to);
CREATE INDEX IF NOT EXISTS idx_graph_edge_object_time
    ON graph_edge(object_entity_id, predicate, valid_from, valid_to);
CREATE INDEX IF NOT EXISTS idx_graph_edge_recorded
    ON graph_edge(recorded_from DESC);
```

Optional after the first version:

```sql
CREATE TABLE IF NOT EXISTS graph_edge_closure (
    ancestor_entity_id INTEGER NOT NULL,
    descendant_entity_id INTEGER NOT NULL,
    predicate TEXT NOT NULL,
    depth INTEGER NOT NULL,
    valid_from TEXT,
    valid_to TEXT,
    PRIMARY KEY(ancestor_entity_id, descendant_entity_id, predicate, depth, valid_from)
);
```

Use closure rows only for stable relations such as `PART_OF`, `SAME_AS`, `BELONGS_TO_PROJECT`, or `LOCATED_IN_FOLDER`. Do not materialize every mention edge.

### Entity Types

Start with a small ontology:

- `app`: from `recorded_context.app_name` and `bundle_identifier`.
- `window`: from `window_title`, scoped to app and normalized aggressively.
- `url`: from `NSDataDetector` links, browser window titles, and web metadata where available.
- `file`: from window title/path hints, Finder events, document app metadata, and input targets.
- `folder`: from file paths and Finder windows.
- `person`: from NLTagger names, Mail/Calendar/Slack/Messages metadata where available, and email display names.
- `organization`: from NLTagger organization names, email domains, URL domains, and window titles.
- `project`: inferred from repo/folder names, repeated title tokens, issue keys, and user-approved merges.
- `task`: extracted from "todo", "next", "follow up", due-date patterns, and action-item sections.
- `topic`: a low-confidence fallback for repeated named nouns that do not yet resolve to a project or organization.

Keep `topic` low status so it does not pollute the graph with every OCR noun.

### Edge Predicates

Start with deterministic, auditable predicates:

- `MENTIONED_IN`: entity -> moment, stored through `context_entity_link`, not `graph_edge`.
- `USED_APP`: person/user-local context -> app, or moment -> app in derived views.
- `VISITED_URL`: app/window or project -> url.
- `OPENED_FILE`: app/window or project -> file.
- `IN_FOLDER`: file -> folder.
- `BELONGS_TO_PROJECT`: file/url/person/task/topic -> project.
- `COMMUNICATED_WITH`: user-local work session -> person, sourced only from explicit messaging/mail/calendar context.
- `ASSIGNED_TASK`: person/project -> task when extracted from action-item text.
- `DUE_ON`: task -> date entity.
- `SAME_AS`: entity -> entity, only deterministic or user-approved.

Avoid vague predicates such as `RELATED_TO` in the first version. If a relation is only co-occurrence, keep it as shared provenance and compute it at query time.

### Extraction Pipeline

Add a new `GraphExtractor` in `Sources/CascadeMemory` or a small `WorkGraphKit` target if the file gets large. It should run after a `recorded_context` row is accepted, not before privacy checks.

1. Gate the context:
   - If `PrivacyRules.isSensitive(context)` is true, do nothing.
   - Redact evidence snippets with `PIIDetector.redact`.
   - If `PIIDetector.containsHighConfidencePII` finds secrets in candidate evidence, store only a hash/canonical key or skip the candidate.

2. Extract deterministic entities:
   - App entity from `app_name` plus `bundle_identifier`.
   - Window entity from app-scoped `window_title`.
   - URL/date/address/phone candidates from `NSDataDetector`; only store phone/address as sensitive entity types if the user later opts in.
   - File/folder candidates from window title patterns, known document extensions, Finder metadata, and `metadata_json`.
   - Person/place/organization candidates from `NLTagger` name types with low initial confidence.

3. Normalize:
   - `canonical_key = "\(type):\(normalized)"`.
   - URLs normalize to scheme+host+path without tracking params.
   - Files normalize to standardized path when available; otherwise use app+title+extension as provisional.
   - People normalize by lowercase, punctuation stripping, email local/domain hints, and alias rows.
   - Projects normalize from folder/repo names and stable issue-key prefixes.

4. Link:
   - Insert/update `graph_entity`.
   - Insert/update aliases.
   - Insert `context_entity_link` rows with extractor, span/evidence, and confidence.
   - Insert deterministic `graph_edge` rows with `recorded_from = captured_at` and `valid_from = captured_at` unless the text explicitly mentions another date.

5. Resolve duplicates:
   - Start deterministic: same URL, same file path, same bundle ID, same email, same normalized domain.
   - Add fuzzy candidates later with Splink/Dedupe-style blocking: same domain plus name similarity, same folder plus filename similarity, same recurring window title plus app.
   - Put ambiguous merges behind a Manager/Cascades review row before writing `SAME_AS`.

### Bitemporal Edge Handling

Graphiti's key idea is that facts change without losing history. Cascade can implement the same with simple SQLite intervals:

- `valid_from` / `valid_to`: when the relation was true in the user's work timeline.
- `recorded_from` / `recorded_to`: when Cascade believed the relation was current.

When a new edge supersedes an old edge, do not delete. Set the old edge's `recorded_to` to the new capture time and insert a replacement. For example, if a project file moves from `Drafts` to `Sent`, keep both folder relations and let Q&A ask "where was it then?" versus "where is it now?"

Default query semantics:

- Current graph: `recorded_to IS NULL AND (valid_to IS NULL OR valid_to > now)`.
- As-of graph: `recorded_from <= asOf AND (recorded_to IS NULL OR recorded_to > asOf)`.
- Timeline graph: overlap `valid_from`/`valid_to` with the user's requested date range.

### Graph Queries For RecordSearchAnswerer

Add a graph-aware tool lane beside the existing `search_record`, `get_timeframe`, `inspect_moment`, and `list_sessions` tools in `Sources/ProviderKit/RecordRecall.swift`.

Suggested tools:

- `find_entities(query, type?, limit?)`: FTS/alias lookup over `graph_entity` and `graph_entity_alias`.
- `entity_timeline(entity_id, since?, until?, limit?)`: moments linked to an entity, sorted by time.
- `entity_neighbors(entity_id, predicates?, depth?, as_of?)`: recursive CTE traversal over `graph_edge`.
- `moments_for_entities(entity_ids, mode, limit?)`: intersection/union of linked moments.
- `paths_between(source_entity_id, target_entity_id, max_depth?)`: explainable relationship paths.

Example recursive CTE:

```sql
WITH RECURSIVE walk(entity_id, depth, path) AS (
    SELECT ?, 0, printf('%d', ?)
    UNION ALL
    SELECT
        CASE
            WHEN e.subject_entity_id = walk.entity_id THEN e.object_entity_id
            ELSE e.subject_entity_id
        END,
        walk.depth + 1,
        path || '>' || e.id
    FROM graph_edge e
    JOIN walk
      ON e.subject_entity_id = walk.entity_id
      OR e.object_entity_id = walk.entity_id
    WHERE walk.depth < ?
      AND e.recorded_to IS NULL
      AND instr(path, printf('>%d', e.id)) = 0
)
SELECT * FROM walk;
```

Q&A flow:

1. User asks "show me everything about the Acme deal".
2. `find_entities("Acme", type: organization/project)` resolves candidates.
3. `entity_neighbors` expands to people, files, URLs, tasks, and apps.
4. `moments_for_entities` returns cited moments.
5. Existing `inspect_moment` provides full grounded evidence.
6. Answer cites moment IDs and names graph links explicitly.

### Files To Touch

- `Sources/CascadeMemory/CascadeMemory.swift`: migrations, write helpers, graph query helpers.
- `Sources/CascadeMemory/PrivacyRules.swift`: no schema change needed, but graph extraction must call it before writing.
- `Sources/CascadeMemory/PIIDetector.swift`: reuse redaction and `NSDataDetector`; consider exposing URL/date detection separately so extraction does not duplicate detector setup.
- `Sources/CascadeMemory/SemanticIndex.swift`: optional only for entity-name embeddings later. Do not make this sequence depend on a new embedding pass.
- `Sources/ProviderKit/RecordRecall.swift`: add graph recall tool functions.
- `Sources/ProviderKit/RecordSearchAnswerer.swift`: update tool prompt so graph tools are preferred for entity/project/person questions.
- `Sources/MacContextKit/RewindRecorder.swift`: call graph extraction after a context row is committed, or emit an indexing task.
- `Tests/CascadeMemoryTests`: add graph migration, extraction, bitemporal edge, and recursive traversal tests.
- `Tests/ProviderKitTests/RecordAnswererTests.swift`: add "Acme deal" graph-aware answer tests with citations.

## Quick Wins vs Larger Bets

### Quick Wins

1. Add schema and deterministic extraction for `app`, `url`, `file`, `folder`, and `person` candidates. This immediately enables "show moments involving X" without a new model.
2. Link every accepted moment to app/window entities. This creates a graph backbone from metadata Cascade already trusts.
3. Add `find_entities` and `entity_timeline` to `RecordSearchAnswerer`. These two tools answer most project/person/file questions with existing moment citations.
4. Use `NSDataDetector` to turn URLs and dates into first-class entities. This unlocks "what was due when" and "what links did I open for this project".
5. Add bitemporal fields from day one, even if the first extractor only sets `valid_from = recorded_from = captured_at`. Retrofitting time later is expensive.
6. Add alias rows for app names, URL domains, file basenames, and person names. Alias FTS gives a lot of recall before fuzzy matching is needed.
7. Store redacted evidence snippets in `context_entity_link`, not raw OCR windows. The full source remains in `recorded_context` behind existing privacy gates.

### Larger Bets

1. Project inference: cluster repeated files, URL domains, people, and folders into project entities, then let the user approve/rename them.
2. Splink-style probabilistic entity resolution: score candidate person/file/project merges with blocking, similarity features, and review thresholds.
3. Graph-aware summaries: precompute per-project/per-person temporal summaries from linked moments, similar to GraphRAG community reports but scoped to personal work.
4. Background relation extraction: use a local or opt-in LLM pass to extract richer triples from non-sensitive context, with confidence thresholds and audit events.
5. Closure table/materialized neighborhoods: cache stable multi-hop project neighborhoods if recursive CTEs become slow over months of data.
6. Entity review UI: add a Cascades/Manager surface for "Cascade thinks these are the same person/project/file" before writing `SAME_AS`.
7. Graph eval harness: fixtures with known people, files, projects, moved files, renamed docs, and retroactive task updates; measure entity recall, merge precision, traversal latency, and citation correctness.

## Recommendation

Build the first version as a SQLite-native `WorkGraph` inside `CascadeMemory`. Do not add a graph database. The minimal implementation can be useful with deterministic extraction only:

- Entities: app, window, URL, file, folder, person, organization, project, task.
- Links: moment-to-entity plus a few deterministic edges.
- Time: bitemporal edge columns from the first migration.
- Retrieval: entity lookup, entity timeline, and one-hop/two-hop neighbor expansion used by `RecordSearchAnswerer`.

This gives Cascade a defensible "second brain" layer while preserving the local-only storage and auditability that make the product distinct.
