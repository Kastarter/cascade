// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

import { invoke } from "@tauri-apps/api/core";

export interface CascadeManagerEvidence {
  label: string;
  value: string;
}

export type CascadeTier = "info" | "suggest" | "urgent";

export interface CascadeManagerSuggestion {
  id?: number | null;
  kind: string;
  title: string;
  summary: string;
  tier: CascadeTier;
  evidence: CascadeManagerEvidence[];
  suggestedAgentKind: string;
  severityScore: number;
  confidence: number;
  status: string;
  createdAt?: string | null;
}

export interface CascadeManagerSuggestionBatch {
  generatedAt: string;
  windowStart: string;
  windowEnd: string;
  hoursAnalyzed: number;
  deliveryMode: string;
  model: string;
  costUsd: number;
  outboxPath: string;
  suggestions: CascadeManagerSuggestion[];
}

export async function generateManagerSuggestions(hours = 8): Promise<CascadeManagerSuggestionBatch> {
  return invoke<CascadeManagerSuggestionBatch>("cascade_generate_manager_suggestions", { hours });
}

export async function listManagerSuggestions(
  opts: { status?: string; limit?: number } = {},
): Promise<CascadeManagerSuggestion[]> {
  return invoke<CascadeManagerSuggestion[]>("cascade_list_manager_suggestions", opts);
}

export async function updateManagerSuggestionStatus(
  suggestionId: number,
  status: "pending" | "sent" | "approved" | "rejected" | "deployed",
): Promise<void> {
  return invoke("cascade_update_manager_suggestion_status", { suggestionId, status });
}
