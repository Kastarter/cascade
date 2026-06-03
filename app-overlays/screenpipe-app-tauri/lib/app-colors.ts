// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Each app's color is derived from the app ITSELF — its real icon — not a
// hardcoded table. The icon is the brand color: Cursor reads grey, Claude
// orange, Obsidian purple, and any app we've never seen still gets the right
// color automatically. We pull the OS-provided icon from the app's local icon
// server (already used elsewhere in the timeline) and extract its dominant
// chromatic color on a canvas, caching the result per app name. Apps the OS
// has no icon for fall back to a stable, distinct hue hashed from the name, so
// every app still reads as "itself" with zero hardcoding.

const ICON_ENDPOINT = "http://localhost:11435/app-icon?name=";
const CACHE_KEY = "cascade-app-colors-v1";

const cache: Record<string, string> = hydrate();
const pending = new Set<string>();
const listeners = new Set<() => void>();

function hydrate(): Record<string, string> {
  if (typeof window === "undefined") return {};
  try {
    return JSON.parse(window.localStorage.getItem(CACHE_KEY) || "{}") || {};
  } catch {
    return {};
  }
}

function persist() {
  try {
    window.localStorage.setItem(CACHE_KEY, JSON.stringify(cache));
  } catch {
    /* non-fatal */
  }
}

/** Re-render hook: callers subscribe to re-paint when an icon color resolves. */
export function subscribeAppColors(fn: () => void): () => void {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

function emit() {
  listeners.forEach((l) => l());
}

/**
 * Stable, distinct color hashed from the app name — used while the icon loads
 * or when the OS has no icon for it. Returned as hex so callers can append an
 * alpha pair, e.g. `${color}33`.
 */
export function fallbackAppColor(app: string): string {
  let h = 2166136261;
  for (let i = 0; i < app.length; i++) {
    h ^= app.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  const hue = (h >>> 0) % 360;
  return hslToHex(hue, 52, 60);
}

/** Synchronous accessor: cached icon color if resolved, else the name fallback. */
export function appColorHex(app: string | null): string {
  if (!app) return "#6f7a68"; // neutral moss-grey for "no app"
  return cache[app] ?? fallbackAppColor(app);
}

/** Kick off async resolution of an app's icon color (idempotent + cached). */
export function resolveAppColor(app: string | null): void {
  if (!app || typeof window === "undefined") return;
  if (cache[app] || pending.has(app)) return;
  pending.add(app);
  loadDominantColor(app)
    .then((hex) => {
      if (hex) {
        cache[app] = hex;
        persist();
        emit();
      }
    })
    .catch(() => {
      /* leave the name fallback in place */
    })
    .finally(() => pending.delete(app));
}

async function loadDominantColor(app: string): Promise<string | null> {
  const res = await fetch(ICON_ENDPOINT + encodeURIComponent(app));
  if (!res.ok) return null;
  const blob = await res.blob();
  if (!blob.size) return null;
  const bitmap = await createImageBitmap(blob);
  const size = 48; // icons are tiny; 48² pixels is plenty and fast
  const canvas = document.createElement("canvas");
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) {
    bitmap.close?.();
    return null;
  }
  ctx.drawImage(bitmap, 0, 0, size, size);
  bitmap.close?.();
  return dominantColor(ctx.getImageData(0, 0, size, size).data);
}

/**
 * Dominant chromatic color from RGBA pixels. Bins opaque, saturated pixels by
 * hue (weighted by saturation × alpha) and averages the heaviest bin — so a
 * single accent color wins over a white/transparent background. Monochrome
 * icons (no meaningful chroma) fall back to their mean tone, so a grey icon
 * stays grey.
 */
function dominantColor(px: Uint8ClampedArray): string | null {
  const BINS = 36;
  const w = new Array(BINS).fill(0);
  const rr = new Array(BINS).fill(0);
  const gg = new Array(BINS).fill(0);
  const bb = new Array(BINS).fill(0);
  let grayW = 0;
  let grayR = 0;
  let grayG = 0;
  let grayB = 0;

  for (let i = 0; i < px.length; i += 4) {
    const a = px[i + 3];
    if (a < 96) continue; // skip transparent pixels
    const r = px[i] / 255;
    const g = px[i + 1] / 255;
    const b = px[i + 2] / 255;
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const v = max;
    const s = max <= 0 ? 0 : (max - min) / max;
    const af = a / 255;

    // Mean-tone accumulator (monochrome fallback), ignoring white background.
    if (!(v > 0.95 && s < 0.08)) {
      grayW += af;
      grayR += r * af;
      grayG += g * af;
      grayB += b * af;
    }

    // Only clearly chromatic, mid-tone pixels feed the hue histogram.
    if (s < 0.22 || v < 0.12 || v > 0.98) continue;
    const hue = rgbToHue(r, g, b, max, min);
    const weight = s * af;
    const bin = Math.min(BINS - 1, Math.floor((hue / 360) * BINS));
    w[bin] += weight;
    rr[bin] += r * weight;
    gg[bin] += g * weight;
    bb[bin] += b * weight;
  }

  let best = -1;
  let bestW = 0;
  for (let i = 0; i < BINS; i++) {
    if (w[i] > bestW) {
      bestW = w[i];
      best = i;
    }
  }

  if (best >= 0 && bestW > 0.6) {
    return rgbToHex(rr[best] / w[best], gg[best] / w[best], bb[best] / w[best]);
  }
  if (grayW > 0) {
    return rgbToHex(grayR / grayW, grayG / grayW, grayB / grayW);
  }
  return null;
}

function rgbToHue(r: number, g: number, b: number, max: number, min: number): number {
  const d = max - min;
  if (d <= 0) return 0;
  let h: number;
  if (max === r) h = ((g - b) / d) % 6;
  else if (max === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  h *= 60;
  return h < 0 ? h + 360 : h;
}

function rgbToHex(r: number, g: number, b: number): string {
  const c = (x: number) =>
    Math.max(0, Math.min(255, Math.round(x * 255)))
      .toString(16)
      .padStart(2, "0");
  return `#${c(r)}${c(g)}${c(b)}`;
}

function hslToHex(h: number, s: number, l: number): string {
  s /= 100;
  l /= 100;
  const k = (n: number) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) => l - a * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1));
  return rgbToHex(f(0), f(8), f(4));
}
