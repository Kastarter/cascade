// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

"use client";

import type { CSSProperties, ReactNode } from "react";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import {
  CascadeManagerSuggestion,
  CascadeManagerSuggestionBatch,
  generateManagerSuggestions,
  listManagerSuggestions,
} from "@/lib/cascade-manager";
import {
  CascadeAgentSpecView,
  generateAgentSpec,
  listAgentSpecs,
  transitionAgentSpec,
} from "@/lib/cascade-agents";
import {
  buildDashboardMetrics,
  ManagerDashboardCascade,
  ManagerDashboardMetrics,
  ManagerDashboardPattern,
  toDashboardCascade,
  toDashboardPattern,
} from "@/lib/cascade-manager-dashboard";

type DashboardTab = "pulse" | "patterns" | "cascades";

export function CascadeManagerDashboard() {
  const router = useRouter();
  const [tab, setTab] = useState<DashboardTab>("pulse");
  const [selected, setSelected] = useState<ManagerDashboardPattern | null>(null);
  const [batch, setBatch] = useState<CascadeManagerSuggestionBatch | null>(null);
  const [suggestions, setSuggestions] = useState<CascadeManagerSuggestion[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  useEffect(() => {
    void loadSuggestions();
  }, []);

  useEffect(() => {
    if (!toast) return;
    const id = window.setTimeout(() => setToast(null), 3200);
    return () => window.clearTimeout(id);
  }, [toast]);

  const patterns = useMemo(
    () => suggestions.map(toDashboardPattern).sort((a, b) => b.heat - a.heat),
    [suggestions],
  );
  const cascades = useMemo(
    () =>
      suggestions
        .filter((suggestion) => ["sent", "approved", "deployed"].includes(suggestion.status))
        .map(toDashboardCascade),
    [suggestions],
  );
  const metrics = useMemo(() => buildDashboardMetrics(suggestions, batch), [suggestions, batch]);

  // Read-only on load — listing never triggers an LLM call. Detection (an Opus
  // pass over the sanitized aggregates) only runs when the manager asks for it.
  async function loadSuggestions() {
    setLoading(true);
    try {
      const existing = await listManagerSuggestions({ limit: 24 });
      setSuggestions(existing);
    } catch (e: any) {
      setToast(`Couldn't load patterns — ${String(e?.message ?? e)}`);
    } finally {
      setLoading(false);
    }
  }

  async function refreshSuggestions() {
    setRefreshing(true);
    try {
      const generated = await generateManagerSuggestions(8);
      setBatch(generated);
      setSuggestions(generated.suggestions);
      setToast(
        generated.suggestions.length === 0
          ? "Detector ran — no clear patterns in this window yet"
          : `Detector surfaced ${generated.suggestions.length} pattern${generated.suggestions.length === 1 ? "" : "s"}`,
      );
    } catch (e: any) {
      setToast(`Detection failed — ${String(e?.message ?? e)}`);
    } finally {
      setRefreshing(false);
    }
  }

  async function handleSent(name: string) {
    setSelected(null);
    setToast(`${name} cascaded to this employee — they’ll review and sandbox-test it`);
    await loadSuggestions();
  }

  return (
    <div data-screen-label="Cascade Manager" style={{ minHeight: "100vh", background: "var(--cascade-bg)" }}>
      <ManagerShell
        tab={tab}
        setTab={setTab}
        onRefresh={refreshSuggestions}
        refreshing={refreshing}
        onBackToReel={() => router.push("/home")}
      >
        <main
          style={{
            maxWidth: 1180,
            margin: "0 auto",
            padding: "24px 32px 80px",
            fontFamily: "var(--cascade-sans)",
            color: "var(--cascade-text)",
          }}
        >
          <ManagerBanner metrics={metrics} />
          <MetricsRail metrics={metrics} />

          {loading ? (
            <EmptyState title="Loading manager signals…" detail="Pulling the latest waste-detection suggestions from the employee app." />
          ) : patterns.length === 0 ? (
            <EmptyState title="No manager patterns yet" detail="Run detection once the employee app has enough activity history to analyze." />
          ) : (
            <>
              {(tab === "pulse" || tab === "patterns") && (
                <>
                  <SectionHeader
                    label={tab === "pulse" ? "Patterns Cascade noticed" : "All patterns"}
                    right={`${patterns.length} surfaced · backed by recorded activity`}
                  />
                  <PatternsBento patterns={patterns} onCompose={setSelected} />
                </>
              )}

              {(tab === "pulse" || tab === "cascades") && (
                <div style={{ marginTop: 28 }}>
                  <SectionHeader
                    label="Cascades in flight"
                    right={`${cascades.length} deployed or approved`}
                  />
                  <CascadesTable cascades={cascades} />
                </div>
              )}
            </>
          )}

          <div
            style={{
              marginTop: 44,
              paddingTop: 18,
              borderTop: "1px solid var(--cascade-border)",
              display: "flex",
              justifyContent: "space-between",
              gap: 20,
              fontFamily: "var(--cascade-mono)",
              fontSize: 9.5,
              letterSpacing: 1.4,
              textTransform: "uppercase",
              color: "var(--cascade-text-4)",
            }}
          >
            <span>Local manager prototype · same Mac</span>
            <span>{metrics.outboxPath}</span>
          </div>
        </main>
      </ManagerShell>

      {selected && (
        <ComposeConsole
          pattern={selected}
          onClose={() => setSelected(null)}
          onSent={handleSent}
        />
      )}

      {toast && (
        <div
          style={{
            position: "fixed",
            bottom: 36,
            left: "50%",
            transform: "translateX(-50%)",
            background: "oklch(0.22 0.03 145)",
            border: "1px solid oklch(0.44 0.08 145 / 0.6)",
            color: "var(--cascade-text)",
            padding: "12px 18px",
            borderRadius: 10,
            fontFamily: "var(--cascade-mono)",
            fontSize: 11,
            letterSpacing: 1,
            boxShadow: "0 16px 48px rgba(0,0,0,0.35)",
            zIndex: 200,
          }}
        >
          {toast}
        </div>
      )}
    </div>
  );
}

function ManagerShell({
  tab,
  setTab,
  onRefresh,
  refreshing,
  onBackToReel,
  children,
}: {
  tab: DashboardTab;
  setTab: (tab: DashboardTab) => void;
  onRefresh: () => void;
  refreshing: boolean;
  onBackToReel: () => void;
  children: ReactNode;
}) {
  return (
    <div
      style={{
        minHeight: "100vh",
        background:
          "radial-gradient(ellipse at top, oklch(0.24 0.03 145 / 0.35), transparent 58%), var(--cascade-bg)",
      }}
    >
      <div
        style={{
          height: 56,
          borderBottom: "1px solid var(--cascade-border)",
          display: "flex",
          alignItems: "center",
          padding: "0 32px",
          gap: 26,
          backdropFilter: "blur(16px) saturate(140%)",
          background: "oklch(0.175 0.010 140 / 0.82)",
          position: "sticky",
          top: 0,
          zIndex: 20,
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <path d="M3 7l9 4 9-4" stroke="var(--cascade-accent)" strokeWidth="1.6" strokeLinecap="round" opacity="0.45" />
            <path d="M3 12l9 4 9-4" stroke="var(--cascade-accent)" strokeWidth="1.6" strokeLinecap="round" opacity="0.75" />
            <path d="M3 17l9 4 9-4" stroke="var(--cascade-accent)" strokeWidth="1.6" strokeLinecap="round" />
          </svg>
          <span style={{ fontSize: 16, fontWeight: 600 }}>Cascade</span>
          <span
            style={{
              fontFamily: "var(--cascade-mono)",
              fontSize: 10,
              color: "var(--cascade-accent)",
              letterSpacing: 1.6,
              textTransform: "uppercase",
              padding: "2px 7px",
              border: "1px solid var(--cascade-accent)",
              borderRadius: 4,
            }}
          >
            Manager
          </span>
        </div>

        <nav style={{ display: "flex", gap: 22 }}>
          {[
            { id: "pulse", label: "Pulse" },
            { id: "patterns", label: "Patterns" },
            { id: "cascades", label: "Cascades" },
          ].map((item) => (
            <button
              key={item.id}
              onClick={() => setTab(item.id as DashboardTab)}
              style={{
                background: "transparent",
                border: "none",
                cursor: "pointer",
                padding: 0,
                fontFamily: "var(--cascade-mono)",
                fontSize: 11,
                fontWeight: 700,
                letterSpacing: 1.4,
                textTransform: "uppercase",
                color: tab === item.id ? "var(--cascade-text)" : "var(--cascade-text-3)",
                borderBottom: tab === item.id ? "1.5px solid var(--cascade-accent)" : "1.5px solid transparent",
                paddingBottom: 4,
                marginBottom: -4,
              }}
            >
              {item.label}
            </button>
          ))}
        </nav>

        <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 10 }}>
          <button
            onClick={onBackToReel}
            style={{
              padding: "8px 12px",
              borderRadius: 8,
              background: "transparent",
              border: "1px solid var(--cascade-border)",
              color: "var(--cascade-text-3)",
              fontFamily: "var(--cascade-mono)",
              fontSize: 10.5,
              cursor: "pointer",
            }}
          >
            Back to Reel
          </button>
          <button
            onClick={onRefresh}
            disabled={refreshing}
            style={{
              padding: "8px 12px",
              borderRadius: 8,
              background: "var(--cascade-panel)",
              border: "1px solid var(--cascade-border)",
              color: "var(--cascade-text-2)",
              fontFamily: "var(--cascade-mono)",
              fontSize: 10.5,
              cursor: "pointer",
            }}
          >
            {refreshing ? "Refreshing…" : "Refresh signals"}
          </button>
        </div>
      </div>

      {children}
    </div>
  );
}

function ManagerBanner({ metrics }: { metrics: ManagerDashboardMetrics }) {
  return (
    <section
      style={{
        padding: "18px 20px",
        border: "1px solid var(--cascade-border)",
        background: "linear-gradient(180deg, oklch(0.25 0.04 60 / 0.22), var(--cascade-panel))",
        borderRadius: 12,
        marginBottom: 22,
      }}
    >
      <div
        style={{
          fontFamily: "var(--cascade-mono)",
          fontSize: 10.5,
          letterSpacing: 1.6,
          textTransform: "uppercase",
          color: "var(--cascade-text-3)",
          marginBottom: 10,
        }}
      >
        Manager window
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", gap: 20, flexWrap: "wrap" }}>
        <div>
          <div style={{ fontFamily: "var(--cascade-serif)", fontSize: 30, fontStyle: "italic" }}>
            Suggestions from recorded work activity
          </div>
          <div style={{ marginTop: 8, color: "var(--cascade-text-2)", fontSize: 14, maxWidth: 720 }}>
            This dashboard is now fed by the employee app’s local waste detector. Managers review surfaced patterns,
            then decide which helper agents should be cascaded back down.
          </div>
        </div>
        <div style={{ minWidth: 220 }}>
          <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, color: "var(--cascade-text-3)" }}>
            Analyzed window
          </div>
          <div style={{ marginTop: 6, fontFamily: "var(--cascade-mono)", fontSize: 12, color: "var(--cascade-text)" }}>
            {metrics.windowLabel}
          </div>
        </div>
      </div>
    </section>
  );
}

function MetricsRail({ metrics }: { metrics: ManagerDashboardMetrics }) {
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "repeat(4, 1fr)",
        border: "1px solid var(--cascade-border)",
        borderRadius: 12,
        background: "var(--cascade-panel)",
        overflow: "hidden",
        marginBottom: 24,
      }}
    >
      <MetricCell value={`${metrics.analyzedHours}h`} label="Analyzed window" sub="latest detector pass" accent />
      <MetricCell value={String(metrics.pendingPatterns)} label="Patterns to review" sub="pending manager action" />
      <MetricCell value={String(metrics.activeCascades)} label="Cascades in flight" sub="sent, approved, or deployed" />
      <MetricCell value={`${metrics.avgConfidencePct}%`} label="Average confidence" sub={`${metrics.avgSeverityPct}% average severity`} warm />
    </div>
  );
}

function MetricCell({
  value,
  label,
  sub,
  accent,
  warm,
}: {
  value: string;
  label: string;
  sub: string;
  accent?: boolean;
  warm?: boolean;
}) {
  return (
    <div style={{ padding: "20px 22px", borderRight: "1px solid var(--cascade-border)", position: "relative" }}>
      <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, letterSpacing: 1.4, textTransform: "uppercase", color: "var(--cascade-text-3)" }}>
        {label}
      </div>
      <div
        style={{
          fontFamily: "var(--cascade-mono)",
          fontSize: 30,
          fontWeight: 600,
          letterSpacing: -1,
          color: warm ? "oklch(0.82 0.12 65)" : "var(--cascade-text)",
          marginTop: 6,
        }}
      >
        {value}
      </div>
      <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, color: "var(--cascade-text-4)", marginTop: 6 }}>
        {sub}
      </div>
      {accent && (
        <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 2, background: "var(--cascade-accent)" }} />
      )}
    </div>
  );
}

function SectionHeader({ label, right }: { label: string; right: string }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 12 }}>
      <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10.5, letterSpacing: 1.8, textTransform: "uppercase", color: "var(--cascade-text-3)" }}>
        {label}
      </span>
      <span style={{ flex: 1, height: 1, background: "var(--cascade-border)" }} />
      <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10.5, color: "var(--cascade-text-3)" }}>{right}</span>
    </div>
  );
}

function PatternsBento({
  patterns,
  onCompose,
}: {
  patterns: ManagerDashboardPattern[];
  onCompose: (pattern: ManagerDashboardPattern) => void;
}) {
  const gridAreas = `"a a b" "a a c" "d e f"`;
  const slots = ["a", "b", "c", "d", "e", "f"];
  return (
    <section
      style={{
        display: "grid",
        gridTemplateColumns: "1fr 1fr 1fr",
        gridTemplateAreas: gridAreas,
        gap: 10,
      }}
    >
      {patterns.slice(0, 6).map((pattern, index) => (
        <PatternCard key={pattern.id} pattern={pattern} big={index === 0} area={slots[index]} onCompose={onCompose} />
      ))}
    </section>
  );
}

function PatternCard({
  pattern,
  area,
  big,
  onCompose,
}: {
  pattern: ManagerDashboardPattern;
  area: string;
  big: boolean;
  onCompose: (pattern: ManagerDashboardPattern) => void;
}) {
  const color = kindColor(pattern.kind);
  return (
    <article
      onClick={() => onCompose(pattern)}
      style={{
        gridArea: area,
        background:
          pattern.heat > 0.72
            ? "linear-gradient(180deg, oklch(0.27 0.05 35 / 0.42), var(--cascade-panel))"
            : "var(--cascade-panel)",
        border: `1px solid ${pattern.heat > 0.72 ? "oklch(0.45 0.08 35 / 0.55)" : "var(--cascade-border)"}`,
        borderRadius: 10,
        padding: big ? "24px 26px 22px" : "18px 20px 16px",
        cursor: "pointer",
        display: "flex",
        flexDirection: "column",
      }}
    >
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, marginBottom: big ? 14 : 10 }}>
        <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 9.5, letterSpacing: 1.5, textTransform: "uppercase", color: "var(--cascade-text-3)" }}>
          {pattern.heat > 0.72 ? "Worth attention" : pattern.heat > 0.5 ? "Reviewable" : "Light signal"}
        </span>
        <div
          style={{
            padding: "2px 7px",
            borderRadius: 4,
            border: `1px solid ${color}`,
            color,
            fontFamily: "var(--cascade-mono)",
            fontSize: 9,
            letterSpacing: 1.2,
            textTransform: "uppercase",
          }}
        >
          {pattern.kind}
        </div>
      </div>

      <h3 style={{ margin: 0, fontSize: big ? 22 : 15.5, lineHeight: big ? 1.25 : 1.35, letterSpacing: -0.3 }}>
        {pattern.title}
      </h3>

      {big && <p style={{ margin: "12px 0 0", fontSize: 13.5, lineHeight: 1.55, color: "var(--cascade-text-2)" }}>{pattern.detail}</p>}

      <div style={{ flex: 1 }} />

      <div style={{ marginTop: big ? 22 : 14, display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
          <span style={{ fontFamily: "var(--cascade-mono)", fontSize: big ? 26 : 18, fontWeight: 600, color }}>
            {pattern.metric}
          </span>
          <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, color: "var(--cascade-text-4)", textTransform: "uppercase", letterSpacing: 1.1 }}>
            {pattern.metricLabel}
          </span>
        </div>
        <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, color: "var(--cascade-text-3)" }}>
          {Math.round(pattern.confidence * 100)}% confidence
        </span>
      </div>
    </article>
  );
}

function CascadesTable({ cascades }: { cascades: ManagerDashboardCascade[] }) {
  if (cascades.length === 0) {
    return <EmptyCard text="No cascades have been approved or deployed yet." />;
  }
  return (
    <div style={{ border: "1px solid var(--cascade-border)", borderRadius: 12, overflow: "hidden", background: "var(--cascade-panel)" }}>
      {cascades.map((cascade, index) => (
        <div
          key={cascade.id}
          style={{
            display: "grid",
            gridTemplateColumns: "110px 1.4fr 0.9fr 110px 120px",
            gap: 16,
            padding: "16px 18px",
            borderTop: index === 0 ? "none" : "1px solid var(--cascade-border)",
            alignItems: "center",
          }}
        >
          <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 10.5, color: "var(--cascade-text-3)", letterSpacing: 1.2 }}>{cascade.code}</div>
          <div>
            <div style={{ fontSize: 14, fontWeight: 600 }}>{cascade.name}</div>
            <div style={{ marginTop: 4, fontFamily: "var(--cascade-mono)", fontSize: 10.5, color: "var(--cascade-text-4)" }}>{cascade.to}</div>
          </div>
          <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 11, color: "var(--cascade-text-2)" }}>{cascade.savedPerWk}</div>
          <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 11, color: "var(--cascade-text-3)" }}>{cascade.sentDays}d ago</div>
          <div style={{ textAlign: "right" }}>
            <span
              style={{
                padding: "3px 8px",
                borderRadius: 999,
                border: "1px solid var(--cascade-border)",
                fontFamily: "var(--cascade-mono)",
                fontSize: 10,
                textTransform: "uppercase",
                color: "var(--cascade-text-2)",
              }}
            >
              {cascade.state}
            </span>
          </div>
        </div>
      ))}
    </div>
  );
}

function ComposeConsole({
  pattern,
  onClose,
  onSent,
}: {
  pattern: ManagerDashboardPattern;
  onClose: () => void;
  onSent: (name: string) => void;
}) {
  const [spec, setSpec] = useState<CascadeAgentSpecView | null>(null);
  const [phase, setPhase] = useState<"idle" | "generating" | "ready" | "sending">("idle");
  const [error, setError] = useState<string | null>(null);

  // If a spec was already generated for this pattern, load it.
  useEffect(() => {
    if (!pattern.suggestionId) return;
    let cancelled = false;
    (async () => {
      try {
        const existing = await listAgentSpecs(100);
        const match = existing.find((s) => s.suggestionId === pattern.suggestionId);
        if (!cancelled && match) {
          setSpec(match);
          setPhase("ready");
        }
      } catch {
        /* non-fatal */
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [pattern.suggestionId]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape" && phase !== "generating" && phase !== "sending") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose, phase]);

  async function handleGenerate() {
    if (!pattern.suggestionId) return;
    setPhase("generating");
    setError(null);
    try {
      const generated = await generateAgentSpec(pattern.suggestionId);
      setSpec(generated);
      setPhase("ready");
    } catch (e: any) {
      setError(String(e?.message ?? e));
      setPhase("idle");
    }
  }

  async function handleSend() {
    if (!spec) return;
    setPhase("sending");
    setError(null);
    try {
      await transitionAgentSpec(spec.id, "send_to_employee");
      onSent(spec.name);
    } catch (e: any) {
      setError(String(e?.message ?? e));
      setPhase("ready");
    }
  }

  const busy = phase === "generating" || phase === "sending";
  const invalid = spec?.validationStatus === "invalid";
  const alreadySent = spec ? spec.status !== "generated" : false;

  return (
    <div
      onClick={onClose}
      style={{
        position: "fixed",
        inset: 0,
        background: "rgba(0,0,0,0.58)",
        backdropFilter: "blur(8px) saturate(140%)",
        zIndex: 100,
        display: "flex",
        justifyContent: "flex-end",
      }}
    >
      <div
        onClick={(event) => event.stopPropagation()}
        style={{
          width: 760,
          height: "100%",
          background: "var(--cascade-bg)",
          borderLeft: "1px solid var(--cascade-border)",
          overflowY: "auto",
          boxShadow: "-32px 0 80px rgba(0,0,0,0.6)",
        }}
      >
        <div style={{ padding: "24px 28px 22px", borderBottom: "1px solid var(--cascade-border)", background: "var(--cascade-panel)" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 14 }}>
            <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 11, letterSpacing: 1.8, textTransform: "uppercase", color: "var(--cascade-accent)" }}>
              Generate cascade
            </span>
            <span style={{ flex: 1, height: 1, background: "var(--cascade-border)" }} />
            <button onClick={onClose} disabled={busy} style={closeBtnStyle}>×</button>
          </div>

          <div style={{ padding: "14px 18px", background: "var(--cascade-bg)", border: "1px solid var(--cascade-border)", borderRadius: 8 }}>
            <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 9.5, letterSpacing: 1.4, textTransform: "uppercase", color: "var(--cascade-text-3)", marginBottom: 8 }}>
              Detected pattern
            </div>
            <div style={{ fontSize: 20, fontWeight: 600, marginBottom: 8 }}>{pattern.title}</div>
            <div style={{ color: "var(--cascade-text-2)", lineHeight: 1.55 }}>{pattern.detail}</div>
          </div>
        </div>

        <div style={{ padding: "16px 28px", borderBottom: "1px solid var(--cascade-border)" }}>
          <Field label="What the detector saw (from sanitized metrics only)">
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
              {pattern.evidence.map((item) => (
                <div key={`${item.label}-${item.value}`} style={evidenceCardStyle}>
                  <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 9, color: "var(--cascade-text-4)", textTransform: "uppercase", letterSpacing: 1.2 }}>
                    {item.label}
                  </div>
                  <div style={{ marginTop: 6, fontSize: 13, color: "var(--cascade-text-2)" }}>{item.value}</div>
                </div>
              ))}
            </div>
          </Field>
        </div>

        {error && (
          <div style={{ margin: "16px 28px 0", padding: "12px 16px", borderRadius: 9, background: "oklch(0.24 0.045 30 / 0.5)", border: "1px solid oklch(0.45 0.085 30 / 0.6)", color: "oklch(0.84 0.085 35)", fontSize: 13 }}>
            {error}
          </div>
        )}

        {!spec ? (
          <div style={{ padding: "28px", textAlign: "center" }}>
            <p style={{ color: "var(--cascade-text-2)", fontSize: 14, lineHeight: 1.6, maxWidth: 520, margin: "0 auto 20px" }}>
              The Agent Generator (Opus) will turn this pattern into a fully-specified helper agent — its workflow,
              the exact tools it may touch, every approval point, and a rollback path. You review it before the
              employee ever sees it.
            </p>
            <button onClick={handleGenerate} disabled={busy} style={{ ...primaryBtnStyle, padding: "11px 22px", fontSize: 12.5 }}>
              {phase === "generating" ? "Generating spec…" : "Generate agent spec"}
            </button>
          </div>
        ) : (
          <SpecReview spec={spec} />
        )}

        {spec && (
          <div style={{ position: "sticky", bottom: 0, background: "var(--cascade-panel)", borderTop: "1px solid var(--cascade-border)", padding: "14px 28px", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, color: invalid ? "oklch(0.84 0.085 35)" : "var(--cascade-text-3)" }}>
              {invalid
                ? "Spec failed validation — cannot be sent. Regenerate."
                : alreadySent
                  ? "Already sent. The employee sandbox-tests and approves it."
                  : "Sending requires the employee to sandbox-test + approve before it runs."}
            </div>
            <div style={{ display: "flex", gap: 8 }}>
              <button onClick={handleGenerate} disabled={busy} style={ghostBtnStyle}>
                {phase === "generating" ? "…" : "Regenerate"}
              </button>
              <button onClick={handleSend} disabled={busy || invalid || alreadySent} style={{ ...primaryBtnStyle, opacity: busy || invalid || alreadySent ? 0.5 : 1 }}>
                {phase === "sending" ? "Sending…" : "Send to employee"}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

function SpecReview({ spec }: { spec: CascadeAgentSpecView }) {
  const d = spec.spec;
  return (
    <div style={{ padding: "16px 28px 24px", display: "grid", gap: 18 }}>
      <div style={{ ...evidenceCardStyle, background: "linear-gradient(180deg, oklch(0.21 0.03 150), var(--cascade-panel))" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap", marginBottom: 8 }}>
          <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, color: "var(--cascade-text-3)", textTransform: "uppercase", letterSpacing: 1.2 }}>
            Generated agent
          </span>
          <SpecBadge label={spec.validationStatus === "valid" ? "valid" : "invalid"} warn={spec.validationStatus !== "valid"} />
          <SpecBadge label={`~$${spec.estCostUsd.toFixed(3)}/run`} />
          <SpecBadge label={`saves ~${Math.round(spec.estTimeSavedMin)}m/wk`} />
        </div>
        <div style={{ fontSize: 17, fontWeight: 600 }}>{d.name}</div>
        <div style={{ marginTop: 8, color: "var(--cascade-text-2)", lineHeight: 1.55 }}>{d.taskDescription}</div>
        <div style={{ marginTop: 6, color: "var(--cascade-text-3)", fontSize: 12.5, lineHeight: 1.5 }}>{d.rationale}</div>
      </div>

      {spec.validationNotes && (
        <div style={{ padding: "10px 14px", borderRadius: 8, background: "oklch(0.24 0.045 30 / 0.35)", border: "1px solid oklch(0.45 0.085 30 / 0.5)", fontSize: 12.5, color: "var(--cascade-text-2)" }}>
          <strong style={{ color: "oklch(0.84 0.085 35)" }}>Validation: </strong>
          {spec.validationNotes}
        </div>
      )}

      <Field label="Workflow">
        <ol style={{ margin: 0, paddingLeft: 18, display: "grid", gap: 5 }}>
          {d.workflow.map((w) => (
            <li key={w.step} style={{ fontSize: 13, color: "var(--cascade-text-2)", lineHeight: 1.5 }}>
              {w.action}
              {w.approvalRequired && (
                <span style={{ marginLeft: 8, fontFamily: "var(--cascade-mono)", fontSize: 9, color: "var(--cascade-accent)", textTransform: "uppercase", letterSpacing: 0.8 }}>
                  · needs approval
                </span>
              )}
            </li>
          ))}
        </ol>
      </Field>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
        <Field label="Tools (whitelist only)">
          <SpecChips items={d.tools} empty="no external tools" />
        </Field>
        <Field label="Approval points">
          <SpecChips items={d.approvalPoints} empty="none" />
        </Field>
      </div>

      <Field label="Rollback path">
        <div style={{ fontSize: 13, color: "var(--cascade-text-2)", lineHeight: 1.5 }}>{d.rollbackPath}</div>
      </Field>
    </div>
  );
}

function SpecChips({ items, empty }: { items: string[]; empty: string }) {
  if (!items || items.length === 0) {
    return <span style={{ fontSize: 12.5, color: "var(--cascade-text-4)" }}>{empty}</span>;
  }
  return (
    <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
      {items.map((t, i) => (
        <span key={`${t}-${i}`} style={{ ...evidenceCardStyle, padding: "4px 9px", fontFamily: "var(--cascade-mono)", fontSize: 11, color: "var(--cascade-text-3)" }}>
          {t}
        </span>
      ))}
    </div>
  );
}

function SpecBadge({ label, warn }: { label: string; warn?: boolean }) {
  return (
    <span
      style={{
        padding: "2px 8px",
        borderRadius: 999,
        background: warn ? "oklch(0.24 0.045 30 / 0.5)" : "var(--cascade-bg)",
        border: `1px solid ${warn ? "oklch(0.45 0.085 30 / 0.6)" : "var(--cascade-border)"}`,
        fontFamily: "var(--cascade-mono)",
        fontSize: 9.5,
        letterSpacing: 0.6,
        color: warn ? "oklch(0.84 0.085 35)" : "var(--cascade-text-3)",
        textTransform: "uppercase",
      }}
    >
      {label}
    </span>
  );
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div style={{ marginBottom: 16 }}>
      <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 9, letterSpacing: 1.4, textTransform: "uppercase", color: "var(--cascade-text-3)", marginBottom: 5 }}>
        {label}
      </div>
      {children}
    </div>
  );
}

function EmptyState({ title, detail }: { title: string; detail: string }) {
  return (
    <div style={{ padding: "48px 28px", border: "1px solid var(--cascade-border)", borderRadius: 12, background: "var(--cascade-panel)" }}>
      <div style={{ fontSize: 22, fontWeight: 600 }}>{title}</div>
      <div style={{ marginTop: 10, color: "var(--cascade-text-2)", maxWidth: 620, lineHeight: 1.55 }}>{detail}</div>
    </div>
  );
}

function EmptyCard({ text }: { text: string }) {
  return (
    <div style={{ padding: "24px 20px", border: "1px solid var(--cascade-border)", borderRadius: 12, background: "var(--cascade-panel)", color: "var(--cascade-text-2)" }}>
      {text}
    </div>
  );
}

function kindColor(kind: ManagerDashboardPattern["kind"]): string {
  return {
    focus: "oklch(0.62 0.14 230)",
    inbox: "oklch(0.62 0.13 195)",
    meetings: "oklch(0.60 0.15 285)",
    wrap: "oklch(0.64 0.14 30)",
    code: "oklch(0.62 0.13 145)",
  }[kind];
}

const evidenceCardStyle: CSSProperties = {
  padding: "10px 12px",
  borderRadius: 8,
  border: "1px solid var(--cascade-border)",
  background: "var(--cascade-panel)",
};

const closeBtnStyle: CSSProperties = {
  width: 28,
  height: 28,
  borderRadius: 14,
  background: "var(--cascade-panel)",
  border: "1px solid var(--cascade-border)",
  color: "var(--cascade-text-3)",
  fontSize: 16,
  cursor: "pointer",
  padding: 0,
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
};

const ghostBtnStyle: CSSProperties = {
  padding: "9px 14px",
  borderRadius: 6,
  background: "transparent",
  color: "var(--cascade-text-3)",
  border: "1px solid var(--cascade-border)",
  fontFamily: "var(--cascade-mono)",
  fontSize: 11,
  cursor: "pointer",
};

const primaryBtnStyle: CSSProperties = {
  padding: "9px 18px",
  borderRadius: 6,
  background: "var(--cascade-accent)",
  color: "var(--cascade-bg)",
  border: "none",
  fontFamily: "var(--cascade-mono)",
  fontSize: 11,
  cursor: "pointer",
};
