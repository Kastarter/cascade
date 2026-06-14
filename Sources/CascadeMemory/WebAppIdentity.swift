import Foundation

/// Identifies the web app / site a browser window is showing, from its title — so a
/// workflow done INSIDE the browser is recognized as the real app (Gmail, Outlook,
/// Google Flights, LinkedIn, GitHub…) instead of being lumped under "Chrome".
///
/// Real Chrome titles look like:
///   "Mail - Mohanad Bahammam - Outlook - Google Chrome – Mohanad"   → Outlook
///   "… Book Your Ticket - Google Flights - Google Chrome – Mohanad" → Google Flights
///   "Messaging | LinkedIn - High memory usage - 830 MB - Google Chrome – Mohanad" → LinkedIn
///   "GitHub - Google Chrome – Mohanad"                              → GitHub
///
/// The trick the earlier version got wrong: the browser appends its OWN name and the
/// PROFILE name ("… - Google Chrome – Mohanad"), and Chrome's memory saver injects
/// "High memory usage - NNN MB". The real app brand sits BEFORE all that. So: drop the
/// browser tail + the noise, then match the remaining segments against known brands.
/// An unrecognized page (a school LMS, a bare repo path) matches nothing and returns
/// nil — the caller keeps the browser's own name, which is honest, never a wrong one.
public enum WebAppIdentity {
    /// Title separators; any of them splits the title into segments.
    private static let separators = [" — ", " – ", " - ", " | ", " · ", " • ", " :: ", " › "]

    /// Browsers append their name (and then the profile) to the title. Finding any of
    /// these as a segment means everything from there on is browser chrome, not content.
    private static let browserNames: Set<String> = [
        "google chrome", "chrome", "chromium", "safari", "firefox", "mozilla firefox",
        "microsoft edge", "edge", "arc", "brave", "opera", "vivaldi", "tor browser",
        "duckduckgo", "orion",
    ]

    /// Known web-app / site brands, canonical spelling. Matched case-insensitively
    /// against a whole title segment. Extend freely; unknown sites fall back to the
    /// browser name.
    static let brands: [String] = [
        // Mail
        "Gmail", "Outlook", "Proton Mail", "Yahoo Mail", "iCloud Mail", "Fastmail", "Hotmail",
        // Google suite + properties
        "Google Docs", "Google Sheets", "Google Slides", "Google Drive", "Google Calendar",
        "Google Meet", "Google Maps", "Google Photos", "Google Forms", "Google Keep",
        "Google Flights", "Google Travel", "Google News", "Google Scholar", "Google Translate",
        "Google Classroom", "Google Analytics", "Google Cloud", "YouTube",
        // Productivity / PM
        "Notion", "Coda", "Airtable", "Miro", "Loom", "Linear", "Asana", "Trello", "Jira",
        "Confluence", "ClickUp", "Monday.com", "Basecamp", "Todoist", "Notion Calendar",
        // Dev
        "GitHub", "GitLab", "Bitbucket", "Stack Overflow", "CodePen", "Replit", "Vercel",
        "Netlify", "Cloudflare", "Heroku", "Render", "Supabase", "Firebase", "AWS",
        "Azure", "DigitalOcean", "npm", "MDN", "Hugging Face",
        // Design
        "Figma", "FigJam", "Canva", "Sketch", "Framer",
        // Chat / social
        "Slack", "Discord", "Microsoft Teams", "Teams", "WhatsApp", "Telegram", "Messenger",
        "Signal", "Twitter", "X", "LinkedIn", "Reddit", "Facebook", "Instagram", "TikTok",
        "Pinterest", "Threads", "Mastodon", "Bluesky", "Quora",
        // Commerce
        "Amazon", "eBay", "Etsy", "Shopify", "AliExpress", "Walmart", "Best Buy",
        // Media
        "Netflix", "Spotify", "Twitch", "Hulu", "Prime Video", "SoundCloud", "Apple Music",
        "Disney+",
        // AI
        "ChatGPT", "Claude", "Gemini", "Perplexity", "Copilot",
        // Knowledge / writing
        "Medium", "Substack", "Wikipedia",
        // Storage / meetings
        "Dropbox", "Box", "OneDrive", "Zoom", "Webex",
        // Business / support / payments
        "Salesforce", "HubSpot", "Zendesk", "Intercom", "Stripe", "PayPal", "Wise",
        "QuickBooks", "Xero",
        // Travel / local
        "Booking.com", "Airbnb", "Expedia", "Skyscanner", "Kayak", "Uber", "Lyft",
        "DoorDash", "Grubhub",
        // Education
        "Coursera", "Udemy", "Khan Academy", "edX",
        // Scheduling / forms / sign
        "Calendly", "Typeform", "SurveyMonkey", "DocuSign",
    ]

    private static let canonicalByLowercased: [String: String] = {
        var map: [String: String] = [:]
        for brand in brands { map[brand.lowercased()] = brand }
        return map
    }()

    public static func from(windowTitle: String?) -> String? {
        guard let raw = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        // 1) Split into segments on any common title separator.
        var working = raw
        for sep in separators { working = working.replacingOccurrences(of: sep, with: "\u{1}") }
        var segments = working
            .split(separator: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 2) Drop the browser's own chrome: the browser name and everything after it
        //    (the profile name browsers append — "… - Google Chrome – Mohanad").
        if let browserIdx = segments.firstIndex(where: { browserNames.contains($0.lowercased()) }) {
            segments = Array(segments[..<browserIdx])
        }
        // 3) Drop Chrome's memory-saver noise ("High memory usage", "830 MB").
        segments = segments.filter { !isNoise($0) }
        guard !segments.isEmpty else { return nil }

        // 4) The app brand sits nearest the (now-removed) browser suffix — check from the
        //    end first ("… - Outlook", "… - Google Flights").
        for segment in segments.reversed() {
            let key = segment.lowercased()
            if let brand = canonicalByLowercased[key] { return brand }
            // Any Google property names itself; an unlisted "Google X" still resolves to
            // Google rather than falling back to the browser.
            if key == "google" { return "Google" }
            if key.hasPrefix("google ") { return segment.count <= 24 ? segment : "Google" }
        }
        return nil
    }

    /// Chrome's memory-saver tooltip ("High memory usage", "830 MB") leaks into the
    /// window title; it's not content.
    private static func isNoise(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        if lower == "high memory usage" { return true }
        // A bare data size like "830 MB" / "1.2 GB".
        let scanner = Scanner(string: lower)
        if scanner.scanDouble() != nil {
            let rest = lower[scanner.currentIndex...].trimmingCharacters(in: .whitespaces)
            if ["kb", "mb", "gb", "tb"].contains(rest) { return true }
        }
        return false
    }
}
