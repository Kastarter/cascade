# Deep Research — Speed · Grounding · Context · Repetitive-Task Agents (2026-07-01)

Synthesized from deep-research workflow `wf_1101a2f2-70a`: 5 search angles → 23 sources
fetched → 109 claims extracted → top 25 adversarially verified (3 votes each) →
**24 confirmed, 1 refuted**. Cross-referenced against the post-SEQ-walk codebase (all 31
SEQs validated 2026-07-01, agent opens/clicks/types end-to-end) and prior internal research
(`docs/AGENT_FAILURE_RATE_RESEARCH.md` 2026-06-24, `docs/research/SEQ-08…`, `SEQ-22…`).

**Headline: build on almost everything; replace exactly one core.** Keep the Swift-native
recorder, AX-first resolver, Apple Vision OCR, SQLite memory, and the Anthropic CU loop.
Add learned sidecars + an eval harness where the 2025–26 evidence is strongest (4B–8B
grounders, Screen2AX-style AX recovery, action-level selector caching). The single REPLACE:
the literal-token candidate-generation core of workflow mining.

**License gate (CLAUDE.md):** port MIT/Apache/BSD only. AGPL/BSL/source-available
(Skyvern, PM4Py, OmniParser detector, screenpipe) = design inspiration only.

---

## Thread 1 — Agent speed

### Verdict: BUILD ON. Shift effort from per-call micro-optimizations to fewer model calls and fewer steps.

Cascade already ships the per-call layer (streaming action execution, prompt caching with
moving breakpoints, screenshot-history pruning, TLS prewarm, model-res JPEG, ModelCallCache).
The verified evidence says that layer is no longer where the time is:

- **OSWorld-Human** ([arXiv 2506.16042](https://arxiv.org/abs/2506.16042), verified 3-0 ×4):
  across 16 agents, (a) **planning/reflection/judging model calls dominate total latency**,
  (b) **later steps run ~3× slower than early steps** as history grows, (c) even the
  strongest agents take **2.7–4.3× more actions than human-determined trajectories**.
  Implications, in order of leverage:
  1. **Step-count reduction** — every eliminated step removes a screenshot, a model call,
     a grounding opportunity to fail, and a verify cycle. Multi-action chunking per turn
     (Cascade already batches fill-fields; extend to safe click→type→submit chains).
  2. **History compaction** — the 3×-slowdown finding says prune harder than "old images →
     text placeholders": summarize old turns into a compact state note (app, url, subgoal
     status) and drop raw tool_results beyond N turns. Directly attacks late-step latency.
  3. **Reserve verifier/critic calls for uncertain/risky turns** (already the design in
     AGENT_FAILURE_RATE_RESEARCH #2/#3 — this is confirmation, not new work).

- **Stagehand action-level caching** ([Browserbase blog](https://www.browserbase.com/blog/stagehand-caching),
  2026-02): caches the **resolved selector per action** (not whole trajectories); cache hit
  = zero LLM calls; **parameterized reuse** (same selector, different typed value); **drift
  = cache miss → normal execution**; claims up to ~80% speedup on repeat workloads.
  This is exactly the SEQ-22 `ActionTrajectoryCache` design → **strong external validation
  of the SEQ-22 doc; implement it as specced** (exact tier auto-executes only verified
  idempotent actions, semantic tier is a prompt hint). BUILD ON `GroundingCache` (already
  ON post-walk) + SEQ-22 schema. Latency impact: high on repeat work — which is Cascade's
  core product loop.

- **Small-model routing**: keep as third priority. OSWorld-Human doesn't isolate model-size
  gains, and the walk found Sonnet-first *increased* turn count (net slower than Opus).
  Route only trivially-verifiable steps (scroll, wait, re-ground) to Haiku/local; A/B with
  the timing audit already emitted per run.

- **browser-use** (MIT, ~102k★) claims 3–5× task speedup on its optimized model path and
  production parallel execution — vendor claims, unverified; mine it for harness patterns
  only. **SKIP** as a dependency (Python, web-only).

**SKIP:** speculative execution of unverified actions (evidence base thin; contradicts
Cascade's supervised/auditable posture except after verifier-confidence gating).

---

## Thread 2 — Grounding accuracy + instruction understanding

### Verdict: BUILD ON the whole stack (it just proved itself in the walk); add a benchmark harness + local-grounder bakeoff before any swap.

Post-walk reality check: seq-21 (ui-tars via OpenRouter, default-on) + seq-25 (finished
GroundingVerifier, accepts good grounds at 0.87) + seq-29 (fail-fast on noCandidates)
cleared the click blocker. The question is no longer "does grounding work" but "how much
headroom is left and which model buys it."

Verified 2025–26 leaderboard state ([ScreenSpot-Pro leaderboard](https://gui-agent.github.io/grounding-leaderboard/),
updated 2026-06-22; greedy decoding, micro-average — Cascade's multi-sample clustering may
beat listed numbers for the same model):

| Model | Sizes | License | ScreenSpot-Pro | Other | Availability |
|---|---|---|---|---|---|
| **UI-Venus-1.5** ([2602.09082](https://arxiv.org/abs/2602.09082)) | 2B/8B dense, 30B-A3B | Apache-2.0 (Qwen3-VL base) | **69.6%** (30B-A3B) | VenusBench-GD 75.0, AndroidWorld 77.6 | HF weights; 8B is the self-host sweet spot |
| **Holo2** ([hcompany.ai/holo2](https://hcompany.ai/holo2), 2025-11) | 4B/8B/30B-A3B | **4B/8B Apache-2.0** | 66.1% (30B-A3B) | OSWorld-G 76.1 | HF weights; 4B/8B verified Apache-2 |
| OpenCUA ([repo](https://github.com/xlang-ai/OpenCUA), MIT) | 7B/32B/72B | MIT | 60.8% (72B) | OSWorld-Verified 45.0 | vLLM-served; + AgentNet cross-OS dataset/tooling |
| UI-TARS-1.5-7B *(current)* | 7B | Apache-2.0 | ~39% | — | current OpenRouter path |
| UI-TARS-2 ([2509.02544](https://arxiv.org/abs/2509.02544)) | — | — | — | OSWorld 47.5 (agent, not grounder-only) | **no released weights/API found — watchlist only** |
| OmniParser V2 (Microsoft) | — | detector AGPL / captioner MIT | 39.5% | — | design-only (AGPL detector) |

Concrete moves, in order:

1. **Benchmark harness first** (new, small): a private grounding eval from Cascade's own
   corpus — the walk produced a natural one (73× `grounding.verifier reject` events,
   `agent.ground.miss` audit rows, recorder frames). 50–200 real click-failures + a
   ScreenSpot-Pro slice. Without this, any grounder swap is faith-based. The recorder
   already stores everything needed (frames + OCR + AX + click outcomes) —
   SEQ-21's doc already proposed recorder-derived eval data; this makes it real.
2. **Bakeoff: Holo2-8B vs UI-Venus-1.5-8B vs current UI-TARS-1.5** through the existing
   `VisualGrounder` (OpenAI-compatible endpoint — both new models serve via vLLM/SGLang
   unchanged; also try Holo2-4B / UI-Venus-2B via MLX for the local-Mac story). Re-verify
   the `smartResize` coordinate mapping — UI-Venus/Holo2 are Qwen3-VL-era, UI-TARS-1.5 was
   Qwen2.5-VL. Keep multi-sample clustering + GroundingVerifier reranking on top: verifier-
   reranked ensembles beat any single grounder (consistent with SEQ-25 findings).
3. **Screen2AX as sparse-AX recovery** ([arXiv 2507.16704](https://arxiv.org/abs/2507.16704),
   [MacPaw repo](https://github.com/MacPaw/Screen2AX) — **macOS-native, from a Mac company**):
   reconstructs AX-style hierarchy from a screenshot when native AX is missing (only ~⅓ of
   macOS apps have full AX support — verified 3-0). Feed reconstructed elements into
   `MixtureGrounder` as one more candidate source scored by the existing verifier — as a
   **recovery/verification layer, not source of truth**. ⚠️ The "77% F1 tree-reconstruction"
   number was **REFUTED (0-3)** in verification — adopt the technique, re-measure the
   accuracy yourself. Check repo license before porting (MacPaw ships MIT-ish, verify).
4. **Intent disambiguation**: no strong new external evidence surfaced this pass; keep the
   current design (repeat-failure → forced strategy change → ask-user) and the PUMICE-style
   "ask only when evidence is ambiguous" rule from SEQ-08's doc.

**vs. the 2026-06-24 internal playbook:** Holo2 (4B/8B, Apache-2) supersedes Holo1.5-7B as
the bakeoff candidate; UI-Venus-1.5 confirmed. The playbook's "gated on hosted availability"
caveat still holds — self-hosting is a vLLM/SGLang/MLX sidecar, not a Swift port.

---

## Thread 3 — OCR + most-accurate context

### Verdict: BUILD ON Apple Vision + AX fusion. No verified evidence that VLM-OCR beats Apple Vision on *screen* text. Route VLM-OCR to low-confidence/table regions only.

The verification pass explicitly failed to establish that Qwen-VL-OCR / GOT-OCR2 /
Florence-2 / DeepSeek-OCR / dots.ocr / PaddleOCR beat `VNRecognizeTextRequest` on macOS
screen text. Screen text ≠ scanned documents: benchmarks like OmniDocBench are
document-parsing benchmarks. So:

- **Keep** Apple Vision as the always-on recorder OCR (native, fast, no sidecar).
- **Targeted adjudication**: for dense tables / tiny fonts / low-confidence regions, a
  region-gated escalation to a doc-VLM is the defensible upgrade. Best candidate:
  **PaddleOCR-VL-1.6** ([repo](https://github.com/PaddlePaddle/PaddleOCR), Apache-2 at repo
  level; check weight licenses) — 0.9B params, claimed 96.3% OmniDocBench v1.6, PP-OCRv6
  has a published Apple-M4 latency figure, PP-StructureV3 emits coordinate-rich structured
  output that maps cleanly onto `ScreenContentStructurer`'s reading-order/key-value/table
  schema. Sidecar, opt-in, region-gated — BUILD ON `structuredContent`, don't replace it.
- **Screen2AX** double-counts here: recovered AX structure is also *context* — a UI tree
  for windows where AX harvesting comes back empty (thread 2, move 3).
- **OCR-Memory** ([arXiv 2604.26622](https://arxiv.org/abs/2604.26622), ACL 2026): stores
  agent history as **rendered annotated images** and retrieves via locate-and-transcribe —
  verbatim text without token-budget blowup. Cascade's recorder *already is* this memory
  (frames + OCR boxes in SQLite); the portable idea is the **retrieval flow**: answer from
  a located frame region (re-OCR the crop) instead of trusting stored summaries. Cheap
  upgrade to `inspect_moment`/`extract_fields`.
- **Automatic episodic context** (the "right past context without on-demand tools" ask):
  no single verified winner. The grounded pattern from screenpipe (event-triggered capture,
  FTS5 — same architecture Cascade already has; license now non-permissive, design-only)
  plus SEQ-22's fused retrieval (embedding + BM25/FTS + entity + recency + success) is the
  path: **auto-inject a small budgeted recall block** (top-3 moments for the current
  app/goal) into turn 1 of each assist run, behind a flag, measured by turn-count delta.
  BUILD ON `RecordRecall` + `RankFusion` + the now-ON work-graph index.

**SKIP:** wholesale VLM-OCR replacement of the recorder pipeline (cost/latency/privacy all
regress; evidence absent). **SKIP** OmniParser as pipeline (AGPL detector) — its
icon-captioning idea (label non-text elements so grounding has names for icons) is the one
concept worth a local port later.

---

## Thread 4 — Repetitive-task detection → background agents

### Verdict: REPLACE the literal-token candidate-generation core. Keep the recorder, episode segmenter, curator, sandbox runtime, and NEEDS_LOGIN protocol.

This is the walk's confirmed product gap (seq-08: ETH/SOL/BTC/LTC → Notion ×4 mined **zero**
candidates in ~1235 events). The external evidence agrees the fix is abstraction-first, not
better literal mining:

- **ASI — Inducing Programmatic Skills** ([arXiv 2504.06821](https://arxiv.org/abs/2504.06821)):
  induces **programs with parameters** from successful trajectories, verifies them by
  execution, adds them to the action space. **+23.5pp over static baseline, +11.3pp over
  text-skill counterpart on WebArena, with fewer steps**; skills transfer across sites with
  shared sub-skills. This is the strongest single blueprint for `AgentRecipe` v2: a recipe
  = a small parameterized program (loop over {ETH,SOL,BTC,LTC}: search(x) → copy → paste),
  not a frozen event sequence.
- **AWM — Agent Workflow Memory** ([arXiv 2409.07429](https://arxiv.org/abs/2409.07429)):
  induces reusable routines offline *or online*; +24.6% rel (Mind2Web) / +51.1% rel
  (WebArena), shorter successful trajectories; gains grow as train/test distribution gap
  widens — i.e., abstraction generalizes across parameter variation, exactly the crypto
  case. Note: the 2026-06-24 playbook said AWM had "no strongly-verified desktop gain" —
  correct, numbers are web benchmarks; adopt the *mechanism* for recipe induction, don't
  expect the web deltas on macOS.
- **SKILL-DISCO** ([arXiv 2606.26669](https://arxiv.org/abs/2606.26669), 2026-06): mines
  **parameterized procedural FSM subgraphs** from successful traces — the direct
  research-grade version of "same actions, different data = one routine."
- **Stagehand parameterized reuse** (thread 1): same cached action with only the typed
  value changed — the runtime counterpart of parameter slots.
- **SmartFlow** ([arXiv 2405.12842](https://arxiv.org/abs/2405.12842)): GUI→text→LLM
  generates the executable sequence; evidence RPA has moved from replay to generate-with-
  variation-tolerance.
- **OpenAdapt** (MIT): demo-library + embedding retrieval + demonstration-conditioned
  prompting (46.7%→100% first-action on a controlled macOS benchmark, self-reported).
  Engineering reference for the demo→execution path; already flagged in SEQ-08's doc.
- **PM4Py** (AGPL): vocabulary/diagnostics only, no code. Leno et al. dataflow-parameter
  discovery ([2001.01007](https://arxiv.org/abs/2001.01007), from SEQ-08 doc) remains the
  concrete algorithm for inferring copy→transform→paste parameters from UI logs.

**Concrete replacement design** (composes with what's already wired):

1. Keep `ActionEpisodeSegmenter` (episodes in, not flat streams) — already landed (D-04).
2. **Abstract before mining**: map each event to a typed action schema
   `(verb, app/surface, target-role, target-label-class, data-class)` where data values are
   replaced by **slots** with categories (ticker, price, name, date — NLEmbedding/NER
   locally, or Haiku for label classing). The crypto runs become 4 identical abstract
   sequences → PrefixSpan finds them *with zero miner changes*.
3. **Cluster episodes semantically** (embed abstract action windows; SEQ-22's
   `LocalSemanticVector` helper) so near-variants merge **before** the ≥3 repetition
   threshold, per SEQ-08's "merge variants before threshold" note.
4. **Synthesize a parameterized program** (ASI-style) via WorkflowCurator: emit
   recipe-with-slots + a loop when instances differ only by slot values; **verify by
   execution** in the sandbox (dry-run/replay) before offering — only verified skills enter
   the library (matches the experience-ledger/skill-consolidation machinery that's already
   ON post-walk).
5. Runtime stays: scheduled `BackgroundWebAgent`, NEEDS_LOGIN pause/resume, audit, STOP.
   For browser recipes, study Skyvern's deterministic-first/AI-fallback execution mode
   (AGPL — concept only): try the cached deterministic step, fall back to the CU loop on
   drift. WebBench 64.4% shows the hybrid holds up in production.

This also likely fixes **seq-18** (proactive offer never fired): offers key off detected
routines; parameterized clustering produces routines where literal mining produced none —
re-test seq-18's threshold after step 3 lands before touching the offer wiring.

---

## Ranked adoption roadmap

Ordered by (failure-rate impact × latency impact) ÷ effort, respecting the license gate:

1. **Grounding eval harness from recorder data** — small, unblocks everything in thread 2;
   no dependency. (failure ↑↑, latency —)
2. **Grounder bakeoff: Holo2-8B / UI-Venus-1.5-8B vs UI-TARS-1.5** behind the existing
   `VisualGrounder` endpoint config; keep verifier reranking. (failure ↑↑↑, latency ~neutral
   with cache; both Apache-2.0) — supersedes Holo1.5 from the June playbook.
3. **Workflow-mining abstraction layer** (typed action schema + slot induction + semantic
   episode clustering → parameterized recipes, ASI/AWM/SKILL-DISCO pattern) — the one
   REPLACE; unblocks the core "agents from repeated work" product promise + seq-18 retest.
   (product value ↑↑↑, failure ↑ for replays, latency ↑↑ on repeat work)
4. **ActionTrajectoryCache per SEQ-22 spec** (Stagehand-validated: action-level, drift=miss,
   parameterized reuse; auto-execute only verified idempotent hits). (latency ↑↑↑ on repeat
   work, failure ↑ via fewer model decisions)
5. **History compaction + multi-action chunking** in the CU loop (OSWorld-Human: late-step
   3× slowdown, 2.7–4.3× human step count). (latency ↑↑, failure ↑)
6. **Screen2AX-style sparse-AX recovery** as a MixtureGrounder candidate source (macOS-
   native; re-measure accuracy — the 77% F1 claim was refuted). (failure ↑↑ on custom UI,
   latency cost — gate to low-AX-confidence turns)
7. **Auto-injected episodic recall block** (top-3 fused-retrieval moments at turn 1, flag +
   turn-count A/B). (failure ↑, latency ~, product ↑)
8. **Region-gated doc-VLM escalation** (PaddleOCR-VL sidecar for tables/dense regions
   feeding ScreenContentStructurer). (context accuracy ↑, opt-in latency)
9. **Watchlist**: UI-TARS-2 (no weights/API yet), Holo3/GUI-OWL-1.5 (per June playbook),
   OpenCUA AgentNet (MIT — candidate training/eval data if Cascade ever fine-tunes),
   OCR-Memory retrieval flow, OmniParser icon-captioning concept.

## Caveats
- Grounder headline numbers (UI-Venus, Holo2, OpenCUA, Skyvern WebBench, Stagehand 80%,
  OpenAdapt 46.7→100) are **self-reported**; ScreenSpot-Pro leaderboard is greedy-decoding
  micro-average. Item 1 (own harness) exists precisely to de-risk this.
- ASI/AWM/SKILL-DISCO numbers are **web-benchmark** results; treat as mechanism evidence,
  not expected macOS deltas.
- Screen2AX's 77% F1 claim **refuted** in verification; technique confirmed, number not.
- No verified evidence surfaced that any VLM-OCR beats Apple Vision on screen text — that
  comparison remains an open question worth a small internal benchmark (open question #4).

## Open questions (from the verification pass)
1. Which 50–200 real click failures become the canonical private grounding benchmark?
2. Can Holo2-4B/8B or UI-Venus-1.5-8B hit the latency budget on Apple Silicon after
   quantization (MLX), or is a LAN/GPU sidecar required?
3. What typed-action-trace schema makes slots (ticker/document/row/destination) minable
   across apps? (→ thread 4 step 2)
4. Do macOS 15/16 Vision/VisionKit APIs materially beat the current
   `VNRecognizeTextRequest` path on screen OCR?

## Source index (23 fetched, 24/25 verified claims)
Primary: arXiv 2506.16042 (OSWorld-Human) · 2602.09082 (UI-Venus-1.5) · 2509.02544
(UI-TARS-2) · 2507.16704 + MacPaw/Screen2AX · 2404.07972 + osworld-v1.xlang.ai (OSWorld) ·
2504.07981 + gui-agent.github.io/grounding-leaderboard (ScreenSpot-Pro) · 2504.06821 (ASI) ·
2409.07429 (AWM) · 2606.26669 (SKILL-DISCO) · 2405.12842 (SmartFlow) · 2604.26622
(OCR-Memory, ACL 2026) · hcompany.ai/holo2 + HF Holo2-4B/8B · github: inclusionAI/UI-Venus,
xlang-ai/OpenCUA, simular-ai/Agent-S, bytedance/UI-TARS-desktop, OpenAdaptAI/OpenAdapt,
skyvern-ai/skyvern, browser-use/browser-use, screenpipe/screenpipe, microsoft/OmniParser,
PaddlePaddle/PaddleOCR, process-intelligence-solutions/pm4py · blog: browserbase.com
(Stagehand caching).
