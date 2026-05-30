// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Fullscreen, click-through overlay that renders EVERY working agent's own
// cursor — one labeled, colored pointer per installed agent. They fly around in
// parallel doing their tasks; the real macOS pointer is never touched.

"use client";

import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";

interface CursorState {
  specId: number;
  name: string;
  x: number;
  y: number;
  clicking: boolean;
  visible: boolean;
  hue: number;
}

export default function HandsCursor() {
  const [cursors, setCursors] = useState<Record<number, CursorState>>({});

  useEffect(() => {
    document.documentElement.style.background = "transparent";
    document.body.style.background = "transparent";
    document.body.style.margin = "0";
    const un = listen<CursorState>("cascade-hands-cursor", (e) => {
      const c = e.payload;
      setCursors((prev) => {
        const next = { ...prev };
        if (!c.visible) {
          delete next[c.specId];
        } else {
          next[c.specId] = c;
        }
        return next;
      });
    });
    return () => {
      un.then((f) => f());
    };
  }, []);

  return (
    <div style={{ position: "fixed", inset: 0, background: "transparent", overflow: "hidden", pointerEvents: "none" }}>
      {Object.values(cursors).map((c) => {
        const color = `oklch(0.78 0.16 ${c.hue})`;
        const deep = `oklch(0.30 0.10 ${c.hue})`;
        return (
          <div
            key={c.specId}
            style={{
              position: "absolute",
              left: c.x,
              top: c.y,
              transition: "left 0.5s cubic-bezier(0.22,1,0.36,1), top 0.5s cubic-bezier(0.22,1,0.36,1)",
              transform: "translate(-3px, -2px)",
            }}
          >
            <div
              style={{
                position: "absolute",
                left: -16,
                top: -16,
                width: 48,
                height: 48,
                borderRadius: "50%",
                background: `radial-gradient(circle, ${color}88, transparent 70%)`,
                filter: "blur(2px)",
              }}
            />
            {c.clicking && (
              <span
                style={{
                  position: "absolute",
                  left: -14,
                  top: -14,
                  width: 32,
                  height: 32,
                  borderRadius: "50%",
                  border: `2px solid ${color}`,
                  animation: "cascadeRipple 0.5s ease-out",
                }}
              />
            )}
            <svg width="26" height="26" viewBox="0 0 24 24" style={{ filter: "drop-shadow(0 2px 4px rgba(0,0,0,0.55))" }}>
              <path
                d="M4 2 L4 20 L9 15 L12.5 22 L15.5 20.5 L12 13.5 L19 13.5 Z"
                fill={color}
                stroke={deep}
                strokeWidth="1.1"
                strokeLinejoin="round"
              />
            </svg>
            <span
              style={{
                position: "absolute",
                left: 22,
                top: 8,
                padding: "2px 7px",
                borderRadius: 6,
                background: deep,
                color: color,
                font: "600 10px ui-monospace, SFMono-Regular, Menlo, monospace",
                letterSpacing: 0.4,
                whiteSpace: "nowrap",
                maxWidth: 160,
                overflow: "hidden",
                textOverflow: "ellipsis",
              }}
            >
              {c.name}
            </span>
          </div>
        );
      })}
      <style>{`@keyframes cascadeRipple { from { transform: scale(0.4); opacity: 1; } to { transform: scale(1.8); opacity: 0; } }`}</style>
    </div>
  );
}
