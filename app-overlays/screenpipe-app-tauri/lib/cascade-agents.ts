// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Typed client for the Layer 2 agent surface:
//   #5 Privacy Aggregator · #3 Agent Generator · #4 Deployment Monitor.
// (The #2 Waste Detector client lives in cascade-manager.ts alongside the
//  manager-suggestion types it shares.)

import { invoke } from "@tauri-apps/api/core";

// ─── #5 Privacy Aggregator ──────────────────────────────────────────

export interface CascadePrivacyAggregate {
  app: string;
  category: string;
  durationMin: number;
  contextSwitches: number;
  noised: boolean;
}

export interface CascadePrivacyReport {
  generatedAt: string;
  windowStart: string;
  windowEnd: string;
  hoursAnalyzed: number;
  aggregates: CascadePrivacyAggregate[];
  excludedCount: number;
  sharedFields: string[];
  outboxPath: string;
}

export async function runPrivacyAggregation(hours = 8): Promise<CascadePrivacyReport> {
  return invoke<CascadePrivacyReport>("cascade_run_privacy_aggregation", { hours });
}

export async function listPrivacyAggregates(
  windowStart: string,
  windowEnd: string,
): Promise<CascadePrivacyAggregate[]> {
  return invoke<CascadePrivacyAggregate[]>("cascade_list_privacy_aggregates", {
    windowStart,
    windowEnd,
  });
}

// ─── #3 Agent Generator ─────────────────────────────────────────────

export interface RequiredInput {
  source: string;
  fields: string[];
}

export interface WorkflowStep {
  step: number;
  action: string;
  tool: string | null;
  decisionPoint: string | null;
  approvalRequired: boolean;
}

export interface AgentSpecDoc {
  name: string;
  taskDescription: string;
  rationale: string;
  executionMode: "background" | "browser";
  targetUrl: string;
  targetHosts: string[];
  observedApps: string[];
  observedWorkflow: string[];
  completionPattern: string;
  requiredInputs: RequiredInput[];
  workflow: WorkflowStep[];
  tools: string[];
  failureConditions: string[];
  approvalPoints: string[];
  rollbackPath: string;
  estimatedCostUsd: number;
  estimatedTimeSavedMin: number;
  scheduleMinutes: number;
}

export type AgentSpecStatus =
  | "generated"
  | "review"
  | "sandbox_passed"
  | "sandbox_failed"
  | "approved"
  | "deployed"
  | "paused"
  | "rejected";

export interface CascadeAgentSpecView {
  id: number;
  suggestionId: number;
  name: string;
  status: AgentSpecStatus;
  validationStatus: "valid" | "invalid";
  validationNotes: string | null;
  estCostUsd: number;
  estTimeSavedMin: number;
  employeeApproved: boolean;
  managerApproved: boolean;
  createdAt: string;
  spec: AgentSpecDoc;
}

export async function generateAgentSpec(suggestionId: number): Promise<CascadeAgentSpecView> {
  return invoke<CascadeAgentSpecView>("cascade_generate_agent_spec", { suggestionId });
}

export async function listAgentSpecs(limit = 50): Promise<CascadeAgentSpecView[]> {
  return invoke<CascadeAgentSpecView[]>("cascade_list_agent_specs", { limit });
}

/** Seed a ready-to-run demo agent (deployed + approved) for testing. */
export async function seedDemoAgent(): Promise<CascadeAgentSpecView> {
  return invoke<CascadeAgentSpecView>("cascade_seed_demo_agent", {});
}

/**
 * Seed the "Notion Work Notes" agent (deployed) — it watches what you're doing
 * (from the Rewind) and writes it up as dated notes in Notion while you work.
 */
export async function seedNotionNotesAgent(): Promise<CascadeAgentSpecView> {
  return invoke<CascadeAgentSpecView>("cascade_seed_notion_notes_agent", {});
}

// ─── #4 Deployment & Runtime Monitor ────────────────────────────────

export interface SandboxStep {
  step: number;
  tool: string;
  action: string;
  mockedResult: string;
}

export interface Anomaly {
  kind: string;
  detail: string;
}

export interface CascadeAgentRun {
  id: number;
  specId: number;
  mode: "sandbox" | "live";
  status: "success" | "failed" | "flagged";
  summary: string;
  steps: SandboxStep[];
  anomalies: Anomaly[];
  costUsd: number;
  durationMs: number;
  createdAt: string;
}

export interface CascadeAuditEntry {
  id: number;
  actor: "employee" | "manager" | "system";
  action: string;
  detail: string;
  createdAt: string;
}

export type SpecTransition =
  | "send_to_employee"
  | "approve_employee"
  | "approve_manager"
  | "deploy"
  | "pause"
  | "resume"
  | "reject";

export async function sandboxTest(specId: number): Promise<CascadeAgentRun> {
  return invoke<CascadeAgentRun>("cascade_sandbox_test", { specId });
}

export async function transitionAgentSpec(
  specId: number,
  action: SpecTransition,
): Promise<CascadeAgentSpecView> {
  return invoke<CascadeAgentSpecView>("cascade_transition_agent_spec", { specId, action });
}

export async function listAgentRuns(specId: number, limit = 20): Promise<CascadeAgentRun[]> {
  return invoke<CascadeAgentRun[]>("cascade_list_agent_runs", { specId, limit });
}

export async function listAudit(specId: number, limit = 50): Promise<CascadeAuditEntry[]> {
  return invoke<CascadeAuditEntry[]>("cascade_list_audit", { specId, limit });
}

// ─── #4 Steady-state runtime (deployed agents actually do the work) ─

export type ActionState = "committed" | "pending" | "rejected" | "rolled_back" | "failed";

export interface CascadeAgentAction {
  id: number;
  runId: number;
  specId: number;
  step: number;
  tool: string;
  summary: string;
  content: string | null;
  artifactPath: string | null;
  reversible: boolean;
  mutating: boolean;
  state: ActionState;
  createdAt: string;
}

export interface CascadeRunResult {
  runId: number;
  specId: number;
  status: "success" | "awaiting_approval" | "flagged" | "failed" | "running";
  summary: string;
  supervised: boolean;
  pendingCount: number;
  costUsd: number;
  anomalies: Anomaly[];
  actions: CascadeAgentAction[];
}

export async function listAgentActions(specId: number, limit = 40): Promise<CascadeAgentAction[]> {
  return invoke<CascadeAgentAction[]>("cascade_list_agent_actions", { specId, limit });
}

export async function approveAction(actionId: number): Promise<CascadeAgentAction> {
  return invoke<CascadeAgentAction>("cascade_approve_action", { actionId });
}

export async function rejectAction(actionId: number): Promise<void> {
  return invoke("cascade_reject_action", { actionId });
}

export async function rollbackAction(actionId: number): Promise<void> {
  return invoke("cascade_rollback_action", { actionId });
}

// ─── Computer use ("Cascade Hands") ─────────────────────────────────

export interface ComputerAgentStatus {
  specId: number;
  awaitingApproval: boolean;
}

/**
 * How an agent does its work — the user's Settings choice, passed straight to
 * the backend run target. "sandbox" = isolated floating-box browser; "screen" =
 * the user's real screen.
 */
export type CascadeRunTarget = "screen" | "sandbox";

/** Start ONE deployed agent doing its task, in the sandbox or on the real screen. */
export async function startComputerTask(
  specId: number,
  goal?: string,
  target?: CascadeRunTarget,
): Promise<void> {
  return invoke("cascade_start_computer_task", { specId, goal: goal ?? null, target: target ?? null });
}

/** Start EVERY installed agent at once — one cursor per agent. */
export async function startAllComputerTasks(target?: CascadeRunTarget): Promise<number> {
  return invoke<number>("cascade_start_all_computer_tasks", { target: target ?? null });
}

/** Stop one agent (specId), or all of them (specId = 0). */
export async function stopComputerTask(specId = 0): Promise<void> {
  return invoke("cascade_stop_computer_task", { specId });
}

/** Pause/resume an agent without shutting it down (specId 0 = all). */
export async function pauseComputerTask(paused: boolean, specId = 0): Promise<void> {
  return invoke("cascade_pause_computer_task", { specId, paused });
}

/** Open a visible browser to log the agent into a service (session persists). */
export async function openAgentLogin(url?: string): Promise<void> {
  return invoke("cascade_open_agent_login", { url: url ?? null });
}

export async function approveComputerStep(specId: number): Promise<void> {
  return invoke("cascade_approve_computer_step", { specId });
}

export async function rejectComputerStep(specId: number): Promise<void> {
  return invoke("cascade_reject_computer_step", { specId });
}

export async function computerStatus(): Promise<ComputerAgentStatus[]> {
  return invoke<ComputerAgentStatus[]>("cascade_computer_status", {});
}
