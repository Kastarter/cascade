# SEQ Validation Walk — Handoff

Validate the 31-SEQ "harden" pass **one SEQ at a time**, on top of the pre-SEQ
baseline, keeping only what works and fixing what's broken — so we end with a
tested product. Senior-engineer plan: one **isolated PR per SEQ** so any failure
is attributable to that SEQ and nothing else. Tested **live** (build + install +
manual + audit log), never by `swift build` alone. See [[cascade-verify-by-running]].

## Topology / base
```
origin/main (5d3851b)
  └─ 99 pre-SEQ commits           ← ONE shared foundation (the "it worked perfectly" state)
       └─ validate/base (0bf61d2)  ← the base every SEQ PR stacks on
            └─ 31 SEQ commits (seq-01 … seq-31)
```
- The 99 pre-SEQ commits are **not sliceable per-SEQ** — seq-01 alone needs 38 of
  them, overlapping what every other SEQ needs (`CascadeAppModel.swift` touched by
  23 of them). They're the untested-but-required floor; we test only the SEQ deltas.
- Bare `main` won't work as a base: a lone SEQ cherry-picked onto `main` conflicts
  (git-proven) because it depends on those 99.

## Order (chronological, NOT numeric)
`01,02,03,04,06,07,08,09,10,11,12,`**`05`**`,13,14,15…31` — **seq-05 was a late redo
committed after seq-12** and depends on 06–12 (5-file cherry-pick conflict proves it).
So the strict-tools 400 lands at seq-05's real position (06–12 add tools → seq-05
marks them strict → 22 > Anthropic's 20-strict cap → 400).

## Per-SEQ mechanics
- Branch `validate/seq-NN`. Up to seq-07 = `git branch` at the SEQ commit (clean
  stack). **After seq-07 got fix commits, subsequent SEQs CHERRY-PICK** their commit
  onto the fixed prior branch so fixes carry forward.
- PR base = the prior approved `validate/seq-*` → PR diff = exactly this SEQ.
- Build in a throwaway worktree `/tmp/wt-seqNN`: `swift build` **twice** (retry — see
  seq-02 finding), `./scripts/build-app.sh`, then re-sign with the
  **`Cascade Local Signing`** cert (`security unlock-keychain -p cascade cascade-signing.keychain`)
  so TCC grants persist.
- Install: quit app, **RESET the DB** (`mv ~/Library/Application Support/Cascade/Cascade.sqlite* aside`)
  — schema changes across SEQs, an older build against a newer DB fails inserts —
  then `ditto` to `/Applications`, `open`.
- Verify: recording advances (`recorded_context` MAX(id) climbs), then a manual test
  of the SEQ's deliverable + the `audit_event` table / `/usr/bin/log show --process Cascade`.

## Verdicts
| SEQ | PR | Verdict |
|-----|----|---------|
| 01 recording-storage | #45 | **APPROVED** — click markers on Reel frames work. Choppy scrub = by-design 1fps snapshots, not a bug. |
| 02 computer-use-agents | #46 | **APPROVED** — agent flawless (open_app + type verified, 3 turns, 0×400). Clean agent baseline (20 tools = right at the cap). |
| 03 gui-grounding | #47 | **APPROVED** — text highlight works; agent *click* grounding failed pervasively (73× `grounding.verifier reject` conf 0.38) — no visual grounder yet. Confirmed fixed by seq-21's visual grounder (ui-tars/OpenRouter, default-on) via a detour test. Gap = "expected until seq-21." |
| 04 semantic-retrieval-memory | #48 | **APPROVED** — Reel ask/search "perfect." |
| 06 reliability-eval | #49 | **APPROVED** — regression-only (thin surface). |
| 07 privacy-security | #50 | **APPROVED WITH FIX** (5 commits) — see below. |
| 08 workflow-mining | #51 | **APPROVED w/ TODO** — didn't detect a real repeated workflow (crypto copy-paste); records + separates browser surfaces, but needs category/param-aware clustering. See fix note below (also a `TODO` in `WasteDetector.detect`). |
| 09 macos-automation | #52 | **APPROVED** — agent types "hello" verified, no crash; secure-input refusal works (refused typing into a password field). Confirmed the keyboard crash is NOT born here (it's latent, exposed later). |
| 10 market-productization | #53 | **APPROVED (dormant)** — adds enterprise-compliance surface (SIEM audit export, SLO/cost cards, privacy outbox, DLP rule counts). Data-driven → shows defaults without real fleet/run history. Additive, low-risk; validate with real data later. |
| 11 on-device-inference | #54 | **APPROVED W/ FIX** — landed as `LocalRegionNarrower` (local AX/OCR region narrowing for grounding); real payoff needs seq-21's visual grounder. Its `async` grounding **exposed the keyboard crash** → fixed (see below). |
| 12 prompt-injection-defense | #55 | **UNDER TEST** — InjectionGuard + provenance/injection scoring + untrusted-content confirmation. |

### seq-02 finding (logged, not blocking)
Adds `import ComputerUseKit` to `Sources/SandboxKit/BackgroundWebAgent.swift` but never
declares `ComputerUseKit` in SandboxKit's `Package.swift` deps → intermittent
`no such module 'ComputerUseKit'` on cold/parallel builds (a retry succeeds). Worth a
one-line Package.swift fix.

### seq-03 finding (separate from grounding)
Multi-step task terminated after step 1: "open System Settings **and** click Privacy &
Security" opened Settings then passed the subgoal with **0 clicks** — the verifier's
success check was only "app frontmost." Planning/verifier issue → **watch at seq-13
(hierarchical-planning)**.

### seq-07 fix (private mode)
BUG (born at seq-07): private mode = `decision() → .deny("private_mode")` for **every**
capture → froze ALL recording. Fixed across 5 commits so private mode **keeps recording
and redacts only sensitive content**:
1. `CapturePrivacyPolicy.decision` no longer denies-all in private mode.
2. Removed the two `MacContextKit` pause-gates (`updateCapturePolicy` pause + `start()` guard).
3. Private mode keeps sensitive frames (doesn't drop them) — redact, don't drop.
4. Redact only sensitive boxes (not blur-everything).
5. **Line-level redaction** + expanded credential labels (`api key`, `secret key`,
   `ssn`, …) so a label's value in an adjacent OCR box (`Password:` / `102010203*2`)
   gets covered too. Also improves normal-mode redaction.
DEFERRED: redaction still leaky on some OCR splits — hardening later.

### KEYBOARD CRASH FIX (seq-09 root / seq-11 exposure) — the big one
This is the crash that made the agent "do nothing / crash" on HEAD. Signature:
`_dispatch_assert_queue_fail` ← `HIToolbox TSMGetInputSourceProperty` ←
`KeyboardLayoutMapper.currentLayoutMapping` ← `NativeComputerUseActuator.pressKey`.
`TISCopyCurrentKeyboardLayoutInputSource`/`TISGetInputSourceProperty` (Carbon) **assert
they run on the MAIN thread**; the actuation path runs them off-main → SIGTRAP on the
first typed key. Latent in **seq-09**'s `KeyboardLayoutMapper` (`Sources/ComputerUseKit/InputSafety.swift`);
**seq-11** made grounding `async`, which pushed actuation off-main and triggered it every run.
FIX (committed on `validate/seq-11`, carries forward): `currentLayoutMapping` hops to the
main thread (`DispatchQueue.main.sync`) before the Carbon calls. Verified live: agent
typed "hello" verified, 0 crash reports, 0 `dispatch_assert`/`KeyboardLayout` log lines.
**Typing should stay crash-free for the rest of the walk.**

## seq-08 FIX NOTE (requested)
**We want to fix the miner so a workflow of the SAME ACTIONS with DIFFERENT DATA is
still recognized as one repeated routine — especially when the items fall under the
same CATEGORY.** Concrete case that produced *nothing*: copying **ETH, SOL, BTC, LTC**
prices from Google into Notion (×4). Today the miner needs near-identical token
sequences, so 4 different coins/prices/click-positions (buried in ~1235 scroll events)
don't cluster. It should:
- **Parameterize the varying value** (the coin name / price) and match on
  **action-structure** ("search a term → copy the result → paste into Notion"),
  not the literal tokens.
- **Cluster by category** — recognize ETH/SOL/BTC/LTC as instances of one "Crypto
  price → Notion" routine → **one agent candidate** worth deploying.
So four crypto copies become a single repeatable agent, not four unrelated variants.
(Records fine + distinguishes Google vs Notion browser "surfaces" already — the gap is
the generalization/clustering step.)

## Next
- **seq-12 prompt-injection-defense** — currently under test (#55). InjectionGuard +
  provenance/injection scoring + confirmation on untrusted screen/web/file content.
- Then **seq-05 (the strict-tools 400 — expect the agent to break; HEAD fix caps strict
  tools at 20)** → **seq-13** (multi-step/planning — watch the "terminates after step 1"
  issue from the seq-03 finding) → 14 … 31.
- The keyboard crash (the agent's biggest blocker) is already FIXED and carried forward,
  so from here the agent should type without crashing.

## Deferred / known
- seq-07 redaction hardening (OCR-split secrets).
- seq-08 category/param-aware mining (the note above).
- Pre-existing: role-column DB migration bug; WasteDetection/curation test failures +
  an Index-out-of-range crash.

## State pointers
- Branches: `validate/base`, `validate/seq-01 … seq-12` (pushed to origin). PRs #45–#55.
- Worktrees: `/tmp/wt-seqNN` (throwaway; recreate with `git worktree add`).
- Fixed prior for cherry-pick = `validate/seq-12` (current tip of approved work; seq-12
  under test). Fix commits so far live on validate/seq-07 (private mode ×5) and
  validate/seq-11 (keyboard crash) and carry forward via cherry-pick.
- Signing cert keychain: `cascade-signing.keychain` (pw `cascade`).
