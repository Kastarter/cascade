# Sequence 4: Semantic Retrieval and Long-Term Memory

## Overview

Cascade already has the right recall shape, but the dense lane is still a prototype. The current path is:

- `Sources/CascadeMemory/SemanticIndex.swift`: creates a single embedding per recorded context by averaging Apple `NLEmbedding` word vectors, stores it in `context_embedding`, then brute-force scans every vector with a hard cosine floor of `0.55`.
- `Sources/CascadeMemory/CascadeMemory.swift`: keeps `recorded_context`, external-content FTS5 table `rewind_fts`, and `context_embedding`; `hybridContexts(matching:limit:candidatePool:)` already fuses BM25 and dense IDs with RRF.
- `Sources/ProviderKit/RecordRecall.swift`: exposes `search_record`, `get_timeframe`, `inspect_moment`, and `list_sessions` to the agent. `search_record` currently returns up to 12 hybrid hits.
- `Sources/ProviderKit/RecordSearchAnswerer.swift`: runs a <=6-hop Sonnet tool loop and expects cited answers.
- `Sources/ProviderKit/AssistMemory.swift`: keeps an 8-turn conversational memory plus a short-lived pointed element, but it is not durable recall over months of work.

The production-grade direction is incremental: keep SQLite as source of truth, keep BM25, keep RRF, but replace word-vector averaging with a real sentence embedding model, move vectors into a SQLite-native or sidecar ANN index, rank chunks instead of whole OCR blobs, add optional reranking for Ask, and add a durable memory-stream score that combines relevance, recency, importance, continuity, and provenance.

## OSS Repos & Papers

| Source | License | Technique | Quality / scale numbers | Cascade take |
| --- | --- | --- | --- | --- |
| [sentence-transformers/all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2) | Apache-2.0 | Compact sentence-transformer, 384-dim sentence/paragraph embeddings, trained on more than 1B sentence pairs. | 22.7M params; truncates past 256 word pieces; legacy MTEB average 56.26 and retrieval 41.95 as reported on the GTE model card. | Good baseline and easy CoreML export target, but weaker retrieval than newer small models. |
| [thenlper/gte-small](https://huggingface.co/thenlper/gte-small) | MIT | General Text Embeddings, BERT-based, average pooling, normalized 384-dim vectors. | 33.4M params, 0.07 GB, 512-token sequence length; legacy MTEB average 61.36, retrieval 49.46, reranking 57.7. | Best first candidate for Cascade's bundled English sentence embedder: small, MIT, strong retrieval, already has Core ML artifact metadata on Hugging Face. |
| [BAAI/bge-small-en-v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5) | MIT | BGE small English embedding, CLS pooling, optional query instruction for short-query-to-long-passage retrieval. | v1.5 improved similarity distribution and retrieval without instruction; model card warns old BGE scores cluster around 0.6-1, so absolute thresholds are unsafe. | Strong alternative to GTE. If used, replace Cascade's fixed `0.55` cutoff with per-model calibration and top-k ranking. |
| [Apple NLContextualEmbedding](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding) | Apple OS framework | On-device contextual embeddings in NaturalLanguage. | Apple docs do not publish retrieval benchmark numbers. | Useful privacy-preserving fallback when no bundled model is available, but quality must be measured against Cascade recall tasks before defaulting to it. |
| [MLX Swift LM / MLXEmbedders](https://github.com/ml-explore/mlx-swift-lm) | MIT | Swift package for MLX model loading; related `MLXEmbedders` examples target encoder/embedding models. | Repo advertises model loading, tokenizer/downloader integrations, LoRA/full fine-tuning, quantized models. | Feasible Swift-native path for local embeddings on Apple Silicon if deployment target and package size are acceptable. |
| [Hugging Face swift-transformers](https://github.com/huggingface/swift-transformers) | Apache-2.0 | Swift transformer-like API and tokenizer utilities used by Swift ML projects. | No retrieval benchmark; infrastructure library. | Useful for tokenizer parity if Cascade exports GTE/BGE to CoreML and needs Swift-side tokenization. |
| [Hugging Face exporters](https://github.com/huggingface/exporters) | Apache-2.0 | Exports Hugging Face models to CoreML and TensorFlow Lite. | Infrastructure project. | Use in a build script to generate `.mlpackage` artifacts for `gte-small` or `bge-small-en-v1.5`; keep generated model attribution in third-party notices. |
| [sqlite-vec](https://github.com/asg017/sqlite-vec) / [docs](https://alexgarcia.xyz/sqlite-vec/) | MIT / Apache-2.0 dual | Pure-C SQLite extension with `vec0` virtual tables for float, int8, and binary vectors; metadata, auxiliary, and partition columns. | Runs anywhere SQLite runs; example KNN is `WHERE embedding MATCH ? ORDER BY distance LIMIT k`; pre-v1, breaking changes expected. | Best first SQLite integration. It removes Swift brute-force scans and keeps vector search in the same database file model. |
| [sqlite-vss](https://github.com/asg017/sqlite-vss) | MIT | SQLite vector search backed by Faiss with FTS5-like API. | Author recommends new projects use `sqlite-vec`; repo is not actively developed. | Avoid for new work unless Faiss behavior is specifically needed. |
| [USearch](https://github.com/unum-cloud/usearch) | Apache-2.0 | Compact HNSW ANN engine with Objective-C and Swift bindings. | HNSW index; repo emphasizes broad language support and compact search. | Larger-scale sidecar for months of vectors if `sqlite-vec` exact KNN is too slow. Persist IDs by `context_chunk.id`. |
| [hnswlib](https://github.com/nmslib/hnswlib) | Apache-2.0 | Header-only C++ HNSW ANN library. | Supports `ef` tradeoff: higher `ef` improves accuracy at slower query time; supports deletion/reuse and serialization. | Strong benchmark/control implementation, but less Mac-app-friendly than sqlite-vec or USearch. |
| [Reciprocal Rank Fusion paper](https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf) | Research paper | Rank fusion formula `sum(1 / (k + rank))`, with `k=60` in the paper. | RRF outperformed Condorcet, CombMNZ, and best individual systems by about 4-5 percent on average in reported experiments. | Validates Cascade's existing `RankFusion.defaultK = 60`; extend it rather than replace it. |
| [Elasticsearch RRF docs](https://www.elastic.co/docs/reference/elasticsearch/rest-apis/reciprocal-rank-fusion) | Documentation | Production RRF across BM25, kNN, and other rankers; uses rank window and rank constant. | Default `rank_constant` is 60; `rank_window_size` controls quality/performance tradeoff. | Use as operational guidance for `candidatePool`: tune rank windows, do not over-index on raw score normalization. |
| [From BM25 to Corrective RAG](https://arxiv.org/abs/2604.01733) | Research paper | Benchmark of 10 retrieval strategies in financial text/table QA. | Hybrid retrieval plus neural reranking: Recall@5 0.816, MRR@3 0.605; BM25 beat dense on precise financial docs. | Reinforces that Cascade must keep BM25 and use dense as a complementary lane, not a replacement. |
| [SemEval 2026 CQA hybrid retrieval](https://arxiv.org/abs/2605.12028) | Research paper | Query rewriting, BM25+dense RRF, cross-encoder reranking. | nDCG@5 0.531; ranked 8/38; +10.7 percent over baseline. | Good template for Cascade Ask: query expansion variants, hybrid candidate generation, rerank final candidates. |
| [BAAI/bge-reranker-base](https://huggingface.co/BAAI/bge-reranker-base) | MIT | Cross-encoder reranker that scores query-document pairs directly. | Model card recommends retrieving top 100 with an embedding model, then reranking to final top 3; more accurate but less efficient than embeddings. | Optional Ask-only reranker over top 40-100 chunks; do not run in hot assist loops. |
| [cross-encoder/ms-marco-MiniLM-L6-v2](https://huggingface.co/cross-encoder/ms-marco-MiniLM-L6-v2) | License not explicit in fetched model page; verify before bundling | MS MARCO passage reranker. | NDCG@10 74.30 on TREC DL19, MRR@10 39.01 on MS MARCO dev, about 1800 docs/sec on V100. | Candidate for offline/server evaluation; local CoreML viability needs export and latency testing. |
| [ColBERT](https://github.com/stanford-futuredata/ColBERT), [ColBERT paper](https://arxiv.org/abs/2004.12832), [ColBERTv2](https://arxiv.org/abs/2112.01488), [PLAID](https://arxiv.org/abs/2205.09707) | MIT repo | Late-interaction retrieval: independent query/document encoders with token-level MaxSim; PLAID accelerates search. | ColBERT reports 2 orders of magnitude faster than BERT reranking and 4 orders fewer FLOPs/query; ColBERTv2 reduces space 6-10x; PLAID reports 45x CPU speedup over vanilla ColBERTv2. | Larger bet for very high recall over huge archives. Too much index complexity for the next local Swift milestone. |
| [Letta / MemGPT](https://github.com/letta-ai/letta) and [MemGPT paper](https://arxiv.org/abs/2310.08560) | Apache-2.0 | Stateful agents with hierarchical memory tiers and virtual context management. | Paper evaluates document analysis beyond context windows and multi-session chat where agents remember, reflect, and evolve. | Use the memory-tier idea: working memory (`AssistMemory`), archival memory (`recorded_context`/chunks), and computed memory summaries. |
| [mem0](https://github.com/mem0ai/mem0) | Apache-2.0 | Long-term agent memory with ADD-only fact extraction, entity linking, semantic/BM25/entity retrieval, temporal reasoning. | README reports LoCoMo 91.6 and LongMemEval 94.8 for April 2026 memory v2, p50 around 0.88-1.09s, 6.8K-7.0K tokens. | Adopt the retrieval shape, not the whole stack: entity/fact extraction and multi-signal fusion for important work moments. |
| [Graphiti](https://github.com/getzep/graphiti) | Apache-2.0 | Temporal knowledge graph memory; facts have validity windows, provenance, invalidation, graph+BM25+dense retrieval. | Managed Zep claims sub-200ms at scale; open-source Graphiti is setup dependent, typically sub-second. | Larger bet for entity/event memory: people, docs, projects, apps, decisions, and changed facts over time. |
| [Cognee](https://github.com/topoteretes/cognee) | Apache-2.0 | Self-hosted graph-RAG memory with vector embeddings, graph reasoning, ontology generation, `remember`/`recall`/`forget`. | No benchmark numbers found in fetched README; paper reference exists at arXiv:2505.24478. | Useful API pattern for Cascade memory operations, but less directly implementable than mem0/Graphiti concepts. |
| [A-MEM](https://arxiv.org/abs/2502.12110) | Paper; repo license must be verified before reuse | Zettelkasten-inspired agentic memory: contextual description, keywords/tags, links to related memories, memory evolution. | Paper reports superior performance over state-of-the-art baselines across six foundation models, but fetched abstract did not include exact scores. | Good design for linking related moments and evolving summaries when a user repeatedly asks about a project. |
| [Generative Agents](https://arxiv.org/abs/2304.03442) | Paper; code license separate | Memory stream with observations, reflection, planning, and dynamic retrieval for behavior. | Ablation showed observation, planning, and reflection each contributed critically to believable behavior. | Directly maps to Cascade memory scoring: relevance, recency, importance, and higher-level reflections over days of work. |

## Concrete Techniques to Adopt

### 1. Replace word-vector averaging with a sentence embedding provider

Current file/function:

- `Sources/CascadeMemory/SemanticIndex.swift`
- `SemanticEmbedder.vector(for:)`
- `CascadeMemory.indexEmbedding(contextID:text:)`
- `CascadeMemory.semanticRankedIDs(matching:limit:)`

Implementation:

- Introduce a protocol:

```swift
public protocol SemanticEmbeddingProvider: Sendable {
    var modelID: String { get }
    var dimension: Int { get }
    var distanceMetric: VectorDistanceMetric { get }
    func embedding(for text: String) async throws -> [Float]
}
```

- Ship `NLEmbeddingAveragingProvider` only as fallback.
- Add `CoreMLSentenceEmbeddingProvider` using a bundled `.mlpackage` for `thenlper/gte-small` first, with `BAAI/bge-small-en-v1.5` as a measured alternative.
- If MLX Swift package size and deployment targets are acceptable, add `MLXSentenceEmbeddingProvider` as the Apple-Silicon path. MLX is attractive because `mlx-swift-lm` already has Swift model loading and embedding examples, but CoreML is safer for first production rollout.
- Store `model_id`, `dimension`, `distance_metric`, and `created_at` with vectors. Current `context_embedding(vector BLOB)` cannot distinguish old word-averaged vectors from future sentence vectors.

Feasibility:

- Swift/CoreML: high. GTE small and BGE small are transformer encoders that can be exported to CoreML. Tokenizer parity is the main work item; use `swift-transformers` or generate a small tokenizer wrapper from the Hugging Face tokenizer files.
- SQLite: high. Add migration and backfill. Keep old vectors until the new model has rebuilt its index.

### 2. Chunk screen/OCR context before embedding

Current issue:

- `SemanticEmbedder.vector(for:)` trims the full text to 1,000 characters and embeds the whole moment once. Long OCR blobs can bury the important line; short noisy OCR can dominate.

Implementation:

- Add a `context_chunk` table:

```sql
CREATE TABLE IF NOT EXISTS context_chunk (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    context_id INTEGER NOT NULL REFERENCES recorded_context(id) ON DELETE CASCADE,
    captured_at REAL NOT NULL,
    app_name TEXT NOT NULL,
    window_title TEXT NOT NULL,
    chunk_text TEXT NOT NULL,
    chunk_kind TEXT NOT NULL,
    token_count INTEGER NOT NULL DEFAULT 0,
    importance REAL NOT NULL DEFAULT 0,
    metadata_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_context_chunk_context ON context_chunk(context_id);
CREATE INDEX IF NOT EXISTS idx_context_chunk_time ON context_chunk(captured_at DESC);
```

- Chunk by visible work unit, not arbitrary characters:
  - Prefer AX-harvested text blocks first, OCR lines second.
  - Keep app/window/title/timestamp in chunk metadata.
  - Target 200-400 tokens with 15-20 percent overlap for dense embeddings.
  - Preserve short atomic chunks for copied text, file names, browser page titles, emails, and form fields.
- Add `rewind_chunk_fts` or extend FTS indexing to chunks. Whole-moment FTS can remain for timeline browsing, but Ask should search chunks.

Feasibility:

- Swift: high. Chunking can happen in `CascadeMemory.saveContext` or a follow-up indexing queue.
- SQLite: high. Existing FTS trigger pattern can be copied for chunk FTS.

### 3. Replace brute-force vector scan with sqlite-vec first, USearch later

Current file/function:

- `Sources/CascadeMemory/SemanticIndex.swift`
- `CascadeMemory.semanticRankedIDs(matching:limit:)`
- Schema migration around `context_embedding`

Implementation:

- Add sqlite-vec as a bundled SQLite extension or statically linked C source.
- Create a vector table keyed to chunks:

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS chunk_vec USING vec0(
    embedding float[384] distance_metric=cosine,
    context_id integer,
    chunk_id integer,
    captured_month text partition key,
    app_name text
);
```

- Query top-k vector candidates in SQL, then join back to `context_chunk` and `recorded_context`.
- Use `captured_month` or another coarse partition only when archives are large enough; sqlite-vec docs warn against over-partitioning.
- Do not rely on a fixed similarity floor. Query top-k, then apply a calibrated minimum per embedding model and per query class.
- For millions of chunks or multi-month archives, evaluate a sidecar `USearch` HNSW index keyed by `context_chunk.id`. SQLite remains source-of-truth; USearch is rebuildable acceleration.

Feasibility:

- sqlite-vec: medium-high. It is pure C and macOS-friendly, but pre-v1 API churn must be isolated behind `VectorIndexStore`.
- USearch: medium. Swift/Objective-C bindings exist, but persistence and crash recovery need more care.

### 4. Keep RRF, but make hybrid fusion explicit and evaluable

Current file/function:

- `Sources/CascadeMemory/RankFusion.swift`
- `CascadeMemory.hybridContexts(matching:limit:candidatePool:)`
- `CascadeMemory.lexicalRankedIDs(matching:limit:)`
- `CascadeMemory.semanticRankedIDs(matching:limit:)`

Implementation:

- Keep `RankFusion.defaultK = 60`; it matches the original RRF paper and common production defaults.
- Extend `RankFusion` to return lane provenance:
  - `lexicalRank`
  - `vectorRank`
  - `memoryRank`
  - `rerankScore`
  - `finalScore`
- Increase `candidatePool` for Ask from 40 to 80-120 once vector lookup is indexed. Keep smaller pools for live assist.
- Add an app/time/entity filter object before search:

```swift
public struct RecordSearchFilter: Sendable {
    public var appNames: [String]
    public var start: Date?
    public var end: Date?
    public var limit: Int
}
```

- Update `RecordRecall.search_record` so the agent can pass filters directly instead of doing broad search then `get_timeframe`.

Feasibility:

- Swift: high. `RankFusion` is already small and isolated.
- SQLite: high. BM25 and vector candidates can be produced independently, then fused in Swift.

### 5. Add optional reranking for Ask and citations

Current file/function:

- `Sources/ProviderKit/RecordRecall.swift`
- `RecordRecall.searchRecord`
- `Sources/ProviderKit/RecordSearchAnswerer.swift`

Implementation:

- Add a `RecordReranker` protocol:

```swift
public protocol RecordReranker: Sendable {
    func rerank(query: String, candidates: [RecordChunkCandidate], limit: Int) async throws -> [RecordChunkCandidate]
}
```

- First implementation can be heuristic:
  - exact phrase boost
  - title/app match
  - query term coverage
  - recency tie-break
- Second implementation can be CoreML cross-encoder:
  - BGE reranker or MiniLM MS MARCO reranker over top 40-100 chunks.
  - Ask-only default; disabled for realtime computer-use loops.
- Return reranked chunks with their parent moment ID so citations still point to `recorded_context.id`.

Feasibility:

- Heuristic reranker: high.
- CoreML cross-encoder: medium. More latency and tokenizer work than sentence embeddings, but tractable for an Ask panel that can spend hundreds of milliseconds.

### 6. Add a durable memory stream score

Current file/function:

- `Sources/ProviderKit/AssistMemory.swift` is short-term and turn-local.
- `recorded_context` is durable but raw.
- `RecordRecall.search_record` uses lexical+dense only.

Implementation:

- Add `memory_event` or `memory_summary`:

```sql
CREATE TABLE IF NOT EXISTS memory_event (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    context_id INTEGER REFERENCES recorded_context(id) ON DELETE CASCADE,
    captured_at REAL NOT NULL,
    app_name TEXT NOT NULL,
    summary TEXT NOT NULL,
    entities_json TEXT NOT NULL DEFAULT '[]',
    importance REAL NOT NULL DEFAULT 0,
    last_accessed_at REAL,
    access_count INTEGER NOT NULL DEFAULT 0,
    links_json TEXT NOT NULL DEFAULT '[]',
    metadata_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_memory_event_time ON memory_event(captured_at DESC);
CREATE INDEX IF NOT EXISTS idx_memory_event_importance ON memory_event(importance DESC);
```

- Score memory candidates with:

```text
score =
  w_relevance * normalized_retrieval_score +
  w_recency * exp(-age_seconds / half_life_seconds) +
  w_importance * importance +
  w_continuity * entity_or_session_boost +
  w_usage * log1p(access_count)
```

- Start with heuristic importance:
  - active keyboard/mouse input nearby
  - copied text, saved files, submitted forms, meeting/doc/email titles
  - repeated workflows detected by `WasteDetector`
  - user asked about or cited the moment
  - long dwell in same app/window
  - app allowlist boosts for docs, browser, calendar, email, terminal, IDE
- Later, add LLM-generated importance and reflection summaries in a background queue, similar to Generative Agents and MemGPT memory tiers.
- Treat memory score as another RRF lane, not as a replacement for relevance.

Feasibility:

- Heuristic memory stream: high.
- LLM-reflection memory: medium, because cost, privacy controls, and audit UI need explicit product decisions.

### 7. Add query planning and expansion inside `search_record`

Current issue:

- `RecordSearchAnswerer` tells the model to search synonyms, but `search_record` accepts only a plain string. That pushes query expansion into slow tool hops.

Implementation:

- Add a deterministic parser for:
  - app names
  - dates / relative times
  - people/project/file-like entities
  - quoted phrases
- Add `query_variants` to `search_record` and fuse each variant's BM25/vector candidates.
- Keep the agent loop for hard questions, but make common recall searches one call:

```json
{
  "query": "budget spreadsheet numbers",
  "query_variants": ["budget spreadsheet", "Q2 forecast", "revenue numbers"],
  "start_iso": "2026-06-01T00:00:00Z",
  "app": ["Numbers", "Safari"],
  "limit": 12
}
```

Feasibility:

- High. It is mostly `RecordRecall` API expansion plus prompt/tool schema changes in `RecordSearchAnswerer`.

### 8. Build recall evaluation before swapping defaults

Current tests:

- `Tests/CascadeMemoryTests/SemanticIndexTests.swift`
- `Tests/CascadeMemoryTests/HybridSearchTests.swift`
- `Tests/ProviderKitTests/RecordRecallTests.swift`

Implementation:

- Add a fixture/eval suite with at least 100 user-style questions:
  - exact lookup: "What was the Q2 total?"
  - fuzzy semantic: "Where did I see cheap flights?"
  - temporal: "What did I work on after the team meeting yesterday?"
  - app-scoped: "What did I type in Terminal before opening Word?"
  - entity/project: "Find the last thing about Project Atlas."
  - negative/sensitive: excluded bank/password/health contexts must not return.
- Track:
  - Recall@5
  - MRR@10
  - citation precision
  - p50/p95 search latency
  - index build throughput
  - storage overhead per day of capture
- Run ablations:
  - FTS only
  - word-avg vector only
  - sentence vector only
  - BM25 + sentence vector RRF
  - RRF + reranker
  - RRF + memory stream score

Feasibility:

- High. Existing demo fixtures and tests already cover the skeleton; add benchmark-style tests that can skip model-backed runs when the CoreML asset is absent.

## Quick Wins vs Larger Bets

### Quick Wins

1. **Remove the fixed dense cutoff from production ranking.** Keep top-k vector candidates and calibrate thresholds per model. BGE explicitly warns that absolute similarity thresholds can be misleading.
2. **Expose app/time filters in `RecordRecall.search_record`.** This reduces agent hops and makes month-scale search cheaper before any model change.
3. **Make RRF provenance visible in tests and debug logs.** Store lexical rank, vector rank, and final fused rank for each candidate.
4. **Add chunk tables and chunk FTS.** Even before CoreML embeddings, chunk-level BM25 will improve citations and reduce noisy OCR blobs.
5. **Add a heuristic memory-stream lane.** Recency, active input, copied/saved/submitted signals, and user-cited moments can improve ranking without new models.
6. **Add a recall benchmark suite.** Do not switch embedding models by intuition; measure Recall@5, MRR@10, citation precision, and latency.

### Larger Bets

1. **Bundle `gte-small` or `bge-small-en-v1.5` as CoreML.** This is the most important quality jump, but it requires tokenizer parity, model packaging, migration, and backfill.
2. **Integrate sqlite-vec.** Good local-first architecture, but it adds C extension packaging and pre-v1 compatibility risk.
3. **Add USearch HNSW sidecar for months of data.** Useful if sqlite-vec exact search is too slow at large chunk counts; more operational complexity.
4. **CoreML cross-encoder reranker.** High answer quality for Ask, but not worth putting in realtime assist loops.
5. **Temporal entity graph memory.** Graphiti/mem0-style facts and invalidation can make project/person/document recall much better, but it needs schema, UI, privacy policy, and evaluation.
6. **Late-interaction retrieval.** ColBERT/PLAID is promising for massive archives, but too heavy for the next Swift local milestone.

## License/Attribution

- Apache-2.0 sources can be used with license and notice preservation: `all-MiniLM-L6-v2`, `swift-transformers`, `exporters`, USearch, hnswlib, Letta, mem0, Graphiti, Cognee.
- MIT sources can be used with license preservation: `gte-small`, `bge-small-en-v1.5`, `bge-reranker-base`, MLX Swift LM, sqlite-vss, ColBERT.
- sqlite-vec is dual MIT / Apache-2.0. Pick one license path for attribution and keep both upstream license files in third-party notices if vendoring source.
- `cross-encoder/ms-marco-MiniLM-L6-v2` did not expose a clear license in the fetched model page; verify before bundling or redistributing.
- Apple NaturalLanguage APIs are OS frameworks, not OSS dependencies. They are safe as platform fallbacks but do not provide public retrieval quality numbers.
- Research papers should be cited when implementing ideas, but paper availability does not grant a code license. Check associated repositories separately before porting code.
- Update `docs/THIRD_PARTY_NOTICES.md` and the app's About/legal surface when bundling any model weights, tokenizer files, SQLite extensions, or ANN libraries.

