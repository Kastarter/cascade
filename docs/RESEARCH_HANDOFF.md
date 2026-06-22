# Research Handoff — "steal the best engine per pipeline stage" (2026-06-22)

For the next Claude continuing the **deep-research** thread. The goal was to survey
high-star open-source repos that overlap Cascade's pipeline and identify the single
best "wedge/engine" to harvest from each, then combine into one engine.

## Status at handoff
A **deep-research workflow is running in the background** (launched this session).

| Field | Value |
|---|---|
| Run ID | `wf_cb3b405b-627` |
| Task ID | `w2zz6lrg5` |
| Transcript dir | `~/.claude/projects/-Users-mohanadbahammam-Desktop-Cascade/123f9102-2d72-4edb-aa13-0421bed30acd/subagents/workflows/wf_cb3b405b-627` |
| Script file | `~/.claude/projects/-Users-mohanadbahammam-Desktop-Cascade/123f9102-2d72-4edb-aa13-0421bed30acd/workflows/scripts/deep-research-wf_cb3b405b-627.js` |
| Phases | scope → 5 parallel WebSearch → fetch ~15 sources → 3-vote adversarial verify → synthesize cited report |

### How to get the result
1. **Watch / check status:** `/workflows`, or `TaskGet`/`TaskOutput` on task `w2zz6lrg5`.
2. **If it finished in THIS session:** the synthesized report is the workflow's final output — capture it and **save to `docs/RESEARCH_FINDINGS.md`** so it survives the session switch.
3. ⚠️ **If you are a DIFFERENT session:** you likely will NOT receive this run's completion notification, and the transcript above may be hard to reach. In that case **re-run it** with the exact args in the next section: `Workflow({ name: "deep-research", args: <below> })`. Same args → same research.
4. **Resume a paused/edited run (same session only):** `Workflow({ scriptPath: <script file above>, resumeFromRunId: "wf_cb3b405b-627" })` — completed agents return cached results.

## The exact research question (re-run with this verbatim)
> Goal: find open-source / high-star GitHub repos whose pipeline overlaps with a macOS "local context recorder + agent" product, so we can harvest the single best "engine" or wedge from each and combine them. Our product (Cascade): Swift-first native macOS app, on-device. Pipeline stages: (1) always-on screen recording with dedup + privacy gating; (2) OCR + Accessibility-tree text capture to "own your context" (searchable memory, Q&A, semantic recall); (3) detect repeated work from recorded user input (clicks/keys) and turn it into automatable agents; (4) deploy agents two ways — an on-screen computer-use agent (vision loop, "clicky"-style companion cursor) and a background/sandbox web agent. Brain is Anthropic computer-use.
>
> For EACH pipeline stage, find the strongest open-source projects (prioritize high stars + recent activity), including ones taking DIFFERENT approaches than ours, and for each repo report: (a) the one part/engine worth stealing and why; (b) its technical approach; (c) language/stack; (d) star count and whether it's actively maintained; (e) LICENSE (we port MIT/Apache/BSD-friendly and deliberately AVOID copyleft/BSL — flag the license clearly).
>
> Known candidates to verify and expand on (find more, don't limit to these):
> - Recorders/OCR-context: mediar-ai/screenpipe, OpenRecall/openrecall, jasonjmcghee/rem, arkohut/memos (Pensieve), Windows Recall.
> - Demonstration→adaptive automation (MOST IMPORTANT — our current architectural question is "learn from what the user did but ADAPT when the screen is different, don't blindly replay recorded clicks"): OpenAdapt (OpenAdaptAI/OpenAdapt), and any "programming by demonstration" / process-mining / RPA-with-LLM-generalization projects.
> - Computer-use / GUI agents (clicky-alike): trycua/cua, simular-ai/Agent-S, bytedance UI-TARS, OthersideAI/self-operating-computer, OpenInterpreter, Skyvern-AI/skyvern, OSWorld.
> - Background/browser agents: browser-use/browser-use, browserbase/stagehand, lavague.
>
> Deliver: (1) a per-stage ranked shortlist with the steal-worthy part + license for each; (2) a synthesized recommendation for ONE combined engine — which repo's approach to take for each of the 4 stages, what specifically to port vs. reimplement, and any license landmines to avoid; (3) special focus on the demonstration→adaptive-replay engine (how the best project generalizes a recorded demo into an intent the agent can re-execute on a changed screen), since that's the piece we're about to build.

## Why this research exists / what to do with it
It feeds an **open architectural decision** (full detail in `docs/HANDOFF.md`). Short version:
the user wants deployed agents to **understand context and adapt, not blindly replay recorded
clicks**. The on-screen deploy path today (`runAgentRecipe`, `CascadeAppModel.swift:2459`) is a
literal replay; the background/sandbox path is already goal-driven. The two candidate fixes:
- **(a)** feed OCR context into curation so the agent's *goal* is content-aware (`WorkflowCurator.userPrompt`).
- **(b)** run on-screen agents goal-first (adaptive) via `runAssistTask(goal:)` instead of literal replay.

**The research's #3 deliverable (demonstration→adaptive-replay engine) directly informs change (b)** —
how OpenAdapt-class projects turn a recorded demo into a re-executable *intent*. Read that section
first, then bring the user a recommendation on which engine's approach to port.

## Constraints to apply when reading the findings
- **License gate:** Cascade ports **MIT / Apache / BSD** only; **avoid copyleft (GPL/AGPL) and BSL**. (Precedent: `mcp-server-macos-use` is BSL → never port code from it; MacosUseSDK is MIT → OK.) Flag every recommended repo's license.
- **Code-port vs design-port:** Cascade is **Swift / on-device**; most candidates are Python (screenpipe is Rust). Expect to steal **architecture/algorithms**, not drop-in code — except clicky (already native) and trycua/cua (Swift/MLX-local pieces). Judge each repo on which it is.
- **STRUCTURAL > advisory** (CLAUDE.md lesson): whatever engine we adopt must be runtime-applied, not a tool/prompt the model chooses to use.
- Reference repos already cloned/known: clicky, openclicky, tiptour-macos, glide (see `docs/PORT_MAP.md`); trycua/cua noted in memory `cascade-cu-downgrade-research`.

## Done when
`docs/RESEARCH_FINDINGS.md` exists with: per-stage shortlist (+ license + port-type per repo), the
one combined-engine recommendation, and the demo→adaptive-replay deep-dive — then a user-facing
recommendation tying it back to changes (a)/(b).
