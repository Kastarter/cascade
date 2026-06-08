// cascade — local recording, rewind, and agent controls
// https://github.com/Mohanad139/Cascade

"use client";

import React, { useState, useEffect, useCallback, useRef } from "react";
import { Monitor, Mic, Keyboard, Lock, Check, RefreshCw, MousePointer2 } from "lucide-react";
import { commands } from "@/lib/utils/tauri";
import { usePlatform } from "@/lib/hooks/use-platform";
import { localFetch } from "@/lib/api";
import posthog from "posthog-js";

type RowStatus = "granted" | "denied" | "checking";
type PermissionAction =
  | Parameters<typeof commands.requestPermission>[0]
  | "inputMonitoring"
  | "keychain";

function hasScreenRecordingPermission(permissions: Record<string, string> | null) {
  return permissions?.screenRecording === "granted" || permissions?.screenRecording === "notNeeded";
}

function PermissionRow({
  icon,
  label,
  description,
  status,
  onFix,
  testId,
  isWorking = false,
}: {
  icon: React.ReactNode;
  label: string;
  description: string;
  status: RowStatus;
  onFix: () => void;
  testId: string;
  isWorking?: boolean;
}) {
  const isGranted = status === "granted";
  const isDisabled = isGranted || status === "checking" || isWorking;
  return (
    <button
      data-testid={testId}
      data-permission-status={status}
      onClick={isGranted ? undefined : onFix}
      disabled={isDisabled}
      className="w-full flex items-center gap-3 px-4 py-3 border border-border/50 transition-all group disabled:cursor-default hover:enabled:bg-foreground hover:enabled:text-background"
    >
      <div
        className={`w-7 h-7 rounded-full flex items-center justify-center shrink-0 transition-colors ${
          isGranted ? "bg-foreground/10" : "bg-muted group-hover:bg-background/10"
        }`}
      >
        <div
          className={`transition-colors ${
            isGranted ? "text-foreground" : "text-muted-foreground group-hover:text-background/70"
          }`}
        >
          {status === "checking" || isWorking ? (
            <RefreshCw className="w-3 h-3 animate-spin" />
          ) : isGranted ? (
            <Check className="w-3.5 h-3.5" strokeWidth={2.5} />
          ) : (
            icon
          )}
        </div>
      </div>

      <div className="flex flex-col items-start min-w-0">
        <span className="font-mono text-xs font-medium">{label}</span>
        <span className="font-mono text-[10px] text-muted-foreground group-hover:enabled:text-background/50 leading-tight">
          {description}
        </span>
      </div>

      <div className="ml-auto shrink-0">
        {isGranted ? (
          <span className="font-mono text-[10px] text-muted-foreground">ok</span>
        ) : status === "checking" ? null : isWorking ? (
          <span className="font-mono text-[10px] text-muted-foreground">opening</span>
        ) : (
          <span className="font-mono text-[10px] text-muted-foreground group-hover:text-background/70">
            grant →
          </span>
        )}
      </div>
    </button>
  );
}

export default function PermissionRecoveryPage() {
  const [permissions, setPermissions] = useState<Record<string, string> | null>(null);
  const [visionStatus, setVisionStatus] = useState<RowStatus>("checking");
  const [inputMonitoringStatus, setInputMonitoringStatus] = useState<RowStatus>("checking");
  const [workingPermission, setWorkingPermission] = useState<PermissionAction | null>(null);
  // Keychain: "granted" if enabled or unavailable (no keychain on this OS),
  // "denied" only if the user previously opted in but access is now refused.
  const [keychainStatus, setKeychainStatus] = useState<RowStatus>("checking");
  const { isMac: isMacOS } = usePlatform();
  const restartTriggeredRef = useRef(false);
  const permissionActionStartedAtRef = useRef<Record<string, number>>({});

  const checkPermissions = useCallback(async () => {
    try {
      const perms = await commands.doPermissionsCheck(false);
      const screenRecording = await commands.checkScreenRecordingPermission();
      const next = { ...perms, screenRecording };
      setPermissions(next);
      return next;
    } catch (error) {
      console.error("failed to check permissions:", error);
      return null;
    }
  }, []);

  const checkVision = useCallback(async (nextPermissions: Record<string, string> | null): Promise<RowStatus> => {
    if (!isMacOS) {
      setVisionStatus("granted");
      return "granted";
    }

    if (!nextPermissions) {
      setVisionStatus("checking");
      return "checking";
    }

    if (!hasScreenRecordingPermission(nextPermissions)) {
      setVisionStatus("denied");
      return "denied";
    }

    try {
      const res = await localFetch("/vision/status", { cache: "no-store" });
      if (!res.ok) {
        setVisionStatus("checking");
        return "checking";
      }
      const json = await res.json();
      const next = json?.status === "ok" ? "granted" : "denied";
      setVisionStatus(next);
      return next;
    } catch (error) {
      console.error("failed to check vision capture:", error);
      setVisionStatus("checking");
      return "checking";
    }
  }, [isMacOS]);

  const checkInputMonitoring = useCallback(async (): Promise<RowStatus> => {
    if (!isMacOS) {
      setInputMonitoringStatus("granted");
      return "granted";
    }

    try {
      const status = await commands.checkInputMonitoringPermissionCmd();
      const next = status === "granted" || status === "notNeeded" ? "granted" : "denied";
      setInputMonitoringStatus(next);
      return next;
    } catch (error) {
      console.error("failed to check input monitoring:", error);
      setInputMonitoringStatus("checking");
      return "checking";
    }
  }, [isMacOS]);

  const checkKeychain = useCallback(async () => {
    try {
      const res = await commands.getKeychainStatus();
      if (res.status === "ok") {
        // "enabled" = user opted in and key accessible
        // "unavailable" = OS keychain missing (Linux without libsecret, etc.) — treat as ok
        // "disabled" = user never opted in OR access denied — only treat as denied on mac
        //   where access-denied is actionable via re-enable.
        if (res.data.state === "enabled" || res.data.state === "unavailable") {
          setKeychainStatus("granted");
        } else {
          setKeychainStatus("denied");
        }
      }
    } catch {
      // keep previous status on error
    }
  }, []);

  const refreshStatuses = useCallback(async () => {
    const nextPermissions = await checkPermissions();
    await checkVision(nextPermissions);
    await checkInputMonitoring();
    if (isMacOS) await checkKeychain();
  }, [checkPermissions, checkVision, checkInputMonitoring, checkKeychain, isMacOS]);

  useEffect(() => {
    refreshStatuses();
    const interval = setInterval(() => {
      if (restartTriggeredRef.current) return;
      refreshStatuses();
    }, 3000);
    return () => clearInterval(interval);
  }, [refreshStatuses]);

  const rawScreenOk = hasScreenRecordingPermission(permissions);
  const screenStatus: RowStatus =
    permissions === null
      ? "checking"
      : rawScreenOk
        ? "granted"
        : "denied";
  const micStatus: RowStatus =
    permissions?.microphone === "granted" || permissions?.microphone === "notNeeded"
      ? "granted"
      : permissions === null
        ? "checking"
        : "denied";
  const accessibilityStatus: RowStatus =
    permissions?.accessibility === "granted" || permissions?.accessibility === "notNeeded"
      ? "granted"
      : permissions === null
        ? "checking"
        : "denied";

  const allOk =
    screenStatus === "granted" &&
    micStatus === "granted" &&
    accessibilityStatus === "granted" &&
    inputMonitoringStatus === "granted";

  // Auto-close and restart when every permission listed on this screen is restored.
  useEffect(() => {
    if (!permissions || restartTriggeredRef.current) return;

    if (allOk) {
      restartTriggeredRef.current = true;
      setTimeout(async () => {
        try {
          await commands.stopScreenpipe();
          await commands.spawnScreenpipe(null);
          await commands.closeWindow("PermissionRecovery");
        } catch {
          try { await commands.closeWindow("PermissionRecovery"); } catch {}
        }
      }, 1000);
    }
  }, [permissions, allOk]);

  const runPermissionAction = async (permission: PermissionAction, action: () => Promise<void>) => {
    const now = Date.now();
    const lastStartedAt = permissionActionStartedAtRef.current[permission] ?? 0;
    if (workingPermission || now - lastStartedAt < 4000) return;

    permissionActionStartedAtRef.current[permission] = now;
    setWorkingPermission(permission);
    try {
      await action();
    } finally {
      const nextPermissions = await checkPermissions();
      await checkVision(nextPermissions);
      await checkInputMonitoring();
      if (isMacOS) await checkKeychain();
      window.setTimeout(() => setWorkingPermission(null), 1200);
    }
  };

  const handleFix = async (permission: Parameters<typeof commands.requestPermission>[0]) => {
    posthog.capture("permission_recovery_manual_fix", { permission });
    await runPermissionAction(permission, async () => {
      try { await commands.requestPermission(permission); } catch {}
    });
  };

  const handleFixInputMonitoring = async () => {
    posthog.capture("permission_recovery_manual_fix", { permission: "inputMonitoring" });
    await runPermissionAction("inputMonitoring", async () => {
      try { await commands.requestInputMonitoringPermission(); } catch {}
    });
  };

  const handleFixKeychain = async () => {
    posthog.capture("permission_recovery_manual_fix", { permission: "keychain" });
    await runPermissionAction("keychain", async () => {
      try { await commands.enableKeychainEncryption(); } catch {}
    });
  };

  return (
    <div className="flex flex-col w-full h-screen overflow-hidden bg-background">
      <div className="w-full h-8 shrink-0" data-tauri-drag-region />

      <div className="flex-1 flex flex-col items-center justify-center px-8 pb-6">
        {allOk ? (
          <div
            className="text-center space-y-2"
            data-testid="permission-recovery-all-fixed"
            data-vision-status={visionStatus}
          >
            <Check className="w-5 h-5 mx-auto text-muted-foreground" />
            <p className="font-mono text-sm">all fixed — resuming</p>
          </div>
        ) : (
          <div
            className="w-full max-w-sm space-y-4"
            data-testid="permission-recovery-page"
            data-vision-status={visionStatus}
            data-input-monitoring-status={inputMonitoringStatus}
          >
            <div className="text-center">
              <h2 className="font-mono text-sm">recording paused</h2>
              <p className="font-mono text-xs text-muted-foreground mt-1">
                some permissions were revoked
              </p>
            </div>

            <div className="space-y-2">
              <PermissionRow
                icon={<Monitor className="w-4 h-4" strokeWidth={1.5} />}
                label="screen"
                description="capture display"
                status={screenStatus}
                onFix={() => handleFix("screenRecording")}
                testId="permission-row-screen"
                isWorking={workingPermission === "screenRecording"}
              />
              <PermissionRow
                icon={<Mic className="w-4 h-4" strokeWidth={1.5} />}
                label="microphone"
                description="transcribe audio"
                status={micStatus}
                onFix={() => handleFix("microphone")}
                testId="permission-row-microphone"
                isWorking={workingPermission === "microphone"}
              />
              {isMacOS && (
                <PermissionRow
                  icon={<Keyboard className="w-4 h-4" strokeWidth={1.5} />}
                  label="accessibility"
                  description="read text from apps"
                  status={accessibilityStatus}
                  onFix={() => handleFix("accessibility")}
                  testId="permission-row-accessibility"
                  isWorking={workingPermission === "accessibility"}
                />
              )}
              {isMacOS && (
                <PermissionRow
                  icon={<MousePointer2 className="w-4 h-4" strokeWidth={1.5} />}
                  label="input monitoring"
                  description="agent click/key health"
                  status={inputMonitoringStatus}
                  onFix={handleFixInputMonitoring}
                  testId="permission-row-input-monitoring"
                  isWorking={workingPermission === "inputMonitoring"}
                />
              )}
              {isMacOS && keychainStatus === "denied" && (
                <PermissionRow
                  icon={<Lock className="w-4 h-4" strokeWidth={1.5} />}
                  label="secure storage"
                  description="encrypt api keys & credentials"
                  status={keychainStatus}
                  onFix={handleFixKeychain}
                  testId="permission-row-keychain"
                  isWorking={workingPermission === "keychain"}
                />
              )}
            </div>

            <p className="font-mono text-[10px] text-muted-foreground text-center">
              closes automatically once fixed
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
