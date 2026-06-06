// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// CascadesView — employee-facing inbox for fix-agents cascaded from a manager.
//
// Drives the real Agent #4 lifecycle over generated specs (Agent #3 output):
//   1. Review    — the structured spec: what it does, what it touches, how to undo
//   2. Sandbox   — dry-run against recent sanitized activity, all tools mocked,
//                  anomaly detection on the result
//   3. Running   — installed agents, with an immutable audit log + pause/uninstall
//   4. History   — declined / failed, kept for the audit trail
//
// Nothing runs against real data until BOTH the manager and the employee
// approve AND the sandbox test passes.

"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { CascadeTitlebar } from "@/components/cascade-titlebar";
import {
  CascadeRunMode,
  getRunMode,
  CASCADE_RUN_MODE_EVENT,
  CASCADE_RUN_MODE_KEY,
} from "@/lib/cascade-defaults";
import {
  CascadeAgentAction,
  CascadeAgentRun,
  CascadeAgentSpecView,
  CascadeAuditEntry,
  approveAction,
  listAgentActions,
  listAgentRuns,
  listAgentSpecs,
  listAudit,
  rejectAction,
  rollbackAction,
  seedDailyRecapAgent,
  sandboxTest,
  seedDemoAgent,
  startAllComputerTasks,
  startComputerTask,
  stopComputerTask,
  pauseComputerTask,
  transitionAgentSpec,
} from "@/lib/cascade-agents";

type Stage = "review" | "sandbox" | "running" | "history";

const STAGE_FROM_STATUS: Record<string, Stage> = {
  review: "review",
  generated: "review",
  sandbox_passed: "sandbox",
  sandbox_failed: "sandbox",
  approved: "sandbox",
  deployed: "running",
  paused: "running",
  rejected: "history",
};

export function CascadesView() {
  const [specs, setSpecs] = useState<CascadeAgentSpecView[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<number | null>(null);
  const [note, setNote] = useState<string | null>(null);
  // Global "on screen vs Local Sandbox" preference, set in Settings.
  const [runMode, setRunMode] = useState<CascadeRunMode>("sandbox");

  useEffect(() => {
    setRunMode(getRunMode());
    const onChange = () => setRunMode(getRunMode());
    // Same-document (custom event) + cross-window (native storage event).
    window.addEventListener(CASCADE_RUN_MODE_EVENT, onChange);
    const onStorage = (e: StorageEvent) => {
      if (e.key === CASCADE_RUN_MODE_KEY) onChange();
    };
    window.addEventListener("storage", onStorage);
    return () => {
      window.removeEventListener(CASCADE_RUN_MODE_EVENT, onChange);
      window.removeEventListener("storage", onStorage);
    };
  }, []);

  const refresh = useCallback(async () => {
    setError(null);
    try {
      const items = await listAgentSpecs(100);
      setSpecs(items);
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

  const buckets = useMemo(() => {
    const map: Record<Stage, CascadeAgentSpecView[]> = {
      review: [],
      sandbox: [],
      running: [],
      history: [],
    };
    for (const s of specs) {
      const stage = STAGE_FROM_STATUS[s.status] ?? "history";
      map[stage].push(s);
    }
    return map;
  }, [specs]);
  // How many installed agents can be started in one go (any mode).
  const watchableRunningCount = useMemo(() => buckets.running.length, [buckets.running]);

  const run = useCallback(
    async (id: number, fn: () => Promise<unknown>, ok: string) => {
      setBusyId(id);
      setError(null);
      try {
        await fn();
        await refresh();
        setNote(ok);
      } catch (e: any) {
        setError(String(e?.message ?? e));
      } finally {
        setBusyId(null);
      }
    },
    [refresh],
  );

  const onSandbox = (s: CascadeAgentSpecView) =>
    run(s.id, () => sandboxTest(s.id), `Sandbox test finished for “${s.name}”`);
  const onInstall = (s: CascadeAgentSpecView) =>
    run(
      s.id,
      async () => {
        if (s.status !== "sandbox_passed") {
          // sandboxTest records `sandbox_failed` WITHOUT throwing, so we must
          // inspect its result. Without this, "approve_employee" would flip
          // employee_approved=true on a failed spec and only "deploy" would
          // reject — leaving a surprising partial-approved state behind.
          const r = await sandboxTest(s.id);
          if (r.status !== "success") {
            throw new Error(
              `Sandbox test didn't pass (${r.status}) — review the flagged items before installing.`,
            );
          }
        }
        await transitionAgentSpec(s.id, "approve_employee");
        await transitionAgentSpec(s.id, "deploy");
      },
      `“${s.name}” is now running on this Mac`,
    );
  const onDecline = (s: CascadeAgentSpecView) =>
    run(s.id, () => transitionAgentSpec(s.id, "reject"), `Declined “${s.name}”`);
  const onPause = (s: CascadeAgentSpecView) =>
    run(s.id, async () => {
      // Pause/resume the live agent (if it's running in the box) too.
      await pauseComputerTask(s.status !== "paused", s.id).catch(() => {});
      await transitionAgentSpec(s.id, s.status === "paused" ? "resume" : "pause");
    }, s.status === "paused" ? `Resumed “${s.name}”` : `Paused “${s.name}”`);
  const onUninstall = (s: CascadeAgentSpecView) =>
    run(s.id, async () => {
      // Stop the running agent (close its browser + loop) before removing it.
      await stopComputerTask(s.id).catch(() => {});
      await transitionAgentSpec(s.id, "reject");
    }, `Uninstalled “${s.name}”`);
  const onWatch = (s: CascadeAgentSpecView) =>
    run(
      s.id,
      () => startComputerTask(s.id, undefined, runMode),
      runMode === "screen"
        ? `${s.name} is working on your screen — follow along in the floating box`
        : `${s.name} is working in the sandbox — watch the steps in the floating box`,
    );
  const onWatchAll = async () => {
    setError(null);
    try {
      const n = await startAllComputerTasks(runMode);
      setNote(
        n === 0
          ? "No installed agents are ready to start yet."
          : `${n} agent${n === 1 ? "" : "s"} now working — follow each one in the floating box.`,
      );
    } catch (e: any) {
      setError(String(e?.message ?? e));
    }
  };
  const [seeding, setSeeding] = useState(false);
  const onSeedDemo = async () => {
    setSeeding(true);
    setError(null);
    try {
      const s = await seedDemoAgent();
      await refresh();
      setNote(`Generated “${s.name}” via the pipeline — it's deployed in Running. Hit Start & watch.`);
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setSeeding(false);
    }
  };
  const [seedingRecap, setSeedingRecap] = useState(false);
  const onSeedRecap = async () => {
    setSeedingRecap(true);
    setError(null);
    try {
      const s = await seedDailyRecapAgent();
      await refresh();
      setNote(
        `Handed the daily-recap task to the detector — the pipeline generated “${s.name}”. ` +
          `It's in Review now: open it, run the sandbox test, approve it, then Start.`,
      );
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setSeedingRecap(false);
    }
  };

  return (
    <div style={{ height: "100vh", overflowY: "auto", display: "flex", flexDirection: "column", background: "var(--cascade-bg)" }}>
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
          <p style={{ fontSize: 14, color: "var(--cascade-text-3)", lineHeight: 1.55, maxWidth: 700, margin: 0 }}>
            Each cascade is a small AI helper, generated from a pattern in the team's recorded work.
            You see the full spec — every tool it can touch, every step, and how to undo it — before anything runs.
            It only runs for real after a sandbox test passes and you approve it. Pause or uninstall anytime.
          </p>
          <div style={{ marginTop: 16, display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
            <PrimaryBtn disabled={seeding} onClick={onSeedDemo}>
              {seeding ? "Generating via the workflow…" : "+ Generate a demo agent"}
            </PrimaryBtn>
            <GhostBtn disabled={seedingRecap} onClick={onSeedRecap}>
              {seedingRecap ? "Sending to detector…" : "+ Daily recap"}
            </GhostBtn>
            <span style={{ fontSize: 12, color: "var(--cascade-text-4)" }}>
              Both go detector → real agent (#3). Demo lands deployed; daily recap lands in Review so you can watch the whole workflow.
            </span>
          </div>
        </div>

        {error && <ErrorBanner message={error} onRetry={refresh} />}
        {note && <InfoBanner message={note} onClose={() => setNote(null)} />}

        {loading && specs.length === 0 ? (
          <EmptyState headline="Loading cascades…" sub="Reading generated agent specs from this device." />
        ) : (
          <>
            <StageSection
              title="1 · Review the spec"
              sub="Your manager generated and sent these. Read exactly what each will do, then dry-run it."
              specs={buckets.review}
              busyId={busyId}
              renderActions={(s) => (
                <>
                  <PrimaryBtn disabled={busyId === s.id} onClick={() => onSandbox(s)}>
                    {busyId === s.id ? "Testing…" : "Run sandbox test"}
                  </PrimaryBtn>
                  <GhostBtn disabled={busyId === s.id} onClick={() => onDecline(s)}>
                    Decline
                  </GhostBtn>
                </>
              )}
            />

            <StageSection
              title="2 · Sandbox result"
              sub="Cascade dry-ran the helper against your recent sanitized activity with every external tool mocked — no real emails, no real changes. Review what it would have done, then install."
              specs={buckets.sandbox}
              busyId={busyId}
              renderActions={(s) =>
                s.status === "sandbox_passed" ? (
                  <>
                    <PrimaryBtn disabled={busyId === s.id} onClick={() => onInstall(s)}>
                      {busyId === s.id ? "Installing…" : "Approve & install"}
                    </PrimaryBtn>
                    <GhostBtn disabled={busyId === s.id} onClick={() => onDecline(s)}>
                      Decline
                    </GhostBtn>
                  </>
                ) : (
                  <>
                    <GhostBtn disabled={busyId === s.id} onClick={() => onSandbox(s)}>
                      Re-test
                    </GhostBtn>
                    <GhostBtn disabled={busyId === s.id} onClick={() => onDecline(s)}>
                      Decline
                    </GhostBtn>
                  </>
                )
              }
            />

            {watchableRunningCount > 1 && (
              <div style={{ display: "flex", justifyContent: "flex-end", marginBottom: -18 }}>
                <PrimaryBtn onClick={onWatchAll}>
                  ▶ Start all {watchableRunningCount} agents{runMode === "screen" ? " on your screen" : " in the sandbox"}
                </PrimaryBtn>
              </div>
            )}

            <StageSection
              title="3 · Running on this Mac"
              sub={
                runMode === "screen"
                  ? "Active helpers doing real work. Press Start and the agent uses your real screen and cursor to do the task — it can operate any app. Switch to the Local Sandbox anytime in Settings → How agents run. Every action is audit-logged and reversible."
                  : "Active helpers doing real work. Press Start and the agent works in the Local Sandbox shown in the floating box (web apps), so you can keep working. Switch to on-screen runs anytime in Settings → How agents run. Every action is audit-logged and reversible."
              }
              specs={buckets.running}
              busyId={busyId}
              showRuntime
              renderActions={(s) => (
                <>
                  <PrimaryBtn
                    disabled={busyId === s.id}
                    onClick={() => onWatch(s)}
                    title={
                      runMode === "screen"
                        ? "Start the agent on your real screen and follow along in the floating box"
                        : "Start the agent in the Local Sandbox and watch the steps in the floating box"
                    }
                  >
                    {busyId === s.id
                      ? "Starting…"
                      : runMode === "screen"
                        ? "▶ Start on my screen"
                        : "▶ Start in the box"}
                  </PrimaryBtn>
                  <GhostBtn disabled={busyId === s.id} onClick={() => onUninstall(s)}>
                    Uninstall
                  </GhostBtn>
                </>
              )}
            />

            <StageSection
              title="4 · History"
              sub="Declined or uninstalled. Kept for your audit."
              specs={buckets.history}
              busyId={busyId}
              renderActions={() => null}
              dim
            />

            {specs.length === 0 && (
              <EmptyState
                headline="No cascades yet."
                sub={
                  "Your manager hasn't generated any helpers for you. When a pattern surfaces in the team's " +
                  "recorded work and the manager turns it into an agent, you'll review it here."
                }
              />
            )}
          </>
        )}
      </div>
    </div>
  );
}

// ─── Stage section ──────────────────────────────────────────────────

function StageSection({
  title,
  sub,
  specs,
  busyId,
  renderActions,
  dim,
  showRuntime,
  lastRunSummary,
}: {
  title: string;
  sub: string;
  specs: CascadeAgentSpecView[];
  busyId: number | null;
  renderActions: (s: CascadeAgentSpecView) => React.ReactNode;
  dim?: boolean;
  showRuntime?: boolean;
  lastRunSummary?: Record<number, string>;
}) {
  if (specs.length === 0) return null;
  return (
    <section style={{ marginBottom: 36, opacity: dim ? 0.6 : 1 }}>
      <div style={{ marginBottom: 12 }}>
        <div style={{ ...labelStyle, color: dim ? "var(--cascade-text-4)" : "var(--cascade-text-3)" }}>{title}</div>
        <div style={{ fontSize: 13, color: "var(--cascade-text-3)", marginTop: 4, maxWidth: 740 }}>{sub}</div>
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "1fr", gap: 12 }}>
        {specs.map((s) => (
          <SpecCard
            key={s.id}
            spec={s}
            actions={renderActions(s)}
            busy={busyId === s.id}
            showRuntime={showRuntime}
            lastRunSummary={lastRunSummary?.[s.id]}
          />
        ))}
      </div>
    </section>
  );
}

// ─── Spec card ──────────────────────────────────────────────────────

function SpecCard({
  spec,
  actions,
  showRuntime,
  lastRunSummary,
}: {
  spec: CascadeAgentSpecView;
  actions: React.ReactNode;
  busy: boolean;
  showRuntime?: boolean;
  lastRunSummary?: string;
}) {
  const [open, setOpen] = useState(false);
  const [runs, setRuns] = useState<CascadeAgentRun[]>([]);
  const [audit, setAudit] = useState<CascadeAuditEntry[]>([]);
  const [agentActions, setAgentActions] = useState<CascadeAgentAction[]>([]);
  const [actionBusy, setActionBusy] = useState<number | null>(null);

  const loadActions = useCallback(async () => {
    if (!showRuntime) return;
    try {
      setAgentActions(await listAgentActions(spec.id, 30));
    } catch {
      /* non-fatal */
    }
  }, [showRuntime, spec.id]);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => {
      try {
        const [r, a] = await Promise.all([listAgentRuns(spec.id, 5), listAudit(spec.id, 12)]);
        if (!cancelled) {
          setRuns(r);
          setAudit(a);
        }
        await loadActions();
      } catch {
        /* non-fatal */
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [open, spec.id, spec.status, lastRunSummary, loadActions]);

  // Pending approvals should surface even when the card is collapsed.
  useEffect(() => {
    if (showRuntime) void loadActions();
  }, [showRuntime, lastRunSummary, loadActions]);

  const runAction = async (id: number, fn: () => Promise<unknown>) => {
    setActionBusy(id);
    try {
      await fn();
      await loadActions();
    } catch (e) {
      console.error("action failed", e);
    } finally {
      setActionBusy(null);
    }
  };

  const pending = agentActions.filter((a) => a.state === "pending");
  const lastRun = runs[0];
  const d = spec.spec;

  return (
    <article
      style={{
        background: "linear-gradient(180deg, oklch(0.225 0.012 55), oklch(0.180 0.010 140))",
        border: "1px solid var(--cascade-border)",
        borderRadius: 14,
        padding: "20px 22px",
      }}
    >
      <div style={{ display: "grid", gridTemplateColumns: "1fr auto", gap: 20, alignItems: "start" }}>
        <div>
          <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8, flexWrap: "wrap" }}>
            <span style={agentKindStyle}>{d.tools.slice(0, 3).join(" · ") || "no external tools"}</span>
            {spec.validationStatus === "invalid" && <Badge label="spec invalid" tone="warn" />}
            <Badge label={`~$${spec.estCostUsd.toFixed(3)}/run`} />
            <Badge label={`saves ~${Math.round(spec.estTimeSavedMin)}m/wk`} />
            <Badge label={spec.status.replace(/_/g, " ")} tone={spec.status === "sandbox_failed" ? "warn" : "neutral"} />
          </div>

          <h3
            style={{
              fontFamily: "var(--cascade-serif)",
              fontSize: 22,
              fontWeight: 400,
              letterSpacing: -0.2,
              margin: "0 0 8px",
            }}
          >
            {spec.name}
          </h3>
          <p style={{ fontSize: 13.5, color: "var(--cascade-text-2)", lineHeight: 1.55, margin: "0 0 6px" }}>
            {d.taskDescription}
          </p>
          <p style={{ fontSize: 12.5, color: "var(--cascade-text-3)", lineHeight: 1.5, margin: 0 }}>{d.rationale}</p>

          {lastRun && lastRun.anomalies.length > 0 && (
            <div style={anomalyBoxStyle}>
              <strong style={{ color: "oklch(0.84 0.085 35)" }}>Sandbox flagged {lastRun.anomalies.length}:</strong>{" "}
              {lastRun.anomalies.map((a) => a.kind).join(", ")}
            </div>
          )}

          {showRuntime && (
            <div style={{ marginTop: 12 }}>
              {spec.status === "paused" && (
                <div style={anomalyBoxStyle}>
                  Paused. {pending.length > 0 ? "Resolve the items below, then resume." : "Resume to let it run again."}
                </div>
              )}
              {lastRunSummary && (
                <div style={{ fontSize: 12.5, color: "var(--cascade-text-2)", marginBottom: 8 }}>
                  Last run — {lastRunSummary}
                </div>
              )}
              <div style={{ fontSize: 11.5, color: "var(--cascade-text-4)", marginBottom: 8 }}>
                Runs about every {formatCadence(d.scheduleMinutes)} on its own.
              </div>

              {pending.length > 0 && (
                <div style={{ marginBottom: 10 }}>
                  <div style={{ ...labelStyle, fontSize: 9.5, marginBottom: 6, color: "var(--cascade-accent)" }}>
                    Awaiting your approval — supervised
                  </div>
                  <div style={{ display: "grid", gap: 8 }}>
                    {pending.map((a) => (
                      <ActionRow
                        key={a.id}
                        action={a}
                        busy={actionBusy === a.id}
                        onApprove={() => runAction(a.id, () => approveAction(a.id))}
                        onReject={() => runAction(a.id, () => rejectAction(a.id))}
                      />
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}

          <button onClick={() => setOpen((v) => !v)} style={discloseBtnStyle}>
            {open ? "▾ Hide details" : showRuntime ? "▸ Spec, work done & audit" : "▸ Spec, sandbox run & audit"}
          </button>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 8, alignItems: "stretch", minWidth: 150 }}>
          {actions}
        </div>
      </div>

      {open && (
        <SpecDetails
          spec={spec}
          lastRun={lastRun}
          audit={audit}
          actions={showRuntime ? agentActions : []}
          actionBusy={actionBusy}
          onRollback={(id) => runAction(id, () => rollbackAction(id))}
        />
      )}
    </article>
  );
}

function formatCadence(minutes: number): string {
  if (!minutes || minutes <= 0) return "day";
  if (minutes >= 1440) {
    const d = Math.round(minutes / 1440);
    return d <= 1 ? "day" : `${d} days`;
  }
  if (minutes >= 60) {
    const h = Math.round(minutes / 60);
    return h <= 1 ? "hour" : `${h} hours`;
  }
  return `${minutes} min`;
}

function ActionRow({
  action,
  busy,
  onApprove,
  onReject,
}: {
  action: CascadeAgentAction;
  busy: boolean;
  onApprove: () => void;
  onReject: () => void;
}) {
  const [show, setShow] = useState(false);
  return (
    <div style={{ border: "1px solid var(--cascade-border)", borderRadius: 8, padding: "10px 12px", background: "var(--cascade-panel)" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, color: "var(--cascade-accent)" }}>{action.tool}</span>
        <span style={{ flex: 1, fontSize: 12.5, color: "var(--cascade-text-2)" }}>{action.summary}</span>
        <GhostBtn disabled={busy} onClick={onApprove}>Approve</GhostBtn>
        <GhostBtn disabled={busy} onClick={onReject}>Reject</GhostBtn>
      </div>
      {action.content && (
        <>
          <button onClick={() => setShow((v) => !v)} style={{ ...discloseBtnStyle, marginTop: 8 }}>
            {show ? "▾ Hide what it produced" : "▸ Preview what it produced"}
          </button>
          {show && <pre style={preStyle}>{action.content}</pre>}
        </>
      )}
    </div>
  );
}

function SpecDetails({
  spec,
  lastRun,
  audit,
  actions,
  actionBusy,
  onRollback,
}: {
  spec: CascadeAgentSpecView;
  lastRun?: CascadeAgentRun;
  audit: CascadeAuditEntry[];
  actions: CascadeAgentAction[];
  actionBusy: number | null;
  onRollback: (id: number) => void;
}) {
  const d = spec.spec;
  const doneActions = actions.filter((a) => a.state !== "pending");
  return (
    <div style={{ marginTop: 16, paddingTop: 16, borderTop: "1px dashed var(--cascade-border)", display: "grid", gap: 16 }}>
      {spec.validationNotes && (
        <div style={anomalyBoxStyle}>
          <strong style={{ color: "oklch(0.84 0.085 35)" }}>Validation notes:</strong> {spec.validationNotes}
        </div>
      )}

      <DetailBlock title="Workflow">
        <ol style={{ margin: 0, paddingLeft: 18, display: "grid", gap: 4 }}>
          {d.workflow.map((w) => (
            <li key={w.step} style={{ fontSize: 12.5, color: "var(--cascade-text-2)", lineHeight: 1.5 }}>
              {w.action}
              {w.approvalRequired && <span style={pillStyle}>needs approval</span>}
              {w.decisionPoint && (
                <span style={{ color: "var(--cascade-text-4)" }}> · if: {w.decisionPoint}</span>
              )}
            </li>
          ))}
        </ol>
      </DetailBlock>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
        <DetailBlock title="Tools it may use">
          <ChipList items={d.tools} empty="none" />
        </DetailBlock>
        <DetailBlock title="Reads">
          <ChipList items={d.requiredInputs.map((i) => i.source)} empty="nothing" />
        </DetailBlock>
        <DetailBlock title="Approval points">
          <ChipList items={d.approvalPoints} empty="none required" />
        </DetailBlock>
        <DetailBlock title="Fails if">
          <ChipList items={d.failureConditions} empty="—" />
        </DetailBlock>
      </div>

      <DetailBlock title="How to undo (rollback)">
        <div style={{ fontSize: 12.5, color: "var(--cascade-text-2)", lineHeight: 1.5 }}>{d.rollbackPath}</div>
      </DetailBlock>

      {doneActions.length > 0 && (
        <DetailBlock title="Work this agent has done">
          <div style={{ display: "grid", gap: 8 }}>
            {doneActions.map((a) => (
              <div key={a.id} style={{ border: "1px solid var(--cascade-border)", borderRadius: 8, padding: "9px 12px", background: "var(--cascade-panel)" }}>
                <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                  <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, color: "var(--cascade-accent)" }}>{a.tool}</span>
                  <span style={{ flex: 1, fontSize: 12.5, color: "var(--cascade-text-2)" }}>{a.summary}</span>
                  <Badge
                    label={a.state.replace(/_/g, " ")}
                    tone={a.state === "rolled_back" || a.state === "rejected" || a.state === "failed" ? "warn" : "neutral"}
                  />
                  {a.reversible && a.state === "committed" && (
                    <GhostBtn disabled={actionBusy === a.id} onClick={() => onRollback(a.id)}>
                      Undo
                    </GhostBtn>
                  )}
                </div>
                {a.artifactPath && (
                  <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, color: "var(--cascade-text-4)", marginTop: 4 }}>
                    {a.artifactPath}
                  </div>
                )}
                {a.content && <pre style={preStyle}>{a.content}</pre>}
              </div>
            ))}
          </div>
        </DetailBlock>
      )}

      {lastRun && (
        <DetailBlock title={`Last sandbox run · ${lastRun.status}`}>
          <div style={{ fontSize: 12.5, color: "var(--cascade-text-2)", lineHeight: 1.5, marginBottom: 8 }}>
            {lastRun.summary}
          </div>
          <div style={{ display: "grid", gap: 5 }}>
            {lastRun.steps.map((s) => (
              <div key={s.step} style={{ fontFamily: "var(--cascade-mono)", fontSize: 11, color: "var(--cascade-text-3)" }}>
                <span style={{ color: "var(--cascade-accent)" }}>{s.tool || "step"}</span> — {s.action}
                {s.mockedResult && <span style={{ color: "var(--cascade-text-4)" }}> → {s.mockedResult}</span>}
              </div>
            ))}
          </div>
        </DetailBlock>
      )}

      {audit.length > 0 && (
        <DetailBlock title="Audit log (immutable)">
          <div style={{ display: "grid", gap: 4 }}>
            {audit.map((a) => (
              <div key={a.id} style={{ fontFamily: "var(--cascade-mono)", fontSize: 10.5, color: "var(--cascade-text-4)" }}>
                {new Date(a.createdAt).toLocaleString()} · <span style={{ color: "var(--cascade-text-3)" }}>{a.actor}</span> · {a.action}
              </div>
            ))}
          </div>
        </DetailBlock>
      )}
    </div>
  );
}

// ─── Small UI pieces ────────────────────────────────────────────────

function DetailBlock({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <div style={{ ...labelStyle, fontSize: 9.5, marginBottom: 6 }}>{title}</div>
      {children}
    </div>
  );
}

function ChipList({ items, empty }: { items: string[]; empty: string }) {
  if (!items || items.length === 0) {
    return <span style={{ fontSize: 12, color: "var(--cascade-text-4)" }}>{empty}</span>;
  }
  return (
    <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
      {items.map((t, i) => (
        <span key={`${t}-${i}`} style={chipStyle}>
          {t}
        </span>
      ))}
    </div>
  );
}

function Badge({ label, tone = "neutral" }: { label: string; tone?: "neutral" | "warn" }) {
  const warn = tone === "warn";
  return (
    <span
      style={{
        padding: "2px 8px",
        borderRadius: 999,
        background: warn ? "oklch(0.24 0.045 30 / 0.5)" : "var(--cascade-panel)",
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

function PrimaryBtn({ children, onClick, disabled, title }: { children: React.ReactNode; onClick?: () => void; disabled?: boolean; title?: string }) {
  return (
    <button onClick={onClick} disabled={disabled} title={title} style={{ ...btnBase, background: "var(--cascade-accent)", color: "var(--cascade-on-accent)", border: "none", opacity: disabled ? 0.5 : 1 }}>
      {children}
    </button>
  );
}

function GhostBtn({ children, onClick, disabled, title }: { children: React.ReactNode; onClick?: () => void; disabled?: boolean; title?: string }) {
  return (
    <button onClick={onClick} disabled={disabled} title={title} style={{ ...btnBase, background: "var(--cascade-panel)", color: "var(--cascade-text-2)", border: "1px solid var(--cascade-border)", opacity: disabled ? 0.5 : 1 }}>
      {children}
    </button>
  );
}

function ErrorBanner({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <div style={bannerStyle("warn")}>
      <span style={{ flex: 1, fontSize: 13 }}>Something went wrong — {message}</span>
      <button onClick={onRetry} style={bannerBtnStyle}>Retry</button>
    </div>
  );
}

function InfoBanner({ message, onClose }: { message: string; onClose: () => void }) {
  return (
    <div style={bannerStyle("ok")}>
      <span style={{ flex: 1, fontSize: 13 }}>{message}</span>
      <button onClick={onClose} style={bannerBtnStyle}>Dismiss</button>
    </div>
  );
}

function EmptyState({ headline, sub }: { headline: string; sub: string }) {
  return (
    <div style={{ background: "var(--cascade-panel)", border: "1px solid var(--cascade-border)", borderRadius: 14, padding: "44px 32px", textAlign: "center", color: "var(--cascade-text-3)" }}>
      <div style={{ fontFamily: "var(--cascade-serif)", fontSize: 24, color: "var(--cascade-text-2)", marginBottom: 6 }}>{headline}</div>
      <div style={{ fontSize: 13.5, lineHeight: 1.5, maxWidth: 520, margin: "0 auto" }}>{sub}</div>
    </div>
  );
}

// ─── styles ─────────────────────────────────────────────────────────

const labelStyle: React.CSSProperties = {
  fontFamily: "var(--cascade-mono)",
  fontSize: 10.5,
  letterSpacing: 1.6,
  textTransform: "uppercase",
  color: "var(--cascade-text-3)",
};

const agentKindStyle: React.CSSProperties = {
  fontFamily: "var(--cascade-mono)",
  fontSize: 10,
  letterSpacing: 1.0,
  textTransform: "uppercase",
  color: "var(--cascade-accent)",
};

const btnBase: React.CSSProperties = {
  padding: "9px 16px",
  borderRadius: 7,
  cursor: "pointer",
  fontFamily: "var(--cascade-sans)",
  fontSize: 12.5,
  fontWeight: 500,
  whiteSpace: "nowrap",
};

const chipStyle: React.CSSProperties = {
  padding: "3px 9px",
  borderRadius: 6,
  background: "var(--cascade-panel-2)",
  border: "1px solid var(--cascade-border)",
  fontFamily: "var(--cascade-mono)",
  fontSize: 10.5,
  color: "var(--cascade-text-3)",
};

const pillStyle: React.CSSProperties = {
  marginLeft: 8,
  padding: "1px 6px",
  borderRadius: 999,
  background: "oklch(0.24 0.045 60 / 0.5)",
  border: "1px solid var(--cascade-border)",
  fontFamily: "var(--cascade-mono)",
  fontSize: 9,
  letterSpacing: 0.5,
  textTransform: "uppercase",
  color: "var(--cascade-text-3)",
};

const discloseBtnStyle: React.CSSProperties = {
  marginTop: 12,
  background: "transparent",
  border: "none",
  cursor: "pointer",
  padding: 0,
  fontFamily: "var(--cascade-mono)",
  fontSize: 11,
  letterSpacing: 0.6,
  color: "var(--cascade-text-3)",
};

const preStyle: React.CSSProperties = {
  marginTop: 8,
  marginBottom: 0,
  padding: "10px 12px",
  borderRadius: 8,
  background: "var(--cascade-bg)",
  border: "1px solid var(--cascade-border)",
  fontFamily: "var(--cascade-mono)",
  fontSize: 11,
  lineHeight: 1.5,
  color: "var(--cascade-text-2)",
  whiteSpace: "pre-wrap",
  wordBreak: "break-word",
  maxHeight: 280,
  overflow: "auto",
};

const anomalyBoxStyle: React.CSSProperties = {
  marginTop: 10,
  padding: "8px 12px",
  borderRadius: 8,
  background: "oklch(0.24 0.045 30 / 0.35)",
  border: "1px solid oklch(0.45 0.085 30 / 0.5)",
  fontSize: 12,
  color: "var(--cascade-text-2)",
};

function bannerStyle(tone: "warn" | "ok"): React.CSSProperties {
  const warn = tone === "warn";
  return {
    background: warn ? "oklch(0.24 0.045 30 / 0.5)" : "oklch(0.22 0.03 145 / 0.5)",
    border: `1px solid ${warn ? "oklch(0.45 0.085 30 / 0.6)" : "oklch(0.44 0.08 145 / 0.6)"}`,
    color: warn ? "oklch(0.84 0.085 35)" : "var(--cascade-text)",
    padding: "12px 16px",
    borderRadius: 9,
    marginBottom: 20,
    display: "flex",
    gap: 12,
    alignItems: "center",
  };
}

const bannerBtnStyle: React.CSSProperties = {
  padding: "6px 12px",
  borderRadius: 6,
  background: "transparent",
  border: "1px solid currentColor",
  color: "inherit",
  fontFamily: "var(--cascade-mono)",
  fontSize: 11,
  cursor: "pointer",
};
