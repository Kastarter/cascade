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

function kindToDash(kind: string): ManagerDashboardPattern["kind"] {
  switch (kind) {
    case "communication_churn":
      return "inbox";
    case "meeting_load":
      return "meetings";
    case "manual_admin_work":
      return "wrap";
    case "research_friction":
      return "code";
    case "context_switching":
    default:
      return "focus";
  }
}

function agentProposal(agentKind: string) {
  switch (agentKind) {
    case "focus-guard":
      return {
        name: "Focus guard",
        what: "Suppress noisy side-channels and nudge the employee back into a single task when rapid switching starts compounding.",
        trigger: "When rapid switching is detected",
        scope: ["Slack", "Browser", "Notifications"],
        verb: "mute" as const,
      };
    case "inbox-batcher":
      return {
        name: "Inbox batcher",
        what: "Batch low-priority communication into scheduled digests so the employee can hold a real focus block.",
        trigger: "Continuous · releases on a schedule",
        scope: ["Slack", "Mail", "Messages"],
        verb: "defer" as const,
      };
    case "meeting-recap":
      return {
        name: "Meeting recap",
        what: "Summarize recurring meetings into a tight recap so the employee doesn’t need to keep reopening recordings or notes.",
        trigger: "When a meeting ends",
        scope: ["Meeting notes", "Recordings", "Calendar"],
        verb: "summarize" as const,
      };
    case "research-assistant":
      return {
        name: "Research assistant",
        what: "Capture browser findings and turn repeated lookup loops into a reusable, task-scoped summary.",
        trigger: "When browser-heavy execution loops appear",
        scope: ["Browser", "Docs", "Knowledge base"],
        verb: "summarize" as const,
      };
    case "status-automation":
    default:
      return {
        name: "Status automation",
        what: "Convert repetitive update and admin work into a reusable workflow the employee can review instead of rewriting from scratch.",
        trigger: "When repetitive admin work is detected",
        scope: ["Docs", "Task tracker", "Status surfaces"],
        verb: "remind" as const,
      };
  }
}

function evidenceMetric(evidence: CascadeManagerEvidence[]): { metric: string; metricLabel: string } {
  if (evidence.length === 0) {
    return { metric: "—", metricLabel: "no evidence yet" };
  }
  return {
    metric: evidence[0].value,
    metricLabel: evidence[0].label,
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
  const proposal = agentProposal(suggestion.suggestedAgentKind);
  const { metric, metricLabel } = evidenceMetric(suggestion.evidence);
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
  return {
    id: suggestion.id ? `cascade-${suggestion.id}` : `cascade-${suggestion.kind}`,
    suggestionId: suggestion.id,
    code: `CS-${String(suggestion.id ?? 0).padStart(3, "0")}`,
    name: agentProposal(suggestion.suggestedAgentKind).name,
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
