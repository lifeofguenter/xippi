import Foundation

/// Every stored timestamp is UTC. GRDB writes `Date` as UTC text in this format;
/// the helper renders the same text so tests and tools can compare against it.
public enum UTC {
    public static func databaseText(for date: Date) -> String {
        date.formatted(
            Date.VerbatimFormatStyle(
                format:
                    "\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: .gmt,
                calendar: Calendar(identifier: .gregorian)))
    }
}
