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
  decisionPoint: string | null;
  approvalRequired: boolean;
}

export interface AgentSpecDoc {
  name: string;
  taskDescription: string;
  rationale: string;
  requiredInputs: RequiredInput[];
  workflow: WorkflowStep[];
  tools: string[];
  failureConditions: string[];
  approvalPoints: string[];
  rollbackPath: string;
  estimatedCostUsd: number;
  estimatedTimeSavedMin: number;
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
