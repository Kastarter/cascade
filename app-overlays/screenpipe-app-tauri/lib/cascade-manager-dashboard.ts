// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

import type {
  CascadeManagerEvidence,
  CascadeManagerSuggestion,
  CascadeManagerSuggestionBatch,
} from "@/lib/cascade-manager";

export interface ManagerDashboardPattern {
  id: string;
  suggestionId?: number | null;
  heat: number;
  kind: "focus" | "inbox" | "meetings" | "wrap" | "code";
  /** The detector's own free-form slug for the observed behavior (display). */
  kindLabel: string;
  title: string;
  detail: string;
  metric: string;
  metricLabel: string;
  evidence: CascadeManagerEvidence[];
  proposal: {
    name: string;
    what: string;
    trigger: string;
    scope: string[];
    verb: "mute" | "defer" | "summarize" | "remind";
  };
  status: string;
  suggestedAgentKind: string;
  confidence: number;
  createdAt?: string | null;
}

export interface ManagerDashboardCascade {
  id: string;
  suggestionId?: number | null;
  code: string;
  name: string;
  to: string;
  sentDays: number;
  installed: number;
  total: number;
  savedPerWk: string;
  state: "pending" | "approved" | "deployed" | "sent";
}

export interface ManagerDashboardMetrics {
  analyzedHours: number;
  pendingPatterns: number;
  activeCascades: number;
  avgConfidencePct: number;
  avgSeverityPct: number;
  windowLabel: string;
  outboxPath: string;
}

function titleCaseSlug(value: string): string {
  return (value || "helper-agent")
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function normalizeEvidenceLabel(label: string): string {
  return label.trim().toLowerCase();
}

function findEvidenceValue(evidence: CascadeManagerEvidence[], label: string): string {
  return evidence.find((item) => normalizeEvidenceLabel(item.label) === label)?.value ?? "";
}

function splitEvidenceList(value: string): string[] {
  return value
    .split(/(?:,|\||->|·)/g)
    .map((item) => item.trim())
    .filter(Boolean);
}

function kindToDash(kind: string): ManagerDashboardPattern["kind"] {
  const value = kind.toLowerCase();
  if (/(mail|message|inbox|notif|slack|reply|follow-up|followup)/.test(value)) return "inbox";
  if (/(meeting|calendar|zoom|call|recap)/.test(value)) return "meetings";
  if (/(admin|portal|status|update|check|digest|triage|review)/.test(value)) return "wrap";
  if (/(research|compare|doc|content|code|build|investigation)/.test(value)) return "code";
  return "focus";
}

function inferProposalVerb(purpose: string): "mute" | "defer" | "summarize" | "remind" {
  const text = purpose.toLowerCase();
  if (/(digest|summar|recap|compile|collect)/.test(text)) return "summarize";
  if (/(delay|batch|triage|queue|defer)/.test(text)) return "defer";
  if (/(mute|suppress|silence|block)/.test(text)) return "mute";
  return "remind";
}

function inferProposalTrigger(purpose: string): string {
  const text = purpose.toLowerCase();
  if (/(schedule|scheduled|every|daily|weekly)/.test(text)) return "Scheduled recurring run";
  if (/(when|after)\b/.test(text)) return "Triggered by observed workflow";
  return "Recurring on-demand workflow";
}

function agentProposal(agentKind: string, evidence: CascadeManagerEvidence[]) {
  const purpose =
    findEvidenceValue(evidence, "proposed automation") ||
    "Automate this recurring workflow using the same tools the user already touches.";
  const scope = splitEvidenceList(findEvidenceValue(evidence, "web tools used") || findEvidenceValue(evidence, "apps used")).slice(0, 4);
  return {
    name: titleCaseSlug(agentKind),
    what: purpose,
    trigger: inferProposalTrigger(purpose),
    scope,
    verb: inferProposalVerb(purpose),
  };
}

function evidenceMetric(suggestion: CascadeManagerSuggestion): { metric: string; metricLabel: string } {
  const tools = splitEvidenceList(findEvidenceValue(suggestion.evidence, "web tools used"));
  if (tools.length > 0) {
    return { metric: tools.slice(0, 2).join(" · "), metricLabel: "runs in" };
  }
  const apps = splitEvidenceList(findEvidenceValue(suggestion.evidence, "apps used"));
  if (apps.length > 0) {
    return { metric: apps.slice(0, 2).join(" · "), metricLabel: "observed in" };
  }
  const workflow = splitEvidenceList(findEvidenceValue(suggestion.evidence, "workflow observed"));
  if (workflow.length > 0) {
    return { metric: `${workflow.length}`, metricLabel: "steps captured" };
  }
  return {
    metric: `${Math.round((suggestion.confidence || 0) * 100)}%`,
    metricLabel: "confidence",
  };
}

function cascadeState(status: string): ManagerDashboardCascade["state"] {
  if (status === "deployed") return "deployed";
  if (status === "approved") return "approved";
  if (status === "sent") return "sent";
  return "pending";
}

function savingsLabel(suggestion: CascadeManagerSuggestion): string {
  const severity = Math.round((suggestion.severityScore || 0) * 100);
  if (severity >= 80) return "High";
  if (severity >= 60) return "Moderate";
  return "Light";
}

function daysSince(iso?: string | null): number {
  if (!iso) return 0;
  const time = new Date(iso).getTime();
  if (!Number.isFinite(time)) return 0;
  const diff = Date.now() - time;
  return Math.max(0, Math.floor(diff / (1000 * 60 * 60 * 24)));
}

export function toDashboardPattern(suggestion: CascadeManagerSuggestion): ManagerDashboardPattern {
  const proposal = agentProposal(suggestion.suggestedAgentKind, suggestion.evidence);
  const { metric, metricLabel } = evidenceMetric(suggestion);
  return {
    id: suggestion.id ? `pattern-${suggestion.id}` : `${suggestion.kind}-${suggestion.title}`,
    suggestionId: suggestion.id,
    heat: suggestion.severityScore,
    kind: kindToDash(suggestion.kind),
    kindLabel: (suggestion.kind || "pattern").replace(/-/g, " "),
    title: suggestion.title,
    detail: suggestion.summary,
    metric,
    metricLabel,
    evidence: suggestion.evidence,
    proposal,
    status: suggestion.status,
    suggestedAgentKind: suggestion.suggestedAgentKind,
    confidence: suggestion.confidence,
    createdAt: suggestion.createdAt,
  };
}

export function toDashboardCascade(suggestion: CascadeManagerSuggestion): ManagerDashboardCascade {
  const state = cascadeState(suggestion.status);
  const proposal = agentProposal(suggestion.suggestedAgentKind, suggestion.evidence);
  return {
    id: suggestion.id ? `cascade-${suggestion.id}` : `cascade-${suggestion.kind}`,
    suggestionId: suggestion.id,
    code: `CS-${String(suggestion.id ?? 0).padStart(3, "0")}`,
    name: proposal.name,
    to: "This employee",
    sentDays: daysSince(suggestion.createdAt),
    installed: state === "deployed" ? 1 : 0,
    total: 1,
    savedPerWk: `${savingsLabel(suggestion)} impact`,
    state,
  };
}

function formatWindowLabel(batch: CascadeManagerSuggestionBatch | null): string {
  if (!batch) return "No analysis window yet";
  const start = new Date(batch.windowStart);
  const end = new Date(batch.windowEnd);
  if (!Number.isFinite(start.getTime()) || !Number.isFinite(end.getTime())) {
    return `${batch.hoursAnalyzed}h window`;
  }
  return `${start.toLocaleDateString(undefined, { month: "short", day: "numeric" })} · ${start.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })} to ${end.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`;
}

export function buildDashboardMetrics(
  suggestions: CascadeManagerSuggestion[],
  batch: CascadeManagerSuggestionBatch | null,
): ManagerDashboardMetrics {
  const pendingPatterns = suggestions.filter((s) => s.status === "pending").length;
  const activeCascades = suggestions.filter((s) => ["sent", "approved", "deployed"].includes(s.status)).length;
  const avgConfidencePct = suggestions.length
    ? Math.round((suggestions.reduce((sum, s) => sum + s.confidence, 0) / suggestions.length) * 100)
    : 0;
  const avgSeverityPct = suggestions.length
    ? Math.round((suggestions.reduce((sum, s) => sum + s.severityScore, 0) / suggestions.length) * 100)
    : 0;

  return {
    analyzedHours: batch?.hoursAnalyzed ?? 0,
    pendingPatterns,
    activeCascades,
    avgConfidencePct,
    avgSeverityPct,
    windowLabel: formatWindowLabel(batch),
    outboxPath: batch?.outboxPath ?? "Not generated yet",
  };
}
