import Foundation

/// XEP-0082 date and time: read with any offset, written in UTC.
///
/// Reads the DateTime profile (`CCYY-MM-DDThh:mm:ss[.sss]TZD`, where TZD is `Z` or
/// `+hh:mm`/`-hh:mm`) and the Date profile (`CCYY-MM-DD`, midnight UTC). Anything else,
/// including a time without a zone, is nil: a time whose zone is unknown cannot be stored as UTC.
public enum XMPPDateTime {
    public static func parse(_ text: String) -> Date? {
        var reader = Reader(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let year = reader.digits(4), reader.take("-"), let month = reader.digits(2),
            reader.take("-"), let day = reader.digits(2),
            (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day)
        else { return nil }
        let midnight = daysSinceEpoch(year: year, month: month, day: day) * 86_400
        if reader.atEnd { return Date(timeIntervalSince1970: TimeInterval(midnight)) }

        guard reader.take("T"), let hour = reader.digits(2), reader.take(":"),
            let minute = reader.digits(2), reader.take(":"), let second = reader.digits(2),
            hour < 24, minute < 60, second <= 60
        else { return nil }
        var fraction = ""
        if reader.take(".") {
            fraction = reader.digitRun()
            guard !fraction.isEmpty else { return nil }
        }
        var offset = 0
        if !reader.take("Z") {
            let sign: Int
            if reader.take("+") {
                sign = 1
            } else if reader.take("-") {
                sign = -1
            } else {
                return nil
            }
            guard let hours = reader.digits(2), reader.take(":"), let minutes = reader.digits(2),
                hours < 24, minutes < 60
            else { return nil }
            offset = sign * (hours * 3600 + minutes * 60)
        }
        guard reader.atEnd else { return nil }

        let whole = midnight + hour * 3600 + minute * 60 + second - offset
        // Nanoseconds are as fine as a Date keeps; read as one decimal so it rounds once.
        let digits = String(fraction.prefix(9))
        if digits.isEmpty { return Date(timeIntervalSince1970: TimeInterval(whole)) }
        if whole >= 0, let value = TimeInterval("\(whole).\(digits)") {
            return Date(timeIntervalSince1970: value)
        }
        guard let part = TimeInterval("0.\(digits)") else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(whole) + part)
    }

    /// `CCYY-MM-DDThh:mm:ssZ`, with milliseconds when the date has a fraction of a second.
    public static func string(from date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        if seconds == seconds.rounded(.down) { return date.formatted(.iso8601) }
        return date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days from 1970-01-01 to a date of the proleptic Gregorian calendar.
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Reads ASCII from the front of a string; never past its end.
    private struct Reader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ text: String) { bytes = Array(text.utf8) }

        var atEnd: Bool { index == bytes.count }

        mutating func take(_ character: Unicode.Scalar) -> Bool {
            guard index < bytes.count, bytes[index] == UInt8(ascii: character) else { return false }
            index += 1
            return true
        }

        /// Exactly `count` ASCII digits as a number.
        mutating func digits(_ count: Int) -> Int? {
            guard bytes.count - index >= count else { return nil }
            var value = 0
            for byte in bytes[index..<index + count] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            index += count
            return value
        }

        /// The ASCII digits from here on, as text.
        mutating func digitRun() -> String {
            let start = index
            while index < bytes.count,
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index])
            {
                index += 1
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}

/// XEP-0203 delayed delivery.
///
/// The server or room that holds a stanza back adds a `<delay/>` naming itself (offline storage:
/// the server's domain; room history: the room's bare JID). Anything else in the stanza was
/// written by the sender, who can name any `from` and any time (XEP-0203 section 6). So a
/// stanza's delays are read with their source, and the caller takes a stamp only from an entity
/// it trusts to deliver it; otherwise the time of arrival counts.
public enum Delay {
    public static let namespace = "urn:xmpp:delay"

    /// One `<delay/>`: its stamp and the entity that says it added it.
    public struct Stamp: Sendable, Hashable {
        public var stamp: Date
        /// nil when the delay names no source, or one that is not a valid JID.
        public var from: JID?

        public init(stamp: Date, from: JID? = nil) {
            self.stamp = stamp
            self.from = from
        }
    }

    /// Every `<delay/>` child of `element` with a valid stamp, in stanza order.
    public static func stamps(in element: Element) -> [Stamp] {
        element.children("delay", namespace: namespace).compactMap { delay in
            delay[attribute: "stamp"].flatMap(XMPPDateTime.parse).map {
                Stamp(stamp: $0, from: delay[attribute: "from"].flatMap { try? JID($0) })
            }
        }
    }

    /// The stamp the delivering entity added: the last one whose `from` is in `trusted`. A
    /// delivering server or room appends its delay after whatever the sender wrote, including a
    /// delay that names the room. Nil when no trusted entity stamped the stanza.
    public static func stamp(in stamps: [Stamp], trusting trusted: Set<JID>) -> Date? {
        stamps.last { $0.from.map(trusted.contains) ?? false }?.stamp
    }

    /// The stamp of the first `<delay/>` child of `element` that carries a valid one. Only for a
    /// wrapper that the forwarding entity alone writes (the `<forwarded/>` of carbons and
    /// archive results), never for a stanza's own delays, which the sender can write too.
    public static func stamp(in element: Element) -> Date? {
        stamps(in: element).first?.stamp
    }

    /// A `<delay/>` stamped with `date`, written in UTC.
    public static func element(stamp date: Date, from: JID? = nil) -> Element {
        var delay = Element(
            "delay", namespace: namespace, attributes: ["stamp": XMPPDateTime.string(from: date)])
        delay[attribute: "from"] = from?.description
        return delay
    }
}
