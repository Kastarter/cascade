// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Vault overlay — storage, quota, throttling, recording controls.
// Ports the Cascade-2 prototype Vault and adds production safeguards.

"use client";

import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { localFetch } from "@/lib/api";
import {
  clearThrottlePauseReason,
  DEFAULT_THROTTLE,
  describeReason,
  useCascadeThrottleSnapshot,
} from "@/components/cascade-throttle";

interface CascadeVaultProps {
  open: boolean;
  onClose: () => void;
}

const QUOTA_KEY = "cascade-quota-gb";

function loadQuotaGb(): number {
  if (typeof window === "undefined") return DEFAULT_THROTTLE.quotaGb;
  const v = parseFloat(window.localStorage.getItem(QUOTA_KEY) ?? "");
  return Number.isFinite(v) && v >= 1 ? v : DEFAULT_THROTTLE.quotaGb;
}

function saveQuotaGb(gb: number): void {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(QUOTA_KEY, String(gb));
}

function formatBytes(b: number | null): string {
  if (b === null || b === undefined) return "—";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let v = b;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v >= 100 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`;
}

export function CascadeVault({ open, onClose }: CascadeVaultProps) {
  const [todayCount, setTodayCount] = useState<number | null>(null);
  const [usedBytes, setUsedBytes] = useState<number | null>(null);
  const [batteryPct, setBatteryPct] = useState<number | null>(null);
  const [batteryCharging, setBatteryCharging] = useState<boolean>(false);
  const [recording, setRecording] = useState<boolean>(true);
  const [busy, setBusy] = useState(false);
  const [quotaGb, setQuotaGbState] = useState<number>(loadQuotaGb());

  // Throttle hook runs even when modal isn't open; we read its state here
  // for the status badge. Mount happens in CascadeTitlebar so it stays alive.
  const throttleState = useCascadeThrottleSnapshot();

  const syncRecordingState = async () => {
    try {
      const r = await localFetch("/health");
      if (!r.ok) return;
      const j = await r.json();
      const status = String(j?.status ?? "").toLowerCase();
      const frameStatus = String(j?.frame_status ?? "").toLowerCase();
      const uiRecorderRunning = Boolean(j?.ui_recorder?.running);
      setRecording(
        status === "recording" ||
          status === "healthy" ||
          status === "starting" ||
          (frameStatus === "ok" && uiRecorderRunning),
      );
    } catch {
      // keep last UI state
    }
  };

  useEffect(() => {
    if (!open) return;
    const start = new Date();
    start.setHours(0, 0, 0, 0);

    // Today's capture count
    localFetch(`/search?content_type=all&start_time=${start.toISOString()}&limit=1`)
      .then((r) => (r.ok ? r.json() : null))
      .then((j) => {
        if (!j) {
          setTodayCount(0);
          return;
        }
        const total = j?.pagination?.total ?? (Array.isArray(j?.data) ? j.data.length : 0);
        setTodayCount(total);
      })
      .catch(() => setTodayCount(0));

    // Disk usage
    invoke<any>("get_disk_usage", { forceRefresh: false })
      .then((r) => {
        const b = r?.total_size ?? r?.used_bytes ?? r?.cascade_size ?? r?.screenpipe_size ?? null;
        setUsedBytes(typeof b === "number" ? b : null);
      })
      .catch(() => setUsedBytes(null));

    // Battery (WKWebView supports navigator.getBattery)
    // @ts-expect-error
    if (typeof navigator?.getBattery === "function") {
      // @ts-expect-error
      navigator.getBattery().then((b: any) => {
        setBatteryPct(Math.round((b.level ?? 1) * 100));
        setBatteryCharging(!!b.charging);
      });
    }

    syncRecordingState();
  }, [open]);

  const pauseRecording = async () => {
    setBusy(true);
    try {
      clearThrottlePauseReason();
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
      clearThrottlePauseReason();
      await invoke("start_capture");
      setRecording(true);
    } catch (e) {
      console.error("start_capture failed", e);
    } finally {
      setBusy(false);
    }
  };

  const handleQuotaChange = (gb: number) => {
    setQuotaGbState(gb);
    saveQuotaGb(gb);
  };

  if (!open) return null;

  const quotaBytes = quotaGb * 1024 ** 3;
  const usedPct = usedBytes !== null ? Math.min(100, (usedBytes / quotaBytes) * 100) : 0;
  const usedColor = usedPct >= 90 ? "oklch(0.70 0.16 30)" : usedPct >= 70 ? "oklch(0.78 0.13 60)" : "var(--cascade-accent)";

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
        overflowY: "auto",
      }}
      onClick={onClose}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: "var(--cascade-bg)",
          borderRadius: 14,
          border: "1px solid var(--cascade-border-hi)",
          maxWidth: 620,
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
          aria-label="Close Vault"
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

        {/* THROTTLE STATUS BADGE */}
        {throttleState.kind === "throttled" && (
          <div
            style={{
              marginBottom: 18,
              padding: "10px 14px",
              borderRadius: 9,
              background: "oklch(0.24 0.045 30 / 0.5)",
              border: "1px solid oklch(0.45 0.085 30 / 0.6)",
              color: "oklch(0.84 0.085 35)",
              fontSize: 12.5,
              display: "flex",
              alignItems: "center",
              gap: 10,
            }}
          >
            <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10.5, letterSpacing: 0.8 }}>⏸ THROTTLED</span>
            <span style={{ flex: 1 }}>{describeReason(throttleState.reason)} — capture paused automatically</span>
          </div>
        )}

        {/* COUNTS ROW */}
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "1fr 1fr 1fr",
            gap: 16,
            marginBottom: 18,
            paddingBottom: 16,
            borderBottom: "1px solid var(--cascade-border)",
          }}
        >
          <StatCard label="captures today" value={todayCount?.toLocaleString() ?? "…"} />
          <StatCard
            label="cascade on disk"
            value={formatBytes(usedBytes)}
            sub={`of ${quotaGb} GB quota`}
          />
          <StatCard
            label="battery"
            value={batteryPct !== null ? `${batteryPct}%` : "—"}
            sub={batteryCharging ? "charging" : "on battery"}
          />
        </div>

        {/* QUOTA BAR + SLIDER */}
        <div style={{ marginBottom: 22 }}>
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "baseline",
              marginBottom: 6,
            }}
          >
            <span
              style={{
                fontFamily: "var(--cascade-mono)",
                fontSize: 10,
                letterSpacing: 1.4,
                textTransform: "uppercase",
                color: "var(--cascade-text-3)",
              }}
            >
              Quota — pauses recording when reached
            </span>
            <span
              style={{
                fontFamily: "var(--cascade-mono)",
                fontSize: 11,
                color: usedPct >= 90 ? "oklch(0.84 0.085 35)" : "var(--cascade-text-2)",
              }}
            >
              {usedPct.toFixed(0)}%
            </span>
          </div>
          <div
            style={{
              height: 8,
              borderRadius: 4,
              background: "oklch(0.180 0.010 140)",
              overflow: "hidden",
              marginBottom: 12,
            }}
          >
            <div
              style={{
                width: `${usedPct}%`,
                height: "100%",
                background: usedColor,
                transition: "width 0.4s ease, background 0.3s ease",
                boxShadow: usedPct >= 90 ? `0 0 8px ${usedColor}` : "none",
              }}
            />
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
            <span style={{ fontSize: 11, color: "var(--cascade-text-3)", minWidth: 60 }}>1 GB</span>
            <input
              aria-label="Recording quota"
              type="range"
              min={1}
              max={50}
              step={1}
              value={quotaGb}
              onChange={(e) => handleQuotaChange(parseInt(e.target.value))}
              style={{
                flex: 1,
                accentColor: "var(--cascade-accent)",
              }}
            />
            <span style={{ fontSize: 11, color: "var(--cascade-text-3)", minWidth: 60, textAlign: "right" }}>50 GB</span>
          </div>
          <div
            style={{
              marginTop: 6,
              fontSize: 11,
              color: "var(--cascade-text-3)",
              fontFamily: "var(--cascade-mono)",
            }}
          >
            Quota: <span style={{ color: "var(--cascade-text)" }}>{quotaGb} GB</span>
          </div>
        </div>

        {/* THROTTLE POLICY */}
        <div
          style={{
            marginBottom: 22,
            paddingTop: 16,
            borderTop: "1px solid var(--cascade-border)",
            fontFamily: "var(--cascade-mono)",
            fontSize: 10.5,
            color: "var(--cascade-text-3)",
            lineHeight: 1.7,
            letterSpacing: 0.4,
          }}
        >
          <div style={{ marginBottom: 4 }}>
            <strong style={{ color: "var(--cascade-text-2)", fontWeight: 500 }}>AUTO-PAUSE WHEN</strong>
          </div>
          <div>· cascade data exceeds {quotaGb} GB quota</div>
          <div>· battery drops below {DEFAULT_THROTTLE.minBatteryPct}% on battery power</div>
          <div style={{ marginTop: 6, color: "var(--cascade-text-4)" }}>
            Resumes automatically when conditions recover. Manual pause overrides everything.
          </div>
        </div>

        {/* ACTIONS */}
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
          {recording ? "● recording locally · nothing leaves this Mac" : "⏸ recording paused · nothing leaves this Mac"}
        </div>
      </div>
    </div>
  );
}

function StatCard({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div>
      <div style={{ fontFamily: "var(--cascade-serif)", fontSize: 24, color: "var(--cascade-text)" }}>{value}</div>
      <div
        style={{
          fontFamily: "var(--cascade-mono)",
          fontSize: 10,
          color: "var(--cascade-text-3)",
          marginTop: 2,
          letterSpacing: 0.6,
          textTransform: "uppercase",
        }}
      >
        {label}
      </div>
      {sub && (
        <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, color: "var(--cascade-text-4)", marginTop: 1 }}>
          {sub}
        </div>
      )}
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
