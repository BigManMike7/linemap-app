import Foundation

// Server responses. Field names follow `supabase/README.md`; decode with
// `JSONDecoder.lineMap`, which converts snake_case keys and server dates.

/// A bar and its door pin (FR-28).
public struct Bar: Codable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let name: String
    public let address: String
    public let doorLat: Double
    public let doorLon: Double
    public let sizeClass: String
    public let displayOrder: Int

    public init(id: Int64, name: String, address: String, doorLat: Double, doorLon: Double,
                sizeClass: String = "medium", displayOrder: Int) {
        self.id = id
        self.name = name
        self.address = address
        self.doorLat = doorLat
        self.doorLon = doorLon
        self.sizeClass = sizeClass
        self.displayOrder = displayOrder
    }
}

/// Every bar's estimate at one moment (FR-17 to FR-21).
public struct Estimates: Codable, Sendable, Hashable {
    public let logicVersion: Int
    public let generatedAt: Date
    public let windowState: WindowState
    public let bars: [BarEstimate]

    public init(logicVersion: Int, generatedAt: Date, windowState: WindowState, bars: [BarEstimate]) {
        self.logicVersion = logicVersion
        self.generatedAt = generatedAt
        self.windowState = windowState
        self.bars = bars
    }

    public func estimate(for barID: Bar.ID) -> BarEstimate? {
        bars.first { $0.barId == barID }
    }
}

/// Where the night was in the old active window. Always `live` since logic
/// version 3 (2026-10-06), which removed the window; kept for decoding.
public enum WindowState: String, Codable, Sendable, Hashable {
    case live
    case closed
    case outsideHours = "outside_hours"
}

/// What a bar should show.
public enum Display: String, Codable, Sendable, Hashable {
    /// Show the signals; stale ones grayed out.
    case estimate
    /// Nothing within 60 minutes, at any time of day ("No live reports").
    case notEnoughData = "not_enough_data"
    /// 2-4 a.m. after an active night. Not sent since logic version 3.
    case closed
    /// Sent only by servers before logic version 2 (2026-10-06); shown like
    /// `notEnoughData`. The server now shows recent reports at any hour.
    case outsideHours = "outside_hours"
}

/// Fresh (30 minutes or less), stale (30 to 60, grayed out), or none (FR-17).
public enum Freshness: String, Codable, Sendable, Hashable {
    case fresh
    case stale
    case none
}

public struct BarEstimate: Codable, Sendable, Hashable, Identifiable {
    public let barId: Int64
    public let display: Display
    public let freshness: Freshness
    /// Distinct people behind the bar's reports (FR-18).
    public let people: Int
    public let latestAt: Date?
    public let lineSize: Signal?
    public let wait: Signal?
    public let busyness: Signal?

    public var id: Int64 { barId }

    public init(barId: Int64, display: Display, freshness: Freshness, people: Int, latestAt: Date?,
                lineSize: Signal? = nil, wait: Signal? = nil, busyness: Signal? = nil) {
        self.barId = barId
        self.display = display
        self.freshness = freshness
        self.people = people
        self.latestAt = latestAt
        self.lineSize = lineSize
        self.wait = wait
        self.busyness = busyness
    }
}

/// One shown value: line size, wait, or busyness (FR-19).
public struct Signal: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable, Hashable {
        /// A timed wait from a wait session; `minutes` is set and `at` is when the person got in.
        case measured
        /// An answered range; only `code` is set.
        case reported
    }

    public enum Rule: String, Codable, Sendable, Hashable {
        case newest
        case majority
    }

    /// The answer code: `LineSize`, `Busyness`, or `RecalledWait` (also used for measured waits).
    public let code: Int
    public let minutes: Int?
    public let source: Source
    public let at: Date
    public let freshness: Freshness
    public let rule: Rule

    public init(code: Int, minutes: Int? = nil, source: Source = .reported, at: Date,
                freshness: Freshness = .fresh, rule: Rule = .newest) {
        self.code = code
        self.minutes = minutes
        self.source = source
        self.at = at
        self.freshness = freshness
        self.rule = rule
    }
}

// MARK: - JSON coding

extension JSONDecoder {
    /// Decodes server JSON: snake_case keys and Postgres timestamps.
    public static var lineMap: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ServerDate.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Not a server timestamp: \(text)")
            }
            return date
        }
        return decoder
    }
}

extension JSONEncoder {
    /// Encodes the app's own files (cache, queue) with the same date format the server reads.
    public static var lineMap: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ServerDate.format(date))
        }
        return encoder
    }
}

/// ISO 8601 timestamps as Postgres writes them, e.g. `2026-10-01T20:32:27.127063+00:00`.
public enum ServerDate {
    /// Parses with or without fractional seconds. Fractions beyond milliseconds are dropped,
    /// because `ISO8601DateFormatter` does not reliably read six digits.
    public static func parse(_ text: String) -> Date? {
        var trimmed = text
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            let fraction = digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)
            trimmed = String(text[..<dot]) + "." + fraction + text[digits.endIndex...]
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Formats in UTC with milliseconds, e.g. `2026-10-01T20:32:27.127Z`.
    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
