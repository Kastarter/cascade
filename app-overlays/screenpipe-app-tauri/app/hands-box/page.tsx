// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// The Cascade Hands box: a floating window that pops over your other apps when
// an agent starts. It shows a LIVE view of your screen with the agent's own
// cursor(s) moving in it as it does the work. Click the preview to reveal small
// per-cursor control boxes at the bottom (stop / approve), one per agent.

"use client";

import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow, LogicalSize } from "@tauri-apps/api/window";

interface Frame {
  imageBase64: string;
  imgW: number;
  imgH: number;
}
interface CursorState {
  specId: number;
  name: string;
  x: number;
  y: number;
  clicking: boolean;
  visible: boolean;
  hue: number;
}
interface StatusState {
  specId: number;
  name: string;
  narration: string;
  awaitingApproval: boolean;
  done: boolean;
  error: string | null;
  hue: number;
}

export default function HandsBox() {
  const [frame, setFrame] = useState<Frame | null>(null);
  const [cursors, setCursors] = useState<Record<number, CursorState>>({});
  const [agents, setAgents] = useState<Record<number, StatusState>>({});
  const [controlsOpen, setControlsOpen] = useState(false);
  const [paused, setPaused] = useState(false);
  const [collapsed, setCollapsed] = useState(false);

  const toggleMinimize = async () => {
    const next = !collapsed;
    setCollapsed(next);
    try {
      const win = getCurrentWindow();
      const sz = await win.innerSize();
      const sf = await win.scaleFactor();
      const logicalW = sz.width / sf;
      await win.setSize(new LogicalSize(logicalW, next ? 58 : 470));
    } catch {
      /* non-fatal */
    }
  };

  useEffect(() => {
    document.documentElement.style.background = "transparent";
    document.body.style.background = "transparent";
    document.body.style.margin = "0";

    const subs = [
      listen<Frame>("cascade-hands-frame", (e) => setFrame(e.payload)),
      listen<CursorState>("cascade-hands-cursor", (e) => {
        const c = e.payload;
        setCursors((prev) => {
          const next = { ...prev };
          if (!c.visible) delete next[c.specId];
          else next[c.specId] = c;
          return next;
        });
      }),
      listen<StatusState>("cascade-hands-status", (e) => {
        const s = e.payload;
        setAgents((prev) => ({ ...prev, [s.specId]: s }));
        if (s.done) {
          setTimeout(() => {
            setAgents((prev) => {
              const next = { ...prev };
              delete next[s.specId];
              return next;
            });
            setFrame((f) => f); // keep last frame briefly
          }, 3500);
        }
      }),
    ];
    return () => {
      subs.forEach((u) => u.then((f) => f()));
    };
  }, []);

  const rows = Object.values(agents);
  const working = rows.filter((r) => !r.done).length;
  const cursorList = Object.values(cursors);
  const latest = rows.find((r) => !r.done) ?? rows[0];

  return (
    <div style={{ fontFamily: "ui-sans-serif, -apple-system, system-ui, sans-serif", padding: 10, boxSizing: "border-box", background: "transparent", height: "100%" }}>
      <div
        style={{
          background: "linear-gradient(180deg, rgba(16,24,20,0.98), rgba(10,16,13,0.98))",
          border: "1px solid rgba(90,200,160,0.35)",
          borderRadius: 16,
          padding: 11,
          color: "#e7f3ec",
          boxShadow: "0 18px 50px rgba(0,0,0,0.55)",
          backdropFilter: "blur(14px)",
          height: "100%",
          boxSizing: "border-box",
          display: "flex",
          flexDirection: "column",
        }}
      >
        {/* header — drag region (move the box by dragging here) */}
        <div data-tauri-drag-region style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: collapsed ? 0 : 9, cursor: "grab" }}>
          <span style={{ width: 8, height: 8, borderRadius: "50%", background: working ? "#5ad8aa" : "#7a8a82", boxShadow: working ? "0 0 8px #5ad8aa" : "none", animation: working ? "cPulse 1.4s ease-in-out infinite" : "none", pointerEvents: "none" }} />
          <span style={{ font: "700 11px ui-monospace, Menlo, monospace", letterSpacing: 1, color: "#9ff0cc", pointerEvents: "none" }}>
            CASCADE HANDS · {working} working
          </span>
          <span style={{ flex: 1 }} />
          <button
            onClick={() => {
              const next = !paused;
              setPaused(next);
              invoke("cascade_pause_computer_task", { specId: 0, paused: next }).catch(() => {});
            }}
            style={pauseBtn}
          >
            {paused ? "RESUME" : "PAUSE"}
          </button>
          <button onClick={toggleMinimize} style={minBtn} title={collapsed ? "Expand" : "Minimize"}>
            {collapsed ? "▢" : "—"}
          </button>
          <button onClick={() => invoke("cascade_stop_computer_task", { specId: 0 }).catch(() => {})} style={stopAll}>
            STOP
          </button>
        </div>

        {!collapsed && (
          <>
        {/* body */}

        {/* live screen preview */}
        <div
          onClick={() => setControlsOpen((v) => !v)}
          title="Click for cursor controls"
          style={{ position: "relative", width: "100%", borderRadius: 10, overflow: "hidden", background: "#06100c", border: "1px solid rgba(255,255,255,0.06)", cursor: "pointer", minHeight: 120 }}
        >
          {frame ? (
            <img src={`data:image/png;base64,${frame.imageBase64}`} alt="agent screen" style={{ width: "100%", display: "block" }} />
          ) : (
            <div style={{ padding: "40px 0", textAlign: "center", color: "#6f8a7d", fontSize: 12.5 }}>
              {working ? "Looking at your screen…" : "Idle"}
            </div>
          )}

          {/* agent cursors overlaid on the preview */}
          {frame &&
            cursorList.map((c) => (
              <div
                key={c.specId}
                style={{
                  position: "absolute",
                  left: `${(c.x / frame.imgW) * 100}%`,
                  top: `${(c.y / frame.imgH) * 100}%`,
                  transform: "translate(-1px,-1px)",
                  transition: "left 0.45s cubic-bezier(0.22,1,0.36,1), top 0.45s cubic-bezier(0.22,1,0.36,1)",
                  pointerEvents: "none",
                }}
              >
                {c.clicking && (
                  <span style={{ position: "absolute", left: -9, top: -9, width: 18, height: 18, borderRadius: "50%", border: `2px solid oklch(0.82 0.16 ${c.hue})`, animation: "cRipple 0.5s ease-out" }} />
                )}
                <svg width="16" height="16" viewBox="0 0 24 24" style={{ filter: "drop-shadow(0 1px 2px rgba(0,0,0,0.6))" }}>
                  <path d="M4 2 L4 20 L9 15 L12.5 22 L15.5 20.5 L12 13.5 L19 13.5 Z" fill={`oklch(0.82 0.16 ${c.hue})`} stroke="#0b2018" strokeWidth="1.1" strokeLinejoin="round" />
                </svg>
                <span style={{ position: "absolute", left: 14, top: 3, padding: "1px 5px", borderRadius: 4, background: `oklch(0.26 0.08 ${c.hue})`, color: `oklch(0.86 0.14 ${c.hue})`, font: "600 8.5px ui-monospace, Menlo, monospace", whiteSpace: "nowrap" }}>
                  {c.name}
                </span>
              </div>
            ))}
        </div>

        {/* narration */}
        <div style={{ fontSize: 12.5, lineHeight: 1.35, marginTop: 9, minHeight: 17, color: latest?.error ? "#ffb4a0" : "#dcebe3" }}>
          {latest ? `▸ ${latest.narration}` : "Starting…"}
        </div>

        {/* per-cursor control boxes (revealed on click) */}
        {controlsOpen && rows.length > 0 && (
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginTop: 9, paddingTop: 9, borderTop: "1px solid rgba(255,255,255,0.07)" }}>
            {rows.map((s) => (
              <CursorControl key={s.specId} s={s} />
            ))}
          </div>
        )}
          </>
        )}
      </div>
      <style>{`@keyframes cPulse { 0%,100%{opacity:1} 50%{opacity:.35} } @keyframes cRipple { from{transform:scale(.4);opacity:1} to{transform:scale(1.9);opacity:0} }`}</style>
    </div>
  );
}

function CursorControl({ s }: { s: StatusState }) {
  const color = `oklch(0.82 0.15 ${s.hue})`;
  const stop = () => invoke("cascade_stop_computer_task", { specId: s.specId }).catch(() => {});
  const approve = () => invoke("cascade_approve_computer_step", { specId: s.specId }).catch(() => {});
  const reject = () => invoke("cascade_reject_computer_step", { specId: s.specId }).catch(() => {});
  return (
    <div style={{ border: `1px solid ${color}55`, borderRadius: 9, padding: "6px 8px", background: "rgba(255,255,255,0.02)", minWidth: 120 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: s.awaitingApproval ? 6 : 0 }}>
        <span style={{ width: 6, height: 6, borderRadius: "50%", background: s.done ? "#7a8a82" : color, flexShrink: 0 }} />
        <span style={{ font: "700 10px ui-monospace, Menlo, monospace", color, maxWidth: 110, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{s.name}</span>
        <span style={{ flex: 1 }} />
        {!s.done && <button onClick={stop} style={miniBtn}>stop</button>}
      </div>
      {s.awaitingApproval && (
        <div style={{ display: "flex", gap: 5 }}>
          <button onClick={approve} style={okBtn}>✓ do it</button>
          <button onClick={reject} style={noBtn}>✗ skip</button>
        </div>
      )}
    </div>
  );
}

const stopAll: React.CSSProperties = {
  padding: "3px 9px",
  borderRadius: 6,
  background: "rgba(220,80,60,0.18)",
  border: "1px solid rgba(220,90,70,0.6)",
  color: "#ffb4a0",
  font: "700 9px ui-monospace, Menlo, monospace",
  letterSpacing: 1,
  cursor: "pointer",
};
const pauseBtn: React.CSSProperties = {
  padding: "3px 9px",
  borderRadius: 6,
  background: "rgba(90,180,150,0.16)",
  border: "1px solid rgba(90,200,160,0.5)",
  color: "#9ff0cc",
  font: "700 9px ui-monospace, Menlo, monospace",
  letterSpacing: 1,
  cursor: "pointer",
};
const minBtn: React.CSSProperties = {
  padding: "3px 8px",
  borderRadius: 6,
  background: "rgba(255,255,255,0.06)",
  border: "1px solid rgba(255,255,255,0.15)",
  color: "#cfe6da",
  font: "700 10px ui-monospace, Menlo, monospace",
  cursor: "pointer",
  lineHeight: 1,
};
const miniBtn: React.CSSProperties = {
  padding: "2px 7px",
  borderRadius: 5,
  background: "rgba(220,80,60,0.15)",
  border: "1px solid rgba(220,90,70,0.5)",
  color: "#ffb4a0",
  font: "600 9px ui-monospace, Menlo, monospace",
  cursor: "pointer",
};
const okBtn: React.CSSProperties = {
  flex: 1,
  padding: "4px 0",
  borderRadius: 6,
  background: "#2f9e74",
  border: "none",
  color: "#04130d",
  font: "700 10px ui-sans-serif, system-ui",
  cursor: "pointer",
};
const noBtn: React.CSSProperties = {
  flex: 1,
  padding: "4px 0",
  borderRadius: 6,
  background: "transparent",
  border: "1px solid rgba(160,180,170,0.4)",
  color: "#c7d6cd",
  font: "600 10px ui-sans-serif, system-ui",
  cursor: "pointer",
};
