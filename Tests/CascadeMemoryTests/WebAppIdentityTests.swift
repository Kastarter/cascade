import CascadeMemory
import Testing

@Test
func webAppIdentityExtractsTheBrandLast() {
    #expect(WebAppIdentity.from(windowTitle: "Inbox (5) - me@example.com - Gmail") == "Gmail")
    #expect(WebAppIdentity.from(windowTitle: "Q3 plan - Google Docs") == "Google Docs")
    #expect(WebAppIdentity.from(windowTitle: "(2) Feed | LinkedIn") == "LinkedIn")
    #expect(WebAppIdentity.from(windowTitle: "anthropics/claude · Pull Requests · GitHub") == "GitHub")
    #expect(WebAppIdentity.from(windowTitle: "Project board – Notion") == "Notion")
}

@Test
func webAppIdentityIsNilWithoutASeparator() {
    // No separator → can't name the web app reliably → keep the browser's own name.
    #expect(WebAppIdentity.from(windowTitle: "Figma") == nil)
    #expect(WebAppIdentity.from(windowTitle: "") == nil)
    #expect(WebAppIdentity.from(windowTitle: nil) == nil)
    #expect(WebAppIdentity.from(windowTitle: "   ") == nil)
}

@Test
func webAppIdentityTrimsAndCaps() {
    #expect(WebAppIdentity.from(windowTitle: "Doc  -  Google Docs  ") == "Google Docs")
    // A long content tail is capped so it can't masquerade cleanly as an app name.
    let long = "x - " + String(repeating: "a", count: 80)
    #expect((WebAppIdentity.from(windowTitle: long)?.count ?? 99) <= 40)
}
