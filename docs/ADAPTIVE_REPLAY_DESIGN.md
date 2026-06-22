# Change (b) — Adaptive On-Screen Replay: combined-engine design (2026-06-22)

How to make a deployed on-screen agent "understand context and adapt, not blindly replay
recorded clicks." Built from two parallel deep-research sweeps (OpenAdapt internals + a
broad hunt for better/different OSS angles) grounded against Cascade's **actual** replay code.
Companion to `docs/RESEARCH_FINDINGS.md` (the per-stage repo shortlist) and `docs/HANDOFF.md`.

---

## 0. The correction that reframes everything

The handoff called `runAgentRecipe` (`CascadeAppModel.swift:2459`) "LITERAL recipe replay."
**It is not.** Reading the code, on-screen replay already does, per click:

1. **Modal pause** — `unexpectedModal()` hands control back if a dialog the recording never saw is up.
2. **A 3-tier re-grounding cascade** (`:2505`):
   - **Tier 1 `ax`** — `resolveByAX` → `AXElementResolver.find(label:near:)`: re-find the element by its
     recorded label in the **live** AX tree (role-aware fuzzy match + nearest-point tiebreak + score).
   - **Tier 2 `vision`** — `regroundedTarget` → `ElementLocator.guide` (Claude vision): "Where is `<anchor>`?"
   - **Tier 3 `recorded`** — fall back to the recorded pixel.
3. **Verification gate** — `uiFingerprint()` (AX frontmost signature) before/after; if the click changed
   nothing, one corrective retry at the recorded coord, then count it unverified.
4. **Escalate on drift** — after **2** consecutive unverified clicks, `escalateRecipeToAssist` hands off to
   the goal-driven vision loop (`runAssistTask`).
5. **`axUnreliable` skip** for canvas apps (Blender) — skip the AX tier + verification; physical-key typing path.

So Cascade already sits at **Tier 2–3 of the re-grounding spectrum** (AX semantic match + vision fallback +
verification + escalate). That also dissolves the handoff's binary ("literal replay *vs.* full goal-driven"):
the **Stagehand cache-then-heal shape is already the architecture** — deterministic replay, escalate to the
LLM only on drift. Change (b) is to **deepen this cascade**, not replace it.

---

## 1. The re-grounding spectrum (brittle→robust, cheap→expensive) and where Cascade sits

| # | Approach | Cost | Cascade today |
|---|---|---|---|
| 1 | Pixel replay (OpenAdapt `NaiveReplayStrategy`) | free | — (never the only tier) |
| 2 | **AX-tree semantic match** (XCUIAutomation, AXorcist) | cheap, no model | ✅ Tier 1 (single-label) |
| 3 | Structural heal vs last-good tree (Healenium) | cheap, no model | ❌ **gap** |
| 4 | Description→coords via VLM per action (OpenAdapt `Visual`, OmniParser, SoM) | the *freeze* | ✅ Tier 2 (Claude/elem) |
| 5 | Full goal-driven VLM agent (Anthropic CU) | slowest | ✅ escalation target |
| 6 | Learned-skill / parameterized-workflow abstraction (AWM, Voyager) | offline + cheap online | ❌ **gap** |

**The leverage insight:** Cascade holds the **macOS AX tree at both record and replay**. OpenAdapt spends a
**SAM segment + a multi-image VLM describe pass _per action_** to approximate from pixels what Cascade can read
nearly free from AX. So the right primary lane is a **richer AX cascade** (rows 2–3), keeping the expensive
vision lane (row 4) for the genuine AX-blind cases (canvas/Electron) where Cascade already flags `axUnreliable`.

---

## 2. What to steal, per engine (all license-checked — port MIT/Apache/BSD only)

| Engine | License | Port type | The one idea to steal |
|---|---|---|---|
| **OpenAdapt** `VisualReplayStrategy` | MIT ✅ | design (Python→Swift) | record click → hit-test to a screen **segment** → store its NL description → re-segment changed screen → re-match description→centroid. **The AX-blind fallback** (FastSAM is the one hard dep → CoreML-FastSAM or Apple Vision). |
| **Apple XCUIAutomation** (WWDC25 #344) | Apple framework (design) | design | ⭐ **keystone:** record a **ranked tuple of coordinate-free locators** per click (AXIdentifier → label → type → structural), try in order at replay, first unique hit wins. Generalizes Cascade's single-label Tier 1. |
| **AXorcist** | MIT ✅ | **code (Swift!)** | `ElementSearch` ranked/fuzzy AX matching (role/title/identifier, regex, hierarchy hints). Drop-in upgrade for `AXElementResolver`. |
| **MacosUseSDK** | MIT ✅ | code (Swift) | clean AX-tree→structured-elements dump; `fazm` adds incremental element caching across turns. |
| **ROBULA+** (Leotta 2016) | reimpl from paper | design | synthesize the **shortest AX predicate that is unique** (`role=button ∧ title="Send"`, not `win>grp[3]>btn[2]`); blacklist volatile attributes. Pure, testable; feeds the cascade's middle tiers. |
| **Healenium** | Apache-2.0 ✅ | design | heal by **weighted-LCS tree-diff vs stored last-good subtree**, scored + thresholded, **zero model call**. The missing cheap lane before vision. |
| **AgentRR** | ⚠️ verify | design | **check-functions** (preconditions/invariants verified before proceeding) — generalizes Cascade's no-effect gate. + multi-level "experience" abstraction for changed screens. |
| **Stagehand** | MIT ✅ | design | cache the resolved locator; on miss re-ground, then **write the heal back into the recipe** → one-time grounding, not per-run. |
| **Agent-E** | MIT ✅ | design | (1) stamp every AX element a stable id, act by id; (2) **"change observation"** = diff the AX **subtree** before/after → NL consequence ("a popup appeared with…"), immune to cursor/animation churn. Upgrades `uiChanged` from a bool. |
| **JARVIS-1** | ⛔ no license (design) | design | **state-similarity GATE before replay** — embed live vs recorded start state; on mismatch (wrong window/version/modal) **re-plan instead of blind-replaying**. |
| **AWM** | Apache-2.0 ✅ | design | induce a **parameterized workflow** (values → `{placeholders}`) from the demo; self-bootstraps from successful runs. The principled `AgentRecipe`+skill-distill. |
| **Voyager / OS-Copilot** | MIT ✅ | design | **verification-gated skill persistence** (critic confirms before a skill enters the library; OS-Copilot's numeric >8 gate is cleaner than a binary critic). |
| **SUGILITE / APPINITE** | ⛔ unlicensed (design) | design | record a **data-description predicate** ("the row whose status=Overdue") evaluated against the live AX tree → generalizes across **different data**, not just moved buttons. |
| **GUI-Actor-3B / UGround-2B / OS-Atlas** | MIT/Apache ✅ | model (MLX) | on-device grounder (description→coords) via cua's grounder/thinker split + MLX-VLM — the **CU-downgrade lane** for AX-blind apps, replacing Claude-vision Tier 2. |
| **SikuliX / Airtest** | MIT / Apache ✅ | design | deterministic no-model fallback for AX-blind apps: **anchor-relative regions** (SikuliX) + **feature-point (SIFT) matching** (Airtest, Retina-scale-invariant). |

**Code-level avoid (license):** Skyvern (AGPL), OmniParser `icon_detect` weights (AGPL), SeeAct (RAIL),
Synapse/JARVIS-1/ICAL/SUGILITE (no/NC license), CogAgent/Ferret-UI weights (restricted), atomacos (GPL),
screenpipe (commercial). Ideas only — copy zero lines.

---

## 3. The combined engine — one layered re-grounding ladder

Not one engine: a ladder, each rung cheaper than the next, Cascade already owns rungs 2/4/5/6.

```
PER RECIPE, before first click:
  0. STATE GATE (JARVIS-1)         ── live app/window/AX-signature ≈ recording's start?
                                       mismatch → escalate to assist (don't blind-replay)   [NEW, cheap]
PER CLICK:
  1. MODAL PAUSE                   ── unexpectedModal()                                      [HAVE]
  2. RANKED AX LOCATOR             ── AXIdentifier → role+title → ROBULA+ unique-predicate
       (XCUIAutomation/AXorcist/ROBULA+)  → nearest-point tiebreak    [HAVE single-label → UPGRADE to ranked]
  3. STRUCTURAL HEAL               ── weighted-LCS live AX tree vs stored subtree, scored    [NEW, zero-model]
       (Healenium)                       accept > threshold
  4. VISION GROUNDING              ── AX-blind apps only: OpenAdapt-segment / on-device MLX
       (OpenAdapt / GUI-Actor / Claude)  grounder / Claude "where is X"        [HAVE Claude → ADD on-device]
  5. RECORDED PIXEL                ── last resort                                            [HAVE]
  6. VERIFY (check-function)       ── AX-subtree diff before/after → NL consequence
       (AgentRR / Agent-E)               [HAVE pixel/AX bool → ENRICH to NL diff]
  7. WRITE-BACK (Stagehand)        ── cache the healed locator into the recipe              [NEW, plumbing exists: retargeted()]
  8. ESCALATE on repeated miss     ── escalateRecipeToAssist → runAssistTask (goal-driven)  [HAVE]
LONGER TERM (semantic):
  9. PARAMETERIZED WORKFLOW + DATA PREDICATES (AWM + SUGILITE/APPINITE), verification-gated
       skill memory (Voyager/OS-Copilot)  → "reply to EACH refund email", "click the Overdue row"  [NEW, big]
```

Everything is **STRUCTURAL** (runtime-applied), honoring the 3×-proven law that advisory
scaffolding the model must choose to use gets ignored. The model is never asked to pick a locator;
the runtime walks the ladder.

---

## 4. Phased plan (leverage ÷ effort)

- **B1 — Ranked AX locator [do first; small, pure, testable, no new deps].** Capture a richer descriptor at
  record time than the bare label (role + title + AXIdentifier + a couple ancestor role/titles + value) into
  the `RecipeStep`; extend `AXElementResolver.find` to rank by that tuple (AXIdentifier → role+title → fuzzy →
  ROBULA+ unique-predicate → nearest tiebreak). Port matching from **AXorcist (MIT, Swift)**; reimplement
  ROBULA+ from the paper. Pinned tests (à la `modelPixel`/`groundingControls`). Directly hardens Tier 1, the
  hottest path. *Touches: InputRecorder descriptor capture, RecipeStep schema, AXElementResolver.*
- **B2 — Zero-model structural heal [Healenium].** Snapshot the small AX subtree around the clicked element at
  record; weighted-LCS heal at replay between Tier 1 and the Claude-vision Tier 2. Cuts model-vision calls (the freeze).
- **B3 — Pre-replay state gate [JARVIS-1].** Cheap app/window/AX-signature check before the first click →
  escalate immediately on the wrong screen instead of after 2 dead clicks. Reuses `uiFingerprint`.
- **B4 — On-device grounder for AX-blind apps [CU-downgrade lane].** MLX GUI-Actor-3B / UGround-2B / OS-Atlas
  replacing Claude-vision Tier 2 for canvas/Electron. Intersects the model-downgrade roadmap. Needs MLX
  integration + eval (cua-Bench-style). Bigger; defer.
- **B5 — Parameterized workflows + data predicates [AWM + SUGILITE/APPINITE], verification-gated skills.**
  The semantic differentiator OpenAdapt lacks; route through the goal-driven assist loop + curation
  (change (a) already feeds content there). Research-grade; defer.
- **Cross-cutting — Agent-E NL change-observation** (enrich the verify gate) + **Stagehand write-back**
  (fold into B1/B2).

**Recommendation:** start with **B1** — it's the highest leverage-to-effort, pure/testable, no new
dependencies, hardens the path the agent uses most, and is a strict superset of today's behaviour (single
label is just the lowest rung of the ranked tuple, so nothing regresses). B2 and B3 are natural follow-ons.
B4/B5 are their own projects, decided separately.

## 5. Done-when
A deployed on-screen agent re-finds a moved/renamed control without a model call (B1/B2), bails fast on the
wrong screen (B3), and falls back to vision/goal-driven only when AX genuinely can't see the target — keeping
replay's speed/determinism while gaining real adaptivity. Verified with a recorded recipe replayed after the
target UI is deliberately changed (button moved, relabeled, window resized).
