# WasteDetector — audit + hardening plan (2026-06-22)

How to make Cascade's repeated-work detector **really detect real workflows and be helpful**.
Code-grounded audit of `Sources/WasteDetection/WasteDetector.swift` (+ the gates in
`CascadeAppModel` and the curator), cross-checked against the state of the art in robotic
process mining (RPM), industry task mining (UiPath/Celonis/Power Automate), and PBD research.
Two parallel research sweeps independently converged on the same core paper —
**Leno et al., "Identifying Candidate Routines for RPA from Unsegmented UI Logs" (ICPM 2020,
arXiv:2008.05782)** — which is the academic version of exactly this problem.

## How it works today (the baseline)

`detectedWaste()` → last **3000** input events + 400 contexts → `WasteDetector.detect()`:
1. Collapse consecutive scroll bursts to one event.
2. **Tokenize each event by SHAPE only**: `kind + app + shortcut` — e.g. `click@Mail`,
   `key:command+c@Mail`, `type@Mail`. Coordinates, typed text, **and the clicked element's
   AX label are all discarded** (the label IS recorded in `InputEvent.text` and used by B1's
   replay, but the *detector* throws it away).
3. For contiguous n-grams length **2…8** (longest first), hash the token sequence, group
   **exactly-equal contiguous** sequences, greedily pick **non-overlapping** occurrences,
   mark consumed so shorter sub-grams don't double-count.
4. Keep if **≥2** non-overlapping occurrences AND `isAutomatableInstance` (≥2 *structural*
   actions [click/⌘-shortcut] + an intent marker [named-element click, real shortcut, or
   ≥2 apps]).
5. Rank survivors by `estimatedTotalSeconds` desc; take top **5**.
6. Gates downstream: `isAutomatable` = **≥3 occurrences AND ≥30s** total → LLM curator
   keeps/drops/names → `pendingCuratedAgents` filters dismissed (persisted, 300-cap) — **no
   top-N cap, no re-rank, no variant merge** at the feed.

## Audit — the real weaknesses (each cross-referenced to the literature)

| # | Weakness (code fact) | Why it hurts | Lit. fix |
|---|---|---|---|
| **W1** | **Token ignores the element label it already records** (`click@Mail`, not `click:Mail/"Reply All"`) | Distinct buttons collapse into one token; unrelated clicks merge; the signature is too coarse to tell real routines apart | Leno **normalized-UI** keeps *context params* incl. element identity. **#1 finding of BOTH sweeps.** |
| **W2** | **Exact-contiguous n-grams only** | Misses a routine the moment it's interrupted by one extra click (gap), has a variable-length middle, or reordered steps; and **fragments** one 8-step routine into many 2/3/4-gram "candidates" | **PrefixSpan** (gapped subsequences) → **BIDE+** (closed → kills fragments) → **max-gap** constraint; or **MINEPI** serial episodes over the stream |
| **W3** | **No segmentation / task boundaries** — mines a flat 3000-event window | n-grams merge unrelated adjacent actions or split one routine; no notion of "a task started/ended" | **Streaming completion-keyword + no-shared-data-value boundary** (Rebmann/van der Aa, CAiSE'23) or **CFG back-edge** segmentation (Leno) |
| **W4** | **No variant merging** | Two slightly-different runs of the same task = different signatures → neither reaches ≥3 (real workflow **missed**), or both surface as **duplicate cards** | Cluster by **normalized Levenshtein ≥0.7** (≤30% edit distance), keep longest representative, **sum** frequencies |
| **W5** | **Ranks by raw total-seconds; no cohesion, decay, diversity, or feed cap** | Long-but-loose junk outranks tight real routines; stale routines linger; near-duplicate cards crowd the feed | **Cohesion = length − median(gaps)** (empirically the best ranker, Leno); recency **decay** `e^(−λΔt)`; **MMR** diversity (λ≈0.7); **top-N** truncation |
| **W6** | **Weak automatability gate** | `isAutomatableInstance` counts ≥2 *structural* but not ≥2 **consecutive deterministic** actions (Bosco: stranded automatable steps among non-deterministic ones = worthless); no **cross-app data-transfer** signal (the strongest positive); no **≥5-actions/≥3-steps** floor; no idle/reading or **noisy-app** (Slack/Zoom/Teams) exclusion; no "does Cascade even have a handle for this app" factor | Bosco/Leno determinism model; UiPath structural floor + noisy-app list; Power Automate connector-availability gate |
| **W7** | **Presentation/trust gaps** | Could prompt mid-task; single dismissal state (no transient-vs-never); opaque card titles (known issue); no dry-run preview | Coarse-**breakpoint** deferral (Iqbal/Bailey, 98% from the event stream); 3-state dismissal (Chrome contract); "Why + time-saved" framing (Lim/Dey); "what this would've done last N times" preview (Trace2TAP) |

**Net:** the detector only finds **exact, contiguous, shape-only** repeats over a flat window —
so it both **misses** real workflows (any noise/variation/gap defeats it) and **clutters** with
fragments and coarse-token false merges. The fixes are well-trodden; most are formulas/algorithms
we reimplement from papers (the reference lib **SPMF is GPLv3 → paper-port only**; OpenAdapt is
MIT, SmartRPA MIT, Google macro-mining Apache — readable references).

## The hybrid principle (what the whole field agrees on)

**Deterministic mining PROPOSES & COUNTS; the LLM only DISPOSES, NAMES, and ABSTRACTS** — over the
handful of survivors. Do **not** push segmentation/counting onto a model (benchmarks show small
models fail at it; hallucination ∝ −capability). Keep mining deterministic; the curator (already
an LLM) stays the judge/namer. Cascade is already shaped this way — this plan strengthens the
deterministic half and tightens the gate the LLM judges behind.

## Hardening plan — phased, ranked by leverage ÷ effort (all license-clean)

- **H1 — Enrich the detection token with the AX label/role [TINY, do first; multiplies everything].**
  `token()` → include `event.text` (the element label, already recorded): `click:Mail/"Reply All"`
  not `click@Mail`. One-line-ish change; makes every downstream step far more discriminating.
  *Fixes W1.* (Leno context-params.)

- **H2 — Cohesion ranking + tighter gate [LOW].** Rank by `cohesion = patternLength − median(gaps)`
  then ROI-weight (`occurrences × est_seconds × complexity_penalty(actionCount, appSpan)`); add to
  `isAutomatableInstance` a **≥2-consecutive-deterministic** requirement and a **≥5-actions/≥3-steps**
  structural floor; exclude noisy apps (Slack/Zoom/Teams). Pure, unit-pinnable. *Fixes W5, W6.*

- **H3 — Closed, gap-tolerant subsequence mining [MEDIUM; the core algorithmic upgrade].** Replace
  exact-contiguous n-grams with **PrefixSpan → filter to closed (BIDE+) → max-gap, non-overlapping
  counting** (reimplement from Pei TKDE'04 / Wang&Han ICDE'04; Spark MLlib PrefixSpan is Apache as a
  reference). *Fixes W2.* Highest algorithmic payoff; gated behind H1 (richer tokens).

- **H4 — Stream segmentation into routine instances [MEDIUM].** Before mining, cut the stream at task
  boundaries: a **completion-keyword** in the clicked label (`Send/Save/Submit/OK`) **AND** a
  no-shared-data-value test (don't split when adjacent chunks share a value) + idle-gap + app/window
  switch (Cascade already records all of these). *Fixes W3.* (Rebmann/van der Aa.)

- **H5 — Variant merge + dedup + decay + MMR + top-N at the feed [MEDIUM].** Single-link cluster
  `DetectedWaste` by normalized Levenshtein over signature tokens (≥0.7), keep longest, sum
  occurrences; apply recency decay; MMR-rerank the curated feed (λ≈0.7) and truncate to ~3–5; push
  the rest to a passive "more" list. *Fixes W4, W5.*

- **H6 — Judgment/trust polish [LOW–MEDIUM, incremental].** Cross-app data-transfer as a positive
  automatability signal (copy-value reappears in another app — already in the recorded data);
  app-handle-exists factor; coarse-breakpoint prompt deferral + meeting/fullscreen suppression;
  3-state dismissal (Accept / transient / Never-for-signature); "saves ~Xm/week · seen N×" + Why on
  every card; "what this would've done the last N times" dry-run before deploy. *Fixes W6, W7.*

**Suggested first PR:** **H1 + H2** — both are small, pure, unit-testable, need no new dependency or
algorithm rewrite, and together fix the two cheapest-but-highest-impact problems (coarse tokens +
junk ranking/gate). H3/H4 are the deeper algorithmic upgrades to schedule next; H5/H6 are
feed-quality and trust.

## License notes (port MIT/Apache/BSD; reimplement formulas freely)
- **SPMF** (reference impl of PrefixSpan/BIDE+/VMSP/MINEPI) = **GPLv3** → behavioral oracle/test
  fixture only, reimplement from the papers.
- **OpenAdapt** event-merge (MIT), **SmartRPA** full pipeline (MIT), **Google macro-mining** LLM-hybrid
  (Apache-2.0) = readable, portable references.
- Cohesion ranking, Levenshtein, MMR, recency decay, context/data-param split, breakpoint deferral,
  consecutive-deterministic gate = algorithms/formulas from papers → reimplement freely.
- ⚠️ Verify repo licenses before any code reuse: `RPM_Segmentator` (Java), the Mannheim streaming repo.

## Done when
The detector surfaces a real multi-step workflow even when it's interrupted, slightly varied, or
separated in time; stops emitting coarse-token false merges and n-gram fragments; ranks tight,
high-value routines first; merges variants into one card; and the feed stays short and trustworthy.
Verified on a recorded session with deliberate noise/variation injected, plus the unit pins per phase.
