import Foundation

public enum Time {
    /// Shared ISO8601DateFormatter with fractional seconds in UTC
    public static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// Shared ISO8601DateFormatter without fractional seconds (still UTC)
    public static let iso8601Basic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// Returns an ISO8601 string (UTC, fractional seconds) for the provided date (defaults to now)
    @discardableResult
    public static func isoString(_ date: Date = Date()) -> String {
        return iso8601.string(from: date)
    }

    /// Parses an ISO8601 string into a Date (supports fractional seconds)
    public static func parseISO(_ string: String) -> Date? {
        if let date = iso8601.date(from: string) {
            return date
        }
        return iso8601Basic.date(from: string)
    }

    /// Parses an optional ISO8601 string into a Date (supports fractional seconds)
    public static func parseISO(_ string: String?) -> Date? {
        guard let string else { return nil }
        return parseISO(string)
    }
}
