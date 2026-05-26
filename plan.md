# Cascade — Layer 1 Implementation Plan

## Context

Cascade is a two-layer enterprise productivity product:
- **Layer 1 (this plan):** passive screen-monitoring + employee-facing rewind & Q&A
- **Layer 2 (later):** admin dashboard, waste-detection agent, deployable fix-agents that the boss "cascades" down to employees (the product's namesake loop)

We're competing against **Clicky** (`farzaa/clicky`, MIT-licensed open source, commercial version at heyclicky.com) — a Swift macOS menu-bar app that watches your screen and **coaches you live** via push-to-talk + voice (Claude + ElevenLabs), drawing a cursor pointer to highlight UI elements. The bet: **passive recording + retrospective intelligence + admin-deployable fix-agents** beats live "tell me what to click" coaching. Clicky's model requires the user to actively engage (push-to-talk) and watch a live overlay; Cascade just records and answers questions later, then (Layer 2) lets a boss push automation down to fix recurring inefficiencies.

**Why Layer 1 first:** Layer 2's detection and fix-agents are useless without a high-quality event store and employee trust. Shipping a personal rewind/Q&A app first (a) validates the capture pipeline, (b) earns employee trust before the admin side appears, (c) gives Layer 2 real data to design against.

**Key research finding that shapes the plan:** Screenpipe (the OSS base we're forking) already ships a mature rewind UI, chat UI, agent runtime (`pi` subprocess with Anthropic provider support), SQLite + FTS5 + sqlite-vec storage, macOS Keychain wrapper, Tauri updater, and an enterprise-edition lane (`ee/`). V1 is mostly **rebrand + provider-pin + prompt design + one bundled pipe** — not "build from scratch." It's MIT/Apache, actively maintained (latest release 2026-05-25), and Mediar AI is YC S26 (high upstream velocity → patches will rot fast).

## V1 scope (locked)

Employee app only, **macOS only**, single user, **fully local — no backend, no sync, no admin side**.

Must do:
1. 24/7 screen capture (frames + OCR; audio opt-in) running in background with low resource use
2. Local searchable event store of everything that happened
3. **Rewind UI** — scrubbable timeline of the day
4. **Q&A agent** — natural-language questions answered using the event store, powered by Claude via BYOK Anthropic key
5. Auto-update, signed macOS binary, sane onboarding

Out of scope: classification, admin dashboard, sync, Windows, agent deployment, team features.

## Locked decisions

- **Project name:** Cascade
- **Fork strategy:** soft fork — git submodule of Screenpipe + `quilt` patch series + cargo workspace overlay
- **Desktop shell:** Tauri (inherited from Screenpipe)
- **Capture/OCR core:** Screenpipe's Rust crates, unmodified
- **Local DB:** Screenpipe's SQLite + FTS5 + sqlite-vec, unmodified; our additions live in sidecar tables
- **Q&A runtime:** Screenpipe's `pi` subprocess (their agent runtime) invoked via a single Cascade pipe — NOT in-process Claude Agent SDK (avoids duplicating their streaming/citation/event-bus infra)
- **Key storage:** macOS Keychain via existing `screenpipe_secrets::keychain` wrapper; mirrored to `~/.pi/agent/auth.json` at runtime only

## Repo structure

All code lives under `~/Desktop/Cascade/`:

```
Cascade/
├── plan.md                                # this plan, copied here as project-root doc
├── README.md
├── vendor/
│   └── screenpipe/                        # git submodule → mediar-ai/screenpipe@<pinned-sha>
├── patches/                               # quilt series, applied in CI on top of submodule
│   ├── 0001-branding-app-name-icons.patch
│   ├── 0002-tauri-conf-product-id.patch
│   ├── 0003-default-provider-anthropic-byok.patch
│   ├── 0004-onboarding-strip-cloud-signup.patch
│   └── 0005-disable-pipe-store.patch
├── crates/
│   └── cascade-schema/                    # additive sidecar tables (forward-compat for Layer 2)
│       ├── Cargo.toml
│       ├── src/lib.rs
│       └── migrations/0001_init.sql
├── pipes/
│   └── cascade-rewind-qa/
│       └── pipe.md                        # the Q&A agent prompt — our entire v1 agent
├── app-overlays/
│   └── screenpipe-app-tauri/              # files overlaid onto vendor/screenpipe/apps/screenpipe-app-tauri
│       ├── public/branding/...
│       ├── components/cascade-onboarding.tsx
│       ├── components/cascade-byok-dialog.tsx
│       ├── lib/cascade-defaults.ts
│       └── src-tauri/src/cascade_commands.rs
├── scripts/
│   ├── apply-patches.sh                   # quilt push -a
│   ├── refresh-from-upstream.sh           # bumps submodule, runs quilt refresh
│   ├── overlay.sh                         # copies app-overlays/** into vendored tree
│   └── build-macos.sh                     # signs + notarizes
├── Cargo.toml                             # workspace incl. vendor/screenpipe/crates/* + cascade-schema
├── .github/workflows/
│   ├── ci.yml
│   └── release-macos.yml
└── .gitmodules
```

**Why submodule + quilt vs. cargo `[patch]` only:** most of the surface we patch is non-Rust (TS/TSX, `tauri.conf.json`, assets). Cargo's patch system only solves Rust crate substitution. `quilt` covers all file types uniformly and is the long-standing Debian-derivatives standard for this exact problem.

## Build order (each milestone shippable on its own)

**M1 — "Screenpipe with Cascade branding."** (~1 week)
- Cascade folder created, submodule pinned, quilt set up, CI applies patches, signed macOS build artifact produced.
- Patches 0001/0002/0004: app name → "Cascade", bundle id, icons, dock label, splash, README.
- Disable upstream PostHog telemetry via patch.
- Verifies the soft-fork pipeline end-to-end before product work begins.

**M2 — "BYOK Anthropic, default provider."** (3–5 days)
- Patch 0003: ship `models.json` with Anthropic preset (`claude-sonnet-4-6`, `claude-opus-4-7`); strip Screenpipe Cloud signup.
- `components/cascade-byok-dialog.tsx`: prompts for Anthropic key, writes via Tauri command into macOS Keychain.
- `src-tauri/src/cascade_commands.rs`: `cascade_set_anthropic_key` writes to Keychain AND mirrors to `~/.pi/agent/auth.json` (the pi agent reads from there).
- Verify existing chat works end-to-end against Claude with user-supplied key.

**M3 — "Rewind UI rebranded, recording on by default."** (3–5 days)
- Use existing `components/rewind/timeline.tsx` and `app/search/page.tsx` unchanged structurally; overlay copy/colors.
- Onboarding simplifies permissions to Screen Recording + Accessibility + (optional) Microphone. Audio default = off.
- Tray menu trimmed to: Pause/Resume Recording, Open Rewind, Settings, Quit.

**M4 — "Cascade Q&A pipe."** (~1 week)
- Ship `pipes/cascade-rewind-qa/pipe.md`: YAML frontmatter pins `provider: anthropic`, `model: claude-sonnet-4-6`, `schedule: manual`, `permissions: reader`, `timeout: 120`.
- Prompt body: instructs agent to use `localhost:3030/search` with time/keyword filters to answer questions like "what did I work on 2–4pm yesterday?" Cite frame timestamps using existing `SourceCitationFooter`.
- Wire chat input → invoke this pipe. Existing `standalone-chat.tsx` + Pi event bus streams responses to UI.
- Patch 0005: hide generic pipe store; expose only our pipe.

**M5 — "Auto-update + onboarding polish."** (3–5 days)
- Tauri updater pointed at Cascade release feed (S3/CloudFront + signed manifest), reusing `src-tauri/src/updates.rs`.
- Onboarding: "everything is local," permission grants, BYOK key entry, "pause anytime" — one screen each.
- Sentry DSN switched to ours.

**M6 — "Layer 2 forward-compatibility hooks."** (3 days, ships dark)
- `crates/cascade-schema` migration: sidecar tables `cascade_event_tags`, `cascade_entity_extractions`, `cascade_classifications`, all FK to `frames.id`.
- One Tauri command `cascade_tag_event(frame_id, tag)` for manual tagging dogfood before Layer 2's classifier.
- No UI yet. Ensures Layer 2 doesn't need a historical-data migration later.

**Total:** ~5 weeks of one engineer, assuming macOS signing pipeline cooperates.

## What to reuse from Screenpipe (be specific)

- **Capture:** `crates/screenpipe-capture`, `screenpipe-screen`, `screenpipe-audio`, `screenpipe-a11y`, `screenpipe-engine` — unmodified
- **Storage:** `crates/screenpipe-db` (frames, ocr_text, audio_chunks, ui_monitoring, FTS tables) — unmodified; our `cascade-schema` adds sidecar tables in the same SQLite file
- **HTTP API:** `apps/screenpipe-app-tauri/src-tauri/src/server.rs` + `server_core.rs` exposing `localhost:3030/search`, `/search/keyword`, `/frames/:id`, `/raw_sql` — our pipe calls these
- **Agent runtime:** the `pi` subprocess + `src-tauri/src/pi.rs` event router
- **Rewind UI:** all of `apps/screenpipe-app-tauri/components/rewind/` + `app/search/page.tsx`
- **Chat UI:** `components/standalone-chat.tsx`, `components/chat/*`, including `SourceCitationFooter`
- **Secrets:** `crates/screenpipe-secrets` + `src-tauri/src/secrets.rs` (macOS Keychain)
- **Permissions/onboarding scaffolding:** `apps/screenpipe-app-tauri/components/onboarding/`, `src-tauri/src/permissions.rs`
- **Updater + tray + dock + crash recovery:** `updates.rs`, `tray.rs`, `dock_menu.rs`, `space_monitor.rs`, `notifications/`
- **Daily summary card:** `components/rewind/daily-summary.tsx` — basically "summarize my week" already exists

## Verify before writing code (M0 gate)

1. ✅ **Anthropic BYOK confirmed in pi agent.** `vendor/screenpipe/apps/screenpipe-app-tauri/src-tauri/src/pi.rs:3212` has `test_build_models_json_anthropic_provider` showing provider key `"anthropic-byok"` with `baseUrl: https://api.anthropic.com` and `api: anthropic-messages`. **No custom shim needed** — Cascade calls existing `pi_start` Tauri command with `provider_config: { provider: "anthropic", model: "claude-sonnet-4-6", token: <key> }`. The biggest M0 unknown is resolved.
2. **Confirm `sqlite-vec` is actually wired into a search path** (not just compiled in). Search migrations for `vec0` virtual table creation. If absent, rewind/Q&A still works via FTS5 + keyword — no blocker, adjust expectations.
3. **Confirm `localhost:3030/raw_sql` is exposed and not enterprise-license-gated** (check `ee/enterprise_policy.rs`). Pipe may need it for time-range queries beyond `/search`.
4. **Run app on a clean macOS install to baseline:** cold-start RAM, idle CPU, daily DB growth. Requires `bun install` + `bun run tauri build`. Without Apple Developer ID, run unsigned with "continue anyway" button after TCC 5s timer.
5. **Verify macOS signing flow with our Developer ID** in patched `tauri.conf.json`.

### Clicky (the actual competitor) — what they do, what we don't

From `farzaa/clicky` README (active as of 2026-04-27, MIT):
- Swift NSPanel menu-bar app, macOS only
- Continuous screenshots for context, NO local storage / NO rewind / NO OCR / NO event store
- Push-to-talk hotkey (Control+Option) — user-driven, synchronous
- AssemblyAI STT → Claude reasoning → ElevenLabs TTS audio reply
- Draws a cursor pointer on screen to point at UI elements
- Cloudflare Workers backend for credential proxy

**Cascade differentiation (where each feature falls vs Clicky):**
| Capability | Clicky | Cascade Layer 1 | Cascade Layer 2 |
|---|---|---|---|
| Always-on capture | ❌ (per-question only) | ✅ | ✅ |
| Local event store | ❌ | ✅ (Screenpipe SQLite) | ✅ |
| Rewind UI | ❌ | ✅ | ✅ |
| Retrospective Q&A | ❌ | ✅ (Cascade pipe) | ✅ |
| Live coaching overlay | ✅ | ❌ (deliberate) | ❌ |
| Voice in/out | ✅ | ❌ | ❌ |
| Admin / multi-user | ❌ | ❌ | ✅ |
| Deployable fix-agents | ❌ | ❌ | ✅ |

**Strategic implication:** if a user wants "tell me what to click right now," they want Clicky, not us. We do **not** ship live overlay coaching in Layer 1 — it's a Clicky feature, building it would dilute our positioning. If Clicky later adds passive recording + retrospective Q&A, our moat compresses to Layer 2 (admin + cascadeable agents).

## Risks that could derail v1

- **Upstream velocity** (Mediar AI is YC S26, multiple releases per week). Mitigation: weekly upstream-merge cadence, CI fails on patch conflict, patches stay minimal and additive (overlays > rewrites).
- **Pi-agent coupling.** `PIPE_EXECUTION_SPEC.md` lists unresolved edge cases (no execution timeout, PID tracking bug, store.bin race). Mitigation: ship the pipe, monitor failure modes, keep "in-process Claude Agent SDK" as Plan B for v1.1.
- **Pipe-store removal blowback.** Disabling pipe store could break chat UI imports. Verify before patching.
- **License boundary.** `ee/` directory is under separate enterprise license. Do not touch or pull into Cascade paths.
- **Cluely competitive read.** If Cluely ships passive mode, differentiation collapses. Not a v1 engineering risk; affects how aggressively M6 (Layer 2 hooks) ships.

## Verification (end-to-end test for v1)

1. Fresh macOS user, no prior install. Download Cascade DMG, drag to Applications, launch.
2. Onboarding: grant Screen Recording + Accessibility, enter Anthropic API key, finish.
3. Use the machine normally for 30 min (browser, code editor, Slack).
4. Open Cascade → Rewind tab → scrub timeline → click a frame → see correct OCR text + window context.
5. Open chat → ask "what did I do in the last 30 minutes?" → answer cites real frames with correct timestamps.
6. Quit Cascade, relaunch → events from step 3 still present.
7. `Activity Monitor`: Cascade RAM < 400 MB idle, < 5% CPU average. SQLite DB growth < 50 MB/hr at default settings.
8. Auto-update: bump version in release feed, confirm app prompts to update on next launch.

## Status snapshot (post-scaffold session)

**Shipped (foundation):**
- ✅ `~/Desktop/Cascade/` scaffolded, git init'd, pushed to `github.com/Mohanad139/Cascade`
- ✅ Screenpipe pinned as submodule at SHA `85b0f37c6e7efbcdde83bfeea21b601f8da79ca7` (v2.2.17-3255-g85b0f37c6)
- ✅ Quilt installed; series + patch infra working
- ✅ `patches/0001-branding-app-name-icons.patch` — productName/identifier/publisher/copy/trayId/deep-link scheme + `$HOME/.cascade/**` allow-listed in asset protocol
- ✅ `patches/0002-disable-upstream-telemetry.patch` — PostHog init replaced with no-op; `PostHogProvider` left wired so call sites don't crash
- ✅ Both patches verified via `./scripts/apply-patches.sh` and pop cleanly via `quilt pop -a`
- ✅ `crates/cascade-schema` — sidecar tables (`cascade_event_tags`, `cascade_entity_extractions`, `cascade_classifications`), async API, FK-cascade verified by green `cargo test`
- ✅ `pipes/cascade-rewind-qa/pipe.md` — prompt format matches actual Screenpipe pipe schema
- ✅ `app-overlays/screenpipe-app-tauri/` — `cascade-defaults.ts`, `cascade-byok-dialog.tsx`, `cascade-onboarding.tsx`, `cascade_commands.rs` (Keychain BYOK + mirror to `~/.pi/agent/auth.json`)
- ✅ `scripts/apply-patches.sh`, `refresh-from-upstream.sh`, `overlay.sh`, `build-macos.sh`
- ✅ `.github/workflows/ci.yml` (patch-applies-clean + schema build/test) + `release-macos.yml` (signed DMG)
- ✅ Workspace `Cargo.toml`, `.gitignore`, `README.md`

**Deferred (not in v1 critical path):**
- ❌ `0003 onboarding-strip-cloud-signup.patch` — onboarding/page.tsx is 188 lines; cleaner as overlay-replacement than in-place patch. Decide in M3.
- ❌ `0004 disable-pipe-store.patch` — pipe-store.tsx is 1765 lines. Cleanest is hiding the route in the layout. Decide in M4.
- ❌ `0005 default-provider-anthropic-byok.patch` — **not needed.** UI calls existing `pi_start` Tauri command with `provider_config`. Removed from series.

**Blocked on user inputs:**
- ⏳ **Apple Developer ID** — needed for signed DMG + TCC permission persistence. Add as GH repo secrets: `APPLE_CERTIFICATE` (base64 .p12), `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`, `KEYCHAIN_PASSWORD`, `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`.
- ⏳ **Anthropic API key** — for dev-time E2E of the Q&A pipe (Cascade is BYOK so this isn't a deploy blocker, but you need one to *test*).
- ⏳ **Release hosting** for M5 auto-update — S3/CloudFront or GitHub Releases endpoint for the Tauri updater manifest.
- ⏳ **Branding assets** — `app-overlays/.../public/branding/` is empty; need Cascade logo + tray icon + DMG background. Until then, builds keep Screenpipe icons.

**Next concrete steps when resuming:**
1. `cd vendor/screenpipe/apps/screenpipe-app-tauri && bun install` to confirm deps resolve, then `./scripts/apply-patches.sh && ./scripts/overlay.sh`.
2. Run `./scripts/build-macos.sh` unsigned and verify DMG opens, app says "Cascade" in dock, tray icon present.
3. Resolve remaining M0 gate items (2: sqlite-vec wiring, 3: raw_sql endpoint, 4: baseline perf, 5: signing).
4. Wire `cascade-onboarding.tsx` into the actual `app/onboarding/page.tsx` route.
5. End-to-end test the Q&A pipe with a real Anthropic key.
