// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// CascadesView — employee-facing inbox for fix-agents cascaded from a manager.
//
// Mirrors the 4-stage agent lifecycle from the architecture spec:
//   1. Review the spec   — what the agent does, what it touches, when it fires
//   2. Sandbox test       — dry-run against synthetic / historical data, no real tool calls
//   3. Approve            — explicit employee + manager dual approval to deploy
//   4. Monitor / rollback — running agents with audit log, pause, undo
//
// This keeps Agent #3 (Generator) and Agent #4 (Deployment Monitor) visually
// separated — the user can see at a glance which stage each cascade is in
// rather than collapsing everything into one "install/decline" toggle.

"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { CascadeTitlebar } from "@/components/cascade-titlebar";
import {
  CascadeManagerSuggestion,
  listManagerSuggestions,
  updateManagerSuggestionStatus,
} from "@/lib/cascade-manager";

type Stage = "review" | "sandbox" | "running" | "history";

const STAGE_FROM_STATUS: Record<string, Stage | null> = {
  sent: "review",
  reviewing: "review",
  sandbox_passed: "sandbox",
  approved: "sandbox", // ready to install
  deployed: "running",
  paused: "running",
  rejected: "history",
  rolled_back: "history",
};

export function CascadesView() {
  const [suggestions, setSuggestions] = useState<CascadeManagerSuggestion[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<number | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      // No status filter — we partition client-side by lifecycle stage.
      const items = await listManagerSuggestions({ limit: 100 });
      setSuggestions(items);
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 30_000);
    return () => clearInterval(id);
  }, [refresh]);

  // Partition cascades by lifecycle stage
  const buckets = useMemo(() => {
    const map: Record<Stage, CascadeManagerSuggestion[]> = {
      review: [],
      sandbox: [],
      running: [],
      history: [],
    };
    for (const s of suggestions) {
      const stage = STAGE_FROM_STATUS[s.status] ?? null;
      if (stage) map[stage].push(s);
    }
    return map;
  }, [suggestions]);

  const transition = async (id: number, next: "approved" | "deployed" | "rejected") => {
    setBusyId(id);
    try {
      await updateManagerSuggestionStatus(id, next);
      await refresh();
    } catch (e) {
      console.error("cascade transition failed", e);
    } finally {
      setBusyId(null);
    }
  };

  return (
    <div style={{ minHeight: "100vh", display: "flex", flexDirection: "column", background: "var(--cascade-bg)" }}>
      <CascadeTitlebar />

      <div
        style={{
          flex: 1,
          padding: "40px 56px 80px",
          maxWidth: 1080,
          margin: "0 auto",
          width: "100%",
          color: "var(--cascade-text)",
          fontFamily: "var(--cascade-sans)",
        }}
      >
        {/* HERO */}
        <div style={{ marginBottom: 32 }}>
          <div style={labelStyle}>Cascades · sent your way</div>
          <h1
            style={{
              fontFamily: "var(--cascade-serif)",
              fontWeight: 400,
              fontSize: 44,
              lineHeight: 1.1,
              letterSpacing: -0.8,
              margin: "8px 0 12px",
            }}
          >
            <span style={{ fontStyle: "italic" }}>Helpers</span> from your manager —{" "}
            <span style={{ color: "var(--cascade-text-3)" }}>review, test, then run.</span>
          </h1>
          <p style={{ fontSize: 14, color: "var(--cascade-text-3)", lineHeight: 1.55, maxWidth: 680, margin: 0 }}>
            Each cascade is a small AI helper proposed because a pattern was detected in the team's recorded work.
            Nothing runs on your Mac until you approve it. You can pause or roll back any cascade at any time.
          </p>
        </div>

        {error && (
          <ErrorBanner message={error} onRetry={refresh} />
        )}

        {loading && suggestions.length === 0 ? (
          <EmptyState
            headline="Loading cascades…"
            sub="Reading the local manager suggestions table."
          />
        ) : (
          <>
            <StageSection
              title="1 · Review the spec"
              sub="The manager has sent these. Read what they'll do, then decide whether to test."
              cascades={buckets.review}
              renderActions={(s) => (
                <>
                  <PrimaryBtn
                    disabled={busyId === s.id}
                    onClick={() => s.id && transition(s.id, "approved")}
                  >
                    Looks good · test it
                  </PrimaryBtn>
                  <GhostBtn
                    disabled={busyId === s.id}
                    onClick={() => s.id && transition(s.id, "rejected")}
                  >
                    Decline
                  </GhostBtn>
                </>
              )}
            />

            <StageSection
              title="2 · Sandbox test"
              sub="Cascade dry-runs the helper against your last 30 days with all external tool calls mocked. No real emails sent, no real changes made. Confirm the output looks right, then install."
              cascades={buckets.sandbox}
              renderActions={(s) => (
                <>
                  <PrimaryBtn
                    disabled={busyId === s.id}
                    onClick={() => s.id && transition(s.id, "deployed")}
                  >
                    Install & run for real
                  </PrimaryBtn>
                  <GhostBtn
                    disabled={busyId === s.id}
                    onClick={() => s.id && transition(s.id, "rejected")}
                  >
                    Decline
                  </GhostBtn>
                </>
              )}
            />

            <StageSection
              title="3 · Running on this Mac"
              sub="Active helpers. Each execution is audit-logged on this device. Pause anytime; rollback when supported."
              cascades={buckets.running}
              renderActions={(s) => (
                <>
                  <GhostBtn disabled title="Pause is wired via Vault for now">
                    Pause
                  </GhostBtn>
                  <GhostBtn
                    disabled={busyId === s.id}
                    onClick={() => s.id && transition(s.id, "rejected")}
                  >
                    Uninstall
                  </GhostBtn>
                </>
              )}
            />

            <StageSection
              title="4 · History"
              sub="Declined, rolled back, or uninstalled. Kept for your audit."
              cascades={buckets.history}
              renderActions={() => null}
              dim
            />

            {Object.values(buckets).every((b) => b.length === 0) && (
              <EmptyState
                headline="No cascades yet."
                sub={
                  "Your manager hasn't sent any helpers your way. " +
                  "When patterns surface in the team's recorded work, you'll review them here."
                }
              />
            )}
          </>
        )}
      </div>
    </div>
  );
}

// ─── Subcomponents ─────────────────────────────────────────────────

function StageSection({
  title,
  sub,
  cascades,
  renderActions,
  dim,
}: {
  title: string;
  sub: string;
  cascades: CascadeManagerSuggestion[];
  renderActions: (s: CascadeManagerSuggestion) => React.ReactNode;
  dim?: boolean;
}) {
  if (cascades.length === 0) return null;

  return (
    <section style={{ marginBottom: 36, opacity: dim ? 0.6 : 1 }}>
      <div style={{ marginBottom: 12 }}>
        <div style={{ ...labelStyle, color: dim ? "var(--cascade-text-4)" : "var(--cascade-text-3)" }}>{title}</div>
        <div style={{ fontSize: 13, color: "var(--cascade-text-3)", marginTop: 4, maxWidth: 720 }}>{sub}</div>
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "1fr", gap: 12 }}>
        {cascades.map((s) => (
          <CascadeCard key={s.id ?? s.title} suggestion={s} actions={renderActions(s)} />
        ))}
      </div>
    </section>
  );
}

function CascadeCard({
  suggestion: s,
  actions,
}: {
  suggestion: CascadeManagerSuggestion;
  actions: React.ReactNode;
}) {
  const conf = Math.round((s.confidence ?? 0) * 100);
  const sev = Math.round((s.severityScore ?? 0) * 100);

  return (
    <article
      style={{
        background: "linear-gradient(180deg, oklch(0.225 0.012 55), oklch(0.180 0.010 140))",
        border: "1px solid var(--cascade-border)",
        borderRadius: 14,
        padding: "20px 22px",
        display: "grid",
        gridTemplateColumns: "1fr auto",
        gap: 20,
        alignItems: "start",
      }}
    >
      <div>
        <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 8 }}>
          <span
            style={{
              fontFamily: "var(--cascade-mono)",
              fontSize: 10,
              letterSpacing: 1.4,
              textTransform: "uppercase",
              color: "var(--cascade-accent)",
            }}
          >
            {s.suggestedAgentKind}
          </span>
          <Badge label={`${conf}% conf`} />
          <Badge label={`${sev}% severity`} tone={sev >= 70 ? "warn" : "neutral"} />
        </div>
        <h3
          style={{
            fontFamily: "var(--cascade-serif)",
            fontSize: 22,
            fontWeight: 400,
            letterSpacing: -0.2,
            margin: "0 0 8px",
            color: "var(--cascade-text)",
          }}
        >
          {s.title}
        </h3>
        <p style={{ fontSize: 13.5, color: "var(--cascade-text-2)", lineHeight: 1.55, margin: "0 0 12px" }}>
          {s.summary}
        </p>

        {s.evidence && s.evidence.length > 0 && (
          <div
            style={{
              display: "flex",
              flexWrap: "wrap",
              gap: 6,
              marginTop: 10,
              paddingTop: 10,
              borderTop: "1px dashed var(--cascade-border)",
            }}
          >
            {s.evidence.slice(0, 6).map((e, i) => (
              <span
                key={i}
                style={{
                  display: "inline-flex",
                  alignItems: "baseline",
                  gap: 5,
                  padding: "3px 9px",
                  borderRadius: 6,
                  background: "var(--cascade-panel-2)",
                  border: "1px solid var(--cascade-border)",
                  fontFamily: "var(--cascade-mono)",
                  fontSize: 10.5,
                  color: "var(--cascade-text-3)",
                }}
              >
                <span style={{ opacity: 0.7 }}>{e.label}</span>
                <strong style={{ color: "var(--cascade-text-2)", fontWeight: 500 }}>{e.value}</strong>
              </span>
            ))}
          </div>
        )}

        {s.createdAt && (
          <div
            style={{
              fontFamily: "var(--cascade-mono)",
              fontSize: 10,
              color: "var(--cascade-text-4)",
              marginTop: 10,
              letterSpacing: 0.4,
            }}
          >
            {new Date(s.createdAt).toLocaleString()}
          </div>
        )}
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 8, alignItems: "stretch" }}>{actions}</div>
    </article>
  );
}

function Badge({ label, tone = "neutral" }: { label: string; tone?: "neutral" | "warn" }) {
  const bg = tone === "warn" ? "oklch(0.24 0.045 30 / 0.5)" : "var(--cascade-panel)";
  const border = tone === "warn" ? "oklch(0.45 0.085 30 / 0.6)" : "var(--cascade-border)";
  const color = tone === "warn" ? "oklch(0.84 0.085 35)" : "var(--cascade-text-3)";
  return (
    <span
      style={{
        padding: "2px 8px",
        borderRadius: 999,
        background: bg,
        border: `1px solid ${border}`,
        fontFamily: "var(--cascade-mono)",
        fontSize: 9.5,
        letterSpacing: 0.6,
        color,
        textTransform: "uppercase",
      }}
    >
      {label}
    </span>
  );
}

function PrimaryBtn({ children, onClick, disabled, title }: { children: React.ReactNode; onClick?: () => void; disabled?: boolean; title?: string }) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      style={{
        padding: "9px 16px",
        borderRadius: 7,
        background: "var(--cascade-accent)",
        color: "var(--cascade-on-accent)",
        border: "none",
        cursor: disabled ? "default" : "pointer",
        fontFamily: "var(--cascade-sans)",
        fontSize: 12.5,
        fontWeight: 500,
        opacity: disabled ? 0.5 : 1,
        whiteSpace: "nowrap",
      }}
    >
      {children}
    </button>
  );
}

function GhostBtn({ children, onClick, disabled, title }: { children: React.ReactNode; onClick?: () => void; disabled?: boolean; title?: string }) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      style={{
        padding: "9px 16px",
        borderRadius: 7,
        background: "var(--cascade-panel)",
        color: "var(--cascade-text-2)",
        border: "1px solid var(--cascade-border)",
        cursor: disabled ? "default" : "pointer",
        fontFamily: "var(--cascade-sans)",
        fontSize: 12.5,
        opacity: disabled ? 0.5 : 1,
        whiteSpace: "nowrap",
      }}
    >
      {children}
    </button>
  );
}

function ErrorBanner({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <div
      style={{
        background: "oklch(0.24 0.045 30 / 0.5)",
        border: "1px solid oklch(0.45 0.085 30 / 0.6)",
        color: "oklch(0.84 0.085 35)",
        padding: "12px 16px",
        borderRadius: 9,
        marginBottom: 24,
        display: "flex",
        gap: 12,
        alignItems: "center",
      }}
    >
      <span style={{ flex: 1, fontSize: 13 }}>Couldn't load cascades — {message}</span>
      <button
        onClick={onRetry}
        style={{
          padding: "6px 12px",
          borderRadius: 6,
          background: "transparent",
          border: "1px solid oklch(0.45 0.085 30 / 0.6)",
          color: "oklch(0.84 0.085 35)",
          fontFamily: "var(--cascade-mono)",
          fontSize: 11,
          cursor: "pointer",
        }}
      >
        Retry
      </button>
    </div>
  );
}

function EmptyState({ headline, sub }: { headline: string; sub: string }) {
  return (
    <div
      style={{
        background: "var(--cascade-panel)",
        border: "1px solid var(--cascade-border)",
        borderRadius: 14,
        padding: "44px 32px",
        textAlign: "center",
        color: "var(--cascade-text-3)",
      }}
    >
      <div
        style={{
          fontFamily: "var(--cascade-serif)",
          fontSize: 24,
          color: "var(--cascade-text-2)",
          marginBottom: 6,
        }}
      >
        {headline}
      </div>
      <div style={{ fontSize: 13.5, lineHeight: 1.5, maxWidth: 520, margin: "0 auto" }}>{sub}</div>
    </div>
  );
}

const labelStyle: React.CSSProperties = {
  fontFamily: "var(--cascade-mono)",
  fontSize: 10.5,
  letterSpacing: 1.6,
  textTransform: "uppercase",
  color: "var(--cascade-text-3)",
};
