// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Cascade Reel — cinematic playback of your day.
// Visual identity ported from the Cascade-2 prototype (reel.jsx + chat panel).
// Data wired to Screenpipe's local /search OCR endpoint via lib/cascade-api.ts.
// Video frame seeking deferred to a follow-up — v1 displays OCR + metadata.

"use client";

import { useEffect, useMemo, useReducer, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import {
  appColor,
  appDisplayName,
  CascadeFrame,
  CascadeSegment,
  durMins,
  fetchFrameImage,
  fetchOcrFrames,
  framesToSegments,
  minToHHMM,
  minToHHMMSS,
  toMinutesFromMidnight,
} from "@/lib/cascade-api";
import { CascadeTitlebar } from "@/components/cascade-titlebar";
import { resolveAppColor, subscribeAppColors } from "@/lib/app-colors";

const SITE_NAMES: Record<string, string> = {
  linkedin: "LinkedIn",
  github: "GitHub",
  youtube: "YouTube",
  gmail: "Gmail",
  google: "Google",
  docs: "Google Docs",
  notion: "Notion",
  figma: "Figma",
  slack: "Slack",
  x: "X",
  twitter: "X",
  stackoverflow: "Stack Overflow",
  reddit: "Reddit",
  chatgpt: "ChatGPT",
  claude: "Claude",
  railway: "Railway",
  vercel: "Vercel",
};

// Turn a browser URL into a friendly site name, e.g. linkedin.com → "LinkedIn".
function siteFromUrl(url: string | null | undefined): string {
  if (!url) return "";
  try {
    const host = new URL(url.includes("://") ? url : `https://${url}`).hostname.replace(/^www\./, "");
    const core = host.split(".").slice(-2, -1)[0] ?? host; // "messaging.linkedin.com" → "linkedin"
    if (SITE_NAMES[core]) return SITE_NAMES[core];
    return core.charAt(0).toUpperCase() + core.slice(1);
  } catch {
    return "";
  }
}

// A clean, short title for the current moment. Prefer the real window/tab title;
// for browsers (where the OS title is often empty) fall back to the site from
// the URL — so it reads "LinkedIn", not just "Chrome". We never scrape OCR (that
// grabs the tab strip / menu bar and reads as garbage); the scene shows the rest.
function describeMoment(
  seg: CascadeSegment | null | undefined,
  frame: CascadeFrame | null | undefined,
): string {
  const app = (seg?.app ?? frame?.app_name ?? "").trim().toLowerCase();
  const win = (frame?.window_name ?? "").trim();
  if (win && win.toLowerCase() !== app && win.length <= 80) return win;
  const site = siteFromUrl(frame?.browser_url);
  if (site && site.toLowerCase() !== app) return site;
  return "";
}

export function CascadeReel() {
  const [frames, setFrames] = useState<CascadeFrame[]>([]);
  const [loading, setLoading] = useState(true);
  const [nowTick, setNowTick] = useState<number>(() => {
    const n = new Date();
    return n.getHours() * 60 + n.getMinutes() + n.getSeconds() / 60;
  });
  // Auto-follow "now" by default — the time displayed is the live clock.
  // Any manual interaction (scrub, play, prev/next) breaks autofollow until
  // user clicks "LIVE" / "Jump to now" to re-engage.
  const [autoFollow, setAutoFollow] = useState(true);
  const [manualTime, setManualTime] = useState<number>(() => {
    const n = new Date();
    return n.getHours() * 60 + n.getMinutes() + n.getSeconds() / 60;
  });
  const time = autoFollow ? nowTick : manualTime;
  const setTime = (t: number | ((p: number) => number)) => {
    setAutoFollow(false);
    setManualTime((prev) => (typeof t === "function" ? (t as (p: number) => number)(prev) : t));
  };
  const [playing, setPlaying] = useState(false);
  const [speed, setSpeed] = useState<"0.5×" | "1×" | "2×" | "8×">("1×");

  // Keep nowTick fresh every second so the timeline end + playhead (in
  // autoFollow mode) advance smoothly.
  useEffect(() => {
    const id = setInterval(() => {
      const n = new Date();
      setNowTick(n.getHours() * 60 + n.getMinutes() + n.getSeconds() / 60);
    }, 1_000);
    return () => clearInterval(id);
  }, []);

  // Periodically refetch frames so new captures appear in the live timeline.
  // Every 30s — light enough not to thrash the API, fresh enough to feel live.
  useEffect(() => {
    const id = setInterval(() => {
      const start = new Date();
      start.setHours(0, 0, 0, 0);
      const end = new Date();
      fetchOcrFrames({ startTime: start, endTime: end, limit: 2000 }).then((f) => {
        setFrames(f);
      });
    }, 30_000);
    return () => clearInterval(id);
  }, []);

  // Load today's OCR frames once on mount
  useEffect(() => {
    const start = new Date();
    start.setHours(0, 0, 0, 0);
    const end = new Date();
    fetchOcrFrames({ startTime: start, endTime: end, limit: 2000 }).then((f) => {
      setFrames(f);
      setLoading(false);
    });
  }, []);

  // Group frames into segments
  const segments = useMemo(() => framesToSegments(frames), [frames]);

  // Each app's timeline color comes from its real icon (lib/app-colors). Kick
  // off resolution for every app in view, and re-render as colors arrive —
  // results are cached, so this only does work the first time we see an app.
  const [, bumpColors] = useReducer((x: number) => x + 1, 0);
  useEffect(() => subscribeAppColors(bumpColors), []);
  useEffect(() => {
    const apps = new Set<string>();
    for (const f of frames) if (f.app_name) apps.add(f.app_name);
    apps.forEach((a) => resolveAppColor(a));
  }, [frames]);

  // Dynamic time range: earliest frame → exactly now (no future padding —
  // showing the next 5 unrecorded minutes felt weird/misleading).
  const { dayStart, dayEnd } = useMemo(() => {
    if (frames.length === 0) {
      return { dayStart: Math.max(0, nowTick - 240), dayEnd: nowTick };
    }
    const first = toMinutesFromMidnight(frames[0].timestamp);
    return {
      dayStart: Math.max(0, Math.min(first - 30, nowTick - 60)),
      dayEnd: nowTick,
    };
  }, [frames, nowTick]);

  // Segment containing current time. Returns null when nothing matches — the
  // UI shows "Idle / no capture at this time" instead of snapping to segments[0].
  const currentSeg = useMemo(
    () => segments.find((s) => time >= s.start_min && time <= s.end_min) ?? null,
    [segments, time],
  );

  // Frame closest to current time, but only if within 5 minutes — otherwise
  // we'd show an unrelated frame when the playhead is in a gap.
  const currentFrame = useMemo(() => {
    if (frames.length === 0) return null;
    let best: CascadeFrame | null = null;
    let bestDelta = Infinity;
    for (const f of frames) {
      const delta = Math.abs(toMinutesFromMidnight(f.timestamp) - time);
      if (delta < bestDelta) {
        bestDelta = delta;
        best = f;
      }
    }
    return bestDelta <= 5 ? best : null;
  }, [frames, time]);

  // Auto-advance time when playing. Tick every 100ms and add fractional
  // minutes so the seconds display advances smoothly. At 1× we add 0.1 min
  // per tick (6 seconds of recorded time per real second — fast but readable).
  // The prototype's "1 minute per tick" felt jumpy once we showed seconds.
  useEffect(() => {
    if (!playing) return;
    const mult = { "0.5×": 0.5, "1×": 1, "2×": 2, "8×": 8 }[speed] || 1;
    const id = setInterval(() => {
      setTime((prev) => {
        const next = prev + 0.1 * mult;
        if (next >= dayEnd) {
          setPlaying(false);
          return dayEnd;
        }
        return next;
      });
    }, 100);
    return () => clearInterval(id);
  }, [playing, speed, dayEnd]);

  // What's actually inside the current moment. window_name is often empty
  // (e.g. Chrome), so we fall back to a description pulled from the OCR text.
  const momentApp = appDisplayName(currentSeg?.app ?? currentFrame?.app_name ?? null);
  const realTitle = describeMoment(currentSeg, currentFrame);
  const observation = currentSeg || currentFrame
    ? realTitle
      ? `${momentApp} — ${realTitle}`
      : momentApp
    : "Idle — no capture at this time.";

  const segColor = currentSeg
    ? appColor(currentSeg.app)
    : currentFrame
      ? appColor(currentFrame.app_name)
      : "transparent";

  return (
    <div style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: "column" }}>
      <CascadeTitlebar />
    <div
      style={{
        flex: 1,
        minHeight: 0,
        display: "flex",
        padding: 22,
        gap: 18,
        background: `radial-gradient(ellipse at 30% 0%, ${segColor}14, transparent 55%),
                     radial-gradient(ellipse at 80% 100%, oklch(0.19 0.05 45 / 0.4), transparent 55%),
                     var(--cascade-bg)`,
        transition: "background 0.5s ease",
        color: "var(--cascade-text)",
        fontFamily: "var(--cascade-sans)",
      }}
    >
      {/* LEFT — hero + scene + transport */}
      <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 14 }}>
        {/* HERO — chapter card */}
        <div
          style={{
            flexShrink: 0,
            display: "grid",
            gridTemplateColumns: "160px 1fr 160px",
            alignItems: "center",
            gap: 24,
            padding: "4px 8px",
          }}
        >
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            <span style={labelStyle}>The moment</span>
            <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 13, color: "var(--cascade-text-2)" }}>
              {currentSeg
                ? `${minToHHMM(currentSeg.start_min)}`
                : currentFrame
                  ? minToHHMM(toMinutesFromMidnight(currentFrame.timestamp))
                  : "—"}
              <span style={{ opacity: 0.5 }}> → </span>
              {currentSeg ? minToHHMM(currentSeg.end_min) : "now"}
            </span>
          </div>

          <div
            key={currentSeg?.id ?? "empty"}
            style={{
              textAlign: "center",
              fontFamily: "var(--cascade-serif)",
              fontStyle: "italic",
              fontWeight: 400,
              fontSize: 32,
              lineHeight: 1.18,
              letterSpacing: -0.5,
              color: "var(--cascade-text)",
              animation: "fadeRise 0.45s cubic-bezier(0.2, 0.8, 0.2, 1)",
              textWrap: "pretty" as any,
            }}
          >
            {observation}
          </div>

          <div style={{ display: "flex", flexDirection: "column", gap: 4, alignItems: "flex-end" }}>
            <span style={labelStyle}>
              {currentSeg ? durMins(currentSeg.end_min - currentSeg.start_min) : "—"} · in
            </span>
            <span style={{ display: "inline-flex", alignItems: "center", gap: 7, fontSize: 13, color: "var(--cascade-text)" }}>
              <span
                style={{
                  width: 8,
                  height: 8,
                  borderRadius: 4,
                  background: segColor,
                  boxShadow: currentSeg?.app ? `0 0 10px ${segColor}` : "none",
                }}
              />
              {appDisplayName(currentSeg?.app ?? currentFrame?.app_name ?? null)}
            </span>
            {/* What's actually happening in that app — window title or OCR-derived. */}
            {realTitle && (
              <span
                style={{
                  fontFamily: "var(--cascade-mono)",
                  fontSize: 10.5,
                  color: "var(--cascade-text-3)",
                  maxWidth: 260,
                  overflow: "hidden",
                  textOverflow: "ellipsis",
                  whiteSpace: "nowrap",
                  textAlign: "right",
                }}
                title={realTitle}
              >
                {realTitle}
              </span>
            )}
          </div>
        </div>

        {/* SCENE FRAME */}
        <div
          style={{
            flex: 1,
            minHeight: 0,
            position: "relative",
            borderRadius: 16,
            overflow: "hidden",
            background: "oklch(0.10 0.012 140)",
            border: "1px solid oklch(0.35 0.018 140)",
            boxShadow: `
              0 24px 80px oklch(0.06 0.02 140 / 0.55),
              0 0 0 1px rgba(255,255,255,0.04) inset,
              0 0 0 1px ${segColor}33,
              0 0 60px ${segColor}20
            `,
            transition: "box-shadow 0.4s ease",
          }}
        >
          <Scene frame={currentFrame} loading={loading} segApp={currentSeg?.app ?? null} />

          {/* vignette */}
          <div
            style={{
              position: "absolute",
              inset: 0,
              pointerEvents: "none",
              background: "radial-gradient(ellipse at center, transparent 55%, oklch(0.06 0.02 140 / 0.4) 100%)",
            }}
          />

          {/* live-capture pill */}
          <div
            style={{
              position: "absolute",
              top: 14,
              right: 14,
              display: "flex",
              alignItems: "center",
              gap: 7,
              padding: "5px 11px 5px 9px",
              borderRadius: 999,
              background: "oklch(0.10 0.014 140 / 0.8)",
              backdropFilter: "blur(12px)",
              WebkitBackdropFilter: "blur(12px)",
              border: "1px solid oklch(0.30 0.020 140 / 0.5)",
              fontFamily: "var(--cascade-mono)",
              fontSize: 9.5,
              color: "oklch(0.85 0.08 25)",
              letterSpacing: 0.6,
            }}
          >
            <div
              style={{
                width: 5,
                height: 5,
                borderRadius: "50%",
                background: "oklch(0.68 0.20 25)",
                boxShadow: "0 0 6px oklch(0.68 0.20 25)",
              }}
            />
            CAPTURED · LOCAL
          </div>
        </div>

        <Transport
          time={time}
          playing={playing}
          onPlay={() => {
            // Starting playback breaks autofollow; seed manualTime at current
            // displayed time so playback continues from where the user sees.
            if (!playing) {
              setManualTime(time);
              setAutoFollow(false);
            }
            setPlaying(!playing);
          }}
          onScrub={setTime}
          speed={speed}
          onSpeed={setSpeed}
          dayStart={dayStart}
          dayEnd={dayEnd}
          autoFollow={autoFollow}
          onJumpToNow={() => {
            setAutoFollow(true);
            setPlaying(false);
          }}
        />

        <FullTimeline
          time={time}
          onScrub={setTime}
          segments={segments}
          dayStart={dayStart}
          dayEnd={dayEnd}
          playheadColor={segColor !== "transparent" ? segColor : undefined}
        />
      </div>

      {/* RIGHT — chat panel */}
      <div style={{ width: 360, flexShrink: 0, display: "flex", flexDirection: "column" }}>
        <SceneChatPanel segId={currentSeg?.id ?? null} currentFrame={currentFrame} segApp={currentSeg?.app ?? null} />
      </div>

      <style>{`
        @keyframes fadeRise {
          from { opacity: 0; transform: translateY(8px); }
          to   { opacity: 1; transform: translateY(0); }
        }
      `}</style>
    </div>
    </div>
  );
}

const labelStyle: React.CSSProperties = {
  fontFamily: "var(--cascade-mono)",
  fontSize: 9.5,
  letterSpacing: 2,
  textTransform: "uppercase",
  color: "var(--cascade-text-3)",
};

// ── Scene — shows OCR text + window context when video unavailable ──
function Scene({ frame, loading, segApp }: { frame: CascadeFrame | null; loading: boolean; segApp: string | null }) {
  const [imgUrl, setImgUrl] = useState<string | null>(null);
  const [imgState, setImgState] = useState<"loading" | "ok" | "error" | "idle">("idle");
  const [showOcr, setShowOcr] = useState(false);
  const urlRef = useRef<string | null>(null);

  // Fetch the real screenshot image for the current frame and convert to a
  // blob URL. Revoke the previous URL before assigning the new one to avoid
  // leaks across scrubs.
  useEffect(() => {
    if (!frame?.frame_id) {
      if (urlRef.current) {
        URL.revokeObjectURL(urlRef.current);
        urlRef.current = null;
      }
      setImgUrl(null);
      setImgState("idle");
      return;
    }
    setImgState("loading");
    let cancelled = false;
    fetchFrameImage(frame.frame_id).then((url) => {
      if (cancelled) {
        if (url) URL.revokeObjectURL(url);
        return;
      }
      if (urlRef.current) URL.revokeObjectURL(urlRef.current);
      urlRef.current = url;
      setImgUrl(url);
      setImgState(url ? "ok" : "error");
    });
    return () => {
      cancelled = true;
    };
  }, [frame?.frame_id]);

  // Final cleanup on unmount
  useEffect(() => {
    return () => {
      if (urlRef.current) {
        URL.revokeObjectURL(urlRef.current);
        urlRef.current = null;
      }
    };
  }, []);

  if (loading) {
    return (
      <div style={{ ...sceneCenter, color: "var(--cascade-text-3)" }}>
        <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 11, letterSpacing: 1.5 }}>LOADING DAY…</span>
      </div>
    );
  }

  if (!frame) {
    return (
      <div style={{ ...sceneCenter, flexDirection: "column", gap: 10, color: "var(--cascade-text-3)" }}>
        <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10.5, letterSpacing: 1.6 }}>
          IDLE · NO CAPTURE AT THIS TIME
        </span>
        <span style={{ fontSize: 12.5, color: "var(--cascade-text-4)" }}>
          Drag the timeline to a moment Cascade recorded.
        </span>
      </div>
    );
  }

  return (
    <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column" }}>
      {/* Window chrome strip */}
      <div
        style={{
          padding: "10px 16px",
          borderBottom: "1px solid oklch(0.20 0.015 140)",
          display: "flex",
          alignItems: "center",
          gap: 10,
          fontFamily: "var(--cascade-mono)",
          fontSize: 10.5,
          color: "var(--cascade-text-3)",
          letterSpacing: 0.4,
          background: "oklch(0.10 0.012 140 / 0.8)",
          backdropFilter: "blur(8px)",
          WebkitBackdropFilter: "blur(8px)",
          zIndex: 2,
          flexShrink: 0,
        }}
      >
        <span
          style={{
            width: 6,
            height: 6,
            borderRadius: 3,
            background: appColor(segApp),
            boxShadow: `0 0 6px ${appColor(segApp)}`,
          }}
        />
        {appDisplayName(frame.app_name)}
        {frame.window_name && (
          <>
            <span style={{ opacity: 0.4 }}>·</span>
            <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {frame.window_name}
            </span>
          </>
        )}
        <span style={{ marginLeft: "auto", opacity: 0.7 }}>{new Date(frame.timestamp).toLocaleTimeString()}</span>
        {frame.text && (
          <button
            onClick={() => setShowOcr((v) => !v)}
            style={{
              padding: "2px 8px",
              borderRadius: 4,
              border: "1px solid var(--cascade-border)",
              background: showOcr ? "var(--cascade-accent)" : "transparent",
              color: showOcr ? "var(--cascade-on-accent)" : "var(--cascade-text-2)",
              fontFamily: "var(--cascade-mono)",
              fontSize: 9.5,
              cursor: "pointer",
              letterSpacing: 0.4,
            }}
          >
            {showOcr ? "HIDE OCR" : "SHOW OCR"}
          </button>
        )}
      </div>

      {/* Image body */}
      <div style={{ flex: 1, position: "relative", overflow: "hidden", background: "oklch(0.07 0.010 140)" }}>
        {imgState === "loading" && (
          <div style={{ ...sceneCenter, color: "var(--cascade-text-4)" }}>
            <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, letterSpacing: 1.4 }}>LOADING FRAME…</span>
          </div>
        )}
        {imgState === "ok" && imgUrl && (
          <img
            src={imgUrl}
            alt={frame.window_name ?? frame.app_name ?? "captured frame"}
            style={{
              position: "absolute",
              inset: 0,
              width: "100%",
              height: "100%",
              objectFit: "contain",
              backgroundColor: "oklch(0.05 0.005 140)",
            }}
          />
        )}
        {imgState === "error" && (
          <div style={{ ...sceneCenter, flexDirection: "column", gap: 8, color: "var(--cascade-text-3)" }}>
            <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, letterSpacing: 1.4 }}>FRAME IMAGE UNAVAILABLE</span>
            <span style={{ fontSize: 12, color: "var(--cascade-text-4)", maxWidth: 320, textAlign: "center" }}>
              Showing OCR text instead. Frame video may have been pruned or auth may be off.
            </span>
          </div>
        )}

        {/* OCR overlay — toggleable, fades over the image */}
        {(showOcr || imgState === "error") && frame.text && (
          <div
            style={{
              position: "absolute",
              left: 0,
              right: 0,
              bottom: 0,
              maxHeight: "60%",
              padding: "20px 32px",
              background: "linear-gradient(0deg, oklch(0.07 0.010 140 / 0.92), oklch(0.07 0.010 140 / 0.7) 70%, transparent)",
              backdropFilter: "blur(4px)",
              WebkitBackdropFilter: "blur(4px)",
              overflow: "auto",
              fontFamily: "var(--cascade-mono)",
              fontSize: 11.5,
              color: "var(--cascade-text-2)",
              lineHeight: 1.6,
              whiteSpace: "pre-wrap" as any,
            }}
          >
            {frame.text}
          </div>
        )}
      </div>
    </div>
  );
}

const sceneCenter: React.CSSProperties = {
  position: "absolute",
  inset: 0,
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
};

// ── Transport — play / scrub / speed ──────────────────────────────
function Transport({
  time,
  playing,
  onPlay,
  onScrub,
  speed,
  onSpeed,
  dayStart,
  dayEnd,
  autoFollow,
  onJumpToNow,
}: {
  time: number;
  playing: boolean;
  onPlay: () => void;
  onScrub: (m: number) => void;
  speed: "0.5×" | "1×" | "2×" | "8×";
  onSpeed: (s: "0.5×" | "1×" | "2×" | "8×") => void;
  dayStart: number;
  dayEnd: number;
  autoFollow: boolean;
  onJumpToNow: () => void;
}) {
  return (
    <div
      style={{
        flexShrink: 0,
        display: "flex",
        alignItems: "center",
        gap: 12,
        padding: "8px 14px",
        background: "oklch(0.180 0.010 140 / 0.65)",
        backdropFilter: "blur(14px)",
        WebkitBackdropFilter: "blur(14px)",
        border: "1px solid var(--cascade-border)",
        borderRadius: 12,
      }}
    >
      <div style={{ display: "flex", gap: 4, alignItems: "center" }}>
        <IconBtn onClick={() => onScrub(Math.max(dayStart, time - 1))} label="−1m">‹</IconBtn>
        <button
          onClick={onPlay}
          aria-label={playing ? "Pause Rewind" : "Play Rewind"}
          style={{
            width: 36,
            height: 32,
            borderRadius: 8,
            background: playing ? "var(--cascade-accent)" : "oklch(0.255 0.012 140)",
            color: playing ? "var(--cascade-on-accent)" : "var(--cascade-text)",
            border: `1px solid ${playing ? "var(--cascade-accent)" : "var(--cascade-border-hi)"}`,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            cursor: "pointer",
            padding: 0,
            boxShadow: playing ? "0 0 16px var(--cascade-accent)" : "none",
            transition: "background 0.15s, color 0.15s, border-color 0.15s, box-shadow 0.15s",
            fontSize: 14,
            fontWeight: 600,
          }}
        >
          {playing ? "❚❚" : "▶"}
        </button>
        <IconBtn onClick={() => onScrub(Math.min(dayEnd, time + 1))} label="+1m">›</IconBtn>
      </div>

      <div style={{ width: 1, height: 18, background: "var(--cascade-border)" }} />

      <div style={{ display: "flex", alignItems: "baseline", gap: 8, flex: 1 }}>
        <span style={{ fontFamily: "var(--cascade-serif)", fontSize: 22, color: "var(--cascade-text)", letterSpacing: -0.3 }}>
          {minToHHMMSS(time)}
        </span>
        <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10, color: "var(--cascade-text-3)", letterSpacing: 0.5 }}>
          / {minToHHMMSS(dayEnd)}
        </span>
        {autoFollow ? (
          <span
            style={{
              display: "inline-flex",
              alignItems: "center",
              gap: 5,
              padding: "2px 7px 2px 6px",
              borderRadius: 999,
              background: "oklch(0.30 0.060 60)",
              border: "1px solid oklch(0.46 0.095 55)",
              fontFamily: "var(--cascade-mono)",
              fontSize: 9.5,
              color: "oklch(0.82 0.12 65)",
              letterSpacing: 0.5,
              marginLeft: 4,
            }}
          >
            <span
              style={{
                width: 5,
                height: 5,
                borderRadius: "50%",
                background: "oklch(0.74 0.18 145)",
                boxShadow: "0 0 6px oklch(0.74 0.18 145)",
              }}
            />
            LIVE
          </span>
        ) : (
          <button
            onClick={onJumpToNow}
            title="Jump back to now"
            style={{
              padding: "2px 8px",
              borderRadius: 999,
              background: "transparent",
              border: "1px solid var(--cascade-border)",
              fontFamily: "var(--cascade-mono)",
              fontSize: 9.5,
              color: "var(--cascade-text-3)",
              letterSpacing: 0.4,
              cursor: "pointer",
              marginLeft: 4,
            }}
          >
            ↓ NOW
          </button>
        )}
      </div>

      <div style={{ display: "flex", gap: 2 }}>
        {(["0.5×", "1×", "2×", "8×"] as const).map((s) => (
          <button
            key={s}
            onClick={() => onSpeed(s)}
            style={{
              background: speed === s ? "oklch(0.240 0.011 140)" : "transparent",
              border: `1px solid ${speed === s ? "var(--cascade-border-hi)" : "transparent"}`,
              color: speed === s ? "var(--cascade-text)" : "var(--cascade-text-3)",
              borderRadius: 6,
              padding: "4px 8px",
              fontSize: 10.5,
              fontFamily: "var(--cascade-mono)",
              cursor: "pointer",
            }}
          >
            {s}
          </button>
        ))}
      </div>
    </div>
  );
}

function IconBtn({ children, onClick, label }: { children: React.ReactNode; onClick: () => void; label: string }) {
  return (
    <button
      onClick={onClick}
      title={label}
      style={{
        width: 28,
        height: 28,
        borderRadius: 7,
        background: "transparent",
        border: "1px solid transparent",
        color: "var(--cascade-text-2)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        cursor: "pointer",
        padding: 0,
        fontSize: 16,
        fontFamily: "var(--cascade-serif)",
      }}
    >
      {children}
    </button>
  );
}

// ── Full timeline strip with legend + hour labels ─────────────────
function FullTimeline({
  time,
  onScrub,
  segments,
  dayStart,
  dayEnd,
  playheadColor,
}: {
  time: number;
  onScrub: (m: number) => void;
  segments: CascadeSegment[];
  dayStart: number;
  dayEnd: number;
  playheadColor?: string;
}) {
  const SPAN = Math.max(60, dayEnd - dayStart);
  const ref = useRef<HTMLDivElement>(null);
  const [dragging, setDragging] = useState(false);

  const setFromX = (clientX: number) => {
    if (!ref.current) return;
    const r = ref.current.getBoundingClientRect();
    const pct = Math.max(0, Math.min(1, (clientX - r.left) / r.width));
    // Don't round — fractional minutes give second-level scrub resolution.
    onScrub(dayStart + pct * SPAN);
  };

  useEffect(() => {
    if (!dragging) return;
    const move = (e: MouseEvent) => setFromX(e.clientX);
    const up = () => setDragging(false);
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
    return () => {
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dragging, dayStart, dayEnd]);

  const legend = useMemo(() => {
    const totals: Record<string, number> = {};
    for (const s of segments) {
      if (!s.app) continue;
      totals[s.app] = (totals[s.app] || 0) + (s.end_min - s.start_min);
    }
    return Object.entries(totals).sort((a, b) => b[1] - a[1]).map(([app]) => app);
  }, [segments]);

  // Dynamic hour labels — pick whole hours that fall within [dayStart, dayEnd]
  const hours = useMemo(() => {
    const firstHour = Math.ceil(dayStart / 60);
    const lastHour = Math.floor(dayEnd / 60);
    const arr: number[] = [];
    for (let h = firstHour; h <= lastHour; h++) arr.push(h);
    return arr;
  }, [dayStart, dayEnd]);

  const playheadPct = ((time - dayStart) / SPAN) * 100;

  return (
    <div
      style={{
        flexShrink: 0,
        background: "oklch(0.180 0.010 140 / 0.65)",
        backdropFilter: "blur(14px)",
        WebkitBackdropFilter: "blur(14px)",
        border: "1px solid var(--cascade-border)",
        borderRadius: 12,
        padding: "12px 16px 14px",
      }}
    >
      <div style={{ display: "flex", flexWrap: "wrap", gap: "4px 14px", marginBottom: 10 }}>
        {legend.length === 0 && (
          <span style={{ fontFamily: "var(--cascade-mono)", fontSize: 10.5, color: "var(--cascade-text-3)", letterSpacing: 0.6 }}>
            NO ACTIVITY RECORDED YET
          </span>
        )}
        {legend.map((app) => (
          <div
            key={app}
            style={{
              display: "inline-flex",
              alignItems: "center",
              gap: 6,
              fontSize: 11,
              color: "var(--cascade-text-2)",
            }}
          >
            <span
              style={{
                width: 9,
                height: 9,
                borderRadius: 2,
                background: appColor(app),
                boxShadow: `0 0 6px ${appColor(app)}66`,
              }}
            />
            {appDisplayName(app)}
          </div>
        ))}
      </div>

      <div
        ref={ref}
        onMouseDown={(e) => {
          setDragging(true);
          setFromX(e.clientX);
        }}
        style={{
          position: "relative",
          height: 22,
          borderRadius: 5,
          overflow: "hidden",
          background: "oklch(0.240 0.011 140)",
          cursor: "pointer",
          marginBottom: 8,
        }}
      >
        {segments.map((s) => {
          const left = ((s.start_min - dayStart) / SPAN) * 100;
          const width = ((s.end_min - s.start_min) / SPAN) * 100;
          return (
            <div
              key={s.id}
              title={s.title}
              style={{
                position: "absolute",
                left: `${left}%`,
                width: `${width}%`,
                top: 0,
                bottom: 0,
                background: s.app ? appColor(s.app) : "transparent",
                opacity: 0.85,
                borderRight: "1px solid var(--cascade-bg)",
              }}
            />
          );
        })}
        <div
          style={{
            position: "absolute",
            left: `${playheadPct}%`,
            top: -6,
            bottom: -6,
            width: 2,
            background: playheadColor ?? "var(--cascade-accent)",
            transform: "translateX(-1px)",
            boxShadow: `0 0 10px ${playheadColor ?? "var(--cascade-accent)"}, 0 0 20px ${playheadColor ?? "var(--cascade-accent)"}`,
            pointerEvents: "none",
            transition: "background 0.2s ease, box-shadow 0.2s ease",
          }}
        >
          <div
            style={{
              position: "absolute",
              top: -22,
              left: "50%",
              transform: "translateX(-50%)",
              background: playheadColor ?? "var(--cascade-accent)",
              color: "var(--cascade-on-accent)",
              fontFamily: "var(--cascade-mono)",
              fontSize: 10,
              fontWeight: 600,
              padding: "2px 6px",
              borderRadius: 4,
              whiteSpace: "nowrap",
            }}
          >
            {minToHHMMSS(time)}
          </div>
        </div>
      </div>

      <div style={{ position: "relative", height: 13 }}>
        {hours.map((h) => {
          const left = ((h * 60 - dayStart) / SPAN) * 100;
          if (left < 0 || left > 100) return null;
          const label = h === 12 ? "12pm" : h < 12 ? `${h}am` : `${h - 12}pm`;
          return (
            <div
              key={h}
              style={{
                position: "absolute",
                left: `${left}%`,
                transform: "translateX(-50%)",
                fontFamily: "var(--cascade-mono)",
                fontSize: 10,
                color: "var(--cascade-text-3)",
              }}
            >
              {label}
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ── Scene chat panel — wires to Anthropic via BYOK key ────────────
interface ChatMsg {
  who: "you" | "cas";
  text: string;
}

function SceneChatPanel({
  segId,
  currentFrame,
  segApp,
}: {
  segId: string | null;
  currentFrame: CascadeFrame | null;
  segApp: string | null;
}) {
  const [log, setLog] = useState<ChatMsg[]>([]);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [hasKey, setHasKey] = useState<boolean>(false);
  const [keyInput, setKeyInput] = useState("");
  const bottomRef = useRef<HTMLDivElement>(null);

  // Detect whether the Anthropic key is set. Source of truth is macOS Keychain.
  useEffect(() => {
    if (typeof window === "undefined") return;
    (async () => {
      try {
        const status = await invoke<{ hasAnthropicKey: boolean }>("cascade_key_status");
        setHasKey(Boolean(status?.hasAnthropicKey));
      } catch {
        /* non-fatal */
      }
    })();
  }, []);

  // Reset chat when segment changes
  useEffect(() => {
    setLog([]);
    setInput("");
  }, [segId]);

  const saveKey = async () => {
    const k = keyInput.trim();
    if (!k.startsWith("sk-ant-")) return;
    try {
      await invoke("cascade_set_anthropic_key", { key: k });
      setHasKey(true);
      setKeyInput("");
    } catch {
      setHasKey(false);
    }
  };

  const clearKey = async () => {
    await invoke("cascade_clear_anthropic_key").catch(() => {});
    setHasKey(false);
  };

  useEffect(() => {
    if (bottomRef.current) bottomRef.current.scrollTop = bottomRef.current.scrollHeight;
  }, [log]);

  const send = async (text?: string) => {
    const q = (text ?? input).trim();
    if (!q || busy) return;
    setBusy(true);
    setLog((prev) => [...prev, { who: "you", text: q }]);
    setInput("");

    try {
      const reply = await askClaude(q, currentFrame);
      setLog((prev) => [...prev, { who: "cas", text: reply }]);
    } catch (err: any) {
      setLog((prev) => [
        ...prev,
        {
          who: "cas",
          text: `(Error: ${err?.message ?? String(err)}. Make sure your Anthropic key is configured in Settings.)`,
        },
      ]);
    } finally {
      setBusy(false);
    }
  };

  const prompts = currentFrame
    ? [
        "What was I doing here?",
        "What's the context of this moment?",
        "Did I finish what I started here?",
      ]
    : ["What did I do today?", "Where did my morning go?", "What's still unfinished?"];

  const title = currentFrame?.window_name ?? appDisplayName(segApp) ?? "This moment";

  return (
    <div
      style={{
        flex: 1,
        display: "flex",
        flexDirection: "column",
        background: "oklch(0.180 0.010 140 / 0.65)",
        backdropFilter: "blur(16px) saturate(160%)",
        WebkitBackdropFilter: "blur(16px) saturate(160%)",
        border: "1px solid var(--cascade-border)",
        borderRadius: 14,
        overflow: "hidden",
        boxShadow: "0 16px 48px oklch(0.06 0.02 140 / 0.4)",
      }}
    >
      <div
        style={{
          padding: "14px 16px",
          borderBottom: "1px solid var(--cascade-border)",
          display: "flex",
          alignItems: "center",
          gap: 10,
        }}
      >
        <div
          style={{
            width: 28,
            height: 28,
            borderRadius: 8,
            background: "oklch(0.280 0.012 140)",
            border: "1px solid var(--cascade-border-hi)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <div style={{ width: 8, height: 8, borderRadius: "50%", background: "var(--cascade-accent)" }} />
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={labelStyle}>Ask about this moment</div>
          <div
            style={{
              fontSize: 12.5,
              color: "var(--cascade-text-2)",
              marginTop: 1,
              whiteSpace: "nowrap",
              overflow: "hidden",
              textOverflow: "ellipsis",
            }}
          >
            {title}
          </div>
        </div>
      </div>

      <div
        ref={bottomRef}
        style={{
          flex: 1,
          overflow: "auto",
          padding: "14px 16px",
          display: "flex",
          flexDirection: "column",
          gap: 14,
          minHeight: 0,
        }}
      >
        {log.length === 0 && (
          <div style={{ color: "var(--cascade-text-3)", fontSize: 12.5, fontStyle: "italic" }}>
            Ask anything about what you were doing.
          </div>
        )}
        {log.map((m, i) =>
          m.who === "you" ? (
            <div key={i} style={{ display: "flex", justifyContent: "flex-end" }}>
              <div
                style={{
                  background: "linear-gradient(180deg, oklch(0.275 0.014 55), oklch(0.200 0.010 140))",
                  color: "var(--cascade-text)",
                  border: "1px solid oklch(0.42 0.024 55)",
                  borderRadius: 12,
                  padding: "9px 13px",
                  maxWidth: "85%",
                  fontSize: 12.5,
                  fontWeight: 500,
                  boxShadow: "0 4px 16px rgba(0,0,0,0.08)",
                }}
              >
                {m.text}
              </div>
            </div>
          ) : (
            <div key={i} style={{ display: "flex", gap: 10 }}>
              <div
                style={{
                  width: 22,
                  height: 22,
                  borderRadius: 7,
                  flexShrink: 0,
                  marginTop: 2,
                  background: "oklch(0.275 0.014 55)",
                  border: "1px solid oklch(0.42 0.024 55)",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                }}
              >
                <div style={{ width: 6, height: 6, borderRadius: "50%", background: "var(--cascade-accent)" }} />
              </div>
              <div
                style={{
                  flex: 1,
                  minWidth: 0,
                  background: "linear-gradient(180deg, oklch(0.275 0.014 55), oklch(0.200 0.010 140))",
                  border: "1px solid oklch(0.42 0.024 55)",
                  borderRadius: 12,
                  padding: "10px 13px",
                  boxShadow: "0 4px 16px rgba(0,0,0,0.08)",
                }}
              >
                <div
                  style={{
                    fontSize: 13,
                    color: "var(--cascade-text)",
                    lineHeight: 1.55,
                    textWrap: "pretty" as any,
                    whiteSpace: "pre-wrap" as any,
                  }}
                >
                  {m.text}
                </div>
              </div>
            </div>
          ),
        )}
        {busy && (
          <div style={{ color: "var(--cascade-text-3)", fontSize: 12, fontStyle: "italic" }}>Cascade is thinking…</div>
        )}
      </div>

      <div style={{ padding: "6px 12px 10px", display: "flex", flexWrap: "wrap", gap: 5 }}>
        {prompts.map((p) => (
          <button
            key={p}
            onClick={() => send(p)}
            disabled={busy}
            style={{
              background: "oklch(0.200 0.010 140)",
              border: "1px solid var(--cascade-border)",
              borderRadius: 999,
              padding: "5px 12px",
              fontSize: 11.5,
              color: "var(--cascade-text-2)",
              cursor: busy ? "default" : "pointer",
              textAlign: "left",
              opacity: busy ? 0.5 : 1,
            }}
          >
            {p}
          </button>
        ))}
      </div>

      <div style={{ padding: "10px 12px 12px", borderTop: "1px solid var(--cascade-border)" }}>
        {!hasKey && (
          <div
            style={{
              marginBottom: 8,
              padding: "10px 12px",
              background: "oklch(0.275 0.014 55)",
              border: "1px solid oklch(0.42 0.024 55)",
              borderRadius: 9,
              fontSize: 12,
              color: "var(--cascade-text-2)",
              lineHeight: 1.5,
            }}
          >
            <div style={{ marginBottom: 6 }}>
              Paste your Anthropic API key to ask questions. Stored in macOS Keychain and used only for Cascade's Anthropic calls.
            </div>
            <div style={{ display: "flex", gap: 6 }}>
              <input
                value={keyInput}
                onChange={(e) => setKeyInput(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") saveKey();
                }}
                placeholder="sk-ant-..."
                type="password"
                spellCheck={false}
                autoComplete="off"
                style={{
                  flex: 1,
                  background: "oklch(0.115 0.008 140 / 0.6)",
                  border: "1px solid var(--cascade-border)",
                  borderRadius: 6,
                  padding: "6px 10px",
                  color: "var(--cascade-text)",
                  fontFamily: "var(--cascade-mono)",
                  fontSize: 11.5,
                  outline: "none",
                }}
              />
              <button
                onClick={saveKey}
                disabled={!keyInput.trim().startsWith("sk-ant-")}
                style={{
                  padding: "6px 12px",
                  borderRadius: 6,
                  background: "var(--cascade-accent)",
                  color: "var(--cascade-on-accent)",
                  border: "none",
                  cursor: keyInput.trim().startsWith("sk-ant-") ? "pointer" : "default",
                  fontFamily: "var(--cascade-sans)",
                  fontSize: 12,
                  fontWeight: 500,
                  opacity: keyInput.trim().startsWith("sk-ant-") ? 1 : 0.4,
                }}
              >
                Save
              </button>
            </div>
          </div>
        )}
        {hasKey && (
          <div
            style={{
              marginBottom: 6,
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
              fontFamily: "var(--cascade-mono)",
              fontSize: 9.5,
              color: "var(--cascade-text-4)",
              letterSpacing: 0.6,
            }}
          >
            <span>✓ ANTHROPIC KEY CONNECTED</span>
            <button
              onClick={clearKey}
              style={{
                background: "transparent",
                border: "none",
                color: "var(--cascade-text-4)",
                cursor: "pointer",
                fontFamily: "var(--cascade-mono)",
                fontSize: 9.5,
                textDecoration: "underline",
              }}
            >
              clear
            </button>
          </div>
        )}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 6,
            background: "oklch(0.115 0.008 140 / 0.5)",
            border: "1px solid var(--cascade-border)",
            borderRadius: 9,
            padding: "4px 4px 4px 12px",
          }}
        >
          <input
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !busy) send();
            }}
            placeholder={hasKey ? "Ask about this scene…" : "Add Anthropic key above first"}
            disabled={busy || !hasKey}
            style={{
              flex: 1,
              background: "transparent",
              border: "none",
              outline: "none",
              color: "var(--cascade-text)",
              fontSize: 13,
              fontFamily: "var(--cascade-sans)",
              padding: "6px 0",
              opacity: hasKey ? 1 : 0.5,
            }}
          />
          <button
            onClick={() => send()}
            disabled={busy || !input.trim() || !hasKey}
            style={{
              width: 28,
              height: 28,
              borderRadius: 6,
              background: "var(--cascade-accent)",
              color: "var(--cascade-on-accent)",
              border: "none",
              cursor: busy || !input.trim() || !hasKey ? "default" : "pointer",
              padding: 0,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              opacity: busy || !input.trim() || !hasKey ? 0.4 : 1,
              fontWeight: 700,
            }}
          >
            →
          </button>
        </div>
      </div>
    </div>
  );
}

async function askClaude(question: string, frame: CascadeFrame | null): Promise<string> {
  return invoke<string>("cascade_ask_reel_question", { question, frame });
}
