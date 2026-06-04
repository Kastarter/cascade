// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

"use client";

import { useState } from "react";
import { commands } from "@/lib/utils/tauri";
import { CascadeOnboarding } from "@/components/cascade-onboarding";
import { useOnboardingWithLoader } from "@/lib/hooks/use-onboarding";

export default function OnboardingPage() {
  const { onboardingData, isLoading, completeOnboarding } = useOnboardingWithLoader();
  const [finishing, setFinishing] = useState(false);

  const finish = async () => {
    if (finishing) return;
    setFinishing(true);
    try {
      await completeOnboarding();
      await commands.showWindow({ Home: { page: null } });
      window.close();
    } catch {
      setFinishing(false);
    }
  };

  if (isLoading || finishing) {
    return (
      <div className="flex items-center justify-center min-h-screen bg-background">
        <div className="w-6 h-6 border border-foreground border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  if (onboardingData.isCompleted) {
    void commands
      .showWindow({ Home: { page: null } })
      .then(() => window.close())
      .catch(() => {});
    return null;
  }

  return <CascadeOnboarding onComplete={finish} />;
}
