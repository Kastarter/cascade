# Cascade — Wow-Factor Demo Script

A shot-by-shot recording plan (~7 minutes). Each scene is one capability the
audience can't unsee. Record in one take per scene; stitch later.

## Preparation (before recording)

- [ ] Fresh-ish state: quit Cascade, optionally clear `~/Library/Application Support/Cascade/` for a clean onboarding shot (keep a copy to restore your real record).
- [ ] Claude key ready to paste; OpenAI key if you want the voice scenes.
- [ ] **Settings → Agent harness → Power harness ON** (scene 5).
- [ ] Plant the props: an email in Mail titled something findable ("Q3 vendor invoice — Falcon Ltd"), a Numbers sheet open, a Chrome tab routine you can repeat (e.g. open the same dashboard, click the same export button).
- [ ] Second display disconnected (or use it deliberately — display-follow works, but keep the demo on one screen).
- [ ] Do NOT pre-record the workflows you'll demo in scene 6 — the audience should see detection go from nothing to a card.

---

## Scene 1 — "It sets itself up" (30s)

Launch Cascade for the first time. The 3-step overlay (Record / Act / Think)
fills the screen. Grant Screen Recording, grant Accessibility + Input
Monitoring, paste the Claude key, hit **Start using Cascade**.

**Say:** "Three permissions, one key, and Cascade is recording my work — locally.
Nothing leaves this Mac."

## Scene 2 — "Your day, rewindable" (45s)

Work naturally for ~2 minutes before this shot: read the planted email, copy
something into Numbers, browse the Chrome dashboard. Then open the **Reel**:
scrub the timeline, show per-app colors, hit a playback speed, type a search
term that appeared on screen ("Falcon") and jump to the hit.

**Say:** "Everything I saw is a timeline I can scrub, play, and search — the
text channel comes straight from the apps' accessibility trees, so it's
character-perfect, and a change-aware capture means a single new message in a
static window is never missed."

## Scene 3 — THE MEMORY MOMENT: ask with proof (60s)

In the Reel chat, ask two questions:

1. **"when is the Falcon invoice due?"** — the agent *hunts* through the record
   (you'll see "Searching your record…"), answers, and — the money shot —
   **proof chips appear under the answer**. Click one → the Reel jumps to the
   exact recorded moment. Point at the screen.
2. Ask with words that never appeared on screen: **"what was that vendor bill
   I looked at?"** — semantic recall finds it anyway.

**Say:** "It doesn't just answer — it shows me the receipt. Click the chip,
and there's the actual moment it's citing. And I didn't have to remember the
right words; it searches by meaning."

## Scene 4 — THE AGENT MOMENT: it does it for you (60s)

Hold **right-⌘** (or press ⌃⌥Space and type): *"reply to the Falcon invoice
email and say the payment was scheduled for Friday"*. The blue companion
cursor flies, opens the reply, types the draft — and STOPS at a draft.

Then press **Esc mid-action** on a second command to show the kill switch.

**Say:** "The same agent that remembers my day can act on it — visible cursor,
my real pointer untouched, Esc stops it instantly, and every click lands in
the audit log. It drafts; I decide what sends."

## Scene 5 — "No screenshots needed" — the harness (45s)

Ask the agent: *"find my latest quarterly spreadsheet, read it, and write a
summary file on my Desktop"*. Watch the dock narrate `search_files` →
`read_file` → `write_file` — instant, no screen-walking. Open the file it wrote.

**Say:** "For file work it doesn't need to look at the screen at all — Spotlight,
bounded reads, AppleScript for bulk edits. Every call shows up here, verbatim,
in the audit trail. The write/execute tier is a switch I own, off by default."

## Scene 6 — THE DETECTION MOMENT: repeated work becomes an agent (75s)

On camera, do the routine twice: copy a line from the Falcon email → paste it
into the Numbers sheet. Open **Cascades**: a card appears — **"Copy from Mail
into Numbers"** — with a real screenshot from the rewind, "2× · ~1m saved",
and the numbered **WHEN DEPLOYED, CASCADE WILL** steps.

Press **Approve agent** → the page auto-scrolls and the new agent card flashes
in YOUR AGENTS, showing WHAT IT DOES. Press **Deploy** → the cursor replays
your workflow by itself.

**Say:** "Cascade watched me do that twice and wrote the agent itself — from my
actual clicks, with the proof and the exact steps on the card. One approve,
and the work is automated."

## Scene 7 — Background agents + scheduling (45s)

Take a detected Chrome workflow (or say: *"create a background agent that
checks the dashboard and notes the new numbers"*). The card says **runs in
background** — deploy it and the floating sandbox box does the work while you
keep using the Mac. Then open the agent card's **clock menu → Run daily at
9:05**.

**Say:** "Web workflows don't even take my screen — they run in a sandboxed
browser with my sign-ins, on a schedule if I want. My screen stays mine."

## Scene 8 — "It learns" + the manager view (30s)

If a LEARNED SKILLS card appeared after scene 5's app work, approve it: "the
agent wrote its own playbook for that app — next run is smarter." Then flip to
**Manager**: reclaimed minutes (real runs only), time on the table, where the
hours go.

**Say:** "Honest numbers — reclaimed counts only completed runs. This is what
an org sees: time coming back, with an audit trail under every minute."

---

## The one-liner close

"Cascade records your work locally, proves every answer with the receipt,
turns what you repeat into agents you approve — and stops the instant you
touch Esc."
