# Plan A — Audit Viewer + Export

Status: proposed · Author: audit follow-up · Date: 2026-06-13
Scope: turn the local `audit_event` log into a first-class, filterable, exportable surface.
Companion: see `docs/FEATURES.md` §8 (Trust, safety) for the current audit surface.

## Why

Cascade is pitched as an **audit-first** product (every agent/computer/harness action lands
in `audit_event`), but the log only surfaces as `agentActivity.prefix(8)` in the Cascades tab
(`CascadeRootView.swift:1401`) — 8 rows, no filter, no search, no range, no export. The data is
already rich and indexed; it just has no front door. This is the cheapest credibility win in the
repo and the artifact an enterprise security review / SOC 2 auditor asks for first.

## Where we are now (grounded)

| Piece | Location | State |
|---|---|---|
| Row model | `AuditEvent` (`id`, `createdAt`, `actor`, `action`, `detail`) | `CascadeMemory.swift:51–65` | clean, `Codable`, `Sendable` |
| Storage | `audit_event` table, index `idx_audit_event_created_at` on `created_at DESC` | `CascadeMemory.swift:877–885` | indexed by time |
| Write | `appendAudit(_:)` | `CascadeMemory.swift:819` | audit-first invariant respected |
| Read | `recentAudit(limit: Int = 80)` | `CascadeMemory.swift:837` | capped; no filter / paging / range |
| Model | `@Published audit: [AuditEvent]`, loaded once | `CascadeAppModel.swift:91, 243` | single 80-row load |
| View | `activitySection` → `agentActivity.prefix(8)` | `CascadeRootView.swift:1395–1405` | 8 rows, buried in Cascades |

## Design

### 1. Query layer (`CascadeMemory`) — additive, `recentAudit` stays
- `func queryAudit(actor: String?, action: String?, since: Date?, until: Date?, search: String?, limit: Int, offset: Int) -> [AuditEvent]`
  — parameterized SQL over the existing `created_at DESC` index; `action`/`detail` matched with
  `LIKE` for free-text search; `action` filter is prefix-aware (`step.`, `agent.`, `harness.`, `ghost.`).
- `func auditActors() -> [String]` / `func auditActions() -> [String]` — `DISTINCT` enumerations
  to populate the filter dropdowns.

### 2. Export
- `func exportAuditCSV(_ rows: [AuditEvent]) -> String` — RFC-4180 escaping (commas / quotes /
  newlines inside `detail`).
- JSON export via the existing `Codable` conformance.
- Wire to an `NSSavePanel`.
- **Self-audit the export**: append `AuditEvent(actor: "employee", action: "audit.export", detail: …)`
  — exporting a surveillance log is itself a privacy event and belongs in the log it exports.

### 3. UI — promote audit to a first-class surface
- A Settings → "Audit log" sheet (or a 4th tab; sheet is lower blast radius).
- Filter bar: actor · action-prefix · date range · free-text.
- Virtualized `List` (paged via `limit`/`offset`), newest first.
- Row → tap jumps to that `createdAt` moment in the Reel, reusing the existing
  `jumpToMoment` / `reelJumpTarget` plumbing — every audited action becomes clickable proof,
  mirroring the Reel's citation chips.

### 4. Retention honesty
- Surface the 7-day / 5 GB prune boundary so an empty older range reads as "pruned," not
  "nothing happened."

## Phases

- **A1** — `queryAudit` + actor/action enumerations + tests.
- **A2** — CSV/JSON export + save panel + the `audit.export` self-audit row.
- **A3** — the filterable viewer UI + Reel jump.

## Tests

- `queryAudit` filter / range / paging correctness (hermetic in-memory DB).
- CSV escaping for commas / quotes / newlines in `detail`.
- The `audit.export` row is appended on export.
- Empty-range vs pruned-range distinction.

## Effort / risk

Small–medium. One query function, one export function, one view. No new dependencies, no
hot-path changes — `recentAudit` and the write path are untouched.
