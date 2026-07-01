# SEQ-14 - Agent Observability, Tracing, Telemetry, and In-Product Eval

## Overview

Cascade already has the compliance substrate: `audit_event` is local, PII-redacted on append, hash-chained, and anchored out-of-band in the Keychain. It also has a reliability eval harness that emits JSONL metrics, plus specific audit rows such as `assist.timing` and `harness.slow`. What it does not yet have is an enterprise-grade trace model: a queryable tree that answers "what happened in this agent run, where did time and cost go, which model/tool failed, what evidence was used, and can I export it to my SIEM without leaking screen content?"

The relevant OSS and standards converge on one model:

- A run is a trace.
- Agent loops, workflow phases, model calls, tool calls, retrieval, validation, and evals are spans/events.
- Token usage, latency, failure kind, and cost are first-class numeric fields.
- Prompt, response, OCR, screenshot, and tool arguments are opt-in or redacted content, not required telemetry.
- Enterprise export should speak OpenTelemetry/OTLP for observability backends and JSON/CSV for audit/SIEM workflows.

For Cascade, the important product decision is to keep `audit_event` as the immutable compliance ledger and add derived trace tables optimized for querying, dashboards, and export. The trace layer should reference `recorded_context.id`, `input_event.id`, audit row ids, hashes, and redaction counts, but never embed raw OCR, raw screenshots, raw prompts, or raw tool results by default.

## OSS/Standards Table

| Project / Standard | URL | License / terms | Schema / technique | Cascade use |
|---|---|---|---|---|
| OpenTelemetry GenAI semantic conventions | [Docs](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/), [raw span model](https://raw.githubusercontent.com/open-telemetry/semantic-conventions/main/model/gen-ai/spans.yaml), [license](https://github.com/open-telemetry/semantic-conventions/blob/main/LICENSE) | Spec repo Apache-2.0; docs page is CC BY 4.0. | Defines GenAI client spans for inference, retrieval, create/invoke agent, execute tool, and invoke workflow. Key attrs include `gen_ai.provider.name`, `gen_ai.operation.name`, `gen_ai.request.model`, `gen_ai.response.model`, token usage, `error.type`, and opt-in content attrs. | Use as the external naming layer for Cascade spans. Map `runAssistEpisode` to `invoke_agent`, saved-agent replay to `invoke_workflow`, harness/tool calls to `execute_tool`, record search to `retrieval`, Anthropic calls to `chat`. |
| OTel GenAI metrics and eval events | [metrics.yaml](https://raw.githubusercontent.com/open-telemetry/semantic-conventions/main/model/gen-ai/metrics.yaml), [events.yaml](https://raw.githubusercontent.com/open-telemetry/semantic-conventions/main/model/gen-ai/events.yaml) | Apache-2.0. | Defines `gen_ai.client.token.usage`, `gen_ai.client.operation.duration`, streaming timing metrics, `gen_ai.evaluation.result`, and exception events. | Back `assist.timing` with structured metric rows; emit eval results from validators and LLM judges as span events instead of free-text audit rows. |
| OpenTelemetry Collector / OTLP | [Datadog Collector setup](https://docs.datadoghq.com/opentelemetry/setup/collector_exporter/), [Splunk OTLP exporter](https://help.splunk.com/en/splunk-observability-cloud/manage-data/splunk-distribution-of-the-opentelemetry-collector/get-started-with-the-splunk-distribution-of-the-opentelemetry-collector/collector-components/exporters/otlp-exporter) | Collector is Apache-2.0; Datadog/Splunk services are commercial. | OTLP traces/logs/metrics over gRPC or HTTP. Collector pipelines can route, batch, redact, and export to Datadog/Splunk. Logs correlate with traces through `trace_id` and `span_id`. | Export local traces as OTLP JSON or protobuf-compatible JSON, and provide a Collector config snippet. For SIEM, also export newline JSON with `trace_id`, `span_id`, `audit_event_id`, `failure_kind`, and redaction metadata. |
| Langfuse | [GitHub](https://github.com/langfuse/langfuse), [observability docs](https://langfuse.com/docs/observability/overview), [license](https://raw.githubusercontent.com/langfuse/langfuse/main/LICENSE) | Core MIT Expat; enterprise directories have separate licensing. | Hierarchical traces/observations, sessions, user metadata, scores, datasets, experiments, prompt management, OTel-compatible ingestion. | Strong reference for Cascade's in-product trace viewer: waterfall + observations + scores + filters by latency/cost/status, but implemented local-first. |
| Arize Phoenix | [GitHub](https://github.com/Arize-ai/phoenix), [docs](https://arize.com/docs/phoenix), [license](https://raw.githubusercontent.com/Arize-ai/phoenix/main/LICENSE) | Elastic License 2.0. | OTel-based AI observability and evaluation UI. Surfaces problematic spans by latency, token count, retrieval relevance, or eval score; supports datasets, experiments, playground/replay. | Reference for "show me the bad spans first": latency outliers, token spikes, repeated no-effect tool loops, failed validators, low judge scores. Do not reuse code without license review. |
| OpenInference | [GitHub](https://github.com/Arize-ai/openinference), [license](https://raw.githubusercontent.com/Arize-ai/openinference/main/LICENSE) | Apache-2.0. | Open standard for LLM application traces used with Phoenix; normalizes span attributes for prompts, LLM calls, retrievers, tools, agents, chains, and evals. | Use as a compatibility lens when OTel GenAI lacks a field Cascade needs. Prefer OTel names for export, but keep internal `cascade.*` attrs for local-only evidence links. |
| OpenLLMetry / Traceloop | [GitHub](https://github.com/traceloop/openllmetry), [docs](https://www.traceloop.com/docs/openllmetry/introduction), [license](https://raw.githubusercontent.com/traceloop/openllmetry/main/LICENSE) | Apache-2.0. | Auto-instrumentation for LLM providers, vector DBs, frameworks, and MCP; emits standard OTel data. Supports privacy control such as disabling trace content capture. | Useful technique, not a Swift dependency: instrument provider/tool boundaries centrally and make content capture a privacy setting. Cascade should default to content references only. |
| Helicone | [GitHub](https://github.com/Helicone/helicone), [OSS docs](https://docs.helicone.ai/references/open-source), [license](https://github.com/Helicone/helicone/blob/main/LICENSE) | Apache-2.0. | Proxy/gateway-style observability for LLM requests with cost, latency, quality, prompt/version experiments, and a large open pricing database. | Reference for model price cards and a cost ledger. Cascade can derive cost from token rows without proxying all traffic. |
| Datadog LLM Observability + OTel GenAI | [Datadog blog](https://www.datadoghq.com/blog/llm-otel-semantic-convention/) | Commercial service. | Native support for OTel GenAI conventions, dashboarding across model latency, tokens, errors, and spans. | Enterprise export target. Produce OTel-conformant attributes so a buyer can forward Cascade traces without bespoke mapping. |
| Splunk Observability / SIEM path | [Splunk OTLP exporter](https://help.splunk.com/en/splunk-observability-cloud/manage-data/splunk-distribution-of-the-opentelemetry-collector/get-started-with-the-splunk-distribution-of-the-opentelemetry-collector/collector-components/exporters/otlp-exporter) | Commercial service; Collector components are OTel-based. | OTLP exporter sends traces, metrics, and logs to Splunk Observability Cloud. SIEM-oriented export usually wants JSON log events with stable fields. | Offer both OTLP export and Splunk-friendly newline JSON/CSV. Include `trace_id`, `span_id`, `audit_event_id`, `actor`, `action`, `failure_kind`, `cost_microusd`, and redaction policy. |

## Concrete Trace/Export Design for Cascade

### Trace model

Keep `audit_event` unchanged as the append-only, hash-chained ledger. Add a query/index layer in `CascadeMemory` that records trace spans at the same time the app writes audit rows. Each trace/span row links back to one or more audit rows so the trace view can prove its source.

Recommended hierarchy:

```text
trace: agent run / assist episode / background sandbox run / saved recipe replay
  span: episode setup / permission preflight / planner turn / recipe step
    span: model call
    span: tool call
    span: retrieval / record search
    event: validation result / judge score / exception / stop
```

Use stable identifiers:

- `trace_id`: 16-byte hex or UUID-derived id per run.
- `span_id`: 8-byte hex per span.
- `parent_span_id`: tree edge.
- `audit_event_id`: source ledger row for the span start/end or event.
- `recorded_context_id`: evidence moment, never raw OCR.
- `input_event_id`: user or replay action reference.
- `prompt_sha256` / `response_sha256`: content fingerprints when a provider call is made.

### SQLite schema

Add these tables to `Sources/CascadeMemory/CascadeMemory.swift`, or split into `Sources/CascadeMemory/AgentTraceStore.swift` once the migration grows:

```sql
CREATE TABLE IF NOT EXISTS agent_trace (
  trace_id TEXT PRIMARY KEY,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  surface TEXT NOT NULL, -- assist, recipeReplay, backgroundWeb, recordQA
  actor TEXT NOT NULL,
  title TEXT NOT NULL,
  goal_hash TEXT,
  app_name TEXT,
  bundle_identifier TEXT,
  status TEXT NOT NULL, -- running, ok, failed, stopped, refused
  failure_kind TEXT,
  root_audit_event_id INTEGER REFERENCES audit_event(id),
  total_input_tokens INTEGER NOT NULL DEFAULT 0,
  total_cache_read_tokens INTEGER NOT NULL DEFAULT 0,
  total_cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
  total_output_tokens INTEGER NOT NULL DEFAULT 0,
  total_reasoning_tokens INTEGER NOT NULL DEFAULT 0,
  total_cost_microusd INTEGER NOT NULL DEFAULT 0,
  redaction_policy TEXT NOT NULL DEFAULT 'content-ref-only',
  metadata_json TEXT
);

CREATE TABLE IF NOT EXISTS agent_span (
  span_id TEXT PRIMARY KEY,
  trace_id TEXT NOT NULL REFERENCES agent_trace(trace_id),
  parent_span_id TEXT REFERENCES agent_span(span_id),
  audit_event_id INTEGER REFERENCES audit_event(id),
  kind TEXT NOT NULL, -- run, step, tool, model, retrieval, eval, export
  name TEXT NOT NULL,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  duration_ms INTEGER,
  status TEXT NOT NULL,
  failure_kind TEXT,
  gen_ai_operation TEXT,
  model_provider TEXT,
  model_name TEXT,
  tool_name TEXT,
  tool_type TEXT,
  app_name TEXT,
  recorded_context_id INTEGER REFERENCES recorded_context(id),
  input_event_id INTEGER REFERENCES input_event(id),
  input_tokens INTEGER NOT NULL DEFAULT 0,
  cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
  cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
  cost_microusd INTEGER NOT NULL DEFAULT 0,
  prompt_sha256 TEXT,
  response_sha256 TEXT,
  attributes_json TEXT
);

CREATE TABLE IF NOT EXISTS trace_event (
  event_id TEXT PRIMARY KEY,
  trace_id TEXT NOT NULL REFERENCES agent_trace(trace_id),
  span_id TEXT REFERENCES agent_span(span_id),
  audit_event_id INTEGER REFERENCES audit_event(id),
  created_at TEXT NOT NULL,
  name TEXT NOT NULL,
  severity TEXT NOT NULL DEFAULT 'info',
  failure_kind TEXT,
  attributes_json TEXT
);

CREATE TABLE IF NOT EXISTS model_cost_ledger (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  trace_id TEXT NOT NULL REFERENCES agent_trace(trace_id),
  span_id TEXT NOT NULL REFERENCES agent_span(span_id),
  created_at TEXT NOT NULL,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  price_card_version TEXT NOT NULL,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
  cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
  cost_microusd INTEGER NOT NULL DEFAULT 0,
  billable INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS trace_eval (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  trace_id TEXT NOT NULL REFERENCES agent_trace(trace_id),
  span_id TEXT REFERENCES agent_span(span_id),
  created_at TEXT NOT NULL,
  evaluator_kind TEXT NOT NULL, -- rule, verifier, llm_judge, human
  evaluator_name TEXT NOT NULL,
  score_value REAL,
  score_label TEXT,
  explanation_redacted TEXT,
  confidence REAL,
  source_span_id TEXT REFERENCES agent_span(span_id)
);

CREATE INDEX IF NOT EXISTS idx_agent_span_trace_started
  ON agent_span(trace_id, started_at);
CREATE INDEX IF NOT EXISTS idx_agent_trace_started
  ON agent_trace(started_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_trace_status_failure
  ON agent_trace(status, failure_kind);
CREATE INDEX IF NOT EXISTS idx_model_cost_trace
  ON model_cost_ledger(trace_id, created_at);
```

Do not place these rows in the audit hash chain directly; they are mutable/query-optimized derived state. Instead, write compact `audit_event` rows for trace boundaries and export actions, then link derived rows to those immutable row ids.

### Internal event API

Add a small typed recorder so AppShell and ProviderKit do not hand-roll telemetry strings:

- `Sources/AgentOrchestrator/AgentTraceRecorder.swift`
- `Sources/CascadeMemory/AgentTraceModels.swift`
- `Sources/CascadeMemory/AgentTraceStore.swift`
- `Sources/ProviderKit/ModelUsage.swift`
- `Sources/AppShell/TraceExplorerView.swift`
- `Sources/AppShell/TraceExportSheet.swift`

Minimal Swift API:

```swift
public protocol AgentTraceRecording: Sendable {
    func beginTrace(_ input: TraceStart) async throws -> TraceContext
    func beginSpan(_ input: SpanStart, in trace: TraceContext) async throws -> SpanContext
    func endSpan(_ span: SpanContext, _ result: SpanResult) async throws
    func recordEvent(_ event: TraceEventInput, in span: SpanContext?) async throws
    func recordModelUsage(_ usage: ModelUsage, in span: SpanContext) async throws
    func endTrace(_ trace: TraceContext, _ result: TraceResult) async throws
}
```

Attach it at these boundaries:

- `CascadeAppModel.runAssistEpisode` and Scout path: trace root, one span per turn, one model span per planner call, events for no-effect/stall/validate.
- `BackgroundWebAgent`: trace root per sandbox run, spans for planner, DOM action, harness, verification.
- `CascadeAppModel.runAgentRecipe`: root for saved agent replay, step spans for each `RecipeStep`, tool/action spans for click/key/type/drag/openApp.
- `ClaudeGroundedAnswerer` / record Q&A: retrieval spans for `search_record`, `get_timeframe`, `inspect_moment`; model spans for answer synthesis; eval events for citation coverage.
- `ProviderKit.AnthropicClient`: model span fields from API usage: input/cache/output/reasoning tokens and response id.
- `AgentHarness`: `execute_tool` spans for `search_files`, `list_folder`, `read_file`, `run_command`, `run_applescript`, `write_file`, with arguments summarized and content omitted.

### OTel export mapping

Export each `agent_trace` / `agent_span` tree as OTLP-style JSON:

```json
{
  "traceId": "8e1b6a7e8d7c4c2e9c4f1a5b5f7a9d21",
  "spanId": "6e8b4f1ac9134a11",
  "parentSpanId": "18b3c2d4e5f60708",
  "name": "execute_tool run_command",
  "kind": "SPAN_KIND_INTERNAL",
  "startTimeUnixNano": 1782486000000000000,
  "endTimeUnixNano": 1782486000123000000,
  "status": { "code": "STATUS_CODE_OK" },
  "attributes": {
    "service.name": "com.humain.cascade",
    "gen_ai.operation.name": "execute_tool",
    "gen_ai.tool.name": "run_command",
    "gen_ai.tool.type": "local_shell",
    "cascade.trace.surface": "assist",
    "cascade.audit_event.id": 1842,
    "cascade.redaction.policy": "content-ref-only",
    "cascade.recorded_context.id": 991,
    "cascade.prompt.sha256": "..."
  }
}
```

OTel privacy defaults:

- Do not export `gen_ai.input.messages`, `gen_ai.output.messages`, `gen_ai.system_instructions`, `gen_ai.tool.call.arguments`, or `gen_ai.tool.call.result` unless an admin explicitly creates a redacted diagnostic bundle.
- Do export token counts, costs, status, failure kind, model name, provider, operation, app name, bundle id, moment ids, and hashes.
- Use `error.type` for stable low-cardinality values, preferably `AgentFailureKind.rawValue`.

### JSON / CSV / SIEM export

Add export choices in AppShell:

- `OTel JSON`: span tree for Datadog, Splunk Observability, Honeycomb, or an OTel Collector.
- `SIEM JSONL`: one event per line, flattened and stable for Splunk HEC / Datadog Logs.
- `CSV`: trace and cost summary for security/procurement review.
- `Cascade Bundle`: local-only diagnostic zip with trace JSON, audit proof rows, thumbnails by `recorded_context.id`, and redaction manifest.

SIEM JSONL row shape:

```json
{
  "timestamp": "2026-06-26T14:22:17.123Z",
  "product": "Cascade",
  "trace_id": "8e1b...",
  "span_id": "6e8b...",
  "parent_span_id": "18b3...",
  "surface": "assist",
  "actor": "agent",
  "span_kind": "tool",
  "operation": "execute_tool",
  "name": "run_command",
  "status": "ok",
  "failure_kind": null,
  "duration_ms": 123,
  "input_tokens": 0,
  "output_tokens": 0,
  "cost_microusd": 0,
  "audit_event_id": 1842,
  "recorded_context_id": 991,
  "redaction_policy": "content-ref-only"
}
```

CSV summaries:

- `traces.csv`: trace id, started, ended, surface, app, status, failure kind, total duration, model duration, tool duration, token totals, cost.
- `spans.csv`: trace id, span id, parent span id, kind, name, status, failure kind, duration, model/tool, audit row id.
- `costs.csv`: provider, model, date, trace id, token columns, price card version, cost.
- `evals.csv`: trace id, span id, evaluator, score, label, confidence, failure kind.

### In-product viewer

Replace the current "8-row activity feed only" ceiling with a local Trace Explorer under Cascades / Activity or a Manager "Observability" tab:

- Filter: date, surface, app, agent, status, failure kind, model, tool, cost range, latency range, eval score.
- Trace detail: waterfall tree, selected span inspector, linked audit rows, linked evidence moments, token/cost breakdown, failure classification.
- Dashboards: p50/p95 run latency, model latency, tool latency, total spend, spend by model, failures by `AgentFailureKind`, no-effect loops, validator-incomplete rate, user-stop rate, top slow harness calls.
- Replay inspection: timeline of span events with local thumbnails retrieved by `recorded_context.id`; never export screenshots by default.
- Quality panel: validator result, LLM-as-judge score, human override, and drift over time for the same agent.

### Privacy guardrails

Default policy: content-reference telemetry.

- Store raw OCR and screenshots only where Cascade already stores them: `recorded_context`, under existing retention and privacy rules.
- Trace rows only store ids, hashes, redaction counts, token counts, model/tool names, durations, status, and failure kinds.
- Exporters must run `PIIDetector` over any free-text field before writing files.
- Include a redaction manifest in every export: policy, timestamp, app version, omitted fields, redacted field counts, and whether screenshots/prompts/tool payloads were included.
- Admin-only diagnostic mode may include redacted prompt/tool snippets, but it must be off by default and audited as `trace.export.diagnostic`.

## Quick Wins vs Larger Bets

### Quick wins

1. Add `trace_id` and `span_id` to existing audit `detail` JSON for `assist.timing`, `harness.*`, `sandbox.*`, `recipe.*`, and `agent.run.completed`.
2. Create `agent_trace`, `agent_span`, and `model_cost_ledger` tables with no UI change; populate from the assist, recipe replay, background web, and record Q&A paths.
3. Normalize provider usage in `ProviderKit.ModelUsage`: input tokens, cache read/create tokens, output tokens, reasoning tokens, response id, model, provider.
4. Add cost cards for Anthropic/OpenAI models as versioned local data; calculate `cost_microusd` with integer math.
5. Build CSV + SIEM JSONL export first. It is low-risk and immediately useful to enterprise buyers.
6. Add a simple AppShell trace list/detail view: filters, span tree, linked audit rows, token/cost totals.
7. Emit `gen_ai.evaluation.result`-equivalent rows from existing validators before adding LLM judges.

### Larger bets

1. Full OTel exporter with OTLP protobuf or Collector-ready JSON and sample Collector configs for Splunk/Datadog.
2. Online LLM-as-judge eval for completed traces: success, harmful side effect, repeated/no-op behavior, evidence sufficiency. Store judge prompts by version and audit every run.
3. Trace replay UI with side-by-side local thumbnails, AX/OCR evidence, tool/result summaries, and verifier outcomes.
4. Cost governance: budgets per agent, model, app, or day; warnings in the notch/Manager when a run is likely to exceed budget.
5. Trace-derived self-improvement: recurring failure clusters feed `AgentFailureKind`-scoped repair memories and learned skills, but only when backed by verifier/audit evidence.
6. Enterprise admin policy: export destinations, retention windows, diagnostic bundle approval, field allow/deny lists, and signed export manifests.

## Proposed Trace Schema Summary

The minimum viable design is:

- `agent_trace`: one row per agent run/episode, totals and terminal outcome.
- `agent_span`: tree nodes for run, step, model, tool, retrieval, eval, export.
- `trace_event`: low-cardinality events attached to spans.
- `model_cost_ledger`: integer micro-USD accounting per model span.
- `trace_eval`: verifier, LLM-judge, human, or rule score per trace/span.

This model turns Cascade's audit trail into something an enterprise can search and export while keeping the legal/audit invariant intact: the ledger proves what happened, the trace store explains it, the cost ledger prices it, and exports reference local evidence by id instead of carrying sensitive screen content out of the device.
