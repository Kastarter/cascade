import Foundation

/// Identifies the web app / site a browser window is showing, from its title — so a
/// workflow done INSIDE the browser is recognized as the real app (Gmail, Notion,
/// Google Docs, Figma…) instead of being lumped under "Safari" / "Chrome".
///
/// Browsers put the site brand in its own segment, usually trailing:
///   "Inbox (5) - me@example.com - Gmail" → "Gmail"
///   "Q3 plan - Google Docs"              → "Google Docs"
///   "(2) Feed | LinkedIn"                → "LinkedIn"
///
/// We only name a web app when a title segment MATCHES A KNOWN BRAND. The naive
/// "grab the last segment" guess is unsafe: Google signs its pages with the account
/// holder's name ("Some doc - Mohanad"), so brand-last harvests the *user's own name*
/// as if it were an app. A wrong name is worse than no name — when nothing matches we
/// return nil and the caller keeps the browser's real name ("Google Chrome").
public enum WebAppIdentity {
    /// Title separators, matched in order; the first present one splits the title.
    private static let separators = [" — ", " – ", " - ", " | ", " · ", " • ", " :: "]

    /// Known web-app / site brands, canonical spelling. Matched case-insensitively
    /// against a whole title segment (never a substring — so "Box" matches a segment
    /// that *is* "Box", not "Box office"). Extend freely; unknown sites simply fall
    /// back to the browser name.
    static let brands: [String] = [
        // Mail
        "Gmail", "Outlook", "Proton Mail", "Yahoo Mail", "iCloud Mail", "Fastmail",
        // Google suite
        "Google Docs", "Google Sheets", "Google Slides", "Google Drive",
        "Google Calendar", "Google Meet", "Google Maps", "Google Photos",
        "Google Forms", "Google Keep", "Google",
        // Productivity / docs / PM
        "Notion", "Notion Calendar", "Coda", "Airtable", "Miro", "Loom",
        "Linear", "Asana", "Trello", "Jira", "Confluence", "ClickUp", "Monday.com",
        "Basecamp", "Height", "Shortcut",
        // Dev
        "GitHub", "GitLab", "Bitbucket", "Stack Overflow", "CodePen", "Replit",
        "Vercel", "Netlify", "Cloudflare", "Heroku", "Render", "Supabase",
        "Firebase", "AWS", "Google Cloud", "Azure", "DigitalOcean",
        // Design
        "Figma", "FigJam", "Canva", "Sketch", "Framer",
        // Chat / social
        "Slack", "Discord", "Microsoft Teams", "WhatsApp", "Telegram", "Messenger",
        "Signal", "Twitter", "LinkedIn", "Reddit", "Facebook", "Instagram",
        "TikTok", "Pinterest", "Threads", "Mastodon", "Bluesky", "Quora",
        // Commerce
        "Amazon", "eBay", "Etsy", "Shopify", "AliExpress", "Walmart",
        // Media
        "YouTube", "Netflix", "Spotify", "Twitch", "Hulu", "Prime Video",
        "SoundCloud", "Apple Music",
        // AI
        "ChatGPT", "Claude", "Gemini", "Perplexity", "Copilot",
        // Knowledge / writing
        "Medium", "Substack", "Wikipedia",
        // Storage / meetings
        "Dropbox", "Box", "OneDrive", "Zoom", "Webex",
        // Business / support / payments
        "Salesforce", "HubSpot", "Zendesk", "Intercom", "Stripe", "PayPal",
        "Wise", "QuickBooks", "Xero",
        // Travel / local
        "Booking.com", "Airbnb", "Expedia", "Skyscanner", "Kayak",
        "Uber", "Lyft", "DoorDash", "Grubhub",
        // Scheduling / forms / sign
        "Calendly", "Typeform", "SurveyMonkey", "DocuSign",
    ]

    /// Lowercased segment → canonical brand, for O(1) case-insensitive lookup.
    private static let canonicalByLowercased: [String: String] = {
        var map: [String: String] = [:]
        for brand in brands { map[brand.lowercased()] = brand }
        return map
    }()

    public static func from(windowTitle: String?) -> String? {
        guard let raw = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        // Candidate segments: split on the first present separator, plus the whole
        // title (so a bare "Figma" with no separator still resolves to a brand).
        var segments: [String] = [raw]
        for separator in separators where raw.contains(separator) {
            segments = raw
                .components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            break
        }

        // The brand trails far more often than it leads ("Doc - Google Docs"), so
        // check from the end. A segment must EQUAL a known brand — a personal name,
        // a doc title, or a row count never matches, so it never wins.
        for segment in segments.reversed() {
            if let brand = canonicalByLowercased[segment.lowercased()] { return brand }
        }
        return nil
    }
}
