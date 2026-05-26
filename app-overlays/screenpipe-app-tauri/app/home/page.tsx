// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade
//
// Cascade replaces Screenpipe's 1,401-line home dashboard with the Reel as
// the primary surface. Settings, chat, search, onboarding routes remain
// intact — only the landing window is replaced.

"use client";

import { CascadeReel } from "@/components/cascade-reel";

export default function HomePage() {
  return (
    <div style={{ height: "100vh", display: "flex", flexDirection: "column" }}>
      <CascadeReel />
    </div>
  );
}
