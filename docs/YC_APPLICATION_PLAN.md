# YC Application Plan — Fall 2026 Batch

Last updated: 2026-07-06

## Timeline (hard dates)

- **Application deadline: July 27, 2026, 8pm PT** (~3 weeks from now).
- Decisions for on-time applicants by **Aug 28**. Interviews are over video in Aug–Sept; decision the same day as the interview.
- Batch runs **Oct–Dec 2026 in San Francisco**, starting with a 3-day in-person kickoff.
- Source: https://www.ycombinator.com/apply

## Acceptance-rate reality

- YC publishes no official stats. Widely-cited recent numbers: ~25k–30k applications per batch, ~150–250 companies funded → **~1% base rate**.
- Most applications are ideas without a working product. A shipped native app + real technical moat + clear buyer competes in a far smaller effective pool.
- The demo and founder video mostly determine application → interview conversion; the interview determines acceptance.

## 1-minute founder video (YC's official rules)

Source: https://www.ycombinator.com/video

- Exactly **1 minute, both co-founders on camera together**, nothing but the founders talking. Screen-recorded video call is acceptable if not co-located.
- **No demo footage, no promo content** — there is a separate demo section in the application.
- **Do not read a script.** Bullet points only; YC explicitly evaluates natural communication and founder chemistry.

Suggested shape (bullets, not lines to memorize):

- ~15s each: who you are, leading with strongest credibility (macOS/agent technical depth; audit/accounting domain exposure).
- ~20s: what Cascade does — "We record employees' work locally, find the repetitive parts, and turn them into supervised agents that do the work — with an audit trail."
- ~10s: why us / why now (computer-use models just became viable; generic agents fail on real screens; we own the grounding layer).

## Demo video (60–90 seconds, one workflow end-to-end)

Partners skim fast; the first 20 seconds decide. No slides, no intro animation, no feature tour. Real screen, real app, narrated.

The differentiating arc is the **closed loop**: Record → Detect → Execute supervised. Generic computer-use startups can only show step 3; the recorder wedge makes steps 1–2 uniquely ours.

| Time | Beat | On screen |
|---|---|---|
| 0:00–0:15 | Local recorder | Reel/rewind timeline, scrub through today's work. "Runs locally — screen, text, inputs. Nothing leaves my machine." |
| 0:15–0:30 | Detection (the magic beat) | Suggestion card: "Cascade noticed I did this task 4× this week" — with evidence from the recordings. Not prompted. Discovered. |
| 0:30–1:10 | Supervised execution | Approve → companion cursor performs the task in the real app. One line: "Esc stops it instantly; every action lands in a tamper-evident audit log." Flash the audit log 2s. |
| 1:10–1:20 | The number | "5 minutes, 20× a month — Cascade found it and now does it." |

### Demo use case (pick one; must match the first-buyer thesis: services/back-office)

1. **Invoice/transaction entry** — pull data from an email/PDF → enter into QuickBooks or a web accounting tool. Universally understood, billable-hours value, exercises real-screen grounding where generic agents visibly fail. **(Preferred.)**
2. **PBC/document chasing** — check a client portal for documents, update a tracker. Very real audit-firm pain.

### Product fixes required BEFORE recording (demo blockers from Known Issues)

1. **Humanize the suggestion card** — currently "Repeated steps in <app>" + token soup ("click · type · cmd+r"). Needs a human-readable story built from recipe AX labels/window titles + an evidence thumbnail from the rewind.
2. **`deploySuggestion` must execute the mined recipe** — today it passes the card TITLE as the agent goal ("Help with repeated work in iTerm2" is not an executable goal).
3. Rehearse the exact take end-to-end and verify against `audit_event` — verify by running, not compiling.

Nice-to-have if time remains: persist declined suggestions (in-memory only today) so the Manager tab looks real in any live-demo follow-up.

## What actually moves acceptance odds (in rough order of leverage)

1. **Usage/traction before the deadline**: even 1–3 pilot users at services firms (accounting/audit/BPO) — or signed LOIs — transforms the application. "X firms run Cascade daily; it found Y repeated workflows; Z hours reclaimed" beats any demo polish.
2. **A demo where the product visibly works on a real screen** (see above).
3. **Clear, numeric answers in the written application**: market size in billable-hours terms, why the recorder wedge defeats cold-start, why AX-first grounding is the moat (cite the observed failure of SOTA agents on trivial real-screen tasks).
4. **Founder video chemistry** — relaxed, fast, no script.
5. Apply **on time** (July 27). Late applications get materially worse attention.

## Objections to pre-empt (application + interview)

- "Isn't this employee surveillance?" → Employee sees their own Rewind; privacy rules drop sensitive frames; manager-visible signals are aggregated. The buyer pitch is reclaimed hours, not monitoring.
- "Why won't OpenAI/Anthropic computer-use kill you?" → They ship the loop, not the grounding or the local context. Our recordings are both the discovery mechanism (what to automate) and the grounding data (how to automate it reliably).
- "Why macOS-native?" → Trust boundary (local-first, TCC permissions, audit) and AX-tree access are platform-deep; an Electron wrapper can't own them.
- "Two founders selling to enterprises?" → Wedge is bottom-up: individual/team installs prove reclaimed hours, then firm-wide rollout.

## Honest assessment

Strengths: working native product, hot space, defensible technical thesis (AX-first grounding), articulated wedge + first buyer, evidence-backed demo arc competitors can't copy.

Risks: crowded computer-use space; no disclosed revenue/pilots yet; "monitoring" perception; enterprise motion with a two-person team; demo path has the two known gaps listed above.

No one can guarantee acceptance at a ~1% base rate — the plan above maximizes every controllable. The single highest-leverage item is **pilot users before July 27**.

## Do we have a chance? (straight answer, 2026-07-06)

Yes — a real one, meaningfully above the ~1% base rate, because most applications are ideas with no product while we have a shipped native app, a defensible technical thesis (AX-first grounding), and a demo arc (record → detect → execute) generic computer-use startups cannot copy. But "better than 1%" is not a guarantee; strong teams with working products get rejected every batch. Anyone promising guaranteed acceptance is selling something.

**The product story is above-average for a YC application; the traction story is currently empty.** Three weeks is enough to partially fix that — and it's the difference between "interesting demo" and "get the interview."

### Guarantee the inputs — 3-week priority order

Since the outcome can't be guaranteed, guarantee the inputs, in order of leverage:

1. **Pilot users before July 27.** The single biggest gap. Everything else is opinion until someone outside the team runs Cascade daily. Even 2–3 accounting/audit/BPO teams — or signed LOIs — changes the application from "promising tech" to "company." If only one thing gets the three weeks, it's this.
2. **Fix the two demo blockers** — human-readable suggestion cards, and `deploySuggestion` executing the actual mined recipe instead of the card title. Without these the demo's magic beat is fake, and YC partners have seen enough staged agent demos to smell it.
3. **Rehearse the demo take against `audit_event`** — verify by running, not compiling.
4. **Founder video: no script, real chemistry.** YC explicitly screens for how the founders communicate together — can't be engineered, only practiced.
5. **Submit on time (July 27, 8pm PT).** Late applications get worse attention.
