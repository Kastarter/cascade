// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Today — editorial summary view. Placeholder for the full port of
// Cascade-2/views.jsx (01-today.png). Real wiring requires: app usage
// rollup, files-made-today, AI-inferred loose ends, key moments scan.
// Lands in the next iteration.

"use client";

import Link from "next/link";
import { CascadeTitlebar } from "@/components/cascade-titlebar";

export default function TodayPage() {
  const now = new Date();
  const greeting = now.getHours() < 12 ? "Good morning" : now.getHours() < 17 ? "Good afternoon" : "Good evening";
  const dateLabel = now.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });

  return (
    <div style={{ minHeight: "100vh", display: "flex", flexDirection: "column", background: "var(--cascade-bg)" }}>
      <CascadeTitlebar />

      <div
        style={{
          flex: 1,
          padding: "64px 80px",
          maxWidth: 980,
          margin: "0 auto",
          width: "100%",
          color: "var(--cascade-text)",
          fontFamily: "var(--cascade-sans)",
        }}
      >
        <div
          style={{
            fontFamily: "var(--cascade-mono)",
            fontSize: 10.5,
            letterSpacing: 1.8,
            textTransform: "uppercase",
            color: "var(--cascade-text-3)",
            marginBottom: 12,
          }}
        >
          {dateLabel}
        </div>

        <h1
          style={{
            fontFamily: "var(--cascade-serif)",
            fontWeight: 400,
            fontSize: 56,
            lineHeight: 1.05,
            letterSpacing: -1,
            margin: 0,
            color: "var(--cascade-text)",
          }}
        >
          {greeting},
          <br />
          <span style={{ fontStyle: "italic", color: "var(--cascade-accent)" }}>Cascader.</span>
        </h1>

        <p
          style={{
            marginTop: 24,
            fontSize: 16,
            lineHeight: 1.55,
            color: "var(--cascade-text-2)",
            maxWidth: 680,
          }}
        >
          The editorial Today view is coming next — narrative summary of your day,{" "}
          <strong>WHERE IT WENT</strong> by app, <strong>WHAT YOU MADE</strong>, and{" "}
          <strong>LOOSE ENDS</strong>. Wiring those up needs an app-usage rollup query, file/artifact
          extraction, and an inference pass — a couple hours of work in the next iteration.
        </p>

        <p style={{ marginTop: 18, fontSize: 14, color: "var(--cascade-text-3)" }}>
          For now, the{" "}
          <Link href="/home" style={{ color: "var(--cascade-accent)", textDecoration: "underline" }}>
            Reel
          </Link>{" "}
          is where the action is.
        </p>
      </div>
    </div>
  );
}
