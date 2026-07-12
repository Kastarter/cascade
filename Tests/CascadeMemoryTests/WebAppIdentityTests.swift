import CascadeMemory
import Testing

// These are the user's ACTUAL Chrome window titles from the record — the format is
// "<page> - Google Chrome – <profile>", with Chrome's memory saver sometimes injecting
// "High memory usage - NNN MB". The app brand sits before all that.
@Test
func webAppIdentityNamesTheAppFromRealChromeTitles() {
    #expect(WebAppIdentity.surface(fromWindowTitle: "Mail - Mohanad Bahammam - Outlook - Google Chrome – Mohanad") == "Outlook")
    #expect(WebAppIdentity.surface(fromWindowTitle: "Find Cheap Flights Worldwide & Book Your Ticket - Google Flights - Google Chrome – Mohanad") == "Google Flights")
    #expect(WebAppIdentity.surface(fromWindowTitle: "Messaging | LinkedIn - High memory usage - 830 MB - Google Chrome – Mohanad") == "LinkedIn")
    #expect(WebAppIdentity.surface(fromWindowTitle: "Feed | LinkedIn - High memory usage - 810 MB - Google Chrome – Mohanad") == "LinkedIn")
    #expect(WebAppIdentity.surface(fromWindowTitle: "GitHub - Google Chrome – Mohanad") == "GitHub")
    #expect(WebAppIdentity.surface(fromWindowTitle: "Checking shapes and marks scoring system - Claude - Google Chrome – Mohanad") == "Claude")
}

@Test
func webAppIdentityNeverHarvestsTheProfileNameOrBrowser() {
    // THE BUG: the title ends in "- Google Chrome – Mohanad". We must never return the
    // browser ("Google Chrome") or the profile ("Mohanad") — an unbranded page is nil.
    #expect(WebAppIdentity.surface(fromWindowTitle: "Untitled - Google Chrome – Mohanad") == nil)
    #expect(WebAppIdentity.surface(fromWindowTitle: "Assignment Evaluation - Jayden Saha - Assignment # 1 - Google Chrome – Mohanad") == nil)
    #expect(WebAppIdentity.surface(fromWindowTitle: "Commits · Mohanad139/Cascade - Google Chrome – Mohanad") == nil)
    #expect(WebAppIdentity.surface(fromWindowTitle: "Untitled document - Mohanad") == nil)
}

@Test
func webAppIdentityNamesBrandsWithoutABrowserSuffix() {
    #expect(WebAppIdentity.surface(fromWindowTitle: "Inbox (5) - me@example.com - Gmail") == "Gmail")
    #expect(WebAppIdentity.surface(fromWindowTitle: "Q3 plan - Google Docs") == "Google Docs")
    #expect(WebAppIdentity.surface(fromWindowTitle: "(2) Feed | LinkedIn") == "LinkedIn")
    #expect(WebAppIdentity.surface(fromWindowTitle: "anthropics/claude · Pull Requests · GitHub") == "GitHub")
    #expect(WebAppIdentity.surface(fromWindowTitle: "Figma") == "Figma")
    #expect(WebAppIdentity.surface(fromWindowTitle: "watch later - youtube") == "YouTube")
}

@Test
func webAppIdentityResolvesUnlistedGooglePropertiesToGoogle() {
    #expect(WebAppIdentity.surface(fromWindowTitle: "Search results - Google Chrome – Mohanad") == nil) // "Search results" isn't a Google property
    #expect(WebAppIdentity.surface(fromWindowTitle: "My Account - Google Account - Google Chrome – Mohanad") == "Google Account")
    #expect(WebAppIdentity.surface(fromWindowTitle: "homework help - Google Search") == "Google Search")
}

@Test
func webAppIdentityIsNilForEmptyInput() {
    #expect(WebAppIdentity.from(windowTitle: "") == nil)
    #expect(WebAppIdentity.from(windowTitle: nil) == nil)
    #expect(WebAppIdentity.from(windowTitle: "   ") == nil)
}

@Test
func webAppIdentityFromReturnsOnlyStableDocumentHashes() {
    let first = WebAppIdentity.from(windowTitle: "Mail - Mohanad Bahammam - Outlook - Google Chrome – Mohanad")
    let second = WebAppIdentity.from(windowTitle: "Mail - Mohanad Bahammam - Outlook - Google Chrome – Other Profile")
    let other = WebAppIdentity.from(windowTitle: "Calendar - Outlook - Google Chrome – Mohanad")

    #expect(first != nil)
    #expect(first == second)
    #expect(first != other)
    #expect(first?.count == 24)
}
