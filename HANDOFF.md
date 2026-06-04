# Cascade — Session Handoff (2026-05-31)

Pick-up doc for continuing in a fresh session. Cascade = privacy-respecting
enterprise AI-agent product, soft-forked from screenpipe (`mediar-ai/screenpipe`).

---

## 0. READ THIS FIRST — state of the tree

- **Nothing from this session is committed.** Git HEAD is still `7f4f212`
  ("isolated agent browser sandbox + persistent login"). The ENTIRE session's
  work (Rewind-based detection, two-engine execution, dynamic target URL,
  contextual login, all bug fixes) lives in the **uncommitted working tree**.
  Run `git diff` to see it. **Commit early** if you want to preserve it.
- **Source of truth = `app-overlays/screenpipe-app-tauri/`.** It is rsync'd into
  the vendored submodule with `bash scripts/overlay.sh` (no `--delete`).
  - EXCEPTION: `vendor/.../src-tauri/src/main.rs` is edited **directly in the
    submodule** (not in app-overlays) — it's the command registry. Don't lose it.
- **Installed app** (`/Applications/Cascade.app`) is the **18:47 build**
  (dynamic-URL + visible-browser + 5 fixes). The **latest** build (adds the
  click/coordinate/prompt fixes) finished compiling but was **NOT installed**
  (install was interrupted). To install the latest, see §5.

## 1. Build / install (toolchain on this Mac)

`cargo` is NOT on the default PATH. Prepend the toolchain bin:
```
export PATH="/Users/mohanadbahammam/.rustup/toolchains/stable-aarch64-apple-darwin/bin:/opt/homebrew/bin:$PATH"
```
- Sync overlay → vendor:  `bash scripts/overlay.sh`
- Compile-check (fast):   `cd vendor/screenpipe/apps/screenpipe-app-tauri/src-tauri && cargo check`
- Type-check FE:          `cd vendor/screenpipe/apps/screenpipe-app-tauri && bunx tsc --noEmit`
- Build (~10 min, debug): `cd vendor/screenpipe/apps/screenpipe-app-tauri && bun run tauri build --debug --bundles app`
  (release build needs Xcode/cidre and ~30 min — use `--debug`.)
- Install:
```
SRC=vendor/screenpipe/apps/screenpipe-app-tauri/src-tauri/target/debug/bundle/macos/Cascade.app
osascript -e 'tell application "Cascade" to quit'; pkill -f "Cascade.app/Contents/MacOS/screenpipe-app"
rm -rf /Applications/Cascade.app && cp -R "$SRC" /Applications/Cascade.app && xattr -dr com.apple.quarantine /Applications/Cascade.app
```
- bun sidecars are pre-placed (`src-tauri/bun-{aarch64,x86_64}-apple-darwin`) so the build doesn't stall on download.

## 2. Product architecture (current, post-pivot)

Full detail in memory: `~/.claude/projects/-Users-mohanadbahammam-Desktop-Cascade/memory/cascade-agent-execution-architecture.md`.

**The 5-agent pipeline** (cascade_agents.rs): #5 Privacy Aggregator → #2 Waste
Detector → #3 Agent Generator → #4 Deploy/Runtime Monitor. UI: Reel · Cascades ·
Manager · Settings (cascade-titlebar nav).

**Detection reads the REWIND, not app-minute aggregates** (user was emphatic).
`fetch_rewind_digest(app, hours, max)` hits screenpipe `/search?content_type=ocr`
→ window titles + OCR of what's actually on screen, sensitive apps dropped. The
detector (`cascade_generate_manager_suggestions`) and the recap runtime both read
this. (This is why "D2L Coursework Digest" got detected correctly.)

**Two execution engines, two buttons:**
- **Run now** → `run_agent_internal` (HEADLESS). Produces a recap grounded in the
  Rewind, delivers into the app the user actually uses via `resolve_delivery_target`
  (Obsidian if running+vault found → vault file; else Apple Notes via AppleScript;
  file fallback). Box shows a result card (`box_result` → `cascade-hands-result` event).
- **Start & watch** → `cascade_start_computer_task` (BROWSER SANDBOX computer-use,
  cascade_computer.rs). A **visible** WKWebView the agent drives via a Claude
  vision loop (screenshot → `computer_system_prompt` → `ComputerAction` →
  `browser_execute` JS injection), streamed into the floating box with a cursor.
  **Web apps only.**

**Dynamic target site (NOT hardcoded):** `cascade_agents::rewind_primary_url(app,
hours, task)` picks the site the user actually uses for this work by counting
hosts in the Rewind's `browser_url`s (drops google/newtab/localhost/sensitive),
biased toward a host matching a task keyword. Stored per-agent in `START_URLS`;
the run loop opens the agent browser there. Old hardcoded `login_target_for_goal`
table is GONE.

**Contextual login (user's explicit design):** NOT a Settings section. On Start,
`maybe_prompt_login_url` pops the resolved site's sign-in (first time per host,
tracked in `LOGGED_IN`). `run_loop` shows "Waiting for you to sign in…" and blocks
until the `cascade-agent-login` window closes, then works. Shared WKWebView cookie
store persists the session for the agent browser.

## 3. What works (verified by the user)

- Rewind-based detection → produced "D2L Coursework Digest" from real D2L usage. ✅
- Floating box capture/streaming — "working perfectly." ✅
- Visible agent browser navigates INTO the target site (D2L Assignments page seen). ✅
- App scroll fixed (globals.css forced `html,body{overflow:hidden}`; cascade view
  roots now `height:100vh; overflowY:auto`, titlebar `position:sticky`). ✅
- Detector/generator no longer crash on `null` JSON (`de_null_string`/`de_null_f64`). ✅
- Uninstall/Pause now stop the running computer task. ✅

## 4. THE OPEN PROBLEM (start here next session)

**A read-from-web agent gathers info but has nowhere to WRITE its result.**
"D2L Coursework Digest" navigates D2L and reads assignments, but D2L is not a doc
tool — the digest has nowhere to land. This is the #1 design question.

Options (an audit workflow was mid-flight on exactly this when the session ended):
1. Surface the gathered digest in the floating box as the run's result card
   (`box_result` already exists, emitted on `cascade-hands-result`).
2. Hand the gathered text to the HEADLESS engine to write into Apple Notes /
   Obsidian (`resolve_delivery_target` already exists in cascade_agents.rs).
3. Both.
Recommended: add a "record/note" action the vision agent can emit to accumulate
findings, and on `done` either show it in the box AND/OR write it via the headless
delivery path. Decide + wire this.

**Also fix next (computer-use reliability — the audit lenses):**
- Interaction reliability on SPAs: `browser_execute` typing into React/controlled
  inputs (needs native value setter + input event), iframes (D2L embeds a lot —
  `elementFromPoint` can't see into cross-origin iframes), no wait-for-navigation
  between actions.
- Stuck/loop detection in `run_task_cycle`: nothing detects "screen didn't change
  after my action" → repeats/oscillation; `MAX_STEPS=24`; weak history feedback.
- Resilience: blank/failed captures looping silently, vision JSON parse failure
  aborting the run, login-window race, stale `START_URLS`.

## 5. Latest fixes BUILT but NOT yet installed

Source already has them (synced + compiled in the last `--debug` build). To install
the latest, just `cp` the bundle (see §1). These three fixes target "agent didn't
do the work, went back to D2L":
- `ensure_agent_browser`: `decorations(false)` — a title bar shifted the screenshot
  ~28px so every click missed; now capture is 1:1 with `document.elementFromPoint`.
- `browser_execute` click: dispatches real `mouseover/mousedown/mouseup/click` on the
  nearest clickable ancestor (was a bare `el.click()` that misses on SPAs).
- `computer_system_prompt`: rewritten — "you're already on the right site + signed
  in, work WITHIN it, don't bounce to the home page." Removed Notion/Gmail nudges.

## 6. Key files

- `app-overlays/.../src-tauri/src/cascade_agents.rs` — pipeline, Rewind
  (`fetch_rewind_digest`, `fetch_rewind_frames`, `rewind_primary_url`,
  `host_from_url`), headless runtime (`run_agent_internal`), delivery
  (`resolve_delivery_target`, `apple_notes_create`, `obsidian_write`), Notion-null
  tolerant parse structs (`de_null_string`/`de_null_f64`).
- `app-overlays/.../src-tauri/src/cascade_computer.rs` — browser sandbox: vision
  loop (`run_task_cycle`/`run_loop`), `ensure_agent_browser` (VISIBLE @48,96),
  `capture_browser`, `browser_execute`, `computer_system_prompt`, `START_URLS`,
  `maybe_prompt_login_url`/`open_login_window`, `box_begin/step/result/end`.
- `app-overlays/.../app/hands-box/page.tsx` — the floating box (frame + cursor +
  result card listening on `cascade-hands-result`).
- `app-overlays/.../components/cascade-cascades-view.tsx` — Cascades inbox
  (Start & watch / Run now / Uninstall→stopComputerTask).
- `app-overlays/.../app/settings/page.tsx` — Settings (Claude key, "How your agents
  work" note; no login section — login is contextual now).
- `vendor/.../src-tauri/src/main.rs` — command registry (edited direct in submodule).

## 7. Phase 2 (acknowledged, not built)

Cloud VM "real sandbox screen" for native apps (Obsidian/Apple Notes inside the
sandbox) — needs real infra (VM provider, streaming, billing). The local browser
sandbox uses the same control loop and is the swap point.

## 8. User working style (from this session)

Tests live and reports specific bugs with screenshots — iterate from runtime
behavior, not static assumptions. Dislikes over-engineering / building 3 things at
once; wants the ONE right thing, testable. Wants dynamic behavior derived from the
Rewind, never hardcoded per app. Build + install + report back each iteration.
Ultracode is ON (xhigh + workflow orchestration).
