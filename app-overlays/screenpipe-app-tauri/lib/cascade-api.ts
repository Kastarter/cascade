// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

/**
 * Thin client for Screenpipe's local HTTP API. We use Screenpipe's own
 * `localFetch` helper which:
 *   - resolves the configurable port (not always 3030)
 *   - auto-injects the Bearer token when API auth is enabled
 *   - handles 401 refresh
 *
 * Plain `fetch('http://localhost:3030/...')` does NOT work — Screenpipe's
 * HTTP server requires auth unless explicitly disabled, and the port can be
 * remapped in Settings. Always go through `localFetch`.
 */

import { localFetch } from "@/lib/api";

export interface CascadeFrame {
  frame_id: number;
  timestamp: string;          // ISO 8601
  app_name: string | null;
  window_name: string | null;
  browser_url: string | null; // active tab URL when the app is a browser
  text: string;               // OCR
  file_path?: string;         // path to the video file containing this frame
  offset_index?: number;      // frame index within the video file
  fps?: number;               // video fps for seeking
}

export interface CascadeSegment {
  id: string;
  app: string | null;
  start_min: number;          // minutes from midnight
  end_min: number;
  title: string;
  detail: string;
  frame_count: number;
}

export async function fetchOcrFrames(opts: {
  startTime?: Date;
  endTime?: Date;
  limit?: number;
  appName?: string;
}): Promise<CascadeFrame[]> {
  const params = new URLSearchParams({
    // 'all' gives denser timeline density vs 'ocr' which only returns frames
    // with detected text. Non-OCR frames still have app_name + window metadata.
    content_type: "all",
    limit: String(opts.limit ?? 100),
  });
  if (opts.startTime) params.set("start_time", opts.startTime.toISOString());
  if (opts.endTime) params.set("end_time", opts.endTime.toISOString());
  if (opts.appName) params.set("app_name", opts.appName);

  try {
    const r = await localFetch(`/search?${params}`);
    if (!r.ok) {
      console.warn(`cascade-api: /search returned ${r.status}`);
      return [];
    }
    const json = await r.json();
    const items = Array.isArray(json?.data) ? json.data : [];
    return items.map((it: any): CascadeFrame => ({
      frame_id: it.content?.frame_id ?? it.frame_id ?? 0,
      timestamp: it.content?.timestamp ?? it.timestamp ?? new Date().toISOString(),
      app_name: it.content?.app_name ?? it.app_name ?? null,
      window_name: it.content?.window_name ?? it.window_name ?? null,
      browser_url: it.content?.browser_url ?? it.browser_url ?? null,
      text: it.content?.text ?? it.text ?? "",
      file_path: it.content?.file_path ?? it.file_path,
      offset_index: it.content?.offset_index ?? it.offset_index,
      fps: it.content?.fps ?? it.fps,
    }));
  } catch (e) {
    console.error("cascade-api: fetchOcrFrames failed", e);
    return [];
  }
}

/**
 * Group raw frames into continuous segments by app — emulates the prototype's
 * SEGMENTS array. A segment is a run of consecutive frames with the same
 * app_name; gaps >5min start a new segment regardless of app.
 */
export function framesToSegments(frames: CascadeFrame[]): CascadeSegment[] {
  if (frames.length === 0) return [];
  const sorted = [...frames].sort((a, b) =>
    new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime()
  );
  const segments: CascadeSegment[] = [];
  const GAP_MS = 5 * 60 * 1000;

  let current = startSegment(sorted[0]);
  for (let i = 1; i < sorted.length; i++) {
    const f = sorted[i];
    const prev = sorted[i - 1];
    const gap = new Date(f.timestamp).getTime() - new Date(prev.timestamp).getTime();
    const appChange = (f.app_name || null) !== (prev.app_name || null);

    if (gap > GAP_MS || appChange) {
      current.end_min = toMinutesFromMidnight(prev.timestamp);
      segments.push(current);
      current = startSegment(f);
    } else {
      current.frame_count++;
    }
  }
  current.end_min = toMinutesFromMidnight(sorted[sorted.length - 1].timestamp);
  segments.push(current);
  return segments;
}

function startSegment(f: CascadeFrame): CascadeSegment {
  const start = toMinutesFromMidnight(f.timestamp);
  return {
    id: `s_${f.frame_id}`,
    app: f.app_name,
    start_min: start,
    end_min: start + 1,
    title: f.window_name || f.app_name || "Untitled",
    detail: f.text.slice(0, 80),
    frame_count: 1,
  };
}

export function toMinutesFromMidnight(iso: string): number {
  const d = new Date(iso);
  return d.getHours() * 60 + d.getMinutes() + d.getSeconds() / 60;
}

export function minToHHMM(min: number): string {
  const totalMin = Math.floor(min);
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  const period = h >= 12 ? "pm" : "am";
  const hh = h === 0 ? 12 : h > 12 ? h - 12 : h;
  return `${hh}:${String(m).padStart(2, "0")}${period}`;
}

/** Second-resolution time display. `min` may be fractional. */
export function minToHHMMSS(min: number): string {
  const totalSeconds = Math.max(0, Math.floor(min * 60));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const period = hours >= 12 ? "pm" : "am";
  const h12 = hours === 0 ? 12 : hours > 12 ? hours - 12 : hours;
  return `${h12}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}${period}`;
}

export function durMins(mins: number): string {
  const total = Math.max(1, Math.round(mins)); // round; never show a fractional minute
  const h = Math.floor(total / 60);
  const m = total % 60;
  if (h === 0) return `${m}m`;
  if (m === 0) return `${h}h`;
  return `${h}h ${m}m`;
}

/** Tight harmonious palette matching the prototype's APPS object. */
export const APP_COLORS: Record<string, { name: string; color: string }> = {
  "Code":            { name: "VS Code",        color: "oklch(0.74 0.11 220)" },
  "Visual Studio Code": { name: "VS Code",     color: "oklch(0.74 0.11 220)" },
  "Cursor":          { name: "Cursor",         color: "oklch(0.74 0.11 220)" },
  "zoom.us":         { name: "Zoom",           color: "oklch(0.74 0.11 255)" },
  "Linear":          { name: "Linear",         color: "oklch(0.72 0.13 290)" },
  "Slack":           { name: "Slack",          color: "oklch(0.74 0.13 335)" },
  "Figma":           { name: "Figma",          color: "oklch(0.74 0.14 15)"  },
  "Google Chrome":   { name: "Chrome",         color: "oklch(0.76 0.12 50)"  },
  "Safari":          { name: "Safari",         color: "oklch(0.76 0.12 50)"  },
  "Notion":          { name: "Notion",         color: "oklch(0.80 0.04 95)"  },
  "Terminal":        { name: "Terminal",       color: "oklch(0.74 0.11 155)" },
  "iTerm2":          { name: "Terminal",       color: "oklch(0.74 0.11 155)" },
  "Mail":            { name: "Mail",           color: "oklch(0.74 0.10 195)" },
};

export function appColor(app: string | null): string {
  if (!app) return "oklch(0.50 0.02 140)";
  return APP_COLORS[app]?.color ?? "oklch(0.65 0.08 140)";
}

export function appDisplayName(app: string | null): string {
  if (!app) return "—";
  return APP_COLORS[app]?.name ?? app;
}

/**
 * Fetch a frame's screenshot as an object URL. Uses localFetch so auth and
 * the configurable port are handled. Caller is responsible for calling
 * URL.revokeObjectURL when the URL is no longer needed (otherwise blob memory
 * leaks).
 */
export async function fetchFrameImage(frameId: number): Promise<string | null> {
  try {
    const r = await localFetch(`/frames/${frameId}`);
    if (!r.ok) {
      console.warn(`cascade-api: /frames/${frameId} returned ${r.status}`);
      return null;
    }
    const blob = await r.blob();
    return URL.createObjectURL(blob);
  } catch (e) {
    console.error("cascade-api: fetchFrameImage failed", e);
    return null;
  }
}
