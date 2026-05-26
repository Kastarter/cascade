// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Cascade titlebar — below the native macOS title chrome.
// Brand + segmented view switcher + REC pill (toggles pause via the Vault
// modal) + storage button. Ported from Cascade-2/app.jsx Titlebar.

"use client";

import { useEffect, useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import { CascadeVault } from "@/components/cascade-vault";

export function CascadeTitlebar() {
  const [tick, setTick] = useState(0);
  const [vaultOpen, setVaultOpen] = useState(false);
  const [now, setNow] = useState<Date>(new Date());
  const router = useRouter();
  const pathname = usePathname();
  const onTodayRoute = pathname === "/today";

  useEffect(() => {
    const idA = setInterval(() => setTick((x) => x + 1), 1200);
    const idB = setInterval(() => setNow(new Date()), 30_000);
    return () => {
      clearInterval(idA);
      clearInterval(idB);
    };
  }, []);

  const dateLabel = now.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });

  return (
    <>
      <div
        style={{
          height: 44,
          flexShrink: 0,
          background: "oklch(0.175 0.010 140 / 0.74)",
          backdropFilter: "blur(16px) saturate(140%)",
          WebkitBackdropFilter: "blur(16px) saturate(140%)",
          borderBottom: "1px solid var(--cascade-border)",
          display: "flex",
          alignItems: "center",
          padding: "0 14px",
          position: "relative",
          gap: 16,
          color: "var(--cascade-text)",
          fontFamily: "var(--cascade-sans)",
        }}
      >
        {/* Brand */}
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <BrandMark />
          <span style={{ color: "var(--cascade-text)", fontSize: 13, fontWeight: 500 }}>Cascade</span>
        </div>

        {/* Segmented view switcher — center. Today disabled for now (Phase C). */}
        <div
          style={{
            position: "absolute",
            left: "50%",
            transform: "translateX(-50%)",
            display: "flex",
            gap: 0,
            background: "var(--cascade-panel)",
            border: "1px solid var(--cascade-border)",
            borderRadius: 8,
            padding: 2,
          }}
        >
          <button
            style={switcherBtn(!onTodayRoute)}
            onClick={() => router.push("/home")}
          >
            Reel
          </button>
          <button
            style={switcherBtn(onTodayRoute)}
            onClick={() => router.push("/today")}
          >
            Today
          </button>
        </div>

        {/* Right cluster: date · storage · REC pill */}
        <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 10 }}>
          <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 11, color: "var(--cascade-text-3)" }}>
            {dateLabel}
          </span>
          <button
            onClick={() => setVaultOpen(true)}
            title="Vault — storage & privacy"
            style={iconBtn}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
              <rect x="5" y="10" width="14" height="10" rx="2" />
              <path d="M8 10V7a4 4 0 0 1 8 0v3" />
            </svg>
          </button>
          <RecordingPill blinkOn={tick % 2 === 0} onClick={() => setVaultOpen(true)} />
        </div>
      </div>

      <CascadeVault open={vaultOpen} onClose={() => setVaultOpen(false)} />
    </>
  );
}

const iconBtn: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  width: 28,
  height: 28,
  borderRadius: 7,
  background: "var(--cascade-panel)",
  border: "1px solid var(--cascade-border)",
  color: "var(--cascade-text-2)",
  cursor: "pointer",
  padding: 0,
};

function switcherBtn(active: boolean): React.CSSProperties {
  return {
    padding: "5px 14px",
    borderRadius: 6,
    background: active ? "oklch(0.255 0.012 140)" : "transparent",
    color: active ? "var(--cascade-text)" : "var(--cascade-text-3)",
    border: "none",
    cursor: "pointer",
    fontFamily: "var(--cascade-sans)",
    fontSize: 12,
    fontWeight: 500,
    letterSpacing: 0.1,
    transition: "all 0.15s",
    boxShadow: active ? "0 1px 2px rgba(0,0,0,0.3)" : "none",
    opacity: 1,
  };
}

function BrandMark() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
      <path d="M4 7c4 0 4 4 8 4s4-4 8-4" stroke="var(--cascade-accent)" strokeWidth="1.5" strokeLinecap="round" opacity="0.5" />
      <path d="M4 13c4 0 4 4 8 4s4-4 8-4" stroke="var(--cascade-accent)" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  );
}

function RecordingPill({ blinkOn, onClick }: { blinkOn: boolean; onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      title="Click to manage recording + storage"
      style={{
        display: "flex",
        alignItems: "center",
        gap: 7,
        padding: "4px 10px 4px 8px",
        borderRadius: 999,
        background: "var(--cascade-rec-bg)",
        border: "1px solid var(--cascade-rec-border)",
        fontFamily: "var(--cascade-mono)",
        fontSize: 10.5,
        color: "var(--cascade-rec-text)",
        letterSpacing: 0.4,
        cursor: "pointer",
      }}
    >
      <span
        style={{
          width: 7,
          height: 7,
          borderRadius: "50%",
          background: "var(--cascade-rec-dot)",
          opacity: blinkOn ? 1 : 0.4,
          boxShadow: "0 0 8px var(--cascade-rec-dot)",
          transition: "opacity 0.5s",
        }}
      />
      REC · LOCAL
    </button>
  );
}
