// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

/**
 * Cascade-wide defaults the UI overlay reads. Centralized so M1's branding patch
 * and M2's BYOK provider config never drift.
 *
 * NOTE: provider key matches what the pi agent uses internally for Anthropic BYOK
 * (`anthropic-byok` in `build_models_json` — see vendor/screenpipe/apps/screenpipe-app-tauri/src-tauri/src/pi.rs).
 */

export const CASCADE_PRODUCT_NAME = "Cascade";
export const CASCADE_BUNDLE_ID = "com.cascade.app";
export const CASCADE_TRAY_ID = "cascade_main";

export const CASCADE_DEFAULT_PROVIDER = {
  provider: "anthropic" as const,
  model: "claude-sonnet-4-6",
  baseUrl: "https://api.anthropic.com",
  api: "anthropic-messages",
} as const;

export const CASCADE_ADVANCED_MODEL = "claude-opus-4-7";

/**
 * Keychain entry name for the user's Anthropic API key.
 * Matches the SERVICE prefix used by screenpipe-secrets but in our namespace.
 */
export const CASCADE_KEYCHAIN_SERVICE = "com.cascade.app";
export const CASCADE_ANTHROPIC_KEY_NAME = "anthropic-api-key";

/**
 * Pipes shipped with Cascade. The pipe-store patch (0005) hides upstream pipes
 * and exposes only these.
 */
export const CASCADE_BUNDLED_PIPES = ["cascade-rewind-qa"] as const;

/**
 * Marketing copy for onboarding screens.
 */
export const CASCADE_TAGLINE =
  "Cascade remembers what you did so you don't have to.";

export const CASCADE_PRIVACY_PROMISE =
  "Everything stays on this Mac. Your recordings never leave your machine unless you explicitly share them.";

/**
 * The ONLY two ways an agent does its work, chosen in Settings and applied to
 * every agent. The same value is passed straight through to the computer-use
 * engine as its run target — there is no third execution path.
 *
 *  - "sandbox" → the agent works in an isolated browser shown in the floating
 *                box (the "Local Sandbox"); web apps only, and you keep working
 *                while it runs. (Default.)
 *  - "screen"  → the agent uses your REAL screen and cursor, so it can operate
 *                any app — not just websites.
 */
export type CascadeRunMode = "screen" | "sandbox";

export const CASCADE_RUN_MODE_KEY = "cascade-run-mode";
export const CASCADE_RUN_MODE_DEFAULT: CascadeRunMode = "sandbox";

/** Fired on `window` after the run mode changes (same-document listeners). */
export const CASCADE_RUN_MODE_EVENT = "cascade-run-mode-changed";

export function getRunMode(): CascadeRunMode {
  try {
    const v = window.localStorage.getItem(CASCADE_RUN_MODE_KEY);
    return v === "screen" || v === "sandbox" ? v : CASCADE_RUN_MODE_DEFAULT;
  } catch {
    return CASCADE_RUN_MODE_DEFAULT;
  }
}

export function setRunMode(mode: CascadeRunMode): void {
  try {
    window.localStorage.setItem(CASCADE_RUN_MODE_KEY, mode);
    window.dispatchEvent(new CustomEvent(CASCADE_RUN_MODE_EVENT, { detail: mode }));
  } catch {
    /* non-fatal */
  }
}
