# Research Sequence 5: Prompt & Harness

## Overview

Cascade already has a strong Anthropic harness: the screen agent uses the current computer-use beta, adaptive thinking, streaming, moving cache breakpoints, batched action plans, screenshot pruning, STOP/audit gates, and a native tool layer that avoids raw coordinate clicks. The main production gaps are now in consistency, cost accounting, and context hygiene rather than raw capability.

The highest-leverage changes are to standardize Claude calls behind a richer Messages API client, use Anthropic structured outputs and strict tools for every brittle JSON/citation path, move dynamic context out of cacheable prefixes, add preflight token/cost budgeting, and introduce targeted evaluator/reflection turns only after no-effect or high-risk action loops. Anthropic's current guidance also reinforces a key design choice Cascade already made: keep GUI control as a tight single-agent loop, and use multi-agent orchestration only for broad research or record-search tasks where independent context windows create value.

Model verification from current Anthropic docs: `claude-opus-4-8`, `claude-sonnet-4-6`, and `claude-haiku-4-5` / `claude-haiku-4-5-20251001` are valid current model identifiers. The current computer-use beta for Opus 4.8 / Sonnet 4.6 is `computer-use-2025-11-24`, matching Cascade's primary screen-agent header.

## Best Practices & Sources

| source | url | technique |
| --- | --- | --- |
| Anthropic prompting best practices | https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices | Start with eval criteria, be clear/direct, use sequential instructions, examples, XML/Markdown sections, and put long reference context before the final query/instructions. |
| Anthropic prompt caching | https://platform.claude.com/docs/en/build-with-claude/prompt-caching | Cache stable system/tool prefixes; measure `cache_read_input_tokens`, `cache_creation_input_tokens`, and `input_tokens`; use 1h TTL for expensive stable prefixes; preserve thinking blocks when possible. |
| Anthropic tool definition guide | https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools | Tool descriptions should state what the tool does, when to use it, parameter meaning, caveats, and examples; consolidate related tools and return high-signal results. |
| Anthropic strict tool use | https://platform.claude.com/docs/en/agents-and-tools/tool-use/strict-tool-use | Add `strict: true` for JSON-Schema-compliant tool inputs via grammar-constrained sampling; schemas are cached separately and are best for agentic workflows. |
| Anthropic structured outputs | https://platform.claude.com/docs/en/build-with-claude/structured-outputs | Use `output_config.format` JSON schemas for final JSON outputs; avoids missing fields, malformed JSON, and ad hoc parsing; keep schemas stable because changes affect cache behavior. |
| Anthropic token counting | https://platform.claude.com/docs/en/build-with-claude/token-counting | Use `/v1/messages/count_tokens` before expensive requests, including tools/images/PDFs, to route model/effort/resolution and enforce budgets before spending. |
| Anthropic context windows | https://platform.claude.com/docs/en/build-with-claude/context-windows | Larger context is not automatically better; context rot increases when irrelevant content accumulates, so curation matters more than raw window size. |
| Anthropic context editing | https://platform.claude.com/docs/en/build-with-claude/context-editing | Clear old tool results or thinking blocks when context pressure is high; this can invalidate cache but is worthwhile when enough low-value context is removed. |
| Anthropic compaction | https://platform.claude.com/docs/en/build-with-claude/compaction | Use custom summarization instructions and `pause_after_compaction` style control for long-running agents; track compaction count and budget. |
| Anthropic adaptive thinking | https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking | Adaptive thinking is recommended for Opus 4.8 and Sonnet 4.6; `max_tokens` is the hard output cap while effort controls the thinking/action tradeoff. |
| Anthropic effort | https://platform.claude.com/docs/en/build-with-claude/effort | Effort affects response tokens, thinking, and tool calls; lower effort may reduce tool calls, while high/xhigh should be reserved for hard autonomy or verifier escalations. |
| Anthropic computer-use tool | https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool | Use `enable_zoom`, accurate display dimensions, sandboxing, least privilege, human confirmation for sensitive actions, and an explicit tool-result loop. |
| Anthropic pricing | https://platform.claude.com/docs/en/about-claude/pricing | Prompt-cache reads are much cheaper than fresh input; output tokens dominate Opus/Sonnet costs, so action-loop max tokens and effort need per-episode accounting. |
| Anthropic model overview | https://platform.claude.com/docs/en/about-claude/models/overview | Verifies current model identifiers and feature compatibility for Opus 4.8, Sonnet 4.6, and Haiku 4.5. |
| Anthropic Opus 4.8 migration guide | https://platform.claude.com/docs/en/about-claude/models/migration-guide | Opus 4.8 supports adaptive thinking, prompt caching, tools, 1M context, lower 1,024-token cache minimum, mid-conversation system messages, and task-budget beta; re-baseline effort/cost. |
| Anthropic Tool Runner SDK | https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-runner | Reference pattern for automatic tool loops, `max_iterations`, tool error propagation, compaction, and managed message history. |
| Claude Agent SDK | https://code.claude.com/docs/en/agent-sdk/overview | Reference implementation for agent sessions, tool permissioning, hooks, subagents, MCP integration, checkpointing, usage tracking, OpenTelemetry, and built-in file/shell/browser tools. |
| Building Effective Agents | https://www.anthropic.com/engineering/building-effective-agents | Prefer simple composable patterns; use agents only when flexible model planning justifies latency/cost; give tools good agent-computer interfaces, stopping conditions, and ground-truth feedback. |
| Effective context engineering | https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents | Keep the smallest high-signal context; use progressive disclosure, lightweight identifiers, structured note-taking, compaction, subagents, and right-altitude system prompts. |
| Writing tools for agents | https://www.anthropic.com/engineering/writing-tools-for-agents | Tool names and schemas are part of the prompt; use namespaced, semantic tool names and concise result formats that are easy for agents to interpret. |
| Anthropic multi-agent research system | https://www.anthropic.com/engineering/multi-agent-research-system | Lead-agent/subagent/citation-agent pattern is useful for breadth-first research; scale subagents and tool calls by query complexity, but expect high cost. |
| Anthropic computer-use demo | https://github.com/anthropics/claude-quickstarts/tree/main/computer-use-demo | OSS exemplar for a sandboxed computer-use loop with prompt caching, image sizing, trajectory recording, shell sandboxing, and production-hardening references. |
| ReAct | https://arxiv.org/pdf/2210.03629 | Interleave reasoning and acting so the model updates plans from observations instead of committing to a stale plan. |
| Reflexion | https://arxiv.org/pdf/2303.11366 | Store concise verbal lessons from failed trajectories and use them to avoid repeated mistakes on later attempts. |
| Self-consistency | https://arxiv.org/abs/2203.11171 | Sample or compare multiple reasoning paths for high-stakes answers; in Cascade, use sparingly as an evaluator/critic rather than for every GUI action. |

## Concrete Techniques to Adopt

### 1. Replace brittle JSON extraction with structured outputs

**Files/functions:** `Sources/ProviderKit/Planner.swift` (`ClaudeSingleStepPlanner.parse`), `Sources/ProviderKit/ElementLocator.swift` (`callRegion`), `Sources/ProviderKit/RecordSearchAnswerer.swift` (`answerAgentically`, final answer parsing), `Sources/ProviderKit/ClaudeAnswerer.swift` when citation metadata is needed.

Cascade currently asks for JSON in prose and extracts the first `{...}` substring. That is fragile under refusals, diagnostics, truncation, or a model that adds a preface. Use Anthropic `output_config.format` JSON schemas for helper calls that return data instead of UI prose.

Implement stable schemas such as:

- `PlannedStep`: `{ "action": enum, "target": string|null, "app": string|null, "url": string|null, "text": string|null, "confidence": number, "reason": string }`.
- `RegionMatch`: `{ "box": [x,y,w,h] | null, "say": string, "confidence": number }`.
- `RecordAnswer`: `{ "answer": string, "cited_moment_ids": [integer], "uncertainty": string|null }`.

Keep `additionalProperties: false` and validate numeric bounds client-side. This is a quick win because it leaves behavior intact while removing regex parsing and final `SOURCES:` conventions.

### 2. Add strict schemas and examples to stable custom tools

**Files/functions:** `ComputerUseAgent.makeToolDefinitions()`, `fillToolDefinitions()`, `extraToolDefinitions`, `harnessToolDefinitions()`, `RecordRecall.toolDefinitions()`.

Anthropic strict tool use can guarantee tool inputs match JSON Schema. Cascade's custom tools already have typed input schemas, but most omit `strict: true`, `additionalProperties: false`, and `input_examples`. Add these for stable tools: `click_target`, `fill_target`, `fill_field`, `type_text`, `press_key`, `scroll`, `wait`, `open_app`, `open_url`, `highlight`, `search_record`, `get_timeframe`, and `inspect_moment`.

Do not try to strict-wrap the built-in computer tool. For dynamic `extraTools`, only enable strict mode when the schema is stable and schema-compatible. For Scout's Groq/non-Anthropic JSON mode, keep runtime validators because Anthropic strict tools are not available there.

### 3. Unify Anthropic request construction and telemetry

**Files/functions:** `AnthropicClient.swift`, `ComputerUseAgent.proceed`, `RecordSearchAnswerer.send`, `ClaudeSingleStepPlanner.planNextStep`, `ElementLocator.callRegion`, `ClaudeGroundedAnswerer.answer`.

`ComputerUseAgent` has the mature request stack: streaming, adaptive thinking, cache control, usage logging, tool loops, retry handling, and stop-reason awareness. `AnthropicClient.complete` is a thin text-only helper with no tools, cache control, structured outputs, thinking config, usage metrics, or stop-reason handling.

Create a shared `AnthropicMessagesClient` that supports:

- `tools`, `tool_choice`, `cache_control`, `thinking`, `output_config`, `stream`/non-streaming.
- Structured output schemas and strict tool definitions.
- `usage` return values and stop-reason/stop-sequence capture.
- A common retry policy that does not retry after side effects.
- Optional count-token preflight.

Then migrate the helper agents onto it. This avoids each helper independently rediscovering prompt-cache, JSON, and token-accounting rules.

### 4. Move dynamic notes out of cacheable prefixes

**Files/functions:** `ComputerUseAgent.systemPrompt(...)`, `RecordSearchAnswerer.systemPrompt()`, `ClaudeGroundedAnswerer` system construction, `ClaudeSingleStepPlanner` prompts.

Prompt caching works best when the cached prefix is byte-stable. Cascade currently does well by cache-marking tool definitions, but several prompts include dynamic context in the same prefix as stable policy text:

- `RecordSearchAnswerer.systemPrompt()` includes `Date()` directly in the system prompt, so repeated calls have a different prefix.
- `ComputerUseAgent.systemPrompt(...)` appends `environmentNote`, `harnessNote`, `recallNote`, and optional extra notes to the system string; if those vary per turn/episode, they can reduce cache reuse of otherwise stable prompt text.

Adopt a strict split:

- Stable system: role, safety policy, tool-use contract, output contract.
- Dynamic context: current date/time, frontmost app/window, environment note, recall memo, failed-action memo, and task-specific instruction in a late user block or non-cache-marked message.
- Stable tools: cache at the last stable tool with `ttl: "1h"` where available.

For Sonnet/Haiku compatibility, prefer a late user context block for dynamic notes unless the specific model/API path is verified to support mid-conversation system messages.

### 5. Add preflight token and cost budgeting

**Files/functions:** `ComputerUseAgent.proceed`, `RecordSearchAnswerer.answerAgentically`, `ClaudeSingleStepPlanner`, `ElementLocator`, future shared `AnthropicMessagesClient`.

Cascade logs post-hoc usage in the screen agent, but production cost control needs preflight estimates. Use Anthropic token counting before expensive requests that include tools, images, or long record snippets.

Implement an `EpisodeBudget` that tracks:

- Estimated tokens before request via `/v1/messages/count_tokens`.
- Actual `input_tokens`, `output_tokens`, `cache_read_input_tokens`, and `cache_creation_input_tokens` after request.
- Estimated dollars from current model pricing.
- Action count, no-effect count, screenshot count, and cache hit ratio.

Use it to select model/effort/resolution:

- Default GUI action loop: Sonnet 4.6 + adaptive thinking + medium effort.
- Stuck/no-effect escalation: one verifier turn, possibly higher effort, not a permanent higher-cost mode.
- Broad record research: Sonnet by default; Opus only for high-value synthesis or repeated low-confidence answers.
- Haiku: simple extraction/classification without visual ambiguity.

Do not raise effort globally. Anthropic guidance frames effort as a cost/latency tradeoff; Cascade should route it by episode state.

### 6. Add context editing or local equivalent for long tool traces

**Files/functions:** `ComputerUseAgent.pruneScreenshots`, `pruned(messages:)`, `RecordSearchAnswerer` multi-hop loop, future shared client.

Cascade prunes old screenshots, which is correct, but long episodes can still accumulate low-value tool results, old failed observations, and repeated harness outputs. Add a context-pressure path:

- First, locally summarize or replace old tool results with compact records: `{tool, intent, status, key_ids, evidence, error}`.
- For Anthropic-supported paths, evaluate API context editing/tool-result clearing when the request is large enough that clearing beats cache invalidation.
- Preserve audit data in SQLite; context clearing is only for the model conversation.
- Keep the last few screen observations verbatim; summarize older observations into an `episode_state` block.

This aligns with Anthropic's context-rot guidance while preserving Cascade's audit-first product requirement.

### 7. Refactor the computer-use prompt into stable, testable sections

**Files/functions:** `ComputerUseAgent.systemPrompt`, `structuralSystemPrompt`, `harnessPowerNote`, `harnessReadOnlyNote`, `recallMemoryNote`.

The current prompt is behaviorally rich but monolithic. Split it into named sections so eval failures can target one policy at a time:

- `<role_and_goal>`: operate the user's Mac, not a simulated environment.
- `<screen_action_contract>`: act inside the target app, no Terminal/scripts unless asked, use visible evidence.
- `<tool_contract>`: target-naming tools, batching rules, fill tools, wait rules.
- `<harness_contract>`: one-lane-per-step, read-only vs power tools.
- `<safety_and_audit>`: STOP, permissions, no secret extraction, no high-risk side effects without confirmation.
- `<completion_contract>`: do not say done until evidence supports completion; include concise final summary.

Keep incident-specific rules in code/evals when possible. The prompt should express stable principles; guards and deny-lists should remain executable policy.

### 8. Add targeted reflection/verification turns after no-effect loops

**Files/functions:** `ComputerUseAgent` no-effect/stall handling, `CascadeOrchestrator` run loop, `AgentRunState`, `AssistMemory`.

Cascade already has stall/no-effect nudges. Add a small verifier only when needed:

- Trigger after two no-effect observations, repeated target failure, or before a high-risk irreversible action.
- Input: previous screenshot, current screenshot, last 3 actions, intended outcome, current app/window.
- Output schema: `{ "state": "progress"|"wrong_target"|"needs_wait"|"blocked"|"needs_user"|"done", "next_strategy": string, "avoid": [string] }`.
- If the same failure repeats, store a Reflexion-style lesson in episode memory or a pending learned skill.

This should not run every turn. It is a production guard for costly loops and duplicated work, not a general planning layer.

### 9. Make record search more agentic only for broad questions

**Files/functions:** `RecordSearchAnswerer`, `RecordRecall`, possible future `RecordResearchOrchestrator`.

Anthropic's multi-agent research pattern is appropriate for broad, independent research, not for tight GUI control. For questions like "what did I work on last week?" or "find the source of this decision," add an optional breadth mode:

1. A lead planner emits 2-5 independent search intents.
2. Each subquery runs `search_record` / `get_timeframe` in its own compact context.
3. A synthesis pass combines findings.
4. A citation pass validates cited moment IDs exist and support the answer.

Gate this behind query complexity and budget. Anthropic reports multi-agent systems can be much more expensive than chat; Cascade should use this only when breadth materially improves recall.

### 10. Use Claude Agent SDK as a parity reference, not a rewrite target

**Files/functions:** `AgentHarness.swift`, `ComputerUseAgent`, `CascadeOrchestrator`, audit/event storage.

The Claude Agent SDK is a useful checklist for production agent ergonomics: tool permissions, hooks, sessions, subagents, checkpointing, cost tracking, OpenTelemetry, and first-class file/shell/browser tools. Cascade should keep the Swift-native harness, but borrow the patterns:

- Pre-tool and post-tool hooks around every harness/computer action.
- Per-run checkpoints and resumable state.
- Structured telemetry spans for model calls, cache hits, tool calls, screenshots, and user interrupts.
- A single permission model that is visible in Settings and enforced in code.

## Quick Wins vs Larger Bets

### Quick wins

- Add `output_config.format` schemas to `ClaudeSingleStepPlanner`, `ElementLocator.callRegion`, and `RecordSearchAnswerer` final answers.
- Move `Date()` and other dynamic notes out of `RecordSearchAnswerer.systemPrompt()` and any cacheable system prefix.
- Add `strict: true`, `additionalProperties: false`, and `input_examples` to stable custom tool definitions.
- Add token usage logging to all Anthropic helper calls, not just `ComputerUseAgent`.
- Add count-token preflight for image/tool-heavy requests and record-search multi-hop calls.
- Split `ComputerUseAgent.systemPrompt` into stable named sections without changing behavior.
- Add an `is_error`/structured-status convention for harness and recall tool failures so the model can distinguish tool failure from an empty result.
- Add cache-hit ratio and estimated cost to existing `llm.usage` audit rows.

### Larger bets

- Build a shared `AnthropicMessagesClient` and migrate all Claude helpers onto it.
- Add API context editing or local tool-result compaction for long-running screen episodes.
- Add an evaluator/critic turn after no-effect loops and feed repeated lessons into `AssistMemory` or learned skills.
- Add token-aware model/effort/resolution routing with explicit episode budgets.
- Add a breadth-first multi-agent mode for complex record-research questions with citation validation.
- Add Agent SDK-style telemetry, checkpoints, and hook semantics around Swift-native tools.
- Create a prompt/harness eval suite that replays known failure trajectories and asserts tool choices, cache behavior, budget, and final evidence.

## Risks

- Strict tools and structured outputs add first-call grammar compilation latency. Keep schemas stable to benefit from Anthropic's schema caching.
- Schema changes, `output_config` changes, and `tool_choice` changes can reduce prompt-cache reuse. Treat schemas and toolsets as versioned artifacts.
- Moving dynamic context out of the system prompt can reduce salience if the late context block is not clearly labeled. Validate with screen-agent evals.
- Context editing and tool-result clearing can remove evidence the model needs. Preserve audit data outside the model context and clear only old, low-value tool results.
- Higher effort or Opus escalation can improve hard tasks but may make real-time cursor control feel slow. Gate escalation on no-effect, ambiguity, or explicit user intent.
- Reflection turns can become another loop if they are not bounded. Limit them to one verifier pass per failure cluster.
- Multi-agent research can cost an order of magnitude more than single-agent chat. Use it for breadth-heavy memory questions, not ordinary Q&A.
- Fable 5 appears in current Anthropic docs, but Cascade should not change model constants without fresh compatibility, latency, and cost evals for computer use, tool loops, and prompt caching.
- The computer-use tool remains a security-sensitive beta surface. Least privilege, STOP gating, human confirmation, sandboxing, and audit logs should stay as executable code, not prompt-only promises.
