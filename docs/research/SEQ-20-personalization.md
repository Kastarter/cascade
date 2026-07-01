# Sequence 20 — Personalization and User Modeling

## Overview

Cascade already has the raw material for personalization: local screen/input context, declined-workflow persistence, durable agent recipes, `AssistMemory`, and audit events. The missing layer is a lightweight user model that turns everyday feedback into local priors: what this user approves, declines, edits, runs, disables, schedules, and asks Cascade never to do.

The product goal is not "train a private foundation model." It is to make the suggestion and agent surfaces feel progressively less generic:

- Accepted, run, scheduled, disabled, deleted, declined, and edited items become preference events.
- Preference events update human-readable local preferences with confidence and scope.
- Suggestion ranking uses a contextual bandit over app/time/workflow features.
- Repetition thresholds adapt per user, app, and routine family.
- Drafting style uses extracted style preferences from accepted/edited drafts, not raw private text.

This fits Cascade's local-first posture. The useful artifact is a small SQLite-backed preference store and ranking layer, not cloud personalization.

## OSS/Papers Table

| Source | URL | Technique | Cascade Use |
|---|---|---|---|
| Vowpal Wabbit | https://github.com/VowpalWabbit/vowpal_wabbit | Fast online learning with contextual-bandit reductions, exploration policies, sparse hashed features, and continuous reward updates. | Design reference for `SuggestionPersonalizationRanker`: encode context features, choose which cards to surface, update from accept/decline/run outcomes. Do not import the C++ stack. |
| MABWiser | https://github.com/fidelity/mabwiser | OSS bandit library with epsilon-greedy, Thompson sampling, UCB, LinUCB, neighborhood policies, simulation support. | Test oracle for Swift implementations of simple bandits. Start with per-arm Beta Thompson sampling, then add linear contextual scoring. |
| Thompson Sampling for Contextual Bandits with Linear Payoffs | https://arxiv.org/abs/1209.3352 | Bayesian exploration for contextual bandits with linear reward assumptions and regret guarantees. | Ranking model for suggestion cards: context = app, hour, surface, estimated time saved, privacy class; reward = approve/run/decline/delete. |
| A Survey on Contextual Multi-armed Bandits | https://arxiv.org/abs/1508.03326 | Survey of exploration/exploitation algorithms, feature design, reward logging, and offline evaluation. | Keeps Cascade's first implementation honest: log propensities, separate candidate generation from ranking, evaluate with replay before changing UI ordering. |
| Bayesian Personalized Ranking from Implicit Feedback | https://arxiv.org/abs/1205.2618 | Pairwise ranking from noisy implicit signals, treating observed actions as preference evidence rather than explicit ratings. | Model `approve > ignore > decline/delete`, `edited-and-used > discarded`, and `scheduled > one-off run` without asking users for star ratings. |
| Direct Preference Optimization | https://arxiv.org/abs/2305.18290 | Converts preference pairs into a direct optimization objective, avoiding a separate reward model. | Inspiration only. On-device Cascade should not fine-tune hosted LLMs; it can store local preference pairs and turn them into prompt/ranking weights. |
| Active Learning for DPO | https://arxiv.org/abs/2503.01076 | Selects the most informative preference comparisons instead of asking for constant feedback. | Ask rare, targeted preference questions only when the bandit/profile is uncertain and the decision has visible value. |
| Enabling On-Device LLM Personalization | https://arxiv.org/abs/2311.12275 | Selects a compact representative subset of local user data and uses sparse annotation for on-device personalization. | Store compact preference exemplars and distilled rules, not all prior drafts or screenshots. Useful for local-only style memory. |
| Teach LLMs to Personalize | https://arxiv.org/abs/2308.07968 | Personalized generation via retrieval, ranking, summarization, synthesis, and generation over user-specific examples. | For draft generation, retrieve a few approved style exemplars, summarize style traits, then generate with those traits. Keep raw text optional and local. |
| Personalized Text Generation with Contrastive Activation Steering | https://arxiv.org/abs/2503.05213 | Separates stylistic preference from content using a compact style vector rather than per-user fine-tuning or large retrieval. | Practical analogue: maintain style bullets or numeric style features per user/app, not full historical content in prompts. |
| Persistent Memory and User Profiles for LLM Agents | https://arxiv.org/abs/2510.07925 | Combines persistent memory, evolving user profiles, retrieval, self-validation, and long-term personalization. | Split Cascade memory into episodic record, short conversation context, and durable user profile claims with evidence/confidence. |
| PersonaMem-v2 | https://arxiv.org/abs/2512.06688 | Agentic memory maintains a compact human-readable user memory from implicit preferences across interactions. | Use a small editable profile such as "prefers date-prefixed filenames" or "does not want email auto-sent"; avoid dumping all history into prompts. |
| Me-Agent | https://arxiv.org/abs/2601.20162 | Mobile agent with prompt-level preference learning plus hierarchical long-term and app-specific habit memory. | Cascade should scope preferences globally, per app/surface, and per workflow. "Never auto-send email" is global; "archive invoices after export" may be app-specific. |
| RF-Mem | https://arxiv.org/abs/2603.09250 | Adaptive memory retrieval: fast familiarity path when confident, deeper recollection path when uncertainty is high. | Query preference memory cheaply first; only inspect detailed local history when a preference is ambiguous or contested. |
| OpenAdapt | https://github.com/OpenAdaptAI/OpenAdapt | Demonstration capture/execution system with screen/action traces, privacy scrubbing, and local automation loops. | Engineering reference for storing demonstrations and feedback as local artifacts with privacy gates; useful for evaluating suggestion precision. |
| Relevance / implicit feedback literature | https://en.wikipedia.org/wiki/Relevance_feedback and https://en.wikipedia.org/wiki/Implicit_data_collection | Explicit and implicit feedback from clicks, dwell time, selections, and skips; noisy signals need conservative weighting. | Treat ignores as weak evidence, declines/deletes as strong negatives, approvals/runs as positives, and edits as preference deltas. |

## Concrete Personalization Features

### 1. Local preference event log

Map to:

- `Sources/CascadeMemory/CascadeMemory.swift`
- `Sources/AppShell/CascadeAppModel.swift`
- `Sources/AgentOrchestrator/AgentOrchestrator.swift`

Add a local-only `preference_event` table:

```sql
CREATE TABLE preference_event (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL,
    kind TEXT NOT NULL,
    reward REAL NOT NULL,
    surface TEXT,
    app_name TEXT,
    workflow_signature TEXT,
    agent_id INTEGER,
    feature_json TEXT NOT NULL,
    evidence_json TEXT
);
```

Initial events:

- `agent.proposed` with feature vector and displayed rank.
- `agent.approved`: strong positive.
- `agent.declined`: strong negative, reusing `dismissedWasteSignatures` as a hard filter.
- `agent.run.completed`: positive, stronger if repeated.
- `agent.disabled` / `agent.deleted`: negative.
- `draft.accepted` / `draft.edited` / `draft.discarded`: style and content-preference signals.

This preserves an auditable trail and gives ranking code something deterministic to replay in tests.

### 2. Human-readable preference profile

Map to:

- `Sources/CascadeMemory/CascadeMemory.swift`
- `Sources/ProviderKit/AssistMemory.swift`
- `Sources/ProviderKit/ComputerUseAgent.swift`
- `Sources/ProviderKit/ClaudeSingleStepPlanner.swift`

Do not overload `AssistMemory`. It is turn memory and referential state. Add a separate durable `preference_profile` table:

```sql
CREATE TABLE preference_profile (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scope TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    confidence REAL NOT NULL,
    positive_count INTEGER NOT NULL DEFAULT 0,
    negative_count INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL,
    evidence_json TEXT
);
```

Scopes:

- `global`: "Never auto-send email."
- `app:Mail`: "Drafts should be concise and direct."
- `surface:Gmail`: "Offer background agents for inbox cleanup."
- `workflow:<signature>`: "This routine should need five repeats before surfacing."
- `drafting:email`: "Use short paragraphs and no exclamation marks."

Extraction rules should be conservative:

- Explicit "always", "never", "prefer", "stop doing" statements can create profile claims immediately.
- Repeated edits across at least three drafts can create a low-confidence style claim.
- A contradicted preference lowers confidence instead of deleting history.
- Every claim remains inspectable and removable in Settings later.

### 3. Contextual-bandit ranking for suggestions and agents

Map to:

- `Sources/AppShell/CascadeAppModel.swift`
- `Sources/WasteDetection/WasteDetector.swift`
- conceptual `SuggestionEngine`
- new `Sources/WasteDetection/SuggestionPersonalizationRanker.swift` or `Sources/CascadeMemory/PreferenceModel.swift`

Keep generation deterministic, personalize ranking after generation.

Candidate features:

- Candidate type: detected workflow, daily recap, taught range, learned skill, manager inbox item.
- App/surface: native app, browser web app, bundle id, window-title class.
- Time: hour bucket, weekday/weekend, recent recurrence.
- Workflow: step count, `occurrences`, `estimatedTotalSeconds`, cross-app flag, background-capable flag.
- Trust: curator value, replayability, privacy risk, prior declines for similar signatures.
- User state: recent accepts/declines, agent run count, disabled/deleted family count.

First Swift implementation:

- Per feature bucket, keep `alpha/beta` for Beta Thompson sampling.
- Sample score for each candidate; mix with deterministic utility score.
- Exploration budget: at most one uncertain candidate in the visible queue.
- Log `displayedRank`, sampled score, and reward so offline replay is possible.

Reward shaping:

- Approve: `+1.0`
- Run completed: `+0.7`
- Schedule: `+0.8`
- Ignore for several refreshes: `-0.05`
- Decline: `-1.0`
- Disable/delete soon after approval: `-1.0`
- Edit then use draft: `+0.4` plus style-delta extraction

This avoids a brittle global sort. Cascade learns that one user loves background inbox agents but hates file-renaming prompts, while another is the opposite.

### 4. Personalized repetition thresholds

Map to:

- `Sources/WasteDetection/WasteDetector.swift`
- `Sources/AppShell/CascadeAppModel.swift`

Current bar:

- `WasteDetector.detect` recalls repeats seen at least twice.
- `CascadeAppModel.minRepeatsToAutomate` promotes only `occurrences >= 3`.
- `CascadeAppModel.minSecondsToReview` requires at least 30 observed seconds.

Replace the hard global promotion bar with a user/app/surface threshold:

```swift
struct PersonalizationThreshold {
    var minRepeats: Int
    var minObservedSeconds: Int
    var confidence: Double
}
```

Rules:

- Start at today's defaults: 3 repeats and 30 seconds.
- Raise threshold for surfaces with repeated declines.
- Lower threshold for surfaces where the user repeatedly approves early suggestions.
- Never lower below 2 repeats unless the user explicitly teaches a range.
- Sensitive or high-risk actions require explicit approval regardless of threshold.

The detector can still return recall candidates; promotion into `pendingCuratedAgents` becomes personalized.

### 5. Routine and time-of-day modeling

Map to:

- `Sources/CascadeMemory/CascadeMemory.swift`
- `Sources/CascadeMemory/SessionSegmenter.swift`
- `Sources/WasteDetection/WasteDetector.swift`
- `Sources/AppShell/CascadeAppModel.swift`

Add a low-cardinality `routine_profile` derived from local events:

- App/surface by hour bucket.
- Candidate signatures recurring on specific weekdays or after specific app activations.
- Agent runs clustered by time and surface.
- "Do not interrupt" windows inferred from repeated dismissals at the same time/app.

Use it narrowly:

- Re-rank, not auto-run, unless the user schedules an agent.
- Change card timing: show end-of-day recap near the user's actual review time.
- Delay suggestions during contexts where the user repeatedly dismisses them.
- Preload likely app-specific preference snippets into the planner only when relevant.

This creates the "it knows my rhythm" effect while staying under user control.

### 6. Learned drafting style

Map to:

- `Sources/ProviderKit/ClaudeGroundedAnswerer.swift`
- `Sources/ProviderKit/ComputerUseAgent.swift`
- `Sources/ProviderKit/AssistMemory.swift`
- `Sources/CascadeMemory/CascadeMemory.swift`

For drafted messages, reports, summaries, or emails:

- Store generated draft metadata and later outcome: accepted, edited, discarded.
- When edited, store a diff summary, not raw content, unless the user opts into exemplars.
- Extract style features: length, greeting style, sign-off, directness, bullet density, hedging, punctuation, formatting.
- Build profile claims such as "prefers short direct email drafts" after repeated evidence.
- Inject only relevant style claims into drafting prompts.

Guardrails:

- Never infer sensitive identity or protected-class preferences.
- Never learn "auto-send" as a default from successful sends; sending remains explicit unless the user creates a saved agent with that behavior.
- Keep style memory separate from content memory.

### 7. Cold start

Map to:

- `Sources/AppShell/CascadeRootView.swift`
- `Sources/AppShell/CascadeAppModel.swift`
- Settings sheet / onboarding

Cold-start should combine neutral priors with optional explicit preferences:

- Start with current global defaults.
- Ask at most three setup choices: "show suggestions early vs only after strong evidence", "drafting tone", "background web agents preference."
- Use existing `dismissedWasteSignatures` and newly recorded declines to adapt fast.
- Show why a suggestion appeared: repeated count, time saved, and "you usually approve this kind of inbox cleanup."

Do not force setup. The system should improve from normal approve/decline behavior.

## Privacy Stance

Personalization should strengthen Cascade's local-first claim:

- All preference events and profiles live in the local Cascade SQLite database or local defaults.
- Raw screen images, OCR, and draft content are not uploaded for preference learning.
- Preference extraction stores compact claims and features, not private full-text histories.
- `PrivacyRules` must gate preference extraction just like recording and retrieval.
- Users can inspect, edit, disable, and delete learned preferences.
- Hard safety preferences override ranking: "never auto-send", "always ask before deleting", "do not act in banking/health apps."
- Audit all behavior-changing profile updates as `preference.learned`, `preference.updated`, or `preference.disabled`.
- If cloud sync ever exists, sync only explicit opt-in preferences; consider local differential privacy only for aggregate product telemetry, not personal automation logic.

The key UX promise: Cascade can learn how the user works without making the user's work data a server-side training asset.

## Quick Wins vs Larger Bets

### Quick Wins

1. Add `preference_event` logging for approve, decline, run, schedule, disable, delete, and draft edit outcomes.
2. Add a local `preference_profile` store with explicit "always/never/prefer" statements and confidence.
3. Use feedback to adjust `pendingCuratedAgents` ordering while keeping current hard declines.
4. Personalize `minRepeatsToAutomate` and `minSecondsToReview` by app/surface using simple counters.
5. Add style-memory bullets for drafts from repeated accepted edits, scoped by draft type.

### Larger Bets

1. Contextual Thompson sampling with logged propensities and offline replay evaluation.
2. Hierarchical memory retrieval: global profile, app profile, workflow profile, then detailed episode recollection only when uncertain.
3. On-device style exemplar selection for users who opt into storing local approved drafts.
4. Routine-profile timing: surface suggestions when the user usually acts on them and suppress during repeated dismissal windows.
5. A preference inspector UI in Settings with evidence, confidence, scopes, and one-click removal.

## Top Implementation Shape

The highest-leverage first pass is small:

- `CascadeMemory`: add `preference_event` and `preference_profile` tables plus append/query APIs.
- `CascadeAppModel`: record preference events in `approveCurated`, `declineCurated`, `setAgentEnabled`, `deleteAgent`, and agent run/schedule paths.
- `WasteDetector` / promotion layer: keep recall broad, but pass candidates through personalized thresholds before curation.
- `SuggestionEngine` / `pendingCuratedAgents`: rank with local reward priors before rendering.
- `AssistMemory`: stay short-term; feed durable profile snippets separately into prompts for planning and drafting.

This makes personalization measurable, reversible, private, and incremental.
