import Foundation

/// Web-specific playbooks the background sandbox agent pulls via `use_skill` — the
/// analog of the cursor agent's app skills, but written for WEBSITES (real URLs, the
/// WebHarness DOM tools), since the native-app skills would mislead inside a browser.
/// Self-contained in SandboxKit (no AppSkillRegistry dependency); served as the
/// agent's `skillProvider` + `skillIndex`.
public enum WebSkills {
    private struct Skill {
        let name: String
        let useWhen: String
        let playbook: String
    }

    private static let skills: [Skill] = [
        Skill(
            name: "webmail",
            useWhen: "reading, sending, replying to, or searching email on a webmail site (Gmail, Outlook, etc.)",
            playbook: """
            WEBMAIL (Gmail = mail.google.com, Outlook = outlook.live.com):
            - Not signed in / a login wall? Reply exactly: NEEDS_LOGIN <site> — never guess credentials.
            - Compose: click_text "Compose" (Gmail) or "New mail" (Outlook); fill_field "To"/"Recipients",
              fill_field "Subject", fill_field "Body"/"Message"; then click_text "Send". Confirm with
              read_page that the draft shows your text before sending.
            - Reply: open the message (click_text its subject/sender), then click_text "Reply" (or "Reply all"),
              fill_field the body, click_text "Send".
            - Search: fill_field the search box (placeholder "Search mail") with the query, press Enter.
            - Read content with read_page, not the screenshot. Report concrete facts: sender, subject, date,
              and any number/link the task asked for.
            - NEVER delete, archive, or send to many recipients unless the task explicitly says so.
            """
        ),
        Skill(
            name: "web-research",
            useWhen: "finding facts, prices, availability, or details on the real web (not how-to articles)",
            playbook: """
            WEB RESEARCH:
            - Go to the REAL source for the task (the airline, the store, the official site, the docs) — NOT
              "how to" articles, NOT ChatGPT/AI assistants. Use open_url for a known site; otherwise start
              from a search and click_text the most authoritative result.
            - Read with read_page (instant, exact) instead of squinting at the screenshot. list_interactives
              to find the right link/control, then click_text it by its visible label.
            - Follow the trail: search → result → detail page. Re-read with read_page after each navigation.
            - Report the CONCRETE answer with its evidence: the price + currency + date, the name, the
              confirmation/flight number, the URL you found it on. A vague summary is a failure.
            - If a fact needs an account you don't have, reply NEEDS_LOGIN <site> rather than inventing it.
            """
        ),
        Skill(
            name: "web-docs",
            useWhen: "creating or editing a document, spreadsheet, or note on a web app (Google Docs/Sheets, Notion)",
            playbook: """
            WEB DOCS (Google Docs = docs.google.com, Sheets = sheets.google.com, Notion = notion.so):
            - Login wall? NEEDS_LOGIN <site>.
            - New doc: open_url the site's "new" entry (docs.google.com/document/create,
              sheets.google.com/create) or click_text "Blank"/"New". It autosaves — there is no Save button.
            - Type the title into the title field (fill_field "title"/"Untitled"), then the body. For a sheet,
              click_text or click the target cell, then type; the value commits on Enter/Tab.
            - To read existing content, read_page — don't rely on the screenshot for text.
            - Report what you created/changed and its URL (read_page shows the URL) so a later step can reuse it.
            """
        ),
        Skill(
            name: "web-forms",
            useWhen: "filling out a form, booking, or anything heading toward a submit/checkout",
            playbook: """
            WEB FORMS & CHECKOUT:
            - list_interactives to see every field + button before acting. fill_field each input BY ITS LABEL
              (placeholder / visible label / name) — don't click pixel coordinates.
            - After filling, read_page to confirm the values landed before moving on.
            - NEVER invent or enter payment card numbers, passwords, SSNs, or personal data you weren't given.
            - STOP before any IRREVERSIBLE or costly action — placing an order, paying, confirming a booking,
              deleting. Get to the final review step, then report exactly what remains ("ready to place the
              $X order — confirm and I'll click Buy") instead of clicking it yourself, unless the task
              explicitly authorized the purchase.
            - Login wall mid-form: NEEDS_LOGIN <site>.
            """
        ),
        Skill(
            name: "web-calendar",
            useWhen: "checking, creating, or editing calendar events on a web calendar (Google Calendar, etc.)",
            playbook: """
            WEB CALENDAR (Google = calendar.google.com):
            - Login wall? NEEDS_LOGIN <site>.
            - Check the schedule: read_page to read the visible events; navigate with click_text "Today"/
              "Next"/the date as needed.
            - New event: click_text "Create" (or the "+"), then fill_field the title, fill_field the date/time
              fields (or click the slot first), then click_text "Save". Confirm with read_page that the event
              shows before declaring done.
            - Report the event's title, date, and time back.
            """
        ),
    ]

    /// The one-line-per-skill catalogue for `ComputerUseAgent(begin: skillIndex:)`.
    public static func index() -> String {
        let lines = skills.map { "- \($0.name): \($0.useWhen)" }
        return """
        Skills available through your use_skill tool — proven playbooks for common web tasks. \
        When one matches what you're about to do, call use_skill with its name FIRST and follow it:
        \(lines.joined(separator: "\n"))
        """
    }

    /// The full playbook for one skill — the agent's `skillProvider`.
    public static func content(named name: String) -> String? {
        skills.first { $0.name == name }?.playbook
    }

    public static var names: Set<String> { Set(skills.map(\.name)) }
}
