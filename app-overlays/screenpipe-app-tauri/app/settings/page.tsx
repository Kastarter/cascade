// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Cascade Settings — replaces the Screenpipe settings UI on this route.
// Cascade-only: Claude API key management + privacy/recording notes + about.

"use client";

import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { CascadeTitlebar } from "@/components/cascade-titlebar";
import { CascadeByokDialog } from "@/components/cascade-byok-dialog";
import {
  CASCADE_DEFAULT_PROVIDER,
  CASCADE_ADVANCED_MODEL,
  CASCADE_PRIVACY_PROMISE,
  CascadeRunMode,
  getRunMode,
  setRunMode,
} from "@/lib/cascade-defaults";

export default function SettingsPage() {
  const [hasKey, setHasKey] = useState<boolean | null>(null);
  const [byokOpen, setByokOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [runMode, setRunModeState] = useState<CascadeRunMode>("local_browser");

  // localStorage is only available in the browser — read it after mount.
  useEffect(() => {
    setRunModeState(getRunMode());
  }, []);

  const chooseRunMode = (mode: CascadeRunMode) => {
    setRunMode(mode);
    setRunModeState(mode);
  };

  const refreshKey = useCallback(async () => {
    try {
      const s = await invoke<{ hasAnthropicKey: boolean }>("cascade_key_status");
      setHasKey(!!s?.hasAnthropicKey);
    } catch {
      setHasKey(false);
    }
  }, []);

  useEffect(() => {
    refreshKey();
  }, [refreshKey]);

  const clearKey = async () => {
    setBusy(true);
    try {
      await invoke("cascade_clear_anthropic_key");
      await refreshKey();
    } finally {
      setBusy(false);
    }
  };

  return (
    <div style={{ height: "100vh", overflowY: "auto", display: "flex", flexDirection: "column", background: "var(--cascade-bg)" }}>
      <CascadeTitlebar />

      <div
        style={{
          flex: 1,
          padding: "40px 56px 80px",
          maxWidth: 820,
          margin: "0 auto",
          width: "100%",
          color: "var(--cascade-text)",
          fontFamily: "var(--cascade-sans)",
        }}
      >
        <div style={{ marginBottom: 28 }}>
          <div style={label}>Settings</div>
          <h1
            style={{
              fontFamily: "var(--cascade-serif)",
              fontWeight: 400,
              fontSize: 40,
              lineHeight: 1.1,
              letterSpacing: -0.6,
              margin: "8px 0 0",
            }}
          >
            Cascade <span style={{ fontStyle: "italic", color: "var(--cascade-text-3)" }}>preferences</span>
          </h1>
        </div>

        {/* Claude API key */}
        <Section
          title="Claude API key"
          sub="Cascade runs its agents on your own Anthropic key (BYOK). Stored in the macOS Keychain — it never leaves this Mac except in calls you make to Anthropic."
        >
          <div style={{ display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
            <KeyBadge state={hasKey} />
            <div style={{ flex: 1 }} />
            <button style={primaryBtn} onClick={() => setByokOpen(true)}>
              {hasKey ? "Update key" : "Add key"}
            </button>
            {hasKey && (
              <button style={ghostBtn} disabled={busy} onClick={clearKey}>
                {busy ? "Removing…" : "Remove key"}
              </button>
            )}
          </div>
          <div style={{ marginTop: 14, display: "flex", gap: 18, flexWrap: "wrap" }}>
            <Meta label="Default model" value={CASCADE_DEFAULT_PROVIDER.model} />
            <Meta label="Escalation model" value={CASCADE_ADVANCED_MODEL} />
            <Meta label="Keychain service" value="com.cascade.app" />
          </div>
          <a
            href="https://console.anthropic.com/settings/keys"
            target="_blank"
            rel="noreferrer"
            style={{ display: "inline-block", marginTop: 12, fontSize: 12.5, color: "var(--cascade-accent)" }}
          >
            Get a key at console.anthropic.com/settings/keys →
          </a>
        </Section>

        {/* How agents run — on screen vs background */}
        <Section
          title="How agents run"
          sub="Pick how every agent works. You can change this anytime — it applies to all your agents."
        >
          <RunModeToggle value={runMode} onChange={chooseRunMode} />
          <p style={{ fontSize: 12.5, color: "var(--cascade-text-3)", lineHeight: 1.55, margin: "14px 0 0" }}>
            {runMode === "screen"
              ? "On your screen — the agent uses your real screen and cursor, so it can operate any app you already use. Requires Screen Recording, Accessibility, Input Monitoring, and a healthy UI recorder."
              : runMode === "local_vm"
                ? "Local VM — the driver contract is defined, but Cascade blocks this mode until a local VM provider is configured."
                : "Local Browser — the agent works inside the isolated browser shown in the control box. Web apps only, and you can keep using your computer while it runs."}
          </p>
        </Section>

        {/* Logins */}
        <Section
          title="Logins"
          sub="The first time an agent needs a tool, Cascade opens that tool's sign-in in context. Once you're in, the agent continues in the same product you already use."
        >
          <p style={{ fontSize: 13, color: "var(--cascade-text-2)", lineHeight: 1.55, margin: 0 }}>
            You never have to pre-wire a separate automation workspace. Logins are requested only when
            a cascade actually needs them, and the saved session is reused on future runs.
          </p>
        </Section>

        {/* Recording & privacy */}
        <Section
          title="Recording & privacy"
          sub="Capture and storage controls live in the Vault (the lock icon up top). Everything is recorded and stored locally."
        >
          <p style={{ fontSize: 13.5, color: "var(--cascade-text-2)", lineHeight: 1.55, margin: 0 }}>
            {CASCADE_PRIVACY_PROMISE}
          </p>
          <p style={{ fontSize: 12.5, color: "var(--cascade-text-3)", lineHeight: 1.5, marginTop: 10 }}>
            Agent suggestions use filtered Rewind context: sensitive apps (banking, health, legal,
            dating, private browsing) are excluded, typed text is skipped, and manager dashboards use
            allowlisted privacy aggregates.
          </p>
        </Section>

        {/* About */}
        <Section title="About" sub="">
          <div style={{ display: "flex", gap: 18, flexWrap: "wrap" }}>
            <Meta label="Product" value="Cascade" />
            <Meta label="Layer 1" value="Reel · rewind + Q&A" />
            <Meta label="Layer 2" value="Detector · manager review · cascaded agents" />
          </div>
        </Section>
      </div>

      <CascadeByokDialog open={byokOpen} onOpenChange={setByokOpen} onSaved={refreshKey} />
    </div>
  );
}

function Section({ title, sub, children }: { title: string; sub: string; children: React.ReactNode }) {
  return (
    <section
      style={{
        border: "1px solid var(--cascade-border)",
        borderRadius: 14,
        background: "var(--cascade-panel)",
        padding: "22px 24px",
        marginBottom: 16,
      }}
    >
      <div style={{ fontSize: 16, fontWeight: 600, marginBottom: sub ? 4 : 14 }}>{title}</div>
      {sub && <div style={{ fontSize: 13, color: "var(--cascade-text-3)", lineHeight: 1.5, marginBottom: 16, maxWidth: 620 }}>{sub}</div>}
      {children}
    </section>
  );
}

function RunModeToggle({
  value,
  onChange,
}: {
  value: CascadeRunMode;
  onChange: (m: CascadeRunMode) => void;
}) {
  const options: { id: CascadeRunMode; title: string; hint: string }[] = [
    { id: "local_browser", title: "Local Browser", hint: "Isolated browser · web apps · keep working" },
    { id: "screen", title: "On your screen", hint: "Uses your real screen · any app" },
    { id: "local_vm", title: "Local VM", hint: "Driver defined · blocked until provider is configured" },
  ];
  return (
    <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
      {options.map((o) => {
        const active = value === o.id;
        return (
          <button
            key={o.id}
            onClick={() => onChange(o.id)}
            style={{
              flex: "1 1 240px",
              textAlign: "left",
              padding: "14px 16px",
              borderRadius: 10,
              cursor: "pointer",
              background: active ? "var(--cascade-accent)" : "var(--cascade-bg)",
              color: active ? "var(--cascade-on-accent)" : "var(--cascade-text-2)",
              border: `1px solid ${active ? "var(--cascade-accent)" : "var(--cascade-border)"}`,
              fontFamily: "var(--cascade-sans)",
            }}
          >
            <div style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 14, fontWeight: 600 }}>
              <span
                style={{
                  width: 14,
                  height: 14,
                  borderRadius: "50%",
                  border: `2px solid ${active ? "var(--cascade-on-accent)" : "var(--cascade-text-4)"}`,
                  background: active ? "var(--cascade-on-accent)" : "transparent",
                  flexShrink: 0,
                }}
              />
              {o.title}
            </div>
            <div style={{ fontSize: 12, marginTop: 5, marginLeft: 22, opacity: active ? 0.85 : 0.7 }}>{o.hint}</div>
          </button>
        );
      })}
    </div>
  );
}

function KeyBadge({ state }: { state: boolean | null }) {
  const set = state === true;
  const text = state === null ? "checking…" : set ? "Key set" : "No key yet";
  const color = set ? "oklch(0.82 0.12 150)" : "var(--cascade-text-3)";
  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 8,
        padding: "5px 11px",
        borderRadius: 999,
        border: "1px solid var(--cascade-border)",
        background: "var(--cascade-bg)",
        fontFamily: "var(--cascade-mono)",
        fontSize: 11.5,
        color,
      }}
    >
      <span style={{ width: 8, height: 8, borderRadius: "50%", background: set ? "oklch(0.72 0.16 150)" : "var(--cascade-text-4)" }} />
      {text}
    </span>
  );
}

function Meta({ label: l, value }: { label: string; value: string }) {
  return (
    <div>
      <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 9.5, letterSpacing: 1.2, textTransform: "uppercase", color: "var(--cascade-text-4)" }}>
        {l}
      </div>
      <div style={{ fontFamily: "var(--cascade-mono)", fontSize: 12, color: "var(--cascade-text-2)", marginTop: 3 }}>{value}</div>
    </div>
  );
}

const label: React.CSSProperties = {
  fontFamily: "var(--cascade-mono)",
  fontSize: 10.5,
  letterSpacing: 1.6,
  textTransform: "uppercase",
  color: "var(--cascade-text-3)",
};

const primaryBtn: React.CSSProperties = {
  padding: "8px 16px",
  borderRadius: 8,
  background: "var(--cascade-accent)",
  color: "var(--cascade-on-accent)",
  border: "none",
  cursor: "pointer",
  fontFamily: "var(--cascade-sans)",
  fontSize: 12.5,
  fontWeight: 500,
};

const ghostBtn: React.CSSProperties = {
  padding: "8px 16px",
  borderRadius: 8,
  background: "var(--cascade-panel)",
  color: "var(--cascade-text-2)",
  border: "1px solid var(--cascade-border)",
  cursor: "pointer",
  fontFamily: "var(--cascade-sans)",
  fontSize: 12.5,
};
