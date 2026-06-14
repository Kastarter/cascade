import CascadeMemory
import Testing

@Test
func webAppIdentityNamesAKnownBrandSegment() {
    #expect(WebAppIdentity.from(windowTitle: "Inbox (5) - me@example.com - Gmail") == "Gmail")
    #expect(WebAppIdentity.from(windowTitle: "Q3 plan - Google Docs") == "Google Docs")
    #expect(WebAppIdentity.from(windowTitle: "(2) Feed | LinkedIn") == "LinkedIn")
    #expect(WebAppIdentity.from(windowTitle: "anthropics/claude · Pull Requests · GitHub") == "GitHub")
    #expect(WebAppIdentity.from(windowTitle: "Project board – Notion") == "Notion")
    // Brand-only title, no separator, still resolves.
    #expect(WebAppIdentity.from(windowTitle: "Figma") == "Figma")
    // Case-insensitive, and tolerant of padded separators.
    #expect(WebAppIdentity.from(windowTitle: "watch later - youtube") == "YouTube")
    #expect(WebAppIdentity.from(windowTitle: "Doc  -  Google Docs  ") == "Google Docs")
}

@Test
func webAppIdentityRefusesToInventANameFromTheTail() {
    // THE BUG THIS FIXES: Google signs pages with the account holder's name, so the old
    // "grab the last segment" logic harvested the user's OWN NAME as if it were an app.
    // Now an unknown trailing segment matches no brand → nil → keep the browser name.
    #expect(WebAppIdentity.from(windowTitle: "Untitled document - Mohanad") == nil)
    #expect(WebAppIdentity.from(windowTitle: "Some random page title with no brand") == nil)
    #expect(WebAppIdentity.from(windowTitle: "Meeting notes - Jane Smith") == nil)
    // A long content tail is no longer mistaken for an app name.
    #expect(WebAppIdentity.from(windowTitle: "x - " + String(repeating: "a", count: 80)) == nil)
    // Substrings of a longer word must NOT match ("Box" inside "Box office").
    #expect(WebAppIdentity.from(windowTitle: "2024 Box office results - IMDb") == nil)
}

@Test
func webAppIdentityNamesTheRealAppEvenWhenTheUserNameAlsoTrails() {
    // If the user's name is a segment BUT the brand is also a segment, the brand wins.
    #expect(WebAppIdentity.from(windowTitle: "Inbox - Mohanad - Gmail") == "Gmail")
}

@Test
func webAppIdentityIsNilForEmptyInput() {
    #expect(WebAppIdentity.from(windowTitle: "") == nil)
    #expect(WebAppIdentity.from(windowTitle: nil) == nil)
    #expect(WebAppIdentity.from(windowTitle: "   ") == nil)
}
