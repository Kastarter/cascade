// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// In-app Cascade floating box. Rendered inside the main Cascade window (mounted
// by the titlebar, so it's on every screen) and listens to the same
// `cascade-hands-status` events the backend emits. This is the reliable way to
// SEE an agent working — detection ("Refresh signals"), background "Run now",
// and computer-use all surface here, fixed bottom-right, with per-agent STOP +
// approve. (The separate always-on-top overlay window handles showing the
// agent's cursor over OTHER apps during computer-use.)

"use client";

import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";

interface HandsStatus {
  specId: number;
  name: string;
  goal: string;
  narration: string;
  step: number;
  supervised: boolean;
  awaitingApproval: boolean;
  done: boolean;
  error: string | null;
  hue: number;
}

export function CascadeHandsInline() {
  const [agents, setAgents] = useState<Record<number, HandsStatus>>({});

  useEffect(() => {
    const un = listen<HandsStatus>("cascade-hands-status", (e) => {
      const s = e.payload;
      setAgents((prev) => ({ ...prev, [s.specId]: s }));
      if (s.done) {
        setTimeout(() => {
          setAgents((prev) => {
            const next = { ...prev };
            delete next[s.specId];
            return next;
          });
        }, 4000);
      }
    });
    return () => {
      un.then((f) => f());
    };
  }, []);

  const rows = Object.values(agents);
  if (rows.length === 0) return null;

  const working = rows.filter((r) => !r.done).length;

  return (
    <div
      style={{
        position: "fixed",
        bottom: 18,
        right: 18,
        width: 340,
        zIndex: 9999,
        fontFamily: "var(--cascade-sans)",
        animation: "cascadeBoxIn 0.3s cubic-bezier(0.2,0.8,0.2,1)",
      }}
    >
      <div
        style={{
          background: "linear-gradient(180deg, oklch(0.20 0.02 150 / 0.97), oklch(0.15 0.015 150 / 0.97))",
          border: "1px solid oklch(0.5 0.12 155 / 0.4)",
          borderRadius: 14,
          padding: "11px 13px",
          color: "var(--cascade-text)",
          boxShadow: "0 18px 50px rgba(0,0,0,0.5)",
          backdropFilter: "blur(14px)",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: rows.length ? 9 : 0 }}>
          <CascadeSpark />
          <span style={{ font: "700 10.5px var(--cascade-mono)", letterSpacing: 1, color: "oklch(0.86 0.13 155)" }}>
            CASCADE {working > 0 ? "IS WORKING" : "FINISHED"}
          </span>
          <span style={{ flex: 1 }} />
          {working > 1 && (
            <button onClick={() => invoke("cascade_stop_computer_task", { specId: 0 }).catch(() => {})} style={stopAll}>
              STOP ALL
            </button>
          )}
        </div>

        <div style={{ display: "grid", gap: 8 }}>
          {rows.map((s) => (
            <Row key={s.specId} s={s} />
          ))}
        </div>
      </div>
      <style>{`@keyframes cascadeBoxIn { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }
        @keyframes cascadePulseInline { 0%,100% { opacity: 1; } 50% { opacity: 0.35; } }`}</style>
    </div>
  );
}

function Row({ s }: { s: HandsStatus }) {
  const color = `oklch(0.80 0.15 ${s.hue})`;
  const isComputerUse = s.specId >= 0;
  return (
    <div style={{ border: `1px solid ${color}44`, borderRadius: 10, padding: "8px 10px", background: "rgba(255,255,255,0.02)" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <span
          style={{
            width: 7,
            height: 7,
            borderRadius: "50%",
            background: s.done ? "var(--cascade-text-4)" : color,
            boxShadow: s.done ? "none" : `0 0 7px ${color}`,
            animation: s.done ? "none" : "cascadePulseInline 1.4s ease-in-out infinite",
            flexShrink: 0,
          }}
        />
        <span style={{ font: "700 11px var(--cascade-mono)", color, maxWidth: 180, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
          {s.name}
        </span>
        <span style={{ flex: 1 }} />
        {!s.done && isComputerUse && (
          <button onClick={() => invoke("cascade_stop_computer_task", { specId: s.specId }).catch(() => {})} style={stopBtn}>
            STOP
          </button>
        )}
      </div>
      <div style={{ fontSize: 12.5, lineHeight: 1.35, marginTop: 5, color: s.error ? "oklch(0.78 0.13 30)" : "var(--cascade-text-2)" }}>
        ▸ {s.narration}
      </div>
      {s.awaitingApproval && isComputerUse && (
        <div style={{ display: "flex", gap: 6, marginTop: 7 }}>
          <button onClick={() => invoke("cascade_approve_computer_step", { specId: s.specId }).catch(() => {})} style={ok}>
            ✓ Do it
          </button>
          <button onClick={() => invoke("cascade_reject_computer_step", { specId: s.specId }).catch(() => {})} style={no}>
            ✗ Skip
          </button>
        </div>
      )}
    </div>
  );
}

function CascadeSpark() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
      <path d="M4 7c4 0 4 4 8 4s4-4 8-4" stroke="oklch(0.82 0.14 155)" strokeWidth="1.6" strokeLinecap="round" opacity="0.5" />
      <path d="M4 13c4 0 4 4 8 4s4-4 8-4" stroke="oklch(0.82 0.14 155)" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  );
}

const stopBtn: React.CSSProperties = {
  padding: "3px 8px",
  borderRadius: 6,
  background: "oklch(0.4 0.12 30 / 0.25)",
  border: "1px solid oklch(0.55 0.14 30 / 0.55)",
  color: "oklch(0.82 0.13 35)",
  font: "700 9px var(--cascade-mono)",
  letterSpacing: 0.8,
  cursor: "pointer",
};
const stopAll: React.CSSProperties = { ...stopBtn, fontSize: 9 };
const ok: React.CSSProperties = {
  flex: 1,
  padding: "6px 0",
  borderRadius: 7,
  background: "oklch(0.6 0.13 155)",
  border: "none",
  color: "oklch(0.14 0.03 155)",
  font: "700 11.5px var(--cascade-sans)",
  cursor: "pointer",
};
const no: React.CSSProperties = {
  flex: 1,
  padding: "6px 0",
  borderRadius: 7,
  background: "transparent",
  border: "1px solid var(--cascade-border)",
  color: "var(--cascade-text-2)",
  font: "600 11.5px var(--cascade-sans)",
  cursor: "pointer",
};
