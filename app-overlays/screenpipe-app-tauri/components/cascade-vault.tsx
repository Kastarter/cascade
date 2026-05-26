// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Vault overlay — privacy/storage controls. Ported from Cascade-2/app.jsx
// VaultOverlay. Wired to real data: capture count from /search, recording
// pause/resume via Tauri commands.

"use client";

import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { localFetch } from "@/lib/api";

interface CascadeVaultProps {
  open: boolean;
  onClose: () => void;
}

export function CascadeVault({ open, onClose }: CascadeVaultProps) {
  const [todayCount, setTodayCount] = useState<number | null>(null);
  const [recording, setRecording] = useState<boolean>(true);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!open) return;
    const start = new Date();
    start.setHours(0, 0, 0, 0);
    localFetch(`/search?content_type=ocr&start_time=${start.toISOString()}&limit=1`)
      .then((r) => (r.ok ? r.json() : null))
      .then((j) => {
        if (!j) {
          setTodayCount(0);
          return;
        }
        const total = j?.pagination?.total ?? (Array.isArray(j?.data) ? j.data.length : 0);
        setTodayCount(total);
      })
      .catch((e) => {
        console.error("cascade-vault: count fetch failed", e);
        setTodayCount(0);
      });
  }, [open]);

  const pauseRecording = async () => {
    setBusy(true);
    try {
      await invoke("stop_capture");
      setRecording(false);
    } catch (e) {
      console.error("stop_capture failed", e);
    } finally {
      setBusy(false);
    }
  };

  const resumeRecording = async () => {
    setBusy(true);
    try {
      await invoke("start_capture");
      setRecording(true);
    } catch (e) {
      console.error("start_capture failed", e);
    } finally {
      setBusy(false);
    }
  };

  if (!open) return null;

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        background: "rgba(0,0,0,0.55)",
        backdropFilter: "blur(10px) saturate(140%)",
        WebkitBackdropFilter: "blur(10px) saturate(140%)",
        zIndex: 90,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        padding: 30,
      }}
      onClick={onClose}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: "var(--cascade-bg)",
          borderRadius: 14,
          border: "1px solid var(--cascade-border-hi)",
          maxWidth: 540,
          width: "100%",
          padding: "32px 36px",
          boxShadow: "0 24px 64px rgba(0,0,0,0.35)",
          position: "relative",
          backgroundImage: "linear-gradient(180deg, oklch(0.275 0.014 55), oklch(0.200 0.010 140))",
          color: "var(--cascade-text)",
          fontFamily: "var(--cascade-sans)",
        }}
      >
        <button
          onClick={onClose}
          style={{
            position: "absolute",
            top: 14,
            right: 16,
            width: 28,
            height: 28,
            borderRadius: 14,
            background: "var(--cascade-panel)",
            border: "1px solid var(--cascade-border)",
            color: "var(--cascade-text-2)",
            cursor: "pointer",
            fontSize: 16,
          }}
        >
          ×
        </button>

        <div
          style={{
            fontFamily: "var(--cascade-mono)",
            fontSize: 10.5,
            letterSpacing: 1.6,
            textTransform: "uppercase",
            color: "var(--cascade-text-3)",
            marginBottom: 6,
          }}
        >
          The vault
        </div>
        <div
          style={{
            fontFamily: "var(--cascade-serif)",
            fontSize: 28,
            fontStyle: "italic",
            color: "var(--cascade-text)",
            letterSpacing: -0.4,
            marginBottom: 8,
            fontWeight: 400,
          }}
        >
          Everything stays on this Mac.
        </div>
        <div style={{ fontSize: 13.5, color: "var(--cascade-text-3)", marginBottom: 22, lineHeight: 1.55 }}>
          No screenshots, transcripts, or OCR ever leave the device unless you export them yourself.
        </div>

        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "baseline",
            marginBottom: 18,
            paddingBottom: 16,
            borderBottom: "1px solid var(--cascade-border)",
          }}
        >
          <div>
            <div style={{ fontFamily: "var(--cascade-serif)", fontSize: 28 }}>
              {todayCount === null ? "…" : todayCount.toLocaleString()}
            </div>
            <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 10.5, color: "var(--cascade-text-3)", marginTop: 2 }}>
              captures today
            </div>
          </div>
          <div style={{ textAlign: "right" }}>
            <div style={{ fontFamily: "var(--cascade-serif)", fontSize: 28, color: "oklch(0.82 0.12 65)" }}>0 B</div>
            <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 10.5, color: "var(--cascade-text-3)", marginTop: 2 }}>
              shared off-device
            </div>
          </div>
        </div>

        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
          <button
            onClick={recording ? pauseRecording : resumeRecording}
            disabled={busy}
            style={vaultBtnStyle(false, busy)}
          >
            <span style={{ fontSize: 14, opacity: 0.8 }}>{recording ? "⏸" : "▶"}</span>
            {recording ? "Pause recording" : "Resume recording"}
          </button>
          <button disabled style={vaultBtnStyle(false, true)}>
            <span style={{ fontSize: 14, opacity: 0.5 }}>⊘</span>
            Manage block-list
          </button>
          <button disabled style={vaultBtnStyle(false, true)}>
            <span style={{ fontSize: 14, opacity: 0.5 }}>⌫</span>
            Forget today
          </button>
          <button disabled style={vaultBtnStyle(false, true)}>
            <span style={{ fontSize: 14, opacity: 0.5 }}>↗</span>
            Export this week
          </button>
        </div>

        <div
          style={{
            marginTop: 20,
            paddingTop: 16,
            borderTop: "1px solid var(--cascade-border)",
            textAlign: "center",
            fontFamily: "var(--cascade-mono)",
            fontSize: 10,
            color: "var(--cascade-text-4)",
          }}
        >
          ● running locally · nothing leaves this Mac
        </div>
      </div>
    </div>
  );
}

function vaultBtnStyle(danger: boolean, disabled: boolean): React.CSSProperties {
  return {
    padding: "12px 14px",
    borderRadius: 7,
    background: "var(--cascade-panel)",
    border: "1px solid var(--cascade-border)",
    color: danger ? "oklch(0.84 0.085 35)" : "var(--cascade-text)",
    fontFamily: "var(--cascade-sans)",
    fontSize: 13,
    cursor: disabled ? "default" : "pointer",
    textAlign: "left",
    display: "flex",
    alignItems: "center",
    gap: 10,
    opacity: disabled ? 0.4 : 1,
  };
}
