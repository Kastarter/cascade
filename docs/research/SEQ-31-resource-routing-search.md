# SEQ-31 - Resource Routing and Search Sufficiency

## Overview

Cascade's on-screen assist agent already *has* every search surface it needs, and is even told about each one in prose:

- `Sources/ProviderKit/AgentHarness.swift` — `readOnlyTools = ["search_files", "list_folder", "read_file"]` (Spotlight + local files), always on; power tier (`run_command`/`run_applescript`/`write_file`) behind the Power-harness opt-in.
- `Sources/ProviderKit/RecordRecall.swift` — `["search_record", "get_timeframe", "inspect_moment", "list_sessions"]` over the user's recorded screen history, wired into the assist agent via `recallEnabled: true` in `makeAssistAgent`.
- `Sources/SandboxKit/BackgroundWebAgent.swift` — the WKWebView browser sandbox for web research.
- The live screenshot / AX tree — the current screen itself.

The guidance for these lives in `ComputerUseAgent.harnessReadOnlyNote`, `harnessPowerNote`, and `recallNote`, appended to the system prompt only when the matching tier is active.

The gap this sequence closes is **not** a missing tool. It is the absence of a **routing decision layer** — *which* of those four resources to search, in *what order*, and a structural check that the agent *actually searched at all* before it is allowed to declare a search task finished. This was confirmed by audit (`Cascade.sqlite` `audit_event`): two consecutive search-shaped goals (2026-06-28T22:15 / 22:16, `goalChars=89` / `85`) each `finished` in 2 turns / ~9s with **~950ms of real action and zero** `search_files` / `search_record` / harness / `computer.act` rows — the agent looked at the current screen, declared itself done, and the user pressed STOP both times. There is a structural *action*-sufficiency gate today (no-effect detection + stall guard in `runAssistEpisode`), but **no** *search*-sufficiency gate, which is exactly the hole the bug fell through.

The research consensus (verified below) is a four-part routing layer:

1. **Route by query complexity** into tiered effort — answer from the model's own knowledge (no search), one cheap local lookup, or iterative multi-source retrieval — instead of always (or never) searching (Adaptive-RAG, Self-RAG).
2. **Gate source escalation on a sufficiency signal** — start on the cheapest source (recorded memory / Spotlight), evaluate whether what came back is adequate, and only fall back to the expensive web when it is judged insufficient (CRAG).
3. **Declare the resource catalog explicitly** — not a giant always-on prompt of every source, but a compact, retrievable manifest of capability cards; description quality dominates selection accuracy (ToolLLM, Re-Invoke, ToolRet, RAG-MCP). Cascade already does this correctly for *skills* via the pull-based `use_skill` index; it does **not** yet do it for the four *search resources*.
4. **Execute the chosen search agentically** — interleave reasoning with retrieval, search when reasoning hits a gap, stop when sufficient (ReAct, Search-o1, Search-R1). Cascade's assist loop is already ReAct-shaped; the missing piece is the source-routing + stop condition wired into it.

Closed-model constraint: Search-R1 / R1-Searcher / ReSearch all require RL fine-tuning of an *open* model, which is unavailable for Cascade's hosted Claude stack. The realizable analog is a **prompt-driven** ReAct/Search-o1 loop plus a small classifier/heuristic router — and, critically, a **runtime-owned structural gate** (the proven pattern in this codebase: advisory scaffolding the model can ignore *gets* ignored — only structural, runtime-applied scaffolding holds).

## OSS Repos & Papers

| Work | URL | Venue / status | What it gives Cascade |
|---|---|---|---|
| Adaptive-RAG | https://aclanthology.org/2024.naacl-long.389/ | NAACL 2024 | The canonical route-by-complexity paper: a small classifier labels each query No-Retrieval / Single-step / Multi-step and routes accordingly (F1 46.94 vs 32.24/20.79 baselines; avoids the always-iterate 4.69-step cost). VERIFIED 3-0. Caveat: gains hinge on the classifier (paper reports 23-47% misclassification; oracle reaches 56.28 vs 46.94). |
| Self-RAG | https://arxiv.org/abs/2310.11511 | ICLR 2024 | Per-step on-demand retrieval: a single LM emits "reflection tokens" deciding *when* to retrieve and whether the retrieved passage / its own answer is good enough — the WHEN-to-search and is-this-enough signals. VERIFIED 3-0. |
| CRAG (Corrective RAG) | https://arxiv.org/abs/2401.15884 · impl https://github.com/HuskyInSalt/CRAG | ICLR 2024 | A lightweight learned retrieval *evaluator* (fine-tuned T5-large) scores Correct/Incorrect/Ambiguous; on inadequate local retrieval it escalates to large-scale web search. The exact local→web gating pattern. VERIFIED 3-0. NOTE (refuted sub-claim): "Ambiguous → query decomposition" is wrong — Ambiguous *combines* local-refined + web knowledge. |
| ToolLLM / ToolBench | https://arxiv.org/abs/2307.16789 · https://proceedings.iclr.cc/paper_files/paper/2024/file/28e50ee5b72e90b50e7196fde8ea260e-Paper-Conference.pdf | ICLR 2024 (spotlight) | Dense bi-encoder API retriever returns the top-k relevant tools from a 16,464-API pool so the model never sees the full catalog. Validates retrieval-over-tools at scale. VERIFIED 3-0. NOTE (refuted sub-claim): "retrieved top-5 beats the ground-truth API set" did not survive. |
| Re-Invoke | https://arxiv.org/abs/2408.01875 · https://research.google/blog/re-invoke-tool-invocation-rewriting-for-zero-shot-tool-retrieval/ | EMNLP 2024 Findings (Google) | Unsupervised, training-free tool retrieval. Two levers: offline document-expansion (LLM generates synthetic queries each tool answers, embedded with the doc) and inference-time intent extraction / query rewriting (+20% nDCG@5 single-tool, +39% multi-tool). The "make descriptions good + rewrite the ask" recipe. VERIFIED 3-0. |
| ToolRet ("Retrieval Models Aren't Tool-Savvy") | https://arxiv.org/pdf/2503.01763 | Mar 2025 (7.6k tasks, 43k tools) | Shows strong IR models retrieve tools poorly (best nDCG@10 = 33.83) and that *low retrieval quality measurably degrades tool-use task pass rate* — resource selection is a real bottleneck, not cosmetic. VERIFIED 3-0. |
| ToolGen | https://arxiv.org/abs/2410.03439 | ICLR 2025 | Alternative extreme: each tool = a unique token, so selection is next-token prediction, scaling to 47k+ tools with no retrieval step. VERIFIED 3-0. Caveat: requires vocabulary expansion + retraining per new tool — impractical for a closed model; cite as direction, not adoption. |
| RAG-MCP | https://arxiv.org/abs/2505.03275 | 2025 | Most on-point for "declare a large catalog": keep tool/source descriptions in an external semantic index, retrieve the relevant subset per query, mitigating prompt bloat in MCP tool selection. |
| Search-o1 | https://arxiv.org/abs/2501.05366 | EMNLP 2025 | Retrieve *during* reasoning: extended chains-of-thought "suffer from knowledge insufficiency"; retrieve at uncertain points, plus a Reason-in-Documents module to fold results back in. VERIFIED 3-0. |
| Search-R1 | https://arxiv.org/abs/2503.09516 · https://github.com/PeterGriffinJin/Search-R1 | 2025 | RL-trains interleaved reason-and-search (+26% over baselines on 7 QA sets), because prompting a model to use search is "often suboptimal." VERIFIED 3-0. For Cascade: the *behavior* is the target; the RL *training* is not realizable on hosted Claude → use the prompted ReAct/Search-o1 analog. |
| ReAct | https://arxiv.org/abs/2210.03629 | ICLR 2023 | Interleave reasoning + actions + observations so plans update from feedback. Cascade's assist loop is already ReAct-like; the upgrade is a source-routing decision + stop condition inside it. |
| Self-ask / Compositionality Gap | https://arxiv.org/abs/2210.03350 | EMNLP 2023 (Findings) | Models often answer all sub-questions yet fail to compose them; motivates explicit decomposition + an external search hop per sub-question for multi-hop "research" asks. |
| RouteLLM | https://arxiv.org/abs/2406.18665 | 2025 | Learned routers (KNN/MLP/matrix-factorization/causal-LLM + a non-predictive cascade variant) pick weak vs strong model per query, cutting cost >2x at ~95% quality. Pattern for a cheap router model in front of the source decision. |
| FrugalGPT | https://arxiv.org/abs/2305.05176 | 2023 | LLM cascade: try the cheap option, escalate only on a reliability signal. The generic cost-tiering frame behind cheap-source-first. |
| LlamaIndex routers | https://developers.llamaindex.ai/python/framework/module_guides/querying/router/ | docs | Buildable reference: `RouterQueryEngine` / `RouterRetriever` / `ToolRetrieverRouter` — wrap each source as a tool, an LLM/embedding selector picks one or more. Mirror in Swift. |
| semantic-router (aurelio-labs) | https://github.com/aurelio-labs/semantic-router | OSS (MIT) | Embedding-similarity routing layer (no LLM call needed for the decision) — a cheap, deterministic first-pass router over the resource catalog. |
| Gorilla | https://arxiv.org/abs/2305.15334 · https://github.com/ShishirPatil/gorilla | 2023 | Retriever-aware tool/API selection; reference for grounding selection in a live, documented catalog rather than parametric memory. |
| LLM-Tool-Survey | https://github.com/quchangle1/LLM-Tool-Survey | survey | Frames tool learning as plan → **select** → call → respond, establishing "tool/resource selection" as a distinct stage — the stage Cascade is missing. |
| MCP tools spec | https://modelcontextprotocol.io/specification/2025-06-18/server/tools | spec | Standard shape for declaring tools/resources (name, description, input schema, list/discovery) — the manifest format to model the resource catalog on. |

## What SEQ-04 / 05 / 13 / 25 / 30 already cover (so this is net-new, not overlap)

A grep of all 30 SEQ docs shows the routing *core* here is absent (Adaptive-RAG, Self-RAG, "resource catalog / capability card / manifest", "retrieval-over-tools / tool selection" = zero hits). The existing docs route **other axes**:

- **SEQ-04 (semantic-retrieval-memory)** — cites Corrective-RAG, but only as "keep BM25 + dense, rerank" guidance *inside* recorded-record recall (FTS+vector RRF). It is not a local→web *source* escalation gate, and it does not declare a multi-resource catalog. Implemented: `SemanticIndex`, RRF fusion, session/episode layer.
- **SEQ-05 (prompt-harness)** — routes the **model and effort** (Sonnet default → one verifier turn / Opus on stuck/no-effect; route effort by episode state), and cites ReAct. Not source routing.
- **SEQ-13 (hierarchical-planning)** — routes the **planning strategy** (planner → executor → verifier, best-of-N for ambiguous grounding) and notes the assist loop "is already ReAct-like." Not source routing.
- **SEQ-25 (test-time-verification)** — sufficiency / verifier gates for **actions and grounding candidates** (pre-action critic, `GroundingVerifier`, `validateAssistCompletion`), not for **search results / source choice**.
- **SEQ-30 (llm-call-determinism-caching)** — pure efficiency: `ModelCallCache`, prompt-cache breakpoints, retry/idempotency, screenshot-hash grounding memoization. Overlaps only the *cache-the-routing-decision* bullet here.

So the only structural sufficiency gate that ships today is **no-effect detection** — an *action* gate, not a *search* gate. SEQ-31 adds the search/source axis those five never touch.

## Concrete Techniques to Adopt

All of the below ship **default-off behind `cascade.experimentalSearchRouting`**, matching the D-series convention (`experimentalModelCallCacheKey`, `experimentalGroundingVerifierKey` in `CascadeAppModel`). Zero shipped-path change until A/B'd.

### 1. A declared Resource Catalog (capability cards), cheapest-first

Replace the three scattered prose notes (`harnessReadOnlyNote`, `recallNote`, and the on-screen/browser guidance) with one structured catalog block — each card = *what it is for · example asks · cost tier* — assembled in `ComputerUseAgent` and appended once per episode (like the skills index). Per ToolRet/Re-Invoke, each card carries **example questions it answers** (so matching is on intent, not keywords), and descriptions are the thing to invest in.

| Resource | Tools | Best for (example asks) | Cost tier |
|---|---|---|---|
| **On screen now** | (just look) | "what does this say", "summarize this page", anything visible | free / 0 latency |
| **Recorded memory** | `search_record`, `get_timeframe`, `inspect_moment`, `list_sessions` | "the email/doc/figure I had open earlier", "what did I work on this morning", "the number from that dashboard" | cheap · local · instant |
| **Local files** | `search_files` (Spotlight), `list_folder`, `read_file` | "find X on my Mac", "what's in that folder", "open the contract" | cheap · local · instant |
| **Web** | browser sandbox (`BackgroundWebAgent`) / on-screen browser | world knowledge, current facts, anything not on this Mac | expensive · slow · network |

- File/function: new `ComputerUseAgent.resourceCatalogNote` (gated by a new init flag), assembled where `harnessReadOnlyNote` / `recallNote` are appended; keep the old prose as the default-on fallback.
- Cross-ref: this is `use_skill`-index retrieval-over-tools applied to *resources*; the four resources are few enough to stay in-context (no embedding index needed at this cardinality — that is a later bet only if resources multiply).

### 2. A routing pre-step: query → intent → source guess (cheap, prompted)

Before the episode acts on a search-shaped goal, run a cheap classification (reuse the existing haiku planner path — `ClaudeSingleStepPlanner` / `AgentTaskPlanner`) that rewrites the spoken/typed ask into `(routingIntent, candidateSources[], cleanQuery)`:

- `onScreen` — the answer is visible now → just look.
- `recordedMemory` — something the user saw/did before → recall first.
- `localFiles` — a file/folder/document on this Mac → Spotlight first.
- `web` — general/current/world knowledge not on this Mac.
- `ambiguous` / `multi` — probe the cheap local sources first, escalate to web on a failed sufficiency check.

This is Re-Invoke's inference-time intent extraction; it also repairs the garbled-voice-transcription problem (`VoiceFragmentGate` already drops non-goals; this rewrites surviving ones into a clean query). File/function: extend the planner call in `runAssistTask` (`CascadeAppModel:1336`), pass the result into the episode as a routing hint.

### 3. THE STRUCTURAL FIX — a search-sufficiency gate before "finished"

This is the centerpiece and the direct fix for the audited bug. It is the search-axis twin of the existing `noEffectTurns` / `idleTurns` guards in `runAssistEpisode` (`CascadeAppModel:1920`) and `runScoutEpisode`.

- Add a `searchToolCalls` counter (like `noEffectTurns` at `:2047`), incremented whenever the episode resolves a recall tool (`RecordRecall.isRecallTool`), a harness search/read tool (`AgentHarness.readOnlyTools`), or a web-sandbox search.
- Detect a **search-shaped goal** structurally (verb/intent: find / search / look up / where is / what's the / how much / who / when … — pure, unit-pinned, EN+AR, mirroring `goalMentionsClipboard` / `goalAsksForScript`).
- When the model tries to finish (the `done` / no-action terminal path) on a search-shaped goal with `searchToolCalls == 0`, **block the finish** and inject a structural nudge via `episodeNote`: *"You have not searched any source yet. Pick the cheapest matching resource from the catalog (recorded memory or Spotlight before the web) and actually search before finishing."* Allow at most one such block, then let the episode end honestly as `.stalled` if it still refuses (no infinite loop) — same shape as the no-effect 3-strike exit.
- Audit each block as `assist.search.ungated` (hashed query descriptor only, per the P7 `AuditIdentity` posture) so the behavior is observable in `audit_event`.

This is runtime-owned, not advisory — the model cannot declare a search done without having searched, exactly as it cannot re-click a dead pixel forever.

### 4. Cheap-first escalation ladder with a sufficiency check (CRAG)

Sequence sources by the cost tiers in §1: **on-screen → {recorded memory ∥ Spotlight} → web**. The two local sources are both cheap/instant and may be probed together (the one place parallel probing is clearly worth it — see Caveats). After the local hop, a lightweight sufficiency judgment (does the recalled/file evidence actually answer the query?) decides whether to escalate to the web sandbox. Reuse the verifier plumbing from SEQ-25 (`validateAssistCompletion` / `VerifierVerdict`) rather than building a new judge; require `abstain` when evidence is thin. Escalate to web only on insufficiency — never lead with it.

### 5. Hand web research to the right engine

Web-search-shaped goals should not be driven by the on-screen agent clicking a browser by screen coordinates (the hard path). When the router picks `web`, prefer dispatching a `BackgroundWebAgent` episode (DOM-native, the validated web tool) and fold its findings back into the on-screen task — the orchestration `runAssistTask` already carries findings across parts.

## Quick Wins vs Larger Bets

Quick wins:

- The search-shaped-goal detector + `searchToolCalls` counter + the **finish-block nudge** in `runAssistEpisode` and `runScoutEpisode` (§3). This alone fixes the audited 2-turn bail and is the highest-value, lowest-risk change.
- The Resource Catalog note (§1) replacing scattered prose, behind the flag.
- `assist.search.ungated` audit row so the gate is measurable before/after.
- Reuse `validateAssistCompletion` for the local-sufficiency judgment (§4) instead of a new verifier.

Larger bets:

- The prompted routing pre-step / query-rewrite classifier (§2) and the full cheap-first escalation ladder with sufficiency gating (§4).
- A trained or embedding-similarity router (semantic-router / RouteLLM style) over the catalog if resource count grows beyond the handful that fit in-context.
- Caching routing decisions by query+context fingerprint in the SEQ-30 `ModelCallCache` (avoid re-deciding the same ask).
- An offline eval set (golden search goals → expected source + expected "did it search") to calibrate the complexity classifier, since Adaptive-RAG's whole benefit rides on classifier accuracy.

## Caveats and Honest Limits

- **Domain transfer.** Every verified claim comes from text-RAG / tool-retrieval / open-domain-QA. NONE studied this exact resource set (Spotlight + a screen-history recorder + live on-screen app UIs + a browser sandbox). On-screen GUI state as a *searchable resource* is unaddressed by any source — the mapping here is reasoned synthesis, not directly evidenced.
- **Closed model.** Search-R1 / R1-Searcher / ReSearch require RL fine-tuning of an open model; Cascade gets only the *prompted* ReAct/Search-o1 analog plus a small bolt-on classifier. Expect a gap vs the trained-policy numbers.
- **Classifier dependence.** Adaptive-RAG's efficiency/accuracy gains hinge on the complexity classifier (23-47% misclassification in-paper); a miscalibrated router can erase the benefit. Hence the structural gate (§3) is the safety net that does **not** depend on the classifier — it only checks "did you search at all," which is robust.
- **Efficiency sub-questions are under-evidenced.** Parallel-vs-sequential source probing and caching the routing decision were *uncovered* by the surviving literature. The §4 "probe both local sources together" choice is a cost heuristic (both are local/instant), not a benchmarked result — measure it.
- **Refuted, do not implement:** CRAG's "Ambiguous → decomposition" (it combines local+web instead), and "retrieved top-5 tools beat the ground-truth set" (it does not).
- **Time-sensitivity.** Most sources are 2024-2025; SOTA numbers will date, though the architectural patterns are stable.

## License/Attribution Notes

- semantic-router, Gorilla, LangChain/LlamaIndex are permissively licensed (MIT/Apache-2.0); CRAG impl (`HuskyInSalt/CRAG`) and Search-R1 (`PeterGriffinJin/Search-R1`) are reference implementations — check each repo's license before porting any code, not just the paper.
- The papers are research references, not code dependencies; cite them in code comments / design docs if their algorithm is implemented (e.g. a `// CRAG-style sufficiency gate, arXiv:2401.15884` note on the escalation check).
- Routing decisions, rewritten queries, and sufficiency judgments may embed OCR / app/window titles / private work facts — apply the same hashing posture as the rest of the audit path (`AuditIdentity`; store query descriptors/hashes, not raw text) and keep any cached routing entries local per user/device, consistent with SEQ-30's privacy notes.
