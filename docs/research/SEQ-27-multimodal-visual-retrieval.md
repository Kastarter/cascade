# SEQ-27: Multimodal Visual Retrieval over the Cascade Record

## Overview

Cascade already records changed screen moments, stores JPEG paths in `recorded_context.image_path`, indexes OCR/AX text through `rewind_fts`, and keeps local text embeddings in `context_embedding`. It also has a 3x3 dHash grid in `PerceptualHash.gridHashes(_:)` and `RewindRecorder.stream(_:didOutputSampleBuffer:of:)` to drop idle near-duplicates before OCR/storage.

The missing lane is visual recall: "find the screen that looked like this", "show me the other dashboard like the one I was on", or "find the red chart / kanban board / checkout page even if OCR missed it". The pragmatic product architecture is a sibling visual index beside the text index:

- Tier 1, production-safe now: Apple Vision feature prints from `VNGenerateImageFeaturePrintRequest`, stored locally with the Vision request revision and vector metadata. This supports query-by-moment, "find similar", visual clustering, and timeline compression without shipping external model weights.
- Tier 2, after license/package review: a CLIP-style image/text lane, ideally a small Core ML or MLX model, for natural-language visual search. This adds "find the screen that looked like X" when X is visual language rather than text in the screenshot.
- Retrieval should stay hybrid: FTS/BM25 + local text embeddings + visual vector ranks fused with the existing `RankFusion.reciprocalRankFusion(...)`, then privacy-filtered and returned as the same `[#id]` citations used by Ask and Reel.

## OSS Repos & Papers

| name | url | stars/venue | license | technique |
|---|---:|---:|---|---|
| Apple Vision feature prints | https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest / https://developer.apple.com/documentation/vision/vnfeatureprintobservation | Apple SDK docs | Apple platform SDK | `VNGenerateImageFeaturePrintRequest` produces `VNFeaturePrintObservation`; use `data`, `elementCount`, `elementType`, `requestRevision`, and `computeDistance(_:to:)` for Swift-native image similarity. |
| apple/ml-mobileclip | https://github.com/apple/ml-mobileclip / https://arxiv.org/abs/2311.17049 / https://arxiv.org/abs/2508.20691 | 1.6k stars; CVPR 2024 + TMLR 2025 | MIT code; model weights are Apple research-only/non-commercial | Efficient CLIP-family image/text embeddings; MobileCLIP2-S0/S2 are attractive Apple-Silicon references, but production use of Apple weights is blocked by the model license. |
| openai/CLIP | https://github.com/openai/CLIP / https://arxiv.org/abs/2103.00020 | 33.9k stars; ICML 2021 | MIT code | Canonical contrastive image/text retrieval: L2-normalized image and text embeddings with cosine/dot-product search. Use as the API and evaluation baseline, not as a Swift dependency. |
| mlfoundations/open_clip | https://github.com/mlfoundations/open_clip | 13.9k stars | MIT code; weights/datasets vary by model | Practical model zoo and preprocessing reference for CLIP variants, including MobileCLIP support. Useful for exporting a license-cleared image/text encoder to Core ML or MLX. |
| ml-explore/mlx-swift-examples | https://github.com/ml-explore/mlx-swift-examples | 2.6k stars | MIT | Swift examples for running MLX models on macOS/iOS. Use if a small CLIP/MobileCLIP-compatible model is easier to ship through MLX than Core ML. |
| asg017/sqlite-vec | https://github.com/asg017/sqlite-vec | 7.8k stars | MIT + Apache-2.0 | Pure-C SQLite vector extension with float, int8, and binary vectors. Good future fit because Cascade already uses SQLite and wants local-only search. |
| facebookresearch/faiss | https://github.com/facebookresearch/faiss / https://arxiv.org/abs/1702.08734 | 40.4k stars; arXiv 2017 | MIT | Dense-vector search, clustering, product/scalar quantization, and k-means. Best used as an algorithmic reference; a C++/CUDA-heavy dependency is too large for Cascade's recorder path. |
| nmslib/hnswlib | https://github.com/nmslib/hnswlib / https://en.wikipedia.org/wiki/Hierarchical_navigable_small_world | 5.3k stars; HNSW TPAMI 2020 | Apache-2.0 | Header-only HNSW approximate nearest-neighbor search with insert/update/delete/filtering patterns. A good larger-bet index once exact scans are too slow. |
| JohannesBuchner/imagehash | https://github.com/JohannesBuchner/imagehash | 3.8k stars | BSD-2-Clause | aHash, pHash, dHash, wHash, colorhash, and crop-resistant hashing. Use to extend Cascade's current dHash grid into better visual cluster prefilters. |
| idealo/imagededup | https://github.com/idealo/imagededup | 5.6k stars | Apache-2.0 | Combines pHash/dHash/wHash/aHash/CNN encodings and includes dedup evaluation workflows. Use as a test-harness model for visual duplicate thresholds. |
| Screen2Vec | https://arxiv.org/abs/2101.11103 | arXiv 2021 | Paper | GUI screen embeddings should combine visual design, text, layout, app context, and interaction traces. This maps unusually well to Cascade's screenshot + OCR + AX + input-event record. |
| ANN-Benchmarks | https://arxiv.org/abs/1807.05614 / http://ann-benchmarks.com | arXiv 2018; Information Systems 2020 | Paper/site | Compare recall/latency tradeoffs before adopting an ANN dependency; exact scan may beat ANN at Cascade's 7-day local scale. |

## Concrete Techniques to Adopt

- Add `Sources/CascadeMemory/VisualIndex.swift` with a storage-facing `VisualVector` model and `CascadeStore.indexVisualFeature(contextID:provider:model:revision:dimension:metric:vector:)`. In `CascadeStore.migrate(_:)`, create:
  - `context_visual_embedding(context_id INTEGER PRIMARY KEY, provider TEXT NOT NULL, model TEXT NOT NULL, revision INTEGER, dimension INTEGER NOT NULL, metric TEXT NOT NULL, vector BLOB NOT NULL, norm REAL, created_at TEXT NOT NULL)`.
  - `visual_cluster(id INTEGER PRIMARY KEY, representative_context_id INTEGER NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, app_name TEXT, first_at TEXT NOT NULL, last_at TEXT NOT NULL, count INTEGER NOT NULL, label TEXT)`.
  - `context_visual_cluster(context_id INTEGER PRIMARY KEY, cluster_id INTEGER NOT NULL, distance REAL NOT NULL)`.

- Add `Sources/MacContextKit/VisionFeaturePrint.swift` with `VisionFeaturePrintEmbedder.featureVector(from cgImage: CGImage) -> (vector: [Float], revision: Int, dimension: Int)`. Use `VNGenerateImageFeaturePrintRequest`, reject non-`.float` observations, derive the vector from `VNFeaturePrintObservation.data`, and store the request revision. Never hard-code dimensionality because Apple has changed feature-print vector sizes across OS revisions.

- In `RewindRecorder.process(frame:)`, after `let inserted = try await store.insert(context)` and after the sensitive-content recheck, enqueue visual indexing on a separate actor, not inline in the OCR/storage actor. Reuse `frame.jpeg` or the existing `cgImage` before it is discarded so the indexer does not reread every JPEG from disk. If the indexer is behind, coalesce by keeping the newest frame per app/window cluster.

- In `CascadeMemory.SemanticIndex.swift`, mirror the current `semanticRankedIDs(matching:limit:)` shape with `visualRankedIDs(matching vector: [Float], provider: String, revision: Int?, limit: Int)`. Start with exact scans and Accelerate/vDSP dot products or squared L2 over BLOB-loaded Float arrays; at 7 days of changed frames this is simpler, deterministic, and probably fast enough.

- Extend `CascadeStore.hybridContexts(matching:limit:candidatePool:)` only for CLIP-enabled text/image models. Add a new overload such as `hybridContexts(text query: String, visualQuery: [Float]?, limit: Int, candidatePool: Int)` that fuses `[keyword, semanticText, semanticVisual]` through the existing `RankFusion.reciprocalRankFusion(...)`. Keep pure Vision feature prints as query-by-image/moment because Vision has no text encoder.

- Add `CascadeStore.visualContexts(similarTo contextID: Int64, limit: Int = 20)` and `CascadeStore.visualContexts(similarToImageAt path: String, limit: Int = 20)`. These should return `RecordedContext` rows with the same privacy filtering boundary already used in `RecordRecall.perform(_:)`.

- Add a `search_visual_record` tool in `Sources/ProviderKit/RecordRecall.swift`. Initial schema: `{ "reference_id": integer, "app_hint": string?, "start_iso": string?, "end_iso": string? }`. It should return the same line format as `search_record`, plus a compact distance: `[#42] 14:03 Safari — Pricing | visual 0.08`. After a licensed CLIP text encoder exists, add `{ "description": string }` for "looked like X" queries.

- Update `RecordRecall.toolDefinitions()` to tell the model when to use visual search: references to color/layout/charts/pages/screenshots/visual similarity should call `search_visual_record`; textual facts should continue using `search_record`. This prevents the visual lane from becoming an expensive default for ordinary OCR questions.

- In `Sources/AppShell/CascadeRootView.swift`, add a "Find Similar" control wherever a moment screenshot is shown: citation thumbnails in `CitationChips`, Reel's selected moment preview, and detected-waste thumbnails. Wire it to `CascadeAppModel.findSimilar(to citedMoment:)`, append an Ask turn with the returned citations, and set `reelJumpTarget` when a result chip is clicked.

- Use visual clusters to compress the Reel without losing evidence. In `RewindRecorder.stream(_:didOutputSampleBuffer:of:)`, keep the existing dHash grid for hot-path skip decisions, but after insertion assign a `visual_cluster` using feature-print distance plus app/window continuity. In Reel, collapse long runs of visually similar moments into one segment with `count` and `first_at/last_at`, while still preserving individual frames for audit.

- Extend `Sources/MacContextKit/PerceptualHash.swift` beyond dHash only for cluster prefiltering, not final retrieval. Add pHash or wHash and a small color histogram inspired by `imagehash`/`imagededup`; store them in `metadata_json` or a `context_visual_hash` table. Use these cheap hashes to avoid Vision/CLIP comparisons between obviously unrelated frames.

- Build `Tests/CascadeMemoryTests/VisualIndexTests.swift`: insert synthetic contexts with known vectors; verify exact nearest-neighbor order, revision filtering, retention pruning cleanup, and RRF fusion behavior. Then add a fixture-based threshold test modeled after `imagededup`: static screenshots with cursor movement, a chart color change, a small new chat message, and a page with the same OCR but different layout.

- Add `VisualIndexMetrics` audit rows via `appendAudit(_:)`: indexing latency, dimension, provider, revision, queue depth, distance threshold, and cluster assignments. This keeps visual retrieval auditable like the rest of Cascade's agent and recorder pipeline.

- Defer ANN dependencies until measured exact scans fail. If a week of changed frames stays under roughly 100k vectors, exact scan over Float16/int8-compressed vectors is easier than HNSW invalidation and rebuilds. If it grows past that, prefer `sqlite-vec` first because it preserves Cascade's embedded SQLite story; use `hnswlib` only if `sqlite-vec` recall/latency is not enough.

- For CLIP-style search, normalize vectors at write time and store the normalization policy in the row (`metric='cosine_normalized'`). Query-time similarity becomes dot product. Add an optional `context_visual_embedding_quantized` lane with int8 vectors once recall tests pass, using sqlite-vec's int8 support as the reference design.

- Use Screen2Vec's lesson for reranking: don't rank by image vector alone. Add a small reranker score over `visualDistance`, same app/window, temporal proximity, OCR/text score, and nearby `input_event` actions. This belongs in `CascadeMemory`, not the model prompt, so Ask gets stable deterministic candidate lists.

- Treat model/provider changes as migrations, not invisible upgrades. Store `provider`, `model`, `revision`, `dimension`, and `metric`; keep multiple lanes side by side until backfill completes; query only compatible dimensions/revisions unless an explicit reindex job has normalized the record.

## Quick Wins vs Larger Bets

Quick wins:

- Add the Vision feature-print table and exact-scan `visualContexts(similarTo:)`.
- Add "Find Similar" from citation/Reel thumbnails using existing `imagePath` and citation IDs.
- Add `search_visual_record(reference_id:)` to Ask so model answers can traverse visually similar moments.
- Add pHash/wHash/colorhash prefilters around the existing `PerceptualHash` grid for better visual clustering.
- Add visual-index tests with synthetic vectors and a small screenshot fixture set.

Larger bets:

- Ship a license-cleared Core ML or MLX CLIP-family model for natural-language visual queries.
- Add `sqlite-vec` for local vector search once exact scans exceed the latency budget.
- Use visual clusters as a first-class Reel compression/read model.
- Add Screen2Vec-style task-aware reranking using visual vectors + OCR/AX + app/window + nearby input events.
- Quantize stored visual vectors to Float16/int8 and keep full-precision vectors only for calibration/backfill.

## License/Attribution notes

- Apple Vision feature prints are platform APIs, not OSS code; no third-party attribution is needed, but stored vectors must carry request revision/dimension because feature-print behavior is OS-revision dependent.
- `apple/ml-mobileclip` code is MIT, but Apple MobileCLIP/MobileCLIP2 weights are licensed for research-only, non-commercial use. Cascade should not ship those weights in an enterprise product without separate clearance.
- `openai/CLIP`, `mlfoundations/open_clip`, `facebookresearch/faiss`, and `ml-explore/mlx-swift-examples` are MIT-code references; individual model weights and datasets can have separate terms.
- `sqlite-vec` is MIT/Apache-2.0 and fits Cascade's local embedded database model; treat it as an optional dependency after exact-scan benchmarks.
- `hnswlib` is Apache-2.0 and header-only, but it adds C++ index lifecycle complexity. Use only after exact scan or sqlite-vec is measured insufficient.
- `imagehash` is BSD-2-Clause and `imagededup` is Apache-2.0; their hashing/evaluation ideas are safe to reimplement in Swift with attribution if code is ported.
