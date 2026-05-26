// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { CascadeByokDialog } from "@/components/cascade-byok-dialog";
import {
  CASCADE_PRODUCT_NAME,
  CASCADE_TAGLINE,
  CASCADE_PRIVACY_PROMISE,
} from "@/lib/cascade-defaults";

type Step = "welcome" | "permissions" | "byok" | "done";

interface CascadeOnboardingProps {
  onComplete: () => void;
}

/**
 * Cascade-branded 3-step onboarding overlay.
 *
 * Step 1 — Welcome + privacy promise (no signup, no cloud)
 * Step 2 — Permission requests (Screen Recording, Accessibility, optional Microphone)
 * Step 3 — BYOK Anthropic key entry
 *
 * Replaces upstream's Screenpipe Cloud signup flow (patched out in 0004).
 */
export function CascadeOnboarding({ onComplete }: CascadeOnboardingProps) {
  const [step, setStep] = useState<Step>("welcome");
  const [byokOpen, setByokOpen] = useState(false);
  const [audioEnabled, setAudioEnabled] = useState(false);

  return (
    <div className="min-h-screen flex items-center justify-center p-6 bg-background">
      <Card className="w-full max-w-lg">
        <CardHeader>
          <CardTitle className="text-2xl">
            {step === "welcome" && `Welcome to ${CASCADE_PRODUCT_NAME}`}
            {step === "permissions" && "Grant permissions"}
            {step === "byok" && "Connect Anthropic"}
            {step === "done" && "You're all set"}
          </CardTitle>
          <CardDescription>
            {step === "welcome" && CASCADE_TAGLINE}
            {step === "permissions" && "Cascade needs these macOS permissions to record your screen."}
            {step === "byok" && "Cascade uses your own Anthropic API key — no Cascade cloud."}
            {step === "done" && "Recording starts in the menu bar. Open Cascade anytime to rewind or ask questions."}
          </CardDescription>
        </CardHeader>

        <CardContent className="space-y-4">
          {step === "welcome" && (
            <>
              <p className="text-sm leading-relaxed">{CASCADE_PRIVACY_PROMISE}</p>
              <Button className="w-full" onClick={() => setStep("permissions")}>
                Get started
              </Button>
            </>
          )}

          {step === "permissions" && (
            <>
              <ul className="text-sm space-y-2 list-disc pl-5">
                <li>
                  <strong>Screen Recording</strong> — required. Lets Cascade capture frames and OCR text.
                </li>
                <li>
                  <strong>Accessibility</strong> — required. Reads window/app/URL metadata so the
                  Q&amp;A agent knows context, not just pixels.
                </li>
                <li>
                  <strong>Microphone</strong> — optional. Off by default; enable only if you want
                  meeting transcription.
                </li>
              </ul>

              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={audioEnabled}
                  onChange={(e) => setAudioEnabled(e.target.checked)}
                />
                Enable microphone recording (off by default)
              </label>

              <Button className="w-full" onClick={() => setStep("byok")}>
                Grant permissions
              </Button>
            </>
          )}

          {step === "byok" && (
            <>
              <p className="text-sm">
                Cascade runs the Q&amp;A agent through your own Anthropic API key. Costs are
                billed by Anthropic directly — typically a few cents per long conversation.
              </p>

              <Button className="w-full" onClick={() => setByokOpen(true)}>
                Enter Anthropic key
              </Button>
              <Button variant="ghost" className="w-full" onClick={() => setStep("done")}>
                Skip for now
              </Button>

              <CascadeByokDialog
                open={byokOpen}
                onOpenChange={setByokOpen}
                onSaved={() => setStep("done")}
              />
            </>
          )}

          {step === "done" && (
            <Button className="w-full" onClick={onComplete}>
              Open Cascade
            </Button>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
