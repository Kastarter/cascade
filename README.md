# Cascade

Enterprise productivity intelligence — passive monitoring + retrospective Q&A on the employee side; waste-detection + cascadeable fix-agents on the admin side.

This repo is a **soft fork of [Screenpipe](https://github.com/mediar-ai/screenpipe)**: upstream is vendored as a git submodule under `vendor/screenpipe/`, our changes live as a `quilt` patch series in `patches/` plus overlay files in `app-overlays/`, and our additive sidecar tables live in `crates/cascade-schema/`.

## What's here

- `plan.md` — the canonical Layer 1 implementation plan
- `vendor/screenpipe/` — upstream Screenpipe at a pinned SHA (submodule, not yet added)
- `patches/` — quilt patch series applied on top of upstream
- `app-overlays/screenpipe-app-tauri/` — files copied over the vendored Tauri app
- `crates/cascade-schema/` — our additive SQLite tables (forward-compat for Layer 2)
- `pipes/cascade-rewind-qa/` — the v1 Q&A agent (a single Screenpipe pipe)
- `scripts/` — apply-patches, refresh-from-upstream, overlay, build-macos
- `.github/workflows/` — CI + release pipelines

## Status

Pre-M0. See `plan.md` for the full milestone breakdown and the M0 verification gate that must pass before any patch is written.

## Quickstart

Nothing to build yet — scaffolding only. After the Screenpipe submodule is added and the M0 gate passes:

```sh
./scripts/apply-patches.sh
./scripts/overlay.sh
./scripts/build-macos.sh
```
