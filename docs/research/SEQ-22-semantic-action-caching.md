# SEQ-22: Semantic Action Caching & Experience Reuse

## Overview

Cascade already records the right raw material for action reuse: `recorded_context`, `input_event`, `agents.recipe_json`, `context_embedding`, per-action audit rows, `RecipeStep.targetDescriptor`, `RecipeStep.ocrAnchor`, AX/OCR/vision replay tiers, and a small in-turn grounding cache in `ComputerUseAgent.pregroundTargets`. The missing optimization layer is a persistent, success-weighted cache that maps "similar goal + similar screen state + same target semantics" to a previously verified action or trajectory.

The strongest research pattern is not blind replay. It is a tiered system:

1. exact cache for stable keys such as app bundle, normalized window title, target descriptor, OCR anchor, frame/grid hash, URL/page identity, and action kind;
2. semantic retrieval for near-repeat tasks using on-device embeddings plus keyword/entity/time signals;
3. confidence gates that execute only idempotent, reversible, or previously verified actions without a model call;
4. fallback to the existing `ComputerUseAgent` / recipe replay when state mismatch, modal, protected action, or low confidence appears;
5. feedback updates that promote verified hits and demote misses.

That fits Cascade's product: repeat enterprise work should get faster and cheaper over time while remaining auditable and stoppable.

## OSS Repos & Papers

| name | url | stars/venue | license | technique |
| --- | --- | --- | --- | --- |
| OpenAdapt | https://github.com/OpenAdaptAI/OpenAdapt | 1.6k stars | MIT | Records GUI demonstrations, stores searchable demo libraries, separates policy from grounding, and uses trajectory-conditioned disambiguation. Its README reports demo-conditioned prompting improved first-action accuracy from 46.7% to 100% on a controlled macOS System Settings benchmark. |
| GPTCache | https://github.com/zilliztech/GPTCache | 8.1k stars | MIT | Exact + semantic cache for LLM calls; useful design pattern for `get/set` cache APIs, similarity thresholds, pluggable stores, and language-agnostic server mode. |
| LangChain | https://github.com/langchain-ai/langchain | 140k stars | MIT | Mature cache/retriever abstractions; relevant pattern is separating cache policy, embedding model, vector store, and invalidation from the caller. |
| Mem0 | https://github.com/mem0ai/mem0 | 59.5k stars | Apache-2.0 | ADD-only memory extraction, agent-generated facts as first-class memories, entity linking, and multi-signal retrieval over semantic, BM25, entity, and temporal signals. |
| Letta | https://github.com/letta-ai/letta | 23.5k stars | Apache-2.0 | Stateful agents with explicit memory blocks and self-improvement loops; useful for separating stable "how to act here" memories from transient conversation context. |
| AutoGen | https://github.com/microsoft/autogen | 59.3k stars | MIT for code, CC-BY-4.0 for docs/assets | Teachability/memo-style agent memory patterns. Note the project is in maintenance mode, so copy design ideas rather than depending on it. |
| Browser Use | https://github.com/browser-use/browser-use | 101k stars | MIT | Browser agent runtime with persistent filesystem/memory in hosted mode; useful for `SandboxKit.BackgroundWebAgent` cache keys based on URL, DOM/action history, and task memory. |
| Skyvern | https://github.com/Skyvern-AI/skyvern | 22k stars | AGPL-3.0 | Vision-based browser workflow automation and workflow builder. Treat as architecture inspiration only because AGPL is not safe to port into Cascade. |
| Agent Workflow Memory | https://arxiv.org/abs/2409.07429 | arXiv 2024 | paper | Induces reusable workflows from past trajectories and selectively injects them into future agent context; reports +24.6% relative success on Mind2Web and +51.1% on WebArena while reducing successful task steps. |
| ExpeL: LLM Agents Are Experiential Learners | https://arxiv.org/abs/2308.10144 | arXiv 2023 | paper/code varies | Extracts natural-language lessons from trajectories, retrieves relevant experiences at inference, and improves without fine-tuning. |
| Reflexion | https://arxiv.org/abs/2303.11366 | arXiv 2023 | paper/code varies | Stores verbal reflections from task feedback in episodic memory; useful for caching failure lessons, not just successes. |
| Voyager | https://arxiv.org/abs/2305.16291 | arXiv 2023 | paper/code varies | Maintains an executable skill library retrieved by embedding and improved through environment feedback and self-verification. |
| GPT Semantic Cache | https://arxiv.org/abs/2411.05276 | arXiv 2024 | paper | Embedding-backed semantic cache in Redis; reports up to 68.8% API-call reduction and positive hit rates above 97%. |
| ContextCache | https://arxiv.org/abs/2506.22791 | arXiv 2025 | paper | Two-stage semantic cache: retrieve by current query, then re-rank with conversation/history context to avoid false hits in multi-turn settings; reports about 10x lower latency than direct LLM calls. |
| From Exact Hits to Close Enough | https://arxiv.org/abs/2603.03301 | arXiv 2026 | paper/code | Semantic-aware online cache policies combining recency, frequency, and locality; relevant for evicting stale action memories. |

## Concrete Techniques to Adopt

- Add a persistent action cache table in `Sources/CascadeMemory/CascadeMemory.swift` and a focused extension file such as `Sources/CascadeMemory/ActionTrajectoryCache.swift`. Store `id`, `created_at`, `last_used_at`, `source` (`assist`, `recipe`, `sandbox`, `grounding`), `goal_norm`, `app_name`, `bundle_identifier`, `window_title_norm`, `web_app_id`, `url_scope`, `screen_hash`, `screen_grid_hashes`, `ocr_simhash`, `ax_fingerprint`, `target_descriptor`, `target_text_norm`, `action_kind`, `action_json`, `precondition_json`, `postcondition_json`, `success_count`, `failure_count`, `confidence`, `embedding`, and `ttl_policy`. This is the local equivalent of GPTCache, but keyed on screen-action semantics.

- Expose the existing on-device embedding path in `Sources/CascadeMemory/SemanticIndex.swift`. `SemanticEmbedder` is currently file-private/internal to context recall; make a small public/internal `LocalSemanticVector` helper so action trajectories can use the same Apple `NLEmbedding` word-average vectors without adding a new dependency.

- Hook exact grounding hits into `Sources/ProviderKit/ComputerUseAgent.swift` at `groundCached(_:frame:cache:)`, `groundedClick`, `expandFillTarget`, and `groundedScroll`. Before `grounder.ground(...)`, compute a `GroundingCacheKey` from target text, app bundle/window supplied by the caller, current frame hash/grid hash, display size, and grounding mode. Return cached points only if the frame/state fingerprint is close enough; store both hits and short-TTL negative misses so repeated "can't find Save" turns do not pay repeated visual-grounder calls.

- Pass screen identity into `ComputerUseAgent` from `Sources/AppShell/CascadeAppModel.swift.makeAssistAgent(...)`. The agent currently sees a frame but not a stable cache namespace. Add an optional `stateProvider` or `groundingCache` dependency carrying frontmost app, bundle id, window title, display id, and the current rewind/frame hash. This keeps cache policy out of the model prompt and avoids JSON prompt churn.

- Add an action-memo preflight before expensive model turns in the foreground assist loop in `Sources/AppShell/CascadeAppModel.swift` around `runAssistEpisode` / agent stepping. For each new screenshot + goal, query `ActionTrajectoryCache.lookup(goal, state, topK: 3)`. If there is an exact high-confidence hit for a safe action (`open_app`, `open_url`, click on stable AX target, scroll, wait), execute it directly via `executeCU`; if it is a semantic hit, inject a short "successful prior trajectory" hint into the next model turn instead of executing blind.

- Add replay-cache lookup in `Sources/AppShell/CascadeAppModel.swift` at the recipe target cascade around lines that choose AX -> OCR -> vision -> recorded. Use `RecipeStep.targetDescriptor` and `RecipeStep.ocrAnchor` as first-class cache keys. On a verified `uiChanged(after:)` success, store the resolved target point and state fingerprint. On an unverified click, increment `failure_count`, lower confidence, and immediately fall through to existing correction/escalation.

- Store idempotent action keys on `RecipeStep` in `Sources/CascadeMemory/CascadeMemory.swift`. Add a computed key from `kind`, `bundleIdentifier`, normalized `windowTitleHint`, `targetDescriptor`, normalized `ocrAnchor`, modifiers/key, and a parameter flag. Never include private typed text in the key. Use this key for cache rows, `WasteDetector` grouping, and audit detail. This makes "same action in same place" stable without leaking content.

- Add cache-aware verification metrics to `Sources/AgentOrchestrator/AgentTrace.swift`. Track `actionCacheHits`, `groundingCacheHits`, `semanticTrajectoryHits`, `cacheBypassReason`, `cacheFalseHit`, `cacheSavedModelCalls`, and estimated saved latency/tokens. Existing `AgentTrace` already tracks model usage; add cache deltas so Manager can report real cost/time savings.

- Make feedback updates automatic in `CascadeAppModel.executeCU(...)`. After any direct cache action, reuse the existing `uiFingerprint()` / `uiChanged(after:)` checks for clicks and the audit result for harness/web actions. Promote only verified hits. For no-effect, unexpected modal, STOP, wrong app, or irreversible guard refusal, demote the cache row and log `action_cache.demote`.

- Apply ContextCache's two-stage match to avoid false hits. Stage 1: vector/keyword lookup by goal and target text. Stage 2: require state compatibility: same bundle/web identity, compatible window title or URL scope, close screen hash/grid hash, matching AX descriptor or OCR anchor, and no modal. Only Stage-2 exact matches can auto-execute; Stage-1 semantic-only matches are prompt hints.

- Use Mem0-style multi-signal retrieval for trajectories. Add a fused scorer near `Sources/CascadeMemory/RankFusion.swift`: semantic score from action embedding, BM25/FTS score from goal/target/action labels, entity match from app/window/web identity, recency, and success frequency. This will outperform pure embedding because GUI actions often hinge on exact labels like "Submit", "Send", "Q2", or a URL host.

- Create a `TrajectoryMemory` summarizer using ExpeL/Reflexion patterns, but run it sparingly. On task completion, store compact facts such as "In Gmail compose, click Send by AXButton identifier before relying on coordinates" or "If the Export sheet appears, choose PDF first." On failure, store "do not click cached coordinate if AX fingerprint unchanged after press." Store these as local text rows tied to cache entries; use them as model hints, not direct actions.

- Reuse OpenAdapt's demo-conditioned replay in `Sources/AgentOrchestrator/WorkflowCurator.swift` and `CascadeOrchestrator.createAgent(from:)`. For each approved agent, persist 1-3 representative successful demonstrations: step labels, safe anchors, before/after state hashes, and failure corrections. When `escalateRecipeToAssist(...)` fires, include the closest successful demo trajectory instead of only the high-level goal.

- Add browser-specific state keys in `Sources/SandboxKit/BackgroundWebAgent.swift`. Cache actions by `WebAppIdentity`, hostname, normalized path template, DOM role/name when available, visual target text, and sandbox task. Direct DOM actions can auto-replay with stricter keys; visual-only actions should be prompt hints unless a prior selector/role survived verification.

- Add bounded cache size and eviction in `CascadeMemory`. Use the semantic-cache policy paper's recency + frequency + locality idea: keep high-success rows, evict stale rows with low success, and expire rows when app version, URL host, or repeated verification failures change. Start with a simple score: `success_count * 3 - failure_count * 5 + recentUseBonus + exactKeyBonus`.

- Keep privacy controls aligned with existing `PrivacyRules`. Do not cache typed text, screenshots, raw OCR snippets longer than a short normalized label, or sensitive-path/harness content. Use hashes, normalized labels, and local-only vectors. If `PrivacyRules.isSensitive(...)` flags a moment or target label, skip cache insertion and audit `action_cache.skipped_sensitive`.

- Add tests before product UI. New focused tests should cover exact hit, semantic-only hint, negative miss TTL, false-hit demotion, sensitive skip, recipe replay target-cache promotion, and no auto-execute when modal/wrong-app/irreversible guard is active. Test locations: `Tests/CascadeMemoryTests`, `Tests/ProviderKitTests/StructuralGroundingTests.swift`, and `Tests/AppShellTests`.

## Quick Wins vs Larger Bets

Quick wins:

- Persist a grounding cache for `ComputerUseAgent.groundCached` using exact target/state keys. This directly cuts repeated UI-TARS/Claude grounding calls and is low risk because the current per-turn cache already proves the shape.
- Add recipe replay target promotion around the existing AX/OCR/vision/recorded cascade. Verified successful target resolution is a perfect cache insertion point because `uiChanged(after:)` already gives a cheap success signal.
- Reuse `SemanticIndex` vectors for action memory instead of adding a new embedding stack. Apple `NLEmbedding` is already portable to Swift and Apple Silicon.
- Add negative cache rows for repeated grounding misses and no-effect clicks. This prevents costly retry loops on stale targets.
- Add cache metrics to `AgentTrace` and audit rows before changing behavior broadly. It gives a safe A/B path: observe hit opportunities first, then enable direct execution.

Larger bets:

- Build a full trajectory-RAG layer that retrieves successful multi-step runs and conditions `ComputerUseAgent` on them. This is AWM/OpenAdapt territory and should be gated by offline evals because false positives are more expensive than missed cache hits.
- Turn approved agents into demo-conditioned policies: store representative successful demonstrations and use them whenever recipe replay escalates to the assist agent.
- Add a local learned action policy for high-frequency apps after enough verified cache rows exist. The training set would be Cascade's own `(state, target, action, verification)` rows, but this belongs after cache instrumentation proves volume and quality.
- Add a human-review UI for cache entries if direct auto-execution expands beyond safe/idempotent actions. Enterprise users need to see what Cascade is learning and revoke bad action memories.

## License/Attribution Notes

- MIT projects (`OpenAdapt`, `GPTCache`, `LangChain`, `Browser Use`, AutoGen code) are safe to study and port with attribution if code is copied. Prefer independent Swift implementations and cite designs in `docs/THIRD_PARTY_NOTICES.md` if any structure or code is ported.
- Apache-2.0 projects (`Mem0`, `Letta`) are safe for design inspiration and code porting with license notice preservation, but avoid importing their dependencies into the Swift app.
- Skyvern is AGPL-3.0. Do not copy code or close paraphrase implementation. Use only high-level architectural lessons.
- Papers can be cited as research sources. If prompts, schemas, or algorithm text are adapted closely, add citation comments or a short notice in research docs.
- Cache rows may contain behavioral traces of employee work. Keep them local, privacy-gated, retention-bound, and auditable under the same rules as `recorded_context` and `audit_event`.
