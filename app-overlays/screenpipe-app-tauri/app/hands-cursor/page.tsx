// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Fullscreen, click-through overlay that renders EVERY working agent's own
// cursor — one labeled, colored pointer per installed agent. The real macOS
// pointer is never touched.
//
// The cursor keeps OpenClicky's fast bezier flight, but the rendered pointer is
// Cascade's own crisp blue/white arrow. Per-agent hue is an accent for glow and
// labels, not the whole pointer body, so a default agent never looks like an old
// green crosshair.

"use client";

import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import {
  planFlight,
  sampleFlight,
  lerpAngle,
  RESTING_TILT,
  type Flight,
  type Pt,
} from "@/lib/cursor-flight";

interface CursorState {
  specId: number;
  name: string;
  x: number;
  y: number;
  clicking: boolean;
  visible: boolean;
  hue: number;
}

// Triangle geometry (equilateral, apex up — matches the Swift original's
// sqrt(3)/2 height). Sized up a touch from OpenClicky's 16px since this rides on
// the full real screen, not a 320px companion panel.
const SIZE = 24;
const PAD = 8;
const BOX = SIZE + PAD * 2;
const HALF = SIZE / 2;
const TRI_H = (SIZE * Math.sqrt(3)) / 2;
const TOP_Y = HALF - TRI_H / 1.5;
const BOT_Y = HALF + TRI_H / 3;
const POINTS = `${HALF},${TOP_Y.toFixed(2)} 0,${BOT_Y.toFixed(2)} ${SIZE},${BOT_Y.toFixed(2)}`;

// Glow grows with the flight scale, exactly like BlueCursorTriangle's
// drop-shadow(0 0 glowIntensity + (scale-1)*k).
const GLOW_BASE = 10;
const GLOW_GAIN = 22;

// How long the heading takes to ease back to RESTING_TILT after arriving.
const SETTLE_MS = 420;

interface Runtime {
  pos: Pt; // current rendered position
  rotation: number; // current rendered heading (deg)
  flight: Flight | null;
  settleStartMs: number | null;
  settleFromRot: number;
  clickStartMs: number | null;
  clicking: boolean;
  clickNonce: number;
  color: string;
}

// Per-agent display props that change rarely — kept in React state so the label
// and click ripple re-render. Position/rotation/scale never touch state; they're
// written straight to the DOM by the rAF loop to stay smooth.
interface Meta {
  name: string;
  hue: number;
  clicking: boolean;
  clickNonce: number;
}

const accentFor = (hue: number) => `oklch(0.68 0.18 ${hue})`;
const glowFor = (hue: number) => `oklch(0.72 0.20 ${hue})`;
const labelBorderFor = (hue: number) => `oklch(0.62 0.16 ${hue} / 0.52)`;
const POINTER_STROKE = "rgba(8, 13, 27, 0.92)";
const POINTER_CORE = "#f8fbff";
const POINTER_BLUE = "#4c8dff";

export default function HandsCursor() {
  const [meta, setMeta] = useState<Record<number, Meta>>({});
  const runtimes = useRef<Map<number, Runtime>>(new Map());
  const nodes = useRef<Map<number, { pos: HTMLDivElement | null; tri: HTMLDivElement | null }>>(
    new Map()
  );

  // Live cursor event stream from the Rust run loop. All animation-state mutation
  // happens here in the event body (one call per event) — never inside setMeta,
  // which must stay pure for React StrictMode's double-invoked updaters.
  useEffect(() => {
    document.documentElement.style.background = "transparent";
    document.body.style.background = "transparent";
    document.body.style.margin = "0";

    const un = listen<CursorState>("cascade-hands-cursor", (e) => {
      const c = e.payload;
      const now = performance.now();

      if (!c.visible) {
        runtimes.current.delete(c.specId);
        nodes.current.delete(c.specId);
        setMeta((prev) => {
          if (!(c.specId in prev)) return prev;
          const next = { ...prev };
          delete next[c.specId];
          return next;
        });
        return;
      }

      let rt = runtimes.current.get(c.specId);
      if (!rt) {
        // First sighting: drop the triangle in place, no entrance flight.
        rt = {
          pos: { x: c.x, y: c.y },
          rotation: RESTING_TILT,
          flight: null,
          settleStartMs: null,
          settleFromRot: RESTING_TILT,
          clickStartMs: null,
          clicking: false,
          clickNonce: 0,
          color: glowFor(c.hue),
        };
        runtimes.current.set(c.specId, rt);
      } else {
        rt.color = glowFor(c.hue);
        // A meaningfully new target re-plans the flight from where the cursor
        // actually is right now, so redirects mid-flight stay continuous.
        const moved = Math.hypot(c.x - rt.pos.x, c.y - rt.pos.y);
        if (moved > 2) {
          rt.flight = planFlight({ ...rt.pos }, { x: c.x, y: c.y }, now);
          rt.settleStartMs = null;
        }
      }

      if (c.clicking && !rt.clicking) {
        rt.clickStartMs = now;
        rt.clickNonce += 1;
      }
      rt.clicking = c.clicking;

      const nonce = rt.clickNonce;
      setMeta((prev) => ({
        ...prev,
        [c.specId]: { name: c.name, hue: c.hue, clicking: c.clicking, clickNonce: nonce },
      }));
    });

    return () => {
      un.then((f) => f());
    };
  }, []);

  // Single rAF loop drives every cursor's transform directly on the DOM.
  useEffect(() => {
    let raf = 0;
    const loop = () => {
      const now = performance.now();
      runtimes.current.forEach((rt, id) => {
        const n = nodes.current.get(id);
        if (!n || !n.pos || !n.tri) return;

        let scale = 1;
        if (rt.flight) {
          const s = sampleFlight(rt.flight, now);
          rt.pos = { x: s.x, y: s.y };
          rt.rotation = s.rotation;
          scale = s.scale;
          if (s.done) {
            rt.flight = null;
            rt.settleStartMs = now;
            rt.settleFromRot = s.rotation;
          }
        } else if (rt.settleStartMs != null) {
          // Ease the heading back to the resting lean once parked.
          const p = Math.min((now - rt.settleStartMs) / SETTLE_MS, 1);
          const e = p * p * (3 - 2 * p);
          rt.rotation = lerpAngle(rt.settleFromRot, RESTING_TILT, e);
          if (p >= 1) rt.settleStartMs = null;
        }

        // Click "press": a quick dip-and-recover punch on top of flight scale.
        if (rt.clickStartMs != null) {
          const cp = (now - rt.clickStartMs) / 220;
          if (cp >= 1) rt.clickStartMs = null;
          else scale *= 1 - Math.sin(cp * Math.PI) * 0.16;
        }

        const glow = GLOW_BASE + (scale - 1) * GLOW_GAIN;
        n.pos.style.transform = `translate3d(${rt.pos.x}px, ${rt.pos.y}px, 0)`;
        n.tri.style.transform = `rotate(${rt.rotation}deg) scale(${scale})`;
        n.tri.style.filter = `drop-shadow(0 0 ${glow}px ${rt.color}) drop-shadow(0 1px 2px rgba(0,0,0,0.55))`;
      });
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
  }, []);

  const setPosNode = (id: number, el: HTMLDivElement | null) => {
    const slot = nodes.current.get(id);
    if (el) nodes.current.set(id, { pos: el, tri: slot?.tri ?? null });
    else if (slot) slot.pos = null;
  };
  const setTriNode = (id: number, el: HTMLDivElement | null) => {
    const slot = nodes.current.get(id);
    if (el) nodes.current.set(id, { pos: slot?.pos ?? null, tri: el });
    else if (slot) slot.tri = null;
  };

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        background: "transparent",
        overflow: "hidden",
        pointerEvents: "none",
      }}
    >
      {Object.entries(meta).map(([idStr, m]) => {
        const id = Number(idStr);
        const accent = accentFor(m.hue);
        const gradId = `cascade-cursor-fill-${id}`;
        const shineId = `cascade-cursor-shine-${id}`;
        return (
          <div
            key={id}
            ref={(el) => setPosNode(id, el)}
            style={{ position: "absolute", left: 0, top: 0, willChange: "transform" }}
          >
            {/* Triangle (rotates + scales; glow rides the scale). */}
            <div
              ref={(el) => setTriNode(id, el)}
              style={{
                position: "absolute",
                left: -BOX / 2,
                top: -BOX / 2,
                width: BOX,
                height: BOX,
                willChange: "transform, filter",
              }}
            >
              <svg width={BOX} height={BOX} viewBox={`${-PAD} ${-PAD} ${BOX} ${BOX}`}>
                <defs>
                  <linearGradient id={gradId} x1="4" y1="-2" x2="20" y2="25" gradientUnits="userSpaceOnUse">
                    <stop offset="0" stopColor={POINTER_CORE} />
                    <stop offset="0.48" stopColor="#dbe8ff" />
                    <stop offset="1" stopColor={POINTER_BLUE} />
                  </linearGradient>
                  <linearGradient id={shineId} x1="7" y1="-2" x2="16" y2="18" gradientUnits="userSpaceOnUse">
                    <stop offset="0" stopColor="#ffffff" stopOpacity="0.92" />
                    <stop offset="1" stopColor="#ffffff" stopOpacity="0" />
                  </linearGradient>
                </defs>
                <circle cx={HALF} cy={HALF} r={SIZE * 0.68} fill={accent} opacity="0.12" />
                <polygon
                  points={POINTS}
                  fill={`url(#${gradId})`}
                  stroke={POINTER_STROKE}
                  strokeWidth={1.35}
                  strokeLinejoin="round"
                />
                <polygon
                  points={`${HALF},${(TOP_Y + 3).toFixed(2)} 6,${(BOT_Y - 4).toFixed(2)} ${HALF},${(BOT_Y - 2).toFixed(2)}`}
                  fill={`url(#${shineId})`}
                  opacity="0.64"
                />
              </svg>
            </div>

            {/* Click ripple — remounts on each click via clickNonce to replay. */}
            {m.clicking && (
              <span
                key={m.clickNonce}
                style={{
                  position: "absolute",
                  left: -16,
                  top: -16,
                  width: 32,
                  height: 32,
                  borderRadius: "50%",
                  border: `2px solid ${accent}`,
                  boxShadow: `0 0 14px ${glowFor(m.hue)}`,
                  animation: "cascadeRipple 0.5s ease-out",
                }}
              />
            )}

            {/* Trailing name caption (does not rotate with the triangle). */}
            <span
              style={{
                position: "absolute",
                left: 18,
                top: -4,
                padding: "2px 7px",
                borderRadius: 6,
                background: "rgba(7, 11, 22, 0.84)",
                border: `1px solid ${labelBorderFor(m.hue)}`,
                boxShadow: `0 8px 22px rgba(4, 7, 16, 0.24), 0 0 16px ${glowFor(m.hue)}`,
                color: "#f8fbff",
                font: "650 10px ui-monospace, SFMono-Regular, Menlo, monospace",
                letterSpacing: 0,
                whiteSpace: "nowrap",
                maxWidth: 160,
                overflow: "hidden",
                textOverflow: "ellipsis",
              }}
            >
              {m.name}
            </span>
          </div>
        );
      })}
      <style>{`@keyframes cascadeRipple { from { transform: scale(0.4); opacity: 1; } to { transform: scale(1.8); opacity: 0; } }`}</style>
    </div>
  );
}
