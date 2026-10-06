import Foundation

// History (FR-43): a bar's combined estimates through one night day (4 a.m.
// to 4 a.m. Eastern), every 15 minutes, computed on the server from the
// reports as of each moment.
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
    /// The night's usual window, 9 p.m. to 2 a.m. Eastern: rows always cover it.
    public let start: Date
    public let end: Date
    /// Earlier nights with reports at this bar, newest first.
    public let nights: [NightDate]
    /// Every 15 minutes through the night day, never later than now. (Before
    /// 2026-10-05 the server sent every 5 minutes from `start` to `end`.)
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
        points.contains(where: \.hasData)
    }

    /// The night's list (FR-43): one row per quarter hour from 9:00 p.m. to
    /// 1:45 a.m., stretched earlier or later to cover every quarter hour with
    /// reports, so an early game-day crowd shows. Two or more quarter hours in
    /// a row with nothing become one "No reports" stretch. Tonight has only the
    /// quarter hours so far.
    public var rows: [HistoryRow] {
        let quarters = quarterHours
        let lastUsual = end.addingTimeInterval(-Self.quarterHour)
        let from = min(start, quarters.first(where: \.hasData)?.at ?? start)
        let to = max(lastUsual, quarters.last(where: \.hasData)?.at ?? lastUsual)

        var rows: [HistoryRow] = []
        var empty: [HistoryPoint] = []
        func closeStretch() {
            if empty.count == 1 {
                rows.append(.point(empty[0]))
            } else if let first = empty.first, let last = empty.last {
                rows.append(.noReports(from: first.at, to: last.at))
            }
            empty.removeAll()
        }
        for point in quarters where point.at >= from && point.at <= to {
            if point.hasData {
                closeStretch()
                rows.append(.point(point))
            } else {
                empty.append(point)
            }
        }
        closeStretch()
        return rows
    }

    /// The quarter hour with the biggest line, then the longest wait, then the
    /// biggest crowd; the earliest wins a tie. Nil when no row has data.
    public var busiestRow: HistoryPoint? {
        var best: HistoryPoint?
        for row in quarterHours where row.hasData {
            if best.map({ $0.busyness3.lexicographicallyPrecedes(row.busyness3) }) ?? true {
                best = row
            }
        }
        return best
    }

    private static let quarterHour: TimeInterval = 15 * 60

    /// The points on the quarter hour. The server sends only these, but older
    /// servers sent every 5 minutes.
    private var quarterHours: [HistoryPoint] {
        points.filter { point in
            Int(point.at.timeIntervalSince(start).rounded()) % Int(Self.quarterHour) == 0
        }
    }
}

/// One line in a night's list (FR-43).
public enum HistoryRow: Sendable, Hashable, Identifiable {
    /// A quarter hour: its estimate, or "No reports" when it stands alone.
    case point(HistoryPoint)
    /// Quarter hours in a row with nothing, from the first to the last.
    case noReports(from: Date, to: Date)

    public var id: Date {
        switch self {
        case .point(let point): point.at
        case .noReports(let from, _): from
        }
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

    /// True when any signal has a value.
    public var hasData: Bool {
        lineSize != nil || wait != nil || busyness != nil
    }

    /// Line size, then wait, then crowd, for picking the busiest quarter hour.
    fileprivate var busyness3: [Int] {
        [lineSize?.code ?? -1, wait?.code ?? -1, busyness?.code ?? -1]
    }

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

    /// The night a moment belongs to (FR-22): its date in `timeZone`, minus a
    /// day before the night boundary (4 a.m.), so 1 a.m. Sunday is Saturday night.
    public init(nightOf date: Date, timeZone: TimeZone, boundaryHour: Int = 4) {
        self.init(calendarDateOf: date.addingTimeInterval(-Double(boundaryHour) * 3600), timeZone: timeZone)
    }

    /// The calendar date of a moment in `timeZone`.
    public init(calendarDateOf date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Noon on this date in `timeZone`: a safe moment to hand a date picker,
    /// whatever daylight saving does at night.
    public func noon(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
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

    /// One quarter-hour row of History (FR-43): "10–25 in line · 15–30 min wait · Busy".
    public static func historyRow(_ point: HistoryPoint) -> String {
        let parts = [
            point.lineSize.flatMap(historyLineSize),
            point.wait.flatMap(historyWait),
            point.busyness.flatMap(historyBusyness),
        ].compactMap { $0 }
        return parts.isEmpty ? "No reports" : parts.joined(separator: " · ")
    }

    /// "1 person" or "4 people".
    public static func people(_ count: Int) -> String {
        count == 1 ? "1 person" : "\(count) people"
    }
}
