// cascade — on-screen cursor flight engine
//
// The motion half of the OpenClicky "blue triangle" cursor: the pointer zips to
// its target along an upward bezier arc, rotates to face its direction of
// travel, and swoops (scales up) at mid-flight. Ported from
//   jasonkneen/CursorBuddy  src/lib/bezier-flight.ts
// which is itself a port of OpenClicky's OverlayWindow.swift.
//   https://github.com/jasonkneen/openclicky
//   https://github.com/jasonkneen/CursorBuddy
//
// The math is unchanged from the original:
//   - Hermite smoothstep easing:  3t² − 2t³
//   - Quadratic bezier:           B(t) = (1−t)²·P0 + 2(1−t)t·P1 + t²·P2
//   - Tangent (heading):          B'(t) = 2(1−t)(P1−P0) + 2t(P2−P1)
//   - Scale "swoop":              1 + sin(π·t)·0.3   (peaks 1.3× mid-flight)
//   - Arc lift:                   min(distance · 0.2, 80px)
//   - Duration:                   clamp(distance / 800, 0.6, 1.4) seconds
//
// What's different here: the original startBezierFlight() is one-shot. Cascade's
// overlay drives many agent cursors whose targets arrive as a live event stream,
// so this version is a *re-targetable* flight — every new target re-plans from the
// cursor's current rendered position, keeping motion continuous mid-flight.

export interface Pt {
  x: number;
  y: number;
}

export interface Flight {
  from: Pt;
  to: Pt;
  control: Pt;
  startMs: number;
  durationMs: number;
}

// The triangle's at-rest lean (degrees). A classic pointer leans up-and-left, so
// after a flight settles we ease the heading back to this rather than freezing
// it pointing wherever it last travelled.
export const RESTING_TILT = -32;

export function planFlight(from: Pt, to: Pt, nowMs: number): Flight {
  const distance = Math.hypot(to.x - from.x, to.y - from.y);
  const durationMs = Math.min(Math.max(distance / 800, 0.6), 1.4) * 1000;
  const arcHeight = Math.min(distance * 0.2, 80);
  const control: Pt = {
    x: (from.x + to.x) / 2,
    y: (from.y + to.y) / 2 - arcHeight,
  };
  return { from, to, control, startMs: nowMs, durationMs };
}

export interface FlightSample {
  x: number;
  y: number;
  rotation: number;
  scale: number;
  done: boolean;
}

export function sampleFlight(f: Flight, nowMs: number): FlightSample {
  const linear =
    f.durationMs <= 0 ? 1 : Math.min((nowMs - f.startMs) / f.durationMs, 1);

  // Hermite smoothstep on position only — the scale pulse rides linear time.
  const t = linear * linear * (3 - 2 * linear);
  const u = 1 - t;

  const x = u * u * f.from.x + 2 * u * t * f.control.x + t * t * f.to.x;
  const y = u * u * f.from.y + 2 * u * t * f.control.y + t * t * f.to.y;

  const tangentX = 2 * u * (f.control.x - f.from.x) + 2 * t * (f.to.x - f.control.x);
  const tangentY = 2 * u * (f.control.y - f.from.y) + 2 * t * (f.to.y - f.control.y);
  // +90° because the SVG triangle is drawn pointing up; align its apex to travel.
  const rotation = Math.atan2(tangentY, tangentX) * (180 / Math.PI) + 90;

  const scale = 1 + Math.sin(linear * Math.PI) * 0.3;

  return { x, y, rotation, scale, done: linear >= 1 };
}

// Shortest-path angular interpolation, so settling from e.g. 170° to -32° turns
// the short way instead of spinning all the way round.
export function lerpAngle(a: number, b: number, t: number): number {
  const delta = ((b - a + 540) % 360) - 180;
  return a + delta * t;
}
