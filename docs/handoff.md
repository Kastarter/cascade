# Cascade — Session Handoff

> Last updated: 2026-05-27 (paused mid-iteration). Read this first when resuming. Combine with `docs/agents.md` (canonical agent spec) and `plan.md` (full milestone breakdown).

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
