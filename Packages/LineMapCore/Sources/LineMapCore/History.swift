import Foundation

// History & details (FR-43): a bar's combined estimates through one night,
// every 5 minutes, computed on the server from the reports as of each moment.
// Field names follow `bar_history` in `supabase/README.md`; decode with
// `JSONDecoder.lineMap`.

/// One night of a bar's history.
public struct BarHistory: Codable, Sendable, Hashable {
    public let logicVersion: Int
    public let barId: Int64
    /// The night shown.
    public let night: NightDate
    /// Tonight on the server, which runs until 4 a.m. Eastern (FR-22).
    public let tonight: NightDate
    /// The chart's range: the night's usual window, 9 p.m. to 2 a.m. Eastern.
    public let start: Date
    public let end: Date
    /// Earlier nights with reports at this bar, newest first.
    public let nights: [NightDate]
    /// Every 5 minutes from `start`, never later than now.
    public let points: [HistoryPoint]

    public init(logicVersion: Int, barId: Int64, night: NightDate, tonight: NightDate,
                start: Date, end: Date, nights: [NightDate], points: [HistoryPoint]) {
        self.logicVersion = logicVersion
        self.barId = barId
        self.night = night
        self.tonight = tonight
        self.start = start
        self.end = end
        self.nights = nights
        self.points = points
    }

    /// True when no point in the night has anything to show.
    public var hasData: Bool {
        points.contains { $0.lineSize != nil || $0.wait != nil || $0.busyness != nil }
    }

    /// The nights the picker offers (FR-43): Tonight and Last night always,
    /// then every earlier night with reports, newest first, without repeats.
    public var pickerNights: [NightDate] {
        var seen: Set<NightDate> = []
        return ([tonight, tonight.adding(days: -1), night] + nights)
            .sorted(by: >)
            .filter { $0 <= tonight && seen.insert($0).inserted }
    }

    /// The newest point with something to show, for the readout before any drag.
    public var latestPointWithData: HistoryPoint? {
        points.last { $0.lineSize != nil || $0.wait != nil || $0.busyness != nil }
    }

    /// The point at or just before a time, for the drag readout.
    public func point(at date: Date) -> HistoryPoint? {
        points.last { $0.at <= date } ?? points.first
    }
}

/// The combined estimate at one moment (FR-43). Never an individual report.
public struct HistoryPoint: Codable, Sendable, Hashable, Identifiable {
    public let at: Date
    /// Distinct people behind the estimate (FR-18); 0 when nothing is within 60 minutes.
    public let people: Int
    public let lineSize: HistorySignal?
    public let wait: HistorySignal?
    public let busyness: HistorySignal?

    public var id: Date { at }

    public init(at: Date, people: Int, lineSize: HistorySignal? = nil,
                wait: HistorySignal? = nil, busyness: HistorySignal? = nil) {
        self.at = at
        self.people = people
        self.lineSize = lineSize
        self.wait = wait
        self.busyness = busyness
    }
}

/// One signal's value at a moment: an answer code, the measured minutes for a
/// timed wait, and whether it was fresh or grayed out (FR-17).
public struct HistorySignal: Codable, Sendable, Hashable {
    public let code: Int
    public let minutes: Int?
    public let freshness: Freshness

    public init(code: Int, minutes: Int? = nil, freshness: Freshness = .fresh) {
        self.code = code
        self.minutes = minutes
        self.freshness = freshness
    }
}

/// A night's date, such as Saturday night for 1 a.m. Sunday (FR-22). Sent as
/// "YYYY-MM-DD". Plain calendar math, so the phone's time zone never shifts it.
public struct NightDate: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses "2026-10-02".
    public init?(_ text: String) {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = NightDate(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a date: \(text)")
        }
        self = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// "2026-10-02"
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: NightDate, rhs: NightDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public func adding(days: Int) -> NightDate {
        let calendar = Self.calendar
        guard let date = calendar.date(from: components),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return self }
        let parts = calendar.dateComponents([.year, .month, .day], from: moved)
        return NightDate(year: parts.year ?? year, month: parts.month ?? month, day: parts.day ?? day)
    }

    /// 1 = Sunday … 7 = Saturday.
    public var weekday: Int {
        guard let date = Self.calendar.date(from: components) else { return 1 }
        return Self.calendar.component(.weekday, from: date)
    }

    /// "Tonight", "Last night", or "Thu, Oct 2".
    public func label(tonight: NightDate) -> String {
        if self == tonight { return "Tonight" }
        if self == tonight.adding(days: -1) { return "Last night" }
        return "\(Self.shortWeekdays[weekday - 1]), \(Self.shortMonths[month - 1]) \(day)"
    }

    /// "Thursday"
    public var weekdayName: String {
        Self.weekdays[weekday - 1]
    }

    private var components: DateComponents {
        DateComponents(year: year, month: month, day: day, hour: 12)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let shortWeekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let shortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}

extension Labels {
    /// Line size in the history readout: "No line", "10–25 in line" (FR-43).
    public static func historyLineSize(_ signal: HistorySignal) -> String? {
        switch LineSize(rawValue: signal.code) {
        case .nobody: "No line"
        case .cantSeeEnd: "Long line"
        case let size?: "\(option(size)) in line"
        case nil: nil
        }
    }

    /// A wait in the history readout: "32 min" when timed, else the range "15–30 min".
    public static func historyWait(_ signal: HistorySignal) -> String? {
        if let minutes = signal.minutes { return "\(minutes) min wait" }
        return RecalledWait(rawValue: signal.code).map { "\(option($0)) wait" }
    }

    /// Busyness in the history readout: "Busy".
    public static func historyBusyness(_ signal: HistorySignal) -> String? {
        Busyness(rawValue: signal.code).map { option($0) }
    }

    /// "1 person" or "4 people".
    public static func people(_ count: Int) -> String {
        count == 1 ? "1 person" : "\(count) people"
    }
}
