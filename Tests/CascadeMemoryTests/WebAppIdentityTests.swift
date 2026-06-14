import CascadeMemory
import Testing

// These are the user's ACTUAL Chrome window titles from the record — the format is
// "<page> - Google Chrome – <profile>", with Chrome's memory saver sometimes injecting
// "High memory usage - NNN MB". The app brand sits before all that.
@Test
func webAppIdentityNamesTheAppFromRealChromeTitles() {
    #expect(WebAppIdentity.from(windowTitle: "Mail - Mohanad Bahammam - Outlook - Google Chrome – Mohanad") == "Outlook")
    #expect(WebAppIdentity.from(windowTitle: "Find Cheap Flights Worldwide & Book Your Ticket - Google Flights - Google Chrome – Mohanad") == "Google Flights")
    #expect(WebAppIdentity.from(windowTitle: "Messaging | LinkedIn - High memory usage - 830 MB - Google Chrome – Mohanad") == "LinkedIn")
    #expect(WebAppIdentity.from(windowTitle: "Feed | LinkedIn - High memory usage - 810 MB - Google Chrome – Mohanad") == "LinkedIn")
    #expect(WebAppIdentity.from(windowTitle: "GitHub - Google Chrome – Mohanad") == "GitHub")
    #expect(WebAppIdentity.from(windowTitle: "Checking shapes and marks scoring system - Claude - Google Chrome – Mohanad") == "Claude")
}

@Test
func webAppIdentityNeverHarvestsTheProfileNameOrBrowser() {
    // THE BUG: the title ends in "- Google Chrome – Mohanad". We must never return the
    // browser ("Google Chrome") or the profile ("Mohanad") — an unbranded page is nil.
    #expect(WebAppIdentity.from(windowTitle: "Untitled - Google Chrome – Mohanad") == nil)
    #expect(WebAppIdentity.from(windowTitle: "Assignment Evaluation - Jayden Saha - Assignment # 1 - Google Chrome – Mohanad") == nil)
    #expect(WebAppIdentity.from(windowTitle: "Commits · Mohanad139/Cascade - Google Chrome – Mohanad") == nil)
    #expect(WebAppIdentity.from(windowTitle: "Untitled document - Mohanad") == nil)
}

@Test
func webAppIdentityNamesBrandsWithoutABrowserSuffix() {
    #expect(WebAppIdentity.from(windowTitle: "Inbox (5) - me@example.com - Gmail") == "Gmail")
    #expect(WebAppIdentity.from(windowTitle: "Q3 plan - Google Docs") == "Google Docs")
    #expect(WebAppIdentity.from(windowTitle: "(2) Feed | LinkedIn") == "LinkedIn")
    #expect(WebAppIdentity.from(windowTitle: "anthropics/claude · Pull Requests · GitHub") == "GitHub")
    #expect(WebAppIdentity.from(windowTitle: "Figma") == "Figma")
    #expect(WebAppIdentity.from(windowTitle: "watch later - youtube") == "YouTube")
}

@Test
func webAppIdentityResolvesUnlistedGooglePropertiesToGoogle() {
    #expect(WebAppIdentity.from(windowTitle: "Search results - Google Chrome – Mohanad") == nil) // "Search results" isn't a Google property
    #expect(WebAppIdentity.from(windowTitle: "My Account - Google Account - Google Chrome – Mohanad") == "Google Account")
    #expect(WebAppIdentity.from(windowTitle: "homework help - Google Search") == "Google Search")
}

@Test
func webAppIdentityIsNilForEmptyInput() {
    #expect(WebAppIdentity.from(windowTitle: "") == nil)
    #expect(WebAppIdentity.from(windowTitle: nil) == nil)
    #expect(WebAppIdentity.from(windowTitle: "   ") == nil)
}
