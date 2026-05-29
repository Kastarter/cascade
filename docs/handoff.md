# Cascade — Session Handoff

> Last updated: 2026-05-29 — Layer 2 agents #2/#3/#4/#5 implemented this session. Read this first when resuming. Combine with `docs/agents.md` (canonical agent spec) and `plan.md` (full milestone breakdown).

## 2026-05-29 session — all five agents now real

Implemented the full Layer 2 agent stack (was: only #1 real, #2 heuristic, #3/#4/#5 absent):

- **#5 Privacy Aggregator** — `cascade_agents.rs::cascade_run_privacy_aggregation`. Deterministic, on-device, $0. Projects the raw activity summary to an allowlist (`app`, `category`, `durationMin`, `contextSwitches`), drops sensitive apps/windows (banking/health/legal/dating/incognito via `SENSITIVE_MARKERS`), applies ε≈1 jitter to counts < 10 (`dp_jitter`, FNV-seeded, no `rand` dep), writes `cascade_privacy_aggregates` + a previewable outbox. This is the privacy boundary: the detector reads ONLY this table, never OCR.
- **#2 Waste Detector** — now **LLM** (Opus, temp 0.2), not heuristic. Runs #5 first, then `call_anthropic_json` over the sanitized aggregates only. Whitelist-clamps `kind`/`suggestedAgentKind`, tiers info/suggest/urgent, caps at 6.
- **#3 Agent Generator** — `cascade_generate_agent_spec` (Opus, temp 0.1). Produces a typed `AgentSpecDoc` (workflow, tool whitelist, approval points, rollback, est cost/time). `validate_spec` enforces: tool whitelist (no shell/exec), mutating-tool→approval-point, rollback required, $0.10 cost cap. Persists to `cascade_agent_specs`.
- **#4 Deployment Monitor** — `cascade_sandbox_test` (Sonnet, temp 0.0) dry-runs the spec over recent aggregates with mocked tools; `detect_anomalies` flags scope-creep / missing-approval / excessive-steps in Rust. `cascade_transition_agent_spec` owns lifecycle (review→sandbox→dual-approve→deploy→pause/reject) with dual-approval enforced on deploy. Every action → immutable `cascade_audit_log`. Runs → `cascade_agent_runs`.

New files: `crates/cascade-schema/migrations/0003_layer2_agents.sql`, `app-overlays/.../src-tauri/src/cascade_llm.rs`, `app-overlays/.../src-tauri/src/cascade_agents.rs`, `app-overlays/.../lib/cascade-agents.ts`. `cascade_commands.rs` trimmed to BYOK+tagging. `main.rs` registers 11 new/moved commands. UI: manager dashboard ComposeConsole now generates+reviews+sends a real spec; cascades-view drives the real spec lifecycle with sandbox results + audit log. Schema crate: `cargo test -p cascade-schema` = 5 green.

NOTE: the heuristic detector (`build_*_suggestion`, `classify_app` keyword lists, OCR `key_texts` reading) is **removed** — that path read raw OCR and was the bossware-risk surface #5 exists to close.

## What's installed right now

- `/Applications/Cascade.app` from build #24 (May 27 02:01) — has Cascades tab rename + employee Cascades inbox UI
- **Known bug in this build:** Cascades tab shows error *"Couldn't load cascades — migration 20240703111257 was previously applied but is missing in the resolved migrations"* because `cascade-schema`'s sqlx migrator collided with Screenpipe's `_sqlx_migrations` table. **The fix is written + tested locally (cargo test passes)** but the **rebuild was killed before completing** — needs a fresh `bun run tauri build` to land in the installed app.

## Where we left off

User asked to pause. Build kill-switch was hit on `cascade-build11.log` after the migration fix landed in source. Memory + agent spec doc updated. Nothing committed to git since `46291bc` (Phase B) — Layer 2 + Phase C work is all uncommitted.

## Pending change (one rebuild away)

Fix: `crates/cascade-schema/src/lib.rs` — `migrate()` no longer uses `sqlx::migrate!()` (which fights Screenpipe's migration tracking). Instead it strips `--` comments + splits on `;` + executes each `CREATE ... IF NOT EXISTS` statement directly. Tests green. To land:

```
cd ~/Desktop/Cascade
./scripts/overlay.sh  # only needed if any TS changed; safe to run anyway
cd vendor/screenpipe/apps/screenpipe-app-tauri
bun run tauri build
# ~30 min, then:
rm -rf /Applications/Cascade.app
cp -R src-tauri/target/release/bundle/macos/Cascade.app /Applications/Cascade.app
xattr -dr com.apple.quarantine /Applications/Cascade.app
```

## Honest agent inventory (the question that prompted the handoff)

User asked "what do I have right now?" — the honest answer:

| Agent | Built? | Detail |
|---|---|---|
| #1 Q&A | ✅ Real | Chat panel in Reel, calls Claude with frame context + guardrails. Works today. |
| #2 Waste Detector | ⚠️ Stage-0 | Heuristic-only (regex/keyword app classifiers in `cascade_commands.rs`), not LLM. Runs on-device, not server. Writes patterns to `cascade_manager_suggestions`. |
| #3 Agent Generator | ❌ | No spec generation. Has a string label for `suggested_agent_kind` but no actual workflow / tools / approval-points / rollback path generated. |
| #4 Deployment Monitor | ❌ | UI lifecycle (Review → Sandbox → Running → History) exists in Cascades inbox but every button just flips a DB status string. No sandbox engine, no runtime, no anomaly detection, no rollback. |
| #5 Privacy Aggregator | ❌ | Manager dashboard reads raw on-device activity with no aggregation/sanitization layer. Bossware risk in any multi-employee deployment. |

`CascadeThrottle` (disk/battery safety polling) exists but is NOT Agent #4 — it monitors Screenpipe capture, not deployed fix-agents.

## What's working in the current build

- Cascade Reel with real frame images, scrubbable timeline, app-colored playhead, second-level time
- Live autofollow now with LIVE pill + "↓ NOW" jump button
- Tight Q&A guardrails (no fabrication, no bold, citations only, redactPII pre-pass)
- Manager dashboard at `/manager` (3 tabs: PULSE / PATTERNS / CASCADES)
- Cascades tab (employee inbox at `/cascades` — has migration bug above)
- Vault overlay with quota slider, storage usage bar, battery indicator
- CascadeThrottle policy (auto-pause on quota / low battery)
- 4 patches applied: branding / telemetry-off / visual-identity / capture-density (15s idle interval = ~4/min floor)

## Build environment

- Rust 1.95.0 stable + cmake + pkg-config + bun 1.3.14 (all installed via brew earlier)
- Each full build ~30 min on Apple Silicon (link of `screenpipe_app` binary dominates)
- DMG bundling step is flaky — `bundle_dmg.sh` AppleScript fails ~50% of the time. The `.app` itself builds fine; DMG only matters for distribution.

## Pending uncommitted local changes

Run `git status` to see them. Key categories:

- `app-overlays/.../components/cascade-{reel,titlebar,vault,manager-dashboard,cascades-view,throttle}.tsx` — all overlay UI updates
- `app-overlays/.../lib/cascade-{api,manager,manager-dashboard}.ts` — typed clients
- `app-overlays/.../src-tauri/src/cascade_commands.rs` — grew from 160 → 912 lines with detector logic
- `crates/cascade-schema/src/lib.rs` — Layer 2 schema + migration fix
- `crates/cascade-schema/migrations/0002_manager_suggestions.sql` — new tables
- `patches/0004-cascade-capture-density.patch` — idle interval bump
- `docs/agents.md` — canonical 5-agent spec (290 lines)
- Direct edits to `vendor/screenpipe/apps/screenpipe-app-tauri/src-tauri/{Cargo.toml,src/main.rs}` — not via patch (technical debt: extract into a `0005-cascade-commands-wiring.patch`)

Last pushed commit: `46291bc` (Phase B). Everything since is local-only.

## When resuming, the next clean steps

In order of value-per-effort:

1. **Rebuild + install** to land the migration fix and stop the Cascades tab error
2. **Test the round-trip:** open Manager → click "Refresh signals" → if patterns surface, go to Cascades tab → confirm they appear in Review stage
3. **Extract `0005-cascade-commands-wiring.patch`** for the main.rs + Cargo.toml direct edits so soft-fork hygiene returns
4. **Commit + push** the whole Layer 2 batch (paused at user request)

Then the substantial work (in `docs/agents.md` priority order):

- Agent #5 Privacy Aggregator (trust foundation, lawsuit-avoidance)
- Real Agent #2 LLM detector (replace heuristics with Opus calls)
- Agent #3 Generator (produce actual spec objects)
- Agent #4 runtime (sandbox engine + executor + anomaly detection)

## Hardware/account dependencies still missing

- Apple Developer ID for signed builds (currently ad-hoc signed — first launch needs right-click → Open)
- Release hosting for M5 auto-update (S3/CloudFront)
- Cascade branding assets (logo, tray icon, DMG bg — `public/branding/` is empty)
