// cascade — passive monitoring + retrospective Q&A
// https://github.com/Mohanad139/Cascade

"use client";

/**
 * Cascade does not use Screenpipe's in-app/native notification handler.
 * Keep the component as a no-op so upstream mount points remain harmless.
 */
export default function NotificationHandler() {
  return null;
}
