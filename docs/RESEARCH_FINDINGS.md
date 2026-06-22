# Research Findings — "steal the best engine per pipeline stage" (2026-06-22)

Synthesized from the deep-research workflow `wf_cb3b405b-627` (run in a prior session). That
run completed **scope → 5 search angles → 20 source fetches (all primary-source) → 21 adversarial
verdicts**, then was interrupted before its own synthesis step. This document IS that missing
synthesis, reconstructed faithfully from the run's journal. See `docs/RESEARCH_HANDOFF.md` for the
exact question and `docs/HANDOFF.md` for the architectural decision it feeds.

**Confidence legend:** ✅-VERIFIED = survived 3-vote adversarial verification (high confidence).
◦-PRIMARY = extracted from the repo's own primary source (README/LICENSE/docs) by a fetch agent
but not independently re-verified (the run was cut off mid-verify; only the Stage-1/2 recorders
got the full 3-vote pass). Treat ◦ claims as reliable-but-double-check-license-before-porting.

**License gate (from CLAUDE.md):** port **MIT / Apache / BSD** only; **never port code from
copyleft (GPL/AGPL) or source-available/BSL/commercial** repos — design/architecture only.

---

## TL;DR — the one combined-engine recommendation

| Stage | Cascade today | Verdict | Best engine to harvest |
|---|---|---|---|
| **1 Record + dedup** | 1fps SCStream + dHash/grid-hash | **Already the standard** — keep | (screenpipe's *event-driven* capture as an efficiency idea only) |
| **2 OCR + AX + memory** | AX-first + OCR-fallback, SQLite+FTS5+word-vec | **Already the standard** — validated by screenpipe convergence | Pensieve's Jina-768 embedding design *if* upgrading the vector lane |
| **3 Demo → adaptive replay** ⭐ | literal recipe replay (`runAgentRecipe`) — **brittle** | **THIS is the build** | **OpenAdapt `VisualReplayStrategy`** (element-description re-grounding) + **AgentRR check-functions** (structural validators) |
| **4a On-screen CU agent** | Anthropic CU vision loop | grounding is the bottleneck | **UI-TARS-1.5-7B** open-weight grounding model (downgrade target); planner/grounder split confirmed by Agent-S + cua |
| **4b Background web agent** | goal-driven WKWebView DOM agent | already adaptive | **browser-use** index-DOM-click + **Stagehand** cache-then-heal |

**The headline:** Stages 1–2 need nothing — Cascade already converged on the same stack every
serious peer uses (the research's strongest cross-cutting signal: screenpipe, Pensieve, OpenRecall,
rem all land on local SQLite + FTS5 + OCR/AX + vector, exactly Cascade's design). **The real prize
is Stage 3**, and the answer is unusually clean: **OpenAdapt (MIT) already solved exactly the
"adapt, don't blindly replay" problem Cascade is about to build**, with a published 100% vs 46.7%
accuracy result, and it's model-agnostic over Claude. Pair its re-grounding mechanism with
**AgentRR's "check functions"** (a structural validator layer that matches Cascade's
STRUCTURAL-over-advisory law and its already-landed no-effect detection).

---

## Stage 1 + 2 — local recorder + OCR/context memory

Ranked by port value to a Swift-first on-device app.

| Repo | ★ | Stack | License | Port type | The one engine worth stealing |
|---|---|---|---|---|---|
| **screenpipe** (mediar-ai) | 19.4k | Rust+TS / Tauri | ⛔ **Source-available "Screenpipe Commercial License"** (was MIT; commercial use needs a paid license) ✅-VERIFIED | **design only** | AX-tree **primary**, OCR **fallback** capture; **event-driven** dedup (capture on app-switch/click/typing-pause/scroll, not fixed-rate); SQLite+FTS5+JPEG — *the de-facto standard, which Cascade already matches* |
| **rem** (jasonjmcghee) | 2.5k | **Swift/SwiftUI 99.1%** | ✅ **MIT** ✅-VERIFIED | **native — closest to a code port** | Only native-Swift peer: 2s screenshot + OCR (Apple Live Text) + SQLite + local video. ⚠️ **Its NL/semantic search is ROADMAP, not shipped** (✅-VERIFIED refutation) — do **not** expect a Swift semantic-search shortcut here; and it does **no** privacy gating (records everything) |
| **Pensieve / memos** (arkohut) | 1.4k | Python+TS | ✅ **Apache-2.0** ✅-VERIFIED | design (reimplement in Swift) | Concrete **semantic-recall reference**: Jina embeddings (768-dim), full-text **and** vector search, SQLite default / pgvector for scale. Best blueprint if Cascade upgrades its word-vector lane |
| **OpenRecall** | 2.9k | Python | ⛔ **AGPL-3.0** ✅-VERIFIED | **design only** | Privacy-first fully-local snapshots+OCR+search; architecture reference but a copyleft landmine |

**Takeaway:** Cascade's Stage 1/2 is **already best-in-class and license-clean**. screenpipe is the
biggest peer but its move to a commercial source-available license (mid-2026) makes it design-only.
The only net-new ideas: (1) screenpipe's **event-driven capture** as an efficiency refinement to
the 1fps loop (already partially echoed by Cascade's app-activation capture); (2) **Pensieve's
Jina-768 embedding** design if/when the deferred embedding-upgrade happens. rem is the only native
peer but offers no shortcut on the part that matters (semantic search is vapor there).

---

## Stage 3 — demonstration → adaptive replay ⭐ (the priority — this is change (b))

This is the stage Cascade is about to build: today the on-screen deploy path (`runAgentRecipe`,
`CascadeAppModel.swift:2459`) **literally replays recorded clicks**, re-anchored via OCR/AX, and
pauses on 2× drift. The question: how do the best projects turn a recorded demo into a re-executable
**intent** that survives a changed screen?

| Repo | ★ | Stack | License | Port type | The mechanism |
|---|---|---|---|---|---|
| **OpenAdapt** (OpenAdaptAI) | 1.6k | Python | ✅ **MIT** ◦-PRIMARY (license + mechanism both from repo source/merged PR) | **design-port to Swift; model-agnostic over Claude** | ⭐ **THE answer** (see deep-dive below) |
| **AgentRR** | — | research repo/paper (May 2025) | ⚠️ **license UNVERIFIED — confirm before porting code** | design (validator pattern) | **"Experience" abstraction + check-functions** (see deep-dive) |
| **Stagehand** (Browserbase) | 23.2k | TypeScript | ✅ **MIT** ◦-PRIMARY | design (web-only, but pattern ports) | **cache-then-heal**: hash page structure + action description → store DOM→action map → replay deterministically with **no LLM**; on DOM change, fall back to live LLM then **update the cache** |

### Deep-dive: OpenAdapt `VisualReplayStrategy` — the engine to port

This is the cleanest match to Cascade's exact problem, and it's MIT + works with `claude-3-opus`.

1. **Record** input actions + screenshots **+ accessibility-tree** (matches Cascade Stage 1–2 exactly).
2. **Generalize, don't memorize:** each recorded mouse event is converted into a **natural-language
   description of the targeted UI element** (via window segmentation + a vision-language description),
   *instead of* storing a fixed click coordinate.
3. **Re-ground at replay:** the element description is converted **back to coordinates on the new
   screen** — so the recorded demo executes on a *changed layout*, not a static pixel.
4. **Trajectory-conditioned disambiguation:** the VLM agent is *conditioned on the human
   demonstration* rather than replaying blindly — published result **100% vs 46.7% baseline accuracy**.
5. **Intent-level steering:** accepts free-text replay instructions that re-target the recorded
   action (`--instructions "Multiply 6x8"`, "write everything in UPPER CASE") — generalizing a demo
   to a new intent.
6. Three-phase **Demonstrate → Learn → Execute**; demos stored in a **searchable library** and used
   to ground intentions to UI coordinates at execution time.

**Why it fits Cascade:** it is *exactly* "record what the user did, but re-ground each step on the
live screen." It's MIT and model-agnostic (the merged PR was tested against Claude). It's Python, so
**port the algorithm into Swift**, reusing Cascade's existing `AXElementResolver` (label→element),
`ElementLocator` (Claude-vision find-X), and the OCR/AX harvest already in the recorder.

### Deep-dive: AgentRR — the structural validator + downgrade layer

Best-aligned with Cascade's two hard-won laws (STRUCTURAL > advisory; downgrade by moving work out
of the model):

- **Generalize a demo into an abstract "Experience"** = a *class* of safe executions; replay enforces
  *conformance to the generalized experience*, not replication of one trace.
- **Multi-level experience hierarchy:** low-level experiences replay fast/reliably but generalize
  poorly; high-level experiences are abstracted (no fixed steps/env) and used **when the screen
  changes** — an explicit changed-screen adaptation knob.
- **"Check functions"** = explicit safety boundaries during replay verifying flow integrity, state
  preconditions, parameter constraints, invariants — **before** proceeding. This is *exactly*
  Cascade's STRUCTURAL-scaffolding philosophy and a generalization of the already-landed **no-effect
  detection**. Port this as the validator gate around any adaptive replay.
- **Record → summary → replay:** an expensive powerful model builds experiences; a **lightweight
  local agent replays** them — directly serving the CU-model-downgrade roadmap.

⚠️ **License unverified** by the run — confirm AgentRR's license before porting any code; the
*pattern* (check-functions, experience hierarchy) is safe to adopt regardless.

### Stagehand's pattern, applied on-screen

Stagehand (MIT, web/DOM) proves the production-grade shape of the same idea: **cache the
deterministic path, heal with the LLM only when it breaks, then re-cache.** Mapped onto Cascade's
on-screen agent this becomes: *replay the recipe deterministically (fast, no LLM/turn) while the
screen matches the recording's AX/OCR fingerprint; the moment it drifts, fall back to OpenAdapt-style
element-description re-grounding (or the `runAssistTask` vision loop), then update the recipe.* That
**dissolves the binary** the handoff posed (literal replay *vs.* full goal-driven) into a hybrid that
keeps replay's speed/determinism and gains adaptivity exactly when needed.

---

## Stage 4a — on-screen computer-use GUI agents

| Repo | ★ | Stack | License | Port type | Steal |
|---|---|---|---|---|---|
| **UI-TARS / UI-TARS Desktop** (ByteDance) | 37k | TS/Electron app; **model = open weights** | ✅ **Apache-2.0** ◦-PRIMARY | **the MODEL, not the app** | **UI-TARS-1.5-7B** pixel-level visual grounding (screenshot→coordinate), **SOTA on ScreenSpotPro beating Claude & OpenAI**. The grounding downgrade target |
| **trycua/cua** | 18.6k | Python + **Rust + Swift** | ✅ **MIT** ◦-PRIMARY | partial code (Swift pieces) + design | **Grounder/thinker split** (cua-agent reasoning vs cua-sandbox/computer-server grounding) + **Cua-Bench** eval harness (OSWorld/ScreenSpot/Windows Arena) + trajectory export. Note: VM-based sandbox (Virtualization.Framework via Lume + QEMU), heavier than Cascade's WKWebView |
| **Agent-S / Agent-S3** (simular-ai) | 11.9k | Python | ✅ **Apache-2.0** ◦-PRIMARY | design | **Planner-grounding split** (planning LLM + separate **UI-TARS-1.5-7B** grounder); **macOS-supported**; S3 **surpasses human on OSWorld (72.6%)**. ⚠️ **NOT** a demo-replay source — its "memory" is in-context reflection + 8-turn trajectory only |
| **self-operating-computer** (OthersideAI) | 10.3k | Python | ✅ **MIT** ◦-PRIMARY | design | Multiple grounding modes: **OCR default**, **Set-of-Mark (YOLOv8 button detection)**, vanilla screenshot; model-agnostic; pure vision loop + PyAutoGUI |
| **Skyvern** | ~22k | Python | ⛔ **AGPL-3.0** ◦-PRIMARY | **design only** | **Planner/Actor/Validator** loop (Validator confirms success + triggers replanning) — same shape as Cascade's no-effect/stall guards. Concept only (copyleft) |
| **OSWorld** | 3k | Python | ✅ **Apache-2.0** ◦-PRIMARY | eval harness | The standard GUI-agent benchmark (real virtualized envs). ⚠️ macOS hosts can't KVM → needs VMware. Borrow as a **scoring/eval** harness, not agent code |

**Takeaway:** the unanimous architectural signal is **split grounding out of the reasoning model**
(Agent-S, cua, UI-TARS) — which is precisely Cascade's CU-downgrade thesis ("grounding, not
reasoning, is the bottleneck"). The concrete asset is **UI-TARS-1.5-7B** (Apache-2.0, open weights,
SOTA grounding, runs locally) as the eventual grounding engine *under* the Anthropic planner — the
structural way to downgrade without a weaker brain (honoring "agent stays on Opus" for *reasoning*).
cua's **Cua-Bench** is the ready-made eval harness to measure any such change.

---

## Stage 4b — background / browser sandbox agents

| Repo | ★ | Stack | License | Port type | Steal |
|---|---|---|---|---|---|
| **browser-use** | ~100k | Python / Playwright | ✅ **MIT** ◦-PRIMARY | design | **Indexed interactive-DOM**: agent clicks an element **by index** ("click 5"), not pixel coords; DOM+vision hybrid; v0.13 added a Rust core + **recovery loops** that correct failed interactions — the adaptive web-replay pattern |
| **Stagehand** | 23.2k | TypeScript | ✅ **MIT** ◦-PRIMARY | design | act/extract/agent primitives + **cache-then-heal** (see Stage 3); v3 is CDP-native (dropped Playwright, claims +44% perf) |
| **LaVague** | — | Python | ✅ **Apache-2.0** ◦-PRIMARY | **skip — stalled** | World-Model + Action-Engine "Large Action Model" pattern, but **no real commits since Jan 2025** — don't depend on it |

**Takeaway:** Cascade's background web agent is **already goal-driven/adaptive** (the handoff
confirms this). browser-use's **click-by-index** and Stagehand's **cache-then-heal** are refinements,
not rebuilds — and Stagehand's caching pattern is the same one recommended for Stage 3 on-screen.

---

## License landmines — flagged clearly

| Repo | License | Status |
|---|---|---|
| **screenpipe** | Source-available "Screenpipe Commercial License" (was MIT) | ⛔ design-only — commercial use needs paid license |
| **OpenRecall** | AGPL-3.0 | ⛔ design-only — copyleft |
| **Skyvern** | AGPL-3.0 | ⛔ design-only — copyleft |
| **AgentRR** | **unverified** | ⚠️ confirm before porting code (pattern safe regardless) |
| OpenAdapt, rem, cua, browser-use, Stagehand | MIT | ✅ port-friendly |
| Pensieve, Agent-S, UI-TARS, self-operating-computer, OSWorld, LaVague | Apache-2.0 | ✅ port-friendly |

---

## Recommendation → back to the open decision (changes (a) and (b))

The handoff (`docs/HANDOFF.md`) framed two changes. The research sharpens both:

- **(a) Feed OCR context into curation** [SMALL, SAFE, do first] — *unchanged recommendation: do it.*
  Nothing in the research argues against it; content-aware goals help both agent types. This is the
  cheap structural win.

- **(b) Make on-screen replay adaptive** [the real build] — the research **reframes** this. Don't
  pose it as the binary "literal `runAgentRecipe` *vs.* full `runAssistTask(goal)`" (which trades
  away replay's speed/determinism/zero-LLM-cost). Instead port the **OpenAdapt + AgentRR + Stagehand**
  hybrid:
  1. Generalize each recorded step from a pixel to an **element description** (OpenAdapt
     `VisualReplayStrategy`) — reusing Cascade's `AXElementResolver` / `ElementLocator` / OCR harvest.
  2. **Replay deterministically while the screen matches** the recording fingerprint; **re-ground via
     the element description (or vision loop) only on drift**, then re-cache (Stagehand cache-then-heal).
  3. Gate every adaptive step with **AgentRR-style check-functions** — the STRUCTURAL validator layer,
     a generalization of the no-effect detection already shipped.

  This is faster than full goal-driven, more robust than literal replay, **structural not advisory**
  (honoring the 3×-proven law), and sets up the eventual **UI-TARS grounding downgrade** without
  weakening the reasoning model.

**Suggested order:** (a) now → prototype OpenAdapt-style element-description re-grounding behind the
existing drift-pause in `runAgentRecipe` (so it's a fallback, not a rewrite) → add check-function
gating → evaluate with a cua-Bench-style harness before flipping it on by default.

---

## Provenance / caveats

- Source: workflow `wf_cb3b405b-627`, journal at
  `~/.claude/projects/-Users-mohanadbahammam-Desktop-Cascade/123f9102-2d72-4edb-aa13-0421bed30acd/subagents/workflows/wf_cb3b405b-627/journal.jsonl`.
- 20 sources fetched, **all rated primary-source** by the fetch agents. The 3-vote adversarial
  verify pass completed only for the **Stage-1/2 recorder** claims (rem, screenpipe, Pensieve — all
  ✅-VERIFIED high-confidence, including the **rem-semantic-search-is-roadmap** refutation) before the
  run was interrupted. Stage 3/4 claims are ◦-PRIMARY (from the repos' own READMEs/LICENSE/docs) —
  reliable, but **re-confirm any license before porting actual code**.
- Star counts / dates are as of the run (2026-06-22) and drift over time.
