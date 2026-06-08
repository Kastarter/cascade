# Cascade Native Architecture

## Product Principle

Cascade is an enterprise work-context recorder first. Agents are downstream of context, evidence, review, and verification. The app must help an employee understand what happened locally before it suggests that anything should act on their behalf.

## Module Boundaries

`CascadeApp`
: SwiftUI app entry, menu bar status item, bundle resources, app commands. It owns app launch only.

`AppShell`
: Native UI composition and view models. It may call high-level services, but it must not call ScreenCaptureKit, AX, SQLite, or provider SDKs directly.

`CascadeDesignSystem`
: Shared colors, button styles, cards, and small visual primitives. Keep this tiny and native.

`CascadeMemory`
: SQLite persistence for recorded context and audit events. No UI, no provider logic, no permission logic.

`MacContextKit`
: macOS observation: permission preflight, app/window metadata, and context recording. ScreenCaptureKit and OCR ports will live here. It must fail closed when Screen Recording is denied.

`ComputerUseKit`
: Native action transport and visible controls: click, key, type, scroll, cursor/overlay, STOP/control dock. It depends on permission health and should never act when health is not ready.

`SuggestionEngine`
: Deterministic evidence rules. No random "AI ideas." A suggestion must have repeated context, evidence strings, a confidence, and a `doable` flag.

`ProviderKit`
: Model/provider adapters. BYOK, Anthropic/OpenAI/local adapters, and error normalization live here. UI and drivers consume protocols, not provider clients.

`AgentOrchestrator`
: One `AgentDriver` interface:

```swift
observe() -> AgentObservation
act(_:) -> Void
verify(goal:) -> AgentVerification
status() -> String
stop()
```

Backends:

- `LocalMacDriver`: current native Mac path.
- `LocalBrowserDriver`: next port, using a controlled browser/sandbox.
- `LocalVmDriver`: interface only when needed, no implementation until a provider exists.

## First Vertical Slice

The first real slice is:

1. Onboarding/settings shows Screen Recording, Accessibility, and Input Monitoring state.
2. Employee starts local recording.
3. App/window context is written into SQLite with audit events.
4. Reel shows captured local context.
5. Q&A answers only from stored context.
6. Suggestion engine surfaces a daily recap or repeated-work helper only when evidence exists.
7. Cascades shows reviewable helpers.
8. Agent driver can observe context, perform an approved safe action, verify against context, and audit it.

## Privacy Boundary

Manager-facing signals must not read raw screenshots or raw OCR. The privacy aggregator should output allowlisted aggregates with sensitive apps excluded. Sensitive categories include banking, health, legal, dating, private browsing, password managers, keychain, and wallets.

## Permission Rules

- Do not call ScreenCaptureKit capture paths while Screen Recording preflight is denied.
- Native prompts come only from explicit user actions.
- Input Monitoring event taps are started only when needed and after explicit permission flow.
- Screen agents are healthy only when Screen Recording, Accessibility, Input Monitoring, recorder health, action caps, and STOP controls are ready.

## Dead-Code Policy

- No placeholder implementations behind visible UI.
- No giant manager classes.
- No future VM code beyond a documented interface.
- No copied file without an attribution note.
- No generated spec can use shell/exec tools in the employee product path.
- No mutating action without approval, audit, and rollback/stop semantics.
- If a control is visible, it works, is explicitly disabled with a reason, or is removed.

## Build Invariants

`swift build` and `swift test` should pass before a native change is considered usable. The package should stay modular enough that storage, suggestions, and orchestration are testable without launching the app.
