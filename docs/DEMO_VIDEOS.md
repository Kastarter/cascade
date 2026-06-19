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
**One line:** "I did the boring task once. Now it's an agent I can deploy."

### Setup
- Pick a short, obviously-repetitive task with a clear shape. Good choice: **rename + file a screenshot**, or **compose a templated email**. Below uses the email template (reads instantly on camera).
- Have Mail (or your editor) ready with the compose shortcut working.

### Script
| t | On screen | Audio / caption |
|---|---|---|
| 0–4s | Press **⌥⌃T**. A banner appears. | Banner: **"Teaching — do the task, narrate if you like, then press ⌥⌃T to finish."** Caption: *"Watch me do it once."* |
| 4–18s | You perform the task **by hand**: open compose, type the standard greeting + body + sign-off. Narrate as you go (your words become the agent's name). | Speak while doing it: **"This is the weekly status email I send every Monday."** |
| 18–22s | Press **⌥⌃T** again. | Banner: **"Saving your demonstration…"** |
| 22–30s | Cascade analyzes the bracketed recording → a **preview sheet** slides up showing the learned recipe: a title (your narration) + the numbered steps it captured (open → compose → type → send). | Caption: *"It pulled out the repeatable steps."* |
| 30–36s | Click **"Add to my agents."** App jumps to the **Cascades** tab; the new agent card **flashes**. | Status: **"Added "…" to your agents."** |
| 36–40s | On the agent card, click **Deploy** → it replays the same steps on a fresh compose window. | Caption: *"Taught once. Now it runs itself."* |

### Money shot
The preview sheet: a freeform, hand-done demonstration turned into a clean numbered recipe — proof it *understood* the task, not just recorded pixels. (If the demo had nothing repeatable you'd get *"Nothing repeatable in that demonstration yet — try the task again"* — rehearse so you don't hit that.)

### Notes
- Alternative ending instead of "Add to my agents": **"Send to manager"** routes it to an approval queue — use that cut if your story is about a team/manager workflow.
- Detection variant (no teaching): do the same action twice and open **Cascades** — Cascade *auto-detects* the repeat and offers the card with a rewind thumbnail. Either path lands the same agent; "teach once" is the deliberate version.

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
