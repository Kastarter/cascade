import Foundation

/// The current-date fact every agent needs but none of the system prompts carried —
/// without it a model cannot tell a PAST date from a future one, resolve "next
/// month" / "in 2 weeks", or know how far to navigate a calendar. (The audited
/// background flights run tried to pick a departure in the CURRENT month, already
/// part-past, instead of navigating forward.) Injected into every agent's
/// environment note. Includes the general navigate-month-FIRST date-picker rule so
/// it holds even when the model doesn't pull a task skill.
public enum AgentDateContext {
    /// The dated guidance line for a given date. Pure (testable) — the live overload
    /// stamps `Date()`. Uses a fixed en_US_POSIX/Gregorian format so the output is
    /// stable regardless of the host locale.
    public static func line(
        for date: Date,
        calendar: Calendar = Calendar(identifier: .gregorian),
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        var cal = calendar
        cal.locale = locale
        cal.timeZone = timeZone
        formatter.calendar = cal
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        let today = formatter.string(from: date)
        return """
        Today's date is \(today). Use it for ALL date reasoning. A date before today is \
        in the PAST and is usually disabled — never try to pick one. To choose a future \
        date in a calendar or date picker, FIRST click the next-month (›) arrow until \
        the calendar's header shows the TARGET month and year, THEN click the day — \
        check the header each step and never click a day while the wrong month is showing.
        """
    }

    /// Live: the guidance for the current moment.
    public static func line() -> String { line(for: Date()) }
}
