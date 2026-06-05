# Cascade

**Your day, recorded locally — then turned into answers and agents.**

Cascade is a privacy-first macOS app that passively records what happens on your
screen, keeps it entirely on your Mac, and turns it into two things: a searchable
*rewind* of your day that you can ask questions about, and AI agents that take the
repetitive work off your plate.

Everything runs locally and on your own Anthropic (Claude) API key — nothing leaves
your machine except the calls you choose to make to Claude.

## What it does

### Reel — rewind your day
A cinematic timeline of everything you worked on, reconstructed from on-screen text
(OCR) and app/window context. Scrub through the day, see what was on screen at any
moment, and watch each segment colored by the real icon of the app you were using.

### Ask your day
Ask plain-language questions about what you did — *"what was that error in Cursor
this morning?"*, *"summarize the doc I read in Obsidian"* — and get answers grounded
in your actual recorded activity instead of a guess.

### Manager — spot the repetitive work
Cascade watches for patterns in how you work and surfaces the repetitive, low-value
loops that are the best candidates to automate.

### Agents — automate the loop
From a surfaced pattern, Cascade can generate an agent that does the work for you.
The important part is that the work still feels like your work: the agent follows
the same workflow, in the same tools, and leaves the result where you already work.
You can watch it in a floating box or let it operate directly on your screen.

- **Floating box** — watch the agent work step by step in a visible box while it
  follows the workflow.
- **On your screen** — the agent uses your real screen and cursor, so it can operate
  the same app you would have used yourself.

## Privacy & local-first

- **All capture and storage stays on your Mac.**
- **Sensitive apps are excluded** entirely — banking, health, legal, dating, private
  browsing.
- A **Privacy Aggregator** sanitizes activity down to an allowlist *before* any agent
  is ever allowed to read it.
- **Bring your own key (BYOK)** — your Anthropic API key lives in the macOS Keychain
  and is used only for the Claude calls Cascade makes on your behalf.

## Requirements

- macOS on Apple Silicon
- An [Anthropic API key](https://console.anthropic.com/settings/keys)
- To build from source: [Bun](https://bun.sh) and a Rust toolchain

## Build & run

```sh
# sync the app source and build a release .app
bash scripts/overlay.sh
cd vendor/screenpipe/apps/screenpipe-app-tauri
bun install
bun run tauri build

# install it
cp -R src-tauri/target/release/bundle/macos/Cascade.app /Applications/
xattr -dr com.apple.quarantine /Applications/Cascade.app
```

On first launch, grant Screen Recording permission and add your Anthropic key in
**Settings**.

## Project layout

- `app-overlays/screenpipe-app-tauri/` — Cascade's app UI and native commands
- `crates/cascade-schema/` — the local SQLite tables Cascade adds
- `pipes/cascade-rewind-qa/` — the rewind Q&A agent
- `scripts/` — overlay + build helpers
- `vendor/screenpipe/` — the vendored on-device capture engine the app is built on

## Product direction

Cascade's wedge is employee context and monitoring first, then agent execution.
See [`docs/product-strategy.md`](docs/product-strategy.md) for how Cascade uses
Screenpipe, OpenClicky, and Glide as references without turning this repo into a
dump of multiple desktop apps.
