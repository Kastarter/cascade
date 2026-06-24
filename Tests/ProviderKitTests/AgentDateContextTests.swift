import Foundation
import Testing

@testable import ProviderKit

/// Pins the current-date line every agent now receives — the fact missing when the
/// background agent tried to pick a departure in the current (part-past) month
/// instead of navigating forward. Formatting is fixed (en_US_POSIX) so it reads the
/// same on any host; the navigate-month-first rule must be present.
struct AgentDateContextTests {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test func statesTodayInAStableFormat() {
        let line = AgentDateContext.line(for: date(2026, 6, 24), timeZone: TimeZone(identifier: "UTC")!)
        #expect(line.contains("June 24, 2026"))
        #expect(line.hasPrefix("Today's date is "))
    }

    @Test func carriesThePastAndNavigateMonthRule() {
        let line = AgentDateContext.line(for: date(2026, 1, 1), timeZone: TimeZone(identifier: "UTC")!)
        #expect(line.contains("January 1, 2026"))
        #expect(line.contains("PAST"))                 // never pick a past date
        #expect(line.lowercased().contains("next-month"))  // navigate forward first
    }
}
