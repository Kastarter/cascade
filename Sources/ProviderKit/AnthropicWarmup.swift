import Foundation
import OSLog

/// Warms the TLS/HTTP-2 connection to the Anthropic API so the first real
/// request doesn't pay a cold TCP+TLS handshake (~100–300ms) on top of the
/// model round-trip. Screen capture is already prewarmed on PTT press; this
/// closes the matching gap on the network side.
///
/// Fire-and-forget: a throwaway GET to the API host establishes a pooled
/// connection in `URLSession.shared` (the same session `ComputerUseAgent` uses),
/// so the next `step()` reuses it. No key, no body, failures ignored — the host
/// returning 404/403 is fine; the handshake is the whole point.
public enum AnthropicWarmup {
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "warmup")
    private static let host = URL(string: "https://api.anthropic.com/")!

    /// Best-effort connection warm-up. Detached and short-timeout so it never
    /// blocks the caller or lingers; call it when the user starts talking (PTT
    /// press), alongside the capture prewarm.
    public static func prewarm() {
        Task.detached(priority: .utility) {
            var request = URLRequest(url: host)
            request.httpMethod = "GET"
            request.timeoutInterval = 4
            _ = try? await URLSession.shared.bytes(for: request)
            logger.debug("TLS connection prewarmed")
        }
    }
}
