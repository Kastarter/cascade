# SEQ-30 - LLM-call determinism, caching and idempotency

## Overview

Cascade already uses Anthropic prompt caching in the high-cost interactive paths: `ComputerUseAgent.step()` caches the static system/tools prefix plus moving user-turn breakpoints, and `RecordSearchAnswerer.send()` splits stable system text from volatile clock text. There is also a narrow in-memory curation cache in `CascadeOrchestrator.curate(_:)`.

The gap is that non-streaming model calls still behave like one-off network calls. `AnthropicClient.complete()` has no shared response cache, deterministic generation parameters, request fingerprint, request-id logging, retry policy, or in-flight deduplication. Callers such as `ClaudeSingleStepPlanner`, `WorkflowCurator`, `AgentTaskPlanner`, `ClaudeGroundedAnswerer`, `RecordSearchAnswerer`, and `ElementLocator` rebuild equivalent classification/grounding prompts often enough that a local exact cache and idempotency ledger would cut cost and make behavior reproducible.

The safest optimization boundary is:

- Cache exact, validated outputs for pure read-only calls: planning JSON, workflow curation JSON, task splitting JSON, record Q&A over the same selected moments, and visual grounding against the same screenshot hash.
- Do not replay cached outputs for live computer-use turns after any tool action has executed. `ComputerUseAgent.streamMessage()` is already correct to avoid retry after delivered actions; keep that boundary.
- Use Anthropic prompt caching for long, repeated prefixes and app-local SQLite response caching for identical full requests. Prompt caching reduces provider prefill cost; response caching avoids the provider call entirely.
- Treat semantic caching as a read-only Q&A option only, with strict context fingerprints and high precision. Do not use semantic cache for actions, compliance-sensitive record answers, or anything that can click/type.

Anthropic's current prompt-caching guidance says cache prefixes are `tools`, then `system`, then `messages`; static content should be at the beginning; breakpoints should sit on the last block that stays identical; there are four breakpoint slots and a 20-block lookback; 5-minute cache writes cost 1.25x input, 1-hour writes cost 2x, and cache reads cost 0.1x input. The error docs list 429, 500, 504, and 529 as transient classes worth retrying, and every response includes a `request-id` header for debugging. No Messages API idempotency-key header is documented, so Cascade should implement client-side idempotency by canonical request hash.

Key source links:

- Anthropic prompt caching: https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- Anthropic errors and request IDs: https://platform.claude.com/docs/en/api/errors
- LiteLLM caching docs: https://docs.litellm.ai/docs/proxy/caching

## OSS Repos & Papers

| name | url | stars/venue | license | technique |
|---|---|---:|---|---|
| LangChain | https://github.com/langchain-ai/langchain | 140k stars | MIT | Standard model interface, provider abstraction, middleware, tracing/evals. Useful pattern for wrapping `AnthropicClient` behind request options, retry, cache, and tracing without changing callsites. |
| LiteLLM | https://github.com/BerriAI/litellm | 51.7k stars | MIT for core, enterprise dir separately licensed | Gateway-level response caching with in-memory, disk, Redis, S3/GCS, Qdrant/Redis/Valkey semantic cache, TTLs, namespaces, and cache headers. Portable lesson: exact cache first, namespace by provider/model/prompt version, semantic cache only with threshold and headers/telemetry. |
| DSPy | https://github.com/stanfordnlp/dspy | 35.4k stars | MIT | Declarative signatures and compiled prompts. Portable lesson: make Cascade planner/curator contracts explicit typed modules, then eval prompt revisions instead of hand-editing opaque strings. |
| promptfoo | https://github.com/promptfoo/promptfoo | 22.6k stars | MIT | Repeatable prompt/agent evals and cached provider outputs. Portable lesson: add fixtures that prove cache keys, JSON validity, retry behavior, and cost deltas remain stable across model-layer changes. |
| Outlines | https://github.com/dottxt-ai/outlines | 14.2k stars | Apache-2.0 | Grammar/regex/JSON-schema guided generation. Hosted Anthropic cannot use Outlines decoding directly, but the product pattern maps to forced tool-use schemas and post-validated DTO caching. |
| Instructor | https://github.com/567-labs/instructor | 13.2k stars | MIT | Pydantic-style structured outputs with automatic validation and retries. Portable lesson: cache the validated DTO, not raw model prose, and retry once with a schema error when parse fails. |
| Portkey AI Gateway | https://github.com/Portkey-AI/gateway | 12.2k stars | MIT | AI gateway with routing, guardrails, and reliability controls. Portable lesson: if Cascade later centralizes model traffic for enterprise, keep local app cache semantics and route metadata compatible with a gateway. |
| GPTCache | https://github.com/zilliztech/GPTCache | 8.1k stars | MIT | Semantic LLM response cache with embedding generators, SQLite/DuckDB/Postgres/Redis stores, vector stores, similarity evaluators, and eviction. Portable lesson: split cache storage, vector lookup, and hit evaluator; start with exact SQLite cache before semantic matching. |
| Don't Break the Cache: An Evaluation of Prompt Caching for Long-Horizon Agentic Tasks | https://arxiv.org/abs/2601.06007 | arXiv 2026 | paper | Evaluates prompt caching for multi-turn agents across providers; reports 45-80 percent cost reduction and 13-31 percent TTFT improvement, with best results from strategic cache block control and dynamic content at the end. |
| Prompt Cache: Modular Attention Reuse for Low-Latency Inference | https://arxiv.org/abs/2311.04934 | arXiv 2023 | paper | Defines reusable prompt modules for overlapping system prompts, examples, and documents. Maps directly to versioned static prompt modules in `ComputerUseAgent`, `RecordSearchAnswerer`, and planner/curator prompts. |
| MeanCache: User-Centric Semantic Cache for LLM-based Web Services | https://arxiv.org/abs/2403.02694 | arXiv 2024 | paper | User-local semantic cache with context-chain awareness; reports higher precision/F-score than baseline semantic caches. Maps to local-only read-only record Q&A cache keyed by query plus context fingerprint. |
| GPT Semantic Cache: Reducing LLM Costs and Latency via Semantic Embedding Caching | https://arxiv.org/abs/2411.05276 | arXiv 2024 | paper | Redis embedding cache that reports up to 68.8 percent API-call reduction and high positive hit rates. Useful only for benign FAQ-like read-only flows, not for computer-use actions. |
| Efficient Guided Generation for Large Language Models | https://arxiv.org/abs/2307.09702 | arXiv 2023 | paper | Formalizes regex/CFG-constrained generation and underpins Outlines. Maps to tool-forced JSON output and strict validators for planner/curator results. |
| Auditing Prompt Caching in Language Model APIs | https://arxiv.org/abs/2502.07776 | arXiv 2025 | paper | Shows prompt caches can leak through timing if shared globally. Cascade should keep response caches local per user/device and avoid global/shared semantic caches for screen/OCR data. |

## Concrete Techniques to Adopt

- Add `Sources/ProviderKit/ModelCallCache.swift` as an actor and a `CascadeMemory` table `model_call_cache`. Store `key_sha256`, `model`, `callsite`, `prompt_version`, `schema_version`, `request_json_sha256`, `response_json`, `validated_payload_json`, `usage_json`, `request_id`, `created_at`, `expires_at`, `hit_count`, and `last_hit_at`. This is the local exact-cache layer that LiteLLM/GPTCache provide out of process, but implemented in Swift/SQLite and scoped to the local user.

- Extend `MessageCompleting` with an options-bearing overload, while keeping the existing method for tests:
  `complete(system:user:model:maxTokens:options:)`, where options include `temperature`, `cachePolicy`, `callsite`, `promptVersion`, `schemaVersion`, `idempotencyClass`, and `retryPolicy`. `AnthropicClient.complete()` should canonicalize a full request body with sorted keys and hash model, API version, beta headers, temperature, max tokens, system, messages, tool schema, and prompt/schema versions.

- Set deterministic defaults for pure calls. In `ClaudeSingleStepPlanner.proposeNextStep`, `WorkflowCurator.curate`, `WorkflowCurator.curateOne`, `AgentTaskPlanner.plan`, `ClaudeGroundedAnswerer.answer`, `RecordSearchAnswerer.send`, `ElementLocator.callRegion`, and `ElementLocator.callComputerUse`, pass `temperature: 0`. Keep `ComputerUseAgent.step()` on adaptive thinking/effort for interactive screen control, where robustness matters more than byte-repeatability.

- Add in-flight deduplication to `ModelCallCache`: if the same canonical key is already running, await the same `Task` instead of issuing another network request. This targets duplicated `curate(_:)` refreshes, simultaneous `RecordSearchAnswerer` follow-ups, and repeated `ElementLocator` or `VisualGrounder` requests for the same target/screenshot.

- Centralize retry behavior in `AnthropicClient`. Retry transport errors plus HTTP 429, 500, 504, and 529 with exponential backoff plus jitter, honoring `Retry-After` and capping attempts. Never retry 400, 401, 402, 403, 404, or 413. Write the Anthropic `request-id` response header into `model_call_cache` and `AgentTrace` attributes. Keep `ComputerUseAgent.streamMessage()` special: retry only before any action/tool block is delivered, as it already does.

- Make client-side idempotency explicit. Since Anthropic does not document a Messages idempotency-key header, treat the canonical request hash as Cascade's idempotency key. Add a `model_request_attempt` table or in-memory ledger with `key_sha256`, `attempt`, `started_at`, `finished_at`, `status`, `request_id`, and `error_type`. This lets retries return the same validated payload for pure calls and prevents refresh storms after transient failures.

- Cache validated DTOs, not raw prose. For `ClaudeSingleStepPlanner.parse`, `AgentTaskPlanner.parse`, and `WorkflowCurator.parse`, store the decoded `ProposedStep`, `[AgentSubtask]`, or `[CuratedAgent]` payload after validation. On a parse failure, retry once with a compact schema-error note and cache the failure for a short TTL, for example 30 seconds, to prevent loops.

- Use forced single-tool JSON for structured outputs where possible. For planner, task planner, curator, and region locator calls, define one tool such as `emit_plan`, `emit_curated_agents`, or `emit_region` and set `tool_choice` to that tool. This follows the Outlines/Instructor lesson using Anthropic-hosted tool use rather than local constrained decoding. Cache the tool input object after validation.

- Add a screenshot-hash cache for visual grounding. In `ElementLocator.locateRegion`, `ElementLocator.callComputerUse`, `VisualGrounder.callModel`, and `ComputerUseAgent.groundCached`, key by `target/question`, prompt version, model, declared resolution, screenshot SHA-256, and existing dHash/grid hashes from `MacContextKit.PerceptualHash`. Cache positive hits for 5-10 minutes and negative misses for 15-30 seconds. Do not use semantic cache for action targets.

- Make prompt-cache builders deterministic. Factor the prompt-cache request assembly in `ComputerUseAgent.step()` and `RecordSearchAnswerer.send()` into a small `AnthropicRequestBuilder` that always emits `tools`, `system`, then `messages`, uses sorted JSON keys, and marks cache breakpoints only on stable blocks. Extend the existing `RecordAnswererTests.stableSystemPromptIsByteIdenticalAcrossCallsAndCarriesNoClock` style to all cacheable callsites.

- Add a cache diagnostics harness. In `Tests/ProviderKitTests/ModelCallCacheTests.swift`, assert that identical pure calls produce the same key, dictionary key order cannot alter the key, volatile timestamps after a cache breakpoint do not change the stable-prefix hash, changing model/prompt/schema version changes the key, and cache hits do not call the fake completer. Add promptfoo-style fixture JSON for planner/curator outputs to catch schema drift.

- Extend usage/cost tracing beyond `ComputerUseAgent.logUsage`. `AnthropicClient.complete`, `RecordSearchAnswerer.send`, and `ElementLocator` should extract `input_tokens`, `output_tokens`, `cache_read_input_tokens`, and `cache_creation_input_tokens`, then emit `AgentTrace` model spans with `cache_hit`, `cache_key_prefix`, `request_id`, and `retry_count`. This turns caching into an observable cost-control feature, not an invisible optimization.

- Add a read-only exact context cache for record Q&A. In `RecordSearchAnswerer.answer` and `ClaudeGroundedAnswerer.answer`, key by normalized question, conversation fingerprint, selected moment IDs, moment content hashes, time-window bucket, model, and prompt version. If the context hash differs, miss. Optional semantic matching can be added later using the existing `SemanticIndex`, but only after measuring false-hit risk and preserving citations.

- Add local-only semantic cache behind a feature flag for benign recall questions. If implemented, follow GPTCache/MeanCache: store query embedding, context-chain fingerprint, answer, citation IDs, evaluator score, and threshold; require very high similarity and same context-set hash. Disable it for sensitive moments, action planning, computer-use grounding, workflow curation, and manager-facing employment decisions.

- Version every model-layer contract. Add constants such as `PlannerPrompt.version`, `WorkflowCurator.promptVersion`, `RecordSearchAnswerer.promptVersion`, `ElementLocator.promptVersion`, and `ComputerUseAgent.promptVersion`. Include them in cache keys and tests. This avoids stale outputs after prompt edits.

- Capture provider request IDs in user-visible diagnostics, not raw prompts. `AnthropicError.http` can carry `requestID`; audit/trace rows should store it for support without logging raw screen/OCR prompt text. This aligns with Anthropic's request-id guidance and Cascade's privacy posture.

## Quick Wins vs Larger Bets

Quick wins:

- Add `temperature: 0` to `AnthropicClient.RequestBody` and pass it from planner, curator, task planner, grounded answerer, record answerer, and element locator.
- Encode Anthropic JSON request bodies with `.sortedKeys` in `ElementLocator` and any other direct `JSONSerialization` callsite, matching `ComputerUseAgent.step()`.
- Add `request-id` extraction and transient retry handling to `AnthropicClient.complete()` for 429, 500, 504, 529, and transport errors.
- Add an in-memory `ExactModelCallCache` actor for `WorkflowCurator` and `ClaudeSingleStepPlanner`, then back it with SQLite once the key format is stable.
- Add screenshot-hash memoization around `ElementLocator.locateRegion` and `VisualGrounder.callModel`.
- Add prompt/schema version constants to planner, curator, answerer, and locator prompts.

Larger bets:

- Build the SQLite `model_call_cache` and `model_request_attempt` tables in `CascadeMemory` with retention, privacy filtering, and cost spans.
- Convert planner, curator, task planner, and region locator outputs to forced single-tool structured objects and cache validated DTOs.
- Add a local-only semantic cache for read-only Q&A using existing `SemanticIndex`, strict context fingerprints, and high thresholds.
- Add a prompt-cache diagnostics/eval suite that compares request prefixes and cost deltas over long agent sessions.
- Consider LiteLLM or Portkey only for enterprise server deployments where centralized routing/budgets matter; do not route local screen/OCR prompts through a shared gateway by default.

## License/Attribution Notes

- LiteLLM core, GPTCache, LangChain, DSPy, promptfoo, Instructor, and Portkey Gateway are MIT-licensed. LiteLLM's repository also marks enterprise-only content separately; do not copy enterprise code or configs.
- Outlines is Apache-2.0. Its constrained-generation idea is safe to implement independently via Anthropic tool-use schemas; copying code would require Apache attribution.
- The papers are research references, not code dependencies. Cite them in design docs if their algorithms are implemented.
- For privacy, keep Cascade response caches local per user/device. Do not share cache entries across employees or tenants. Prompt-caching papers show timing/cache isolation can leak information when cache state is globally shared.
- Cached prompts and responses may contain OCR, app/window titles, or private work facts. Apply the same retention, pruning, PII filtering, and future encryption posture as `recorded_context`; never include raw cached prompt text in exported traces.
