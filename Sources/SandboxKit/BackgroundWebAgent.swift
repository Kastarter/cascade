import Foundation
import ProviderKit

/// Runs a task entirely inside a `WebSandbox` — the isolated, background browser —
/// using Claude's Computer Use vision loop, but routing every action to the sandbox
/// (JavaScript) instead of the user's real screen. The user can keep working; the
/// agent's progress streams out as snapshots + status.
@MainActor
public final class BackgroundWebAgent {
    public struct Update: Sendable {
        public let status: String
        public let snapshotPNG: Data?
        public let url: String
        public let done: Bool
        public let result: String?
        public var needsLogin: Bool = false
    }

    private let keyStore: AnthropicKeyStore
    private let model: String
    private var stopped = false

    public let sandbox = WebSandbox()

    public init(keyStore: AnthropicKeyStore = AnthropicKeyStore(), model: String = AnthropicModel.sonnet) {
        self.keyStore = keyStore
        self.model = model
    }

    public func stop() { stopped = true }

    /// Carries out `task` in the sandbox, calling `onUpdate` after each step.
    public func run(task: String, onUpdate: @escaping @MainActor (Update) -> Void) async {
        onUpdate(Update(status: "Opening a private browser…", snapshotPNG: nil, url: "", done: false, result: nil))

        let startURL = await suggestStartURL(for: task)
        await sandbox.navigate(to: startURL)

        guard var shot = await sandbox.snapshotPNG() else {
            onUpdate(Update(status: "Couldn't open the sandbox browser.", snapshotPNG: nil, url: sandbox.currentURL, done: true, result: nil))
            return
        }
        onUpdate(Update(status: "Working: \(task)", snapshotPNG: shot, url: sandbox.currentURL, done: false, result: nil))

        let agent = ComputerUseAgent(
            keyStore: keyStore,
            model: model,
            environmentNote: """
            You are inside a single web view in a sandboxed browser — there are NO tabs, \
            NO "+" button and NO address bar, and there are no other apps (the open_app \
            tool does nothing here). Do not look for them and never try to open a new \
            tab. There is only this one view. To go to a different site or known URL, \
            use the open_url tool — it loads instantly in this same view. Links that \
            would normally open in a new tab automatically open right here, so just \
            click them and continue working in place.

            Actually CARRY OUT the task on the real website(s) for it. Do NOT search for \
            tutorials, articles, or "how to" guides about the task, and do NOT go to \
            ChatGPT/OpenAI to ask how — just do the task itself directly.

            If the page is a sign-in / login / "log in to continue" wall and you do not \
            have credentials, do NOT guess or type anything. Stop immediately and reply \
            with exactly: NEEDS_LOGIN <site name>.
            """
        )
        var step = await agent.begin(
            goal: task,
            screenshot: shot,
            displayWidthPoints: Int(WebSandbox.width),
            displayHeightPoints: Int(WebSandbox.height)
        )

        let maxSteps = 40
        var count = 0
        while count < maxSteps, !stopped {
            if step.done {
                let raw = step.text.isEmpty ? "Done." : step.text
                if let site = Self.loginSite(in: raw) {
                    let message = "I need you to sign in to \(site). I've opened it in the box — sign in, then press Continue."
                    onUpdate(Update(status: message, snapshotPNG: shot, url: sandbox.currentURL, done: true, result: message, needsLogin: true))
                } else {
                    onUpdate(Update(status: raw, snapshotPNG: shot, url: sandbox.currentURL, done: true, result: raw))
                }
                return
            }
            if !step.text.isEmpty {
                onUpdate(Update(status: step.text, snapshotPNG: shot, url: sandbox.currentURL, done: false, result: nil))
            }
            for action in step.actions {
                await apply(action)
            }
            try? await Task.sleep(for: .milliseconds(350))
            shot = await sandbox.snapshotPNG() ?? shot
            onUpdate(Update(status: step.text.isEmpty ? "Working…" : step.text, snapshotPNG: shot, url: sandbox.currentURL, done: false, result: nil))
            step = await agent.proceed(screenshot: shot)
            count += 1
        }

        let closing = stopped ? "Stopped." : "Reached the step limit — ask again to continue."
        onUpdate(Update(status: closing, snapshotPNG: shot, url: sandbox.currentURL, done: true, result: stopped ? nil : closing))
    }

    /// Maps a Computer Use action onto the web sandbox. The agent works in bottom-left
    /// AppKit coordinates; the page wants top-left, so y is flipped.
    private func apply(_ action: CUAction) async {
        func topLeftY(_ y: Double) -> CGFloat { WebSandbox.height - CGFloat(y) }
        switch action {
        case .click(let x, let y), .doubleClick(let x, let y), .rightClick(let x, let y):
            await sandbox.click(xTopLeft: CGFloat(x), yTopLeft: topLeftY(y))
        case .move:
            break  // no pointer in the sandbox
        case .type(let text):
            await sandbox.typeText(text)
        case .key(let combo):
            await sandbox.pressKey(combo)
        case .scroll(_, _, let direction, let amount):
            let magnitude = CGFloat(max(1, amount)) * 120
            await sandbox.scroll(dy: direction.lowercased() == "up" ? -magnitude : magnitude)
        case .wait:
            try? await Task.sleep(for: .milliseconds(600))
        case .screenshot:
            break
        case .openApp:
            break  // no apps inside the web sandbox
        case .openURL(let urlString):
            await sandbox.navigate(to: urlString)
            try? await Task.sleep(for: .milliseconds(800))  // let the page start rendering
        }
    }

    /// Detects the agent's NEEDS_LOGIN signal and returns the site name.
    private static func loginSite(in text: String) -> String? {
        let upper = text.uppercased()
        guard upper.contains("NEEDS_LOGIN") else { return nil }
        if let range = text.range(of: "NEEDS_LOGIN", options: .caseInsensitive) {
            let rest = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:")))
            if !rest.isEmpty { return rest }
        }
        return "this site"
    }

    /// Asks Claude for the single best starting URL; falls back to a web search.
    private func suggestStartURL(for task: String) async -> String {
        let fallback = "https://www.google.com/search?q=" +
            (task.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        guard let key = keyStore.readKey(), !key.isEmpty else { return fallback }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 60,
            "messages": [[
                "role": "user",
                "content": "I need to ACTUALLY DO this task on the web (not research how to do it). What single website should I open first to do it? Task: \(task)\n\nPick the real service/site for doing the task (a booking site, the tool's own website, etc.) — NOT a how-to article and NOT ChatGPT/OpenAI. Reply with ONLY the full https:// URL, nothing else.",
            ]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return fallback }
        request.httpBody = data
        guard let (respData, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            return fallback
        }
        // Pull the first URL-looking token out of the reply.
        if let match = text.range(of: #"https?://[^\s"'<>]+"#, options: .regularExpression) {
            return String(text[match])
        }
        return fallback
    }
}
