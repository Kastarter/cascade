// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

"use client";

import { CascadeReel } from "@/components/cascade-reel";

export default function ReelPage() {
  return (
    <div style={{ height: "100vh", display: "flex", flexDirection: "column" }}>
      <CascadeReel />
    </div>
  );
}
