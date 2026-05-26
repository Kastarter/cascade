// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

"use client";

import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";
import {
  CASCADE_DEFAULT_PROVIDER,
  CASCADE_PRIVACY_PROMISE,
} from "@/lib/cascade-defaults";

interface CascadeByokDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}

/**
 * BYOK Anthropic key collection. Writes to macOS Keychain via
 * `cascade_set_anthropic_key`, which also mirrors into ~/.pi/agent/auth.json
 * so the pi agent picks it up on next start.
 */
export function CascadeByokDialog({ open, onOpenChange, onSaved }: CascadeByokDialogProps) {
  const [key, setKey] = useState("");
  const [saving, setSaving] = useState(false);

  async function handleSave() {
    if (!key.startsWith("sk-ant-")) {
      toast.error("That doesn't look like an Anthropic API key (expected prefix: sk-ant-)");
      return;
    }
    setSaving(true);
    try {
      await invoke("cascade_set_anthropic_key", { key });
      toast.success("Anthropic key saved to Keychain");
      setKey("");
      onSaved();
      onOpenChange(false);
    } catch (err) {
      toast.error(`Failed to save key: ${err}`);
    } finally {
      setSaving(false);
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Connect your Anthropic account</DialogTitle>
          <DialogDescription>
            Cascade uses your Anthropic API key to run the rewind Q&amp;A agent.
            Default model: <code className="font-mono">{CASCADE_DEFAULT_PROVIDER.model}</code>.
            <br />
            <br />
            Get a key at{" "}
            <a
              href="https://console.anthropic.com/settings/keys"
              target="_blank"
              rel="noreferrer"
              className="underline"
            >
              console.anthropic.com/settings/keys
            </a>
            .
            <br />
            <br />
            <span className="text-xs italic">{CASCADE_PRIVACY_PROMISE}</span>
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-2">
          <Label htmlFor="anthropic-key">API key</Label>
          <Input
            id="anthropic-key"
            type="password"
            placeholder="sk-ant-..."
            value={key}
            onChange={(e) => setKey(e.target.value)}
            autoComplete="off"
            spellCheck={false}
          />
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)} disabled={saving}>
            Cancel
          </Button>
          <Button onClick={handleSave} disabled={!key || saving}>
            {saving ? "Saving..." : "Save to Keychain"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
