# Cascade — Session Handoff (2026-06-05)

## 2026-06-05 update

- The "read-from-web agent has nowhere to write" problem is now resolved in source:
  `cascade_computer.rs` supports a `record` action, builds a digest from recorded
  findings on `done`, shows it in the floating box, and writes it through
  `cascade_agents::deliver_artifact_write` to Obsidian, Apple Notes, or a file
  fallback.
- The current strategy is Screenpipe for employee context/monitoring, OpenClicky
  as the native-control reference, and Glide as product/integration reference.
  See `docs/product-strategy.md`.
- Computer-use reliability work should now focus on real SPA behavior and loop
  prevention: controlled-input typing, click targeting, same-screen/no-effect
  detection, login robustness, and clear audit/result delivery.

Pick-up doc for continuing in a fresh session. Cascade = privacy-respecting
enterprise AI-agent product, soft-forked from screenpipe (`mediar-ai/screenpipe`).

---

## 2026-06-05 session — sandbox now reuses existing browser sessions

User goal: stop making the employee log in separately inside Cascade's local
sandbox just so the agent can access the same web app the employee already uses.

### What changed

- Added sandbox session hydration in
  `app-overlays/screenpipe-app-tauri/src-tauri/src/cascade_computer.rs`.
- Synced it into the vendored app with `./scripts/overlay.sh`; overlay and vendor
  copies match.
- New flow:
  1. `run_loop` resolves the sandbox start URL from the Rewind as before.
  2. Before opening the manual login window, it calls `hydrate_sandbox_session`.
  3. `hydrate_sandbox_session` reads matching cookies from the user's supported
     real browsers through the existing `owned_browser_cookies::cookies_for_host`
     path.
  4. It injects those cookies into the shared WKWebView `WKHTTPCookieStore`.
  5. If cookie injection succeeds, the host is marked signed-in for this app
     session and the sandbox starts without the separate local login.
  6. If no portable cookies exist, injection fails, or the site stores auth in
     localStorage/IndexedDB/passkeys/WebAuthn, the old visible login fallback
     still runs.

This does **not** read saved passwords. It only copies already-existing session
cookies into the local sandbox webview.

### Update (same day) — load-and-verify fallback (closes the step-5 gap)

The step-5 logic above marked the host signed-in after injecting **any** cookie,
so localStorage/passkey sites and **expired** sessions silently skipped the
fallback and the agent got stuck logged-out. Now the decision is based on where
the page actually LANDS, not the cookie count:

1. `hydrate_sandbox_session` injects cookies (best-effort).
2. The agent browser is opened at the start URL immediately, so it loads WITH
   those cookies. `ensure_agent_browser` got an `on_page_load` recorder
   (`AGENT_BROWSER_URL`).
3. After ~3s, `sandbox_landed_authenticated(spec_id, host)` checks the landed URL:
   on the target host AND not a login/SSO/MFA URL (`looks_like_auth_url`) → signed
   in. Otherwise → `ensure_host_login` (visible login), then `reload_agent_browser`
   to pick up the fresh session.

Verified the auth-detection heuristic in isolation (8 cases pass). Still NOT
compiled in the full app crate (cidre/Xcode). Known limit: a same-URL SPA login
(no path/host change) reads as authed — URL-only heuristic.

### Exact files touched this session

- `app-overlays/screenpipe-app-tauri/src-tauri/src/cascade_computer.rs`
- `vendor/screenpipe/apps/screenpipe-app-tauri/src-tauri/src/cascade_computer.rs`
  via `./scripts/overlay.sh`

Pre-existing dirty files remain dirty and were not reverted:

- `app-overlays/screenpipe-app-tauri/app/hands-cursor/page.tsx`
- `app-overlays/screenpipe-app-tauri/src-tauri/src/cascade_agents.rs`
- `crates/cascade-schema/src/lib.rs`
- `app-overlays/screenpipe-app-tauri/lib/cursor-flight.ts`
- `crates/cascade-schema/migrations/0005_daily_summaries.sql`
- `vendor/screenpipe` submodule dirty state

### Verification

- Ran `./scripts/overlay.sh` successfully.
- Confirmed overlay and vendor `cascade_computer.rs` match with `cmp`.
- Ran:
  `PATH="/Users/mohanadbahammam/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH" cargo test -p cascade-schema`
  Result: **7 passed**.
- Tried a focused Tauri app compile check:
  `cargo check --manifest-path vendor/screenpipe/apps/screenpipe-app-tauri/src-tauri/Cargo.toml --bin screenpipe-app`
  It did **not** reach app-level checking. It failed in native dependency `cidre`
  because the active developer directory is Command Line Tools, not full Xcode:
  `xcode-select: error: tool 'xcodebuild' requires Xcode`.
- `rustfmt` was not available in the active toolchain:
  `/Users/mohanadbahammam/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustfmt`
  missing.

### Important caveat

The implementation duplicates the macOS WK cookie injection logic locally in
`cascade_computer.rs` instead of reusing `owned_browser.rs`, because the existing
owned-browser injector is private and attached to `BrowserSidebar`/owned-browser
navigation. This was the quickest scoped fix. Later cleanup should extract a
shared helper so both owned-browser and Cascade sandbox use one cookie injection
implementation.

### Next clean steps

1. Install full Xcode or point `xcode-select` at a full Xcode install, then rerun
   the Tauri compile check.
2. Install `rustfmt` for the active toolchain, then format `cascade_computer.rs`.
3. Build and install a debug app:
   ```
   export PATH="/Users/mohanadbahammam/.rustup/toolchains/stable-aarch64-apple-darwin/bin:/opt/homebrew/bin:$PATH"
   ./scripts/overlay.sh
   cd vendor/screenpipe/apps/screenpipe-app-tauri
   bun run tauri build --debug --bundles app
   SRC=src-tauri/target/debug/bundle/macos/Cascade.app
   osascript -e 'tell application "Cascade" to quit' || true
   pkill -f "Cascade.app/Contents/MacOS/screenpipe-app" || true
   rm -rf /Applications/Cascade.app
   cp -R "$SRC" /Applications/Cascade.app
   xattr -dr com.apple.quarantine /Applications/Cascade.app
   ```
4. Runtime test:
   - Log into a target site in Arc/Chrome/Brave/Edge.
   - Start a browser workflow in Local Sandbox.
   - Expected: Hands box says it is using the existing browser session, then the
     sandbox opens already signed in.
   - If macOS Keychain prompts for browser safe storage, approve it.
   - If the site still asks for login, check whether it uses localStorage,
     IndexedDB, passkeys, or WebAuthn; those still need the fallback.

---

# Previous Handoff (2026-05-31)

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

## 4. Current computer-use reliability focus

The read-only web-result delivery path exists now: the vision agent can `record`
findings, then `done` writes a digest through the same artifact delivery path used
by headless agents.

Fix next:
- Interaction reliability on SPAs: keep improving `browser_execute` for React /
  controlled inputs, iframes, shadow DOM, and post-action settle/wait behavior.
- Stuck/loop detection in `run_task_cycle`: keep strengthening "screen did not
  change" feedback, repeated-action loop brakes, and history given back to the
  vision model.
- Resilience: blank/failed captures, vision JSON parse failures, login-window
  race cases, and stale `START_URLS`.

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
