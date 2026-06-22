# Cascade — Three 30–45s Demo Videos

Three short, single-take demos, each showing one pillar of the product:

1. **Background agent** — it works in a floating box while you keep working.
2. **Teach once** — show it a task by hand once; it becomes a reusable agent.
3. **Cursor** — it operates your real Mac with the blue companion cursor; hands off.

Each script is shot-by-shot. The bracketed strings are the **real on-screen / spoken
strings from the code**, so what you record matches what ships.

> All three assume Cascade is running, recording, and your Claude key is in Settings.
> Run `./scripts/demo-setup.sh` once to create `~/CascadeDemo` (Falcon invoice = **18,450 USD due June 30**, Q1/Q2 reports, roadmap notes, Inbox).

---

## Recording notes (read once)

- **Tool:** QuickTime "New Screen Recording" or OBS, 1080p, 30fps.
- **Cursor:** for Demo 1 & 3 the point is that the *blue companion cursor* moves, not your real one. Keep your real pointer parked in a corner so the audience sees only Cascade's cursor.
- **Notch HUD:** the floating notch sits top-center — it shows `Listening` / `Thinking…` and the live waveform. Keep it in frame.
- **Voice:** hold **Right ⌘** to talk (`PushToTalk` = Right Command). Release to send. Speak one clean sentence; the `VoiceFragmentGate` drops half-words, so don't trail off.
- **Length:** each is timed to land at 30–45s. Trim dead air in post; don't rush the cursor flights — they're the demo.

---

## Demo 1 — Background agent (~35s)
**One line:** "I asked for research, kept working, and it did the whole thing in a box."

### Setup
- Have a normal work app open and visible (a doc, your editor) — the point is you never leave it.
- No login needed for the task below (keeps it to one take). If a site asks to sign in, the box turns its dot **orange** and shows *"I need you to sign in… press Continue"* — avoid that path for this cut.

### Script
| t | On screen | Audio / caption |
|---|---|---|
| 0–4s | You're typing in your work app. Hold **Right ⌘**. Notch shows **`Listening`** + waveform. | Speak: **"Create a background agent to find the three cheapest direct flights to Tokyo next month and a well-rated hotel near Shibuya."** |
| 4–6s | Release. Cascade speaks back. | TTS: **"On it. I'll handle that in the background."** Caption: *"It starts the agent — I go back to my work."* |
| 6–9s | A small **60×60 chip** taps in at the **middle-right edge** of the screen. You keep typing in your main app. | Caption: *"It runs over here — I'm still working."* |
| 9–13s | Hover the chip → it **blooms left into a 760×430 panel**. Header dot is **green** (working), red **`● LIVE`** badge on the preview. | — |
| 13–25s | **Left pane:** live sandbox browser — Google Flights loads, the **blue agent cursor** flies to the search box (ripple on click), types the route. **Right pane:** chat bubbles fill in: *"Opening google flights…" → "Searching Tokyo flights…"* | Caption: *"Real browser, its own cursor — not mine."* |
| 25–33s | Chat lands the result, green dot. Bubble shows the findings memo (flights + hotel). | TTS summary plays. Caption: *"Found it — three flights and a hotel, while I never left my doc."* |

### Money shot
Split attention: your text cursor blinking in the work app on the left **while** the blue agent cursor clicks inside the floating box on the right. That single frame *is* the pitch.

### Trigger reference
Any of: `"create/make/build … agent"`, `"in the background"`, `"background agent"`, `"in the sandbox"`. Cap is 8 concurrent.

---

## Demo 2 — Teach once (~40s)
**One line:** "I logged one invoice into the ledger by hand. Now it's an agent that does the whole stack."

This is the task every AP clerk / accountant does dozens of times a day: open an
invoice, copy the vendor, amount, and due date into a tracking sheet, next invoice,
repeat. You do it **once** on camera and Cascade turns the copy→paste rhythm into a
reusable agent.

### Setup
- Run `./scripts/demo-setup.sh` — it creates the open invoices (**Falcon 18,450 / Meridian 4,820 / Vertex 9,600**) and `Invoices/invoice-tracker.csv` with one row already filled (so it reads as an ongoing ledger).
- Open **`invoice-tracker.csv` in Numbers** on the right; open an invoice **`.txt`** (TextEdit/Preview) on the left, side by side. Both visible in frame.
- **Critical:** copy and paste with the **⌘C / ⌘V keyboard shortcuts** — *not* the Edit menu or right-click. The keyboard ⌘C-in-one-app→⌘V-in-another is exactly what Cascade names **"Copy from … into Numbers"**; menu copies don't fire that.

### Script
| t | On screen | Audio / caption |
|---|---|---|
| 0–4s | Press **⌥⌃T**. A banner appears. | Banner: **"Teaching — do the task, narrate if you like, then press ⌥⌃T to finish."** Caption: *"Watch me log one invoice."* |
| 4–20s | You do it **by hand**: in the invoice, select the vendor → **⌘C** → click into Numbers' next empty row → **⌘V** → **Tab** → back to the invoice, select the amount → **⌘C** → Numbers → **⌘V** → **Tab** → same for the due date. Then start the **next** invoice's row to show the loop. Narrate once — your words name the agent. | Speak: **"This is my daily invoice entry — I copy each vendor, amount, and due date into the AP tracker."** |
| 20–24s | Press **⌥⌃T** again. | Banner: **"Saving your demonstration…"** |
| 24–32s | A **preview sheet** slides up: header **"You taught Cascade a task"**, an **ON SCREEN** tag, the title from your narration, an app chip row, and a **"WHEN DEPLOYED, CASCADE WILL"** line describing the copy→paste flow. A provenance chip links back to the recorded moment. | Caption: *"It understood the repeatable steps — not just pixels."* |
| 32–37s | Click **"Add to my agents  →"**. App jumps to the **Cascades** tab; the new agent card **flashes** (3s ring). | Status: **"Added "…" to your agents."** |
| 37–40s | On the agent card, click **"Deploy  →"** → it replays the same copy→paste steps to log the next invoice's row. | Caption: *"Taught once. Now it runs itself."* |

### Money shot
The preview sheet: a freeform, hand-done copy/paste turned into a named, grounded
agent with a "when deployed, Cascade will…" plan and a chip back to the exact
moment you did it — proof it *understood* the AP task, not just recorded pixels.
(If you used menu copy/paste or did too little, you'll get *"Nothing repeatable in
that demonstration yet — try the task again"* — so use **⌘C/⌘V** and log at least
one full invoice. A cross-app copy→paste pair is the minimum that passes.)

### Notes
- Narration is optional but it **names the agent** — speak one clean sentence (the `VoiceFragmentGate` drops half-words, so don't trail off). With no narration Cascade auto-names it **"Copy from TextEdit into Numbers."**
- Alternative ending instead of "Add to my agents": **"Send to manager"** routes it to the Manager approval queue — use that cut for a team/manager story.
- Detection variant (no teaching): just log two invoices the normal way and open **Cascades** — Cascade *auto-detects* the repeat and offers the same card with a rewind thumbnail. Either path lands the same agent; "teach once" is the deliberate version.

### Trigger reference
Teach hotkey is **⌥⌃T** (start and finish). The recipe is built only if the demonstration clears the bar: **≥2 structural actions** (clicks / ⌘- or ⌃-shortcuts) **and an intent marker** (a named-element click, a real shortcut, or a cross-app flow). One ⌘C-in-invoice → ⌘V-in-Numbers pair satisfies both.

---

## Demo 3 — Cursor (the on-screen agent) (~40s)
**One line:** "It uses my actual Mac, hands off — and one key takes control back."

### Setup
- Open **Mail** with one email visible whose subject mentions **"Falcon invoice"** (from `demo-setup.sh` story).
- Park your real pointer in a corner. Pick a cursor theme from the notch beforehand (e.g. green — *"glides with a soft halo"*).

### Script
| t | On screen | Audio / caption |
|---|---|---|
| 0–4s | Mail is frontmost. Hold **Right ⌘** → notch flips to **`Listening`** + waveform bars. | Speak: **"Reply to the Falcon invoice email and say the payment is scheduled for June 30th."** |
| 4–7s | Release. Notch shows **`Thinking…`**; dock reads **"Cascade is thinking…"**. | Caption: *"It looks at the screen, then acts."* |
| 7–12s | The **blue companion cursor** flies in from beside your parked pointer to the **Reply** button, lands with a **press ripple**. Dock: **"Cascade is doing it."** | Caption: *"That's its cursor — mine never moved."* |
| 12–28s | Reply window opens; the cursor places into the body and **types the message in real time**. Short spoken clauses play: **"Opening the reply" → "Writing the response."** | Caption: *"Real typing, real app."* |
| 28–33s | It stops **at the draft — never hits Send.** | Caption / TTS: *"It writes the draft and stops. Sending is yours."* |
| 33–40s | Start a second action — say **"scroll through this thread and summarize it"** — then **hit Esc** mid-flight. Overlay vanishes. | Dock: **"Stopped. Control returned to you."** Caption: *"Esc always wins — mid-click, mid-sentence."* |

### Money shot
Two beats: (1) the blue cursor typing into a real Reply window while your real pointer sits dead-still in the corner; (2) Esc, and everything halts instantly. Trust = autonomy + the kill switch in the same clip.

### Bonus beat (if you want a 4th ~10s clip)
**"Where is the reply-all button?"** — the companion cursor flies to the control and holds a **marching-ants highlight** without clicking. Same agent, *pointing* instead of acting — good for showing it can teach, not just do.

---

## The close (caption over the last frame of any of the three)

> "Cascade works in the background, learns from one demonstration, and uses your
> Mac with your hands off — local, audited, and stoppable with one key."
