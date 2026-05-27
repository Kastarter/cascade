// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Cascade Throttle — background safety net for production deployments.
//
// Polls disk usage + battery every 60 seconds. When thresholds are breached,
// pauses Screenpipe capture via `stop_capture`. When conditions recover,
// resumes — but only if WE paused it (never override a user-initiated pause).
//
// Caveat: this is a JS-side throttle. It only runs while the Cascade window
// is open. A production-grade autonomous throttle belongs in Rust, hooked
// into the capture loop directly. This is the v1 — it covers the common case
// (user opens Cascade, disk fills overnight) but not the edge case (Cascade
// window closed, disk fills, no throttle).

"use client";

import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";

export interface ThrottleConfig {
  quotaGb: number;            // hard cap on Cascade local data dir
  minFreeDiskGb: number;      // pause if total disk free < this
  minBatteryPct: number;      // pause if battery < this AND unplugged
  pollIntervalMs: number;
}

export const DEFAULT_THROTTLE: ThrottleConfig = {
  quotaGb: 10,
  minFreeDiskGb: 20,
  minBatteryPct: 20,
  pollIntervalMs: 60_000,
};

export type ThrottleState =
  | { kind: "active" }
  | { kind: "throttled"; reason: "quota_exceeded" | "low_disk" | "low_battery" };

const PAUSE_REASON_KEY = "cascade-throttle-paused-by";
const THROTTLE_STATE_EVENT = "cascade-throttle-state";

let throttleSnapshot: ThrottleState = { kind: "active" };

function isBrowser(): boolean {
  return typeof window !== "undefined";
}

function sameThrottleState(a: ThrottleState, b: ThrottleState): boolean {
  if (a.kind !== b.kind) return false;
  if (a.kind === "active") return true;
  return b.kind === "throttled" && a.reason === b.reason;
}

function publishThrottleSnapshot(next: ThrottleState) {
  if (sameThrottleState(throttleSnapshot, next)) return;
  throttleSnapshot = next;
  if (!isBrowser()) return;
  window.dispatchEvent(new CustomEvent(THROTTLE_STATE_EVENT, { detail: next }));
}

export function getCascadeThrottleSnapshot(): ThrottleState {
  return throttleSnapshot;
}

export function clearThrottlePauseReason(): void {
  if (!isBrowser()) return;
  window.localStorage.removeItem(PAUSE_REASON_KEY);
}

export function useCascadeThrottleSnapshot(): ThrottleState {
  const [state, setState] = useState<ThrottleState>(getCascadeThrottleSnapshot());

  useEffect(() => {
    if (!isBrowser()) return;
    const handler = (event: Event) => {
      const custom = event as CustomEvent<ThrottleState>;
      if (custom.detail) {
        setState(custom.detail);
      }
    };
    window.addEventListener(THROTTLE_STATE_EVENT, handler as EventListener);
    return () => window.removeEventListener(THROTTLE_STATE_EVENT, handler as EventListener);
  }, []);

  return state;
}

interface DiskUsageResponse {
  // Screenpipe returns numeric bytes; key names checked at runtime
  total_size?: number;
  used_bytes?: number;
  free?: number;
  // We tolerate either schema shape — Screenpipe's response varies by version.
  [k: string]: any;
}

interface BatteryStatus {
  pct: number;
  charging: boolean;
}

async function getCascadeDataBytes(): Promise<number | null> {
  try {
    const r: DiskUsageResponse | null = await invoke("get_disk_usage", { forceRefresh: false });
    if (!r) return null;
    // Try multiple field names — Screenpipe's schema has shifted across versions
    return (
      r.total_size ??
      r.used_bytes ??
      r.cascade_size ??
      r.screenpipe_size ??
      null
    );
  } catch (e) {
    console.warn("cascade-throttle: get_disk_usage failed", e);
    return null;
  }
}

async function getBatteryStatus(): Promise<BatteryStatus | null> {
  if (typeof navigator === "undefined") return null;
  // navigator.getBattery is deprecated in Chrome but works in WKWebView (Safari).
  // Tauri on macOS uses WKWebView, so this is reliable in our target environment.
  // @ts-expect-error — getBattery is not in modern type defs but exists in WKWebView
  if (typeof navigator.getBattery !== "function") return null;
  try {
    // @ts-expect-error
    const b: any = await navigator.getBattery();
    return { pct: Math.round((b.level ?? 1) * 100), charging: !!b.charging };
  } catch {
    return null;
  }
}

/**
 * useCascadeThrottle — runs the throttle policy in a React component.
 * Returns the current ThrottleState so other components (e.g. the Vault
 * modal) can render it.
 *
 * Mount once globally (e.g. in CascadeTitlebar) — it owns the Screenpipe
 * pause/resume calls and stamps localStorage so we don't fight a
 * user-initiated pause.
 */
export function useCascadeThrottle(config: ThrottleConfig = DEFAULT_THROTTLE): ThrottleState {
  const [state, setState] = useState<ThrottleState>({ kind: "active" });
  const lastReasonRef = useRef<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    const evaluate = async () => {
      if (cancelled) return;
      const [dataBytes, battery] = await Promise.all([
        getCascadeDataBytes(),
        getBatteryStatus(),
      ]);

      const quotaBytes = config.quotaGb * 1024 ** 3;
      const overQuota = dataBytes !== null && dataBytes > quotaBytes;
      const lowBattery = battery !== null && !battery.charging && battery.pct < config.minBatteryPct;

      // Disk-free check: navigator.storage.estimate gives quota, not free disk.
      // For production we should add a Tauri command for true free-disk; v1
      // skips that and only enforces the Cascade-quota part.
      let nextState: ThrottleState = { kind: "active" };
      if (overQuota) nextState = { kind: "throttled", reason: "quota_exceeded" };
      else if (lowBattery) nextState = { kind: "throttled", reason: "low_battery" };

      setState(nextState);
      publishThrottleSnapshot(nextState);

      // Apply / clear pause
      if (nextState.kind === "throttled") {
        if (lastReasonRef.current !== nextState.reason) {
          try {
            await invoke("stop_capture");
            if (isBrowser()) {
              window.localStorage.setItem(PAUSE_REASON_KEY, nextState.reason);
            }
            console.info(`cascade-throttle: paused — ${nextState.reason}`);
          } catch (e) {
            console.error("cascade-throttle: stop_capture failed", e);
          }
          lastReasonRef.current = nextState.reason;
        }
      } else {
        // Only resume if WE paused it. Don't override a user-initiated pause
        // from the Vault.
        if (isBrowser() && window.localStorage.getItem(PAUSE_REASON_KEY) && lastReasonRef.current) {
          try {
            await invoke("start_capture");
            clearThrottlePauseReason();
            console.info("cascade-throttle: resumed — conditions recovered");
          } catch (e) {
            console.error("cascade-throttle: start_capture failed", e);
          }
          lastReasonRef.current = null;
        }
      }
    };

    // Evaluate immediately on mount, then on every poll
    evaluate();
    const id = setInterval(evaluate, config.pollIntervalMs);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [config.quotaGb, config.minFreeDiskGb, config.minBatteryPct, config.pollIntervalMs]);

  return state;
}

/**
 * Mountable component wrapper — renders nothing, just runs the hook.
 * Use this when you want to wire up throttling without consuming the state.
 */
export function CascadeThrottle({ config }: { config?: ThrottleConfig }) {
  useCascadeThrottle(config);
  return null;
}

export function describeReason(reason: "quota_exceeded" | "low_disk" | "low_battery"): string {
  switch (reason) {
    case "quota_exceeded":
      return "Cascade storage quota reached";
    case "low_disk":
      return "Mac disk space low";
    case "low_battery":
      return "Battery low and unplugged";
  }
}
