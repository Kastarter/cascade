# Cascade — Complete Feature Reference

Everything Cascade does today, organized by surface. Updated 2026-06-10.

## 1. Local context recorder (the foundation)

- **Always-on screen recording**, 1 fps via ScreenCaptureKit, capped at 1920px, excluding Cascade's own windows. Frames stored as JPEG with Vision OCR text in a local SQLite database (WAL). Nothing leaves the Mac.
- **Frame dedup** — dHash perceptual hashing skips near-identical frames (Hamming ≤ 6).
- **Input recording** (listen-only CGEvent tap): clicks (with the clicked element's **AX label**, resolved off the tap thread and privacy-gated), double/right clicks, typed-text events, keyboard shortcuts, scrolls — all anchored to the screen rewind.
- **Privacy rules**: a substring exclude-list (bank / health / password / …) drops frames, OCR, AX labels, and harness file reads outright — no redaction, no partial leaks. One-shot captures and the continuous path are both gated.
- **Retention**: 7 days / 5 GB auto-prune.
- **Hotkeys**: ⇧⌘R capture this moment, ⇧⌘L start/pause recording.

## 2. Reel (rewind + grounded chat)

- Scrubber timeline with per-app colors (real app icon colors), playback at 0.5×–8×, live edge, click/drag scrubbing, hour axis.
- Full-text search (FTS5) over everything ever seen on screen.
- **Ask panel** — grounded Q&A over the record: layered grounding (24h timeline shape, hourly content samples, question-matched moments, freshest moments), Claude-backed with a local heuristic fallback, brief replies. Shares one conversation memory with the voice agent ("one brain").
- "Where do I find X" → vision locate + the companion cursor points at it on the real screen.

## 3. Assist agent (hotkey ⌃⌥Space · voice hold-right-⌘)

The fast computer-use agent that operates the Mac in front of you.

### Computer-use capabilities (the full action set)
| Capability | Detail |
|---|---|
| Click / double / triple / right-click | Tiered: AX press → CGEvent with cursor restore; canvas apps (`axUnreliable`) skip AX |
| Drag | Press → interpolated move → release; drawing shapes, moving objects, selecting ranges |
| Type | 3-tier: AX selected-text insert → clipboard paste (your clipboard restored) → paced chunked keystrokes; per-char physical keys for modal apps (Blender) |
| Keyboard shortcuts | Full key-code map (all letters, digits, symbols, F-keys, arrows, media) |
| Scroll | Direction + amount, pointer warped to target and restored |
| Zoom | Native-resolution crop of any region so small text is actually readable |
| Screenshot / wait | Standard observe loop at the model's ideal resolution |
| **open_app / open_url** | Instant programmatic launch — no Dock hunting, no address-bar typing |
| **highlight** | Cascade's own marching-ants overlay + companion cursor over any region in any app — "show me where…" |
| **use_skill** | Pull-based app skills (below) fetched on demand, zero standing token cost |

### Direct-Mac harness (no screenshots needed — instant)
- **Always on (read-only)**: `search_files` (Spotlight), `list_folder`, `read_file` (bounded 24KB, privacy-gated, binary-refused).
- **Power harness (Settings toggle, default OFF)**: `run_command` (zsh, 25s cap), `run_applescript` (drive Numbers/Excel/Mail/Finder — bulk edits in one script), `write_file` (home/temp only).
- Every call audited **verbatim** and shown live in the dock; destructive deny-list (sudo, `rm -rf /`, pipe-to-shell, disk ops, keychain dumps) refuses regardless of the toggle; credential paths (`.ssh`, `.aws`, Keychains, …) fenced across every tool.

### Intelligence
- **Conversation memory** — rolling 8 turns + compacted archive; referential follow-ups ("now the second one"), bare "click that" acts on the last pointed element instantly; failed turns never pollute the archive.
- **Multi-part planning** — "do X then Y in another app" splits into episodes (Haiku planner), each handing findings to the next; trivial commands skip planning entirely.
- **Grounding note** per frame (frontmost app + window) and a skill nudge when one covers the app.
- **App skills** (Markdown SKILL.md, user-overridable): 13 bundled — Blender, email, spreadsheets, web research, slides, Figma, Photoshop, terminal, Xcode, PDF forms, calendar, messaging, Finder. Runtime policies applied automatically by app: `axUnreliable`, `keysFollowPointer` (Blender pointer-routed hotkeys), modal numeric input.
- **Speed engineering**: prompt caching (tools + 3 moving breakpoints), screenshot pruning, JPEG pass-through at model resolution, capture prewarm on push-to-talk, truncation recovery, retry-on-5xx.

### Control
- Visible **companion cursor** (themeable) with trail and ripple; your real pointer is restored after every action.
- **STOP**: Esc, the dock button, or just talking over it (voice barge-in); checked before every single event posts, mid-batch included.
- Every action audited; typed content never logged (character counts only).

## 4. Detected workflows → agents (Cascades tab)

- **WasteDetector** mines recorded input for repeated action sequences: scroll-bursts collapse to one gesture; a candidate needs **two structural actions** (clicks / ⌘-shortcuts) **and an intent marker** (a click on a *named* element, a shortcut, or a cross-app flow) — typing, bare editing keys, and anonymous clicking never become "workflows".
- Cards tell the story: human titles ("Copy from Mail into Numbers"), a rewind-frame thumbnail, a numbered **when-deployed preview** built from recorded AX anchors, occurrences × honest time math, last-seen.
- **Approve → agent** built from your real actions. Replay re-targets every click: AX label match → Claude vision re-grounding → recorded pixel, with UI-fingerprint verification (pauses after 2 unverified clicks instead of plowing on).
- **Web workflows deploy in the background sandbox** — the floating box does the work with your saved sign-ins while your screen stays yours; everything else replays on the real screen with the visible cursor.
- Suggestions (daily recap, repeated-context) run as **grounded deliverables** in the Reel chat.
- Manager-cascade inbox (persisted), declines persist, full agent activity feed.

## 5. Background web agents (sandbox)

- Isolated WKWebView browser per agent in a floating watch box; persistent data store reuses your sign-ins.
- Same computer-use brain routed to JS actions; **NEEDS_LOGIN** pause → you sign in → Continue resumes mid-plan with findings intact.
- Task planner (≤5 subtasks, step budgets, findings memo); spoken + chat completion reports; results audited.
- Spawn by voice/chat ("create an agent that …", "in the background …") or auto via web-workflow deploys.

## 6. Manager (analytics)

- **Honest math**: "reclaimed" = seconds-per-run × *completed* runs (background and foreground both count); "on the table" = unreviewed workflows + approved-but-never-run agents.
- Apps observed, top repeated workflows (read-only, jump to Cascades), where-the-time-goes per-app bars, cascades-sent history.
- Compose-a-cascade → employee's persisted inbox (separate manager platform later).

## 7. Voice

- GPT-Realtime-2 push-to-talk (hold right ⌘), spoken replies, live transcription; barge-in halts any running agent; capture pipeline prewarms on key-down.

## 8. Trust, safety, setup

- Permission preflight everywhere; fail closed without Screen Recording; prompts only from explicit Settings/onboarding buttons.
- Every agent/computer/harness action lands in the local `audit_event` log.
- First-run onboarding (Record / Act / Think), Settings: hotkeys, permissions, app identity, Keychain-stored model keys, Power harness toggle, cursor theme, light/dark.
