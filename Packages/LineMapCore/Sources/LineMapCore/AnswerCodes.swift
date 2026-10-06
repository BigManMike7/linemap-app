/// Fixed answer codes (NFR-10). These raw values are stored on the server and
/// must never change meaning. See `supabase/README.md`.
public enum Definitions {
    /// The answer definitions version every report carries. Version 2
    /// (2026-10-06) added line sizes 50–100 and 100+ and stopped offering 50+;
    /// the server accepts both 1 and 2.
    public static let version = 2
}

/// How a question was answered (FR-12). "I can't tell" is stored separately from skipped.
public enum AnswerState: String, Codable, Sendable, Hashable {
    case answered
    case cantTell = "cant_tell"
    case skipped
}

/// Line size: the whole line, from the wait card and Report line size (FR-6,
/// FR-11). Codes aren't in size order, since 50–100 and 100+ came later; use
/// `rank` to compare sizes.
public enum LineSize: Int, Codable, Sendable, Hashable, CaseIterable {
    case nobody = 0
    case oneToTen = 1
    case tenTo25 = 2
    case twentyFiveTo50 = 3
    /// Added in definitions version 2 (2026-10-06).
    case fiftyTo100 = 6
    /// Added in definitions version 2 (2026-10-06).
    case hundredPlus = 7
    /// Offered until definitions version 2; old reports keep showing "50+".
    case fiftyPlus = 4
    /// Not offered since 2026-10-01; the code stays reserved.
    case cantSeeEnd = 5

    /// The line sizes the app offers, smallest first.
    public static let offered: [LineSize] = [
        .nobody, .oneToTen, .tenTo25, .twentyFiveTo50, .fiftyTo100, .hundredPlus,
    ]

    /// Size order for comparing codes: 50+, 50–100, and "Can't see the end"
    /// share a rank, and 100+ is above them. The server's `app.line_size_rank`
    /// matches it.
    public var rank: Int {
        switch self {
        case .nobody: 0
        case .oneToTen: 1
        case .tenTo25: 2
        case .twentyFiveTo50: 3
        case .fiftyPlus, .fiftyTo100, .cantSeeEnd: 4
        case .hundredPlus: 5
        }
    }

    /// The rank of a stored code, or -1 for an unknown one.
    public static func rank(code: Int) -> Int {
        LineSize(rawValue: code)?.rank ?? -1
    }
}

/// Busyness, relative to the bar's size. Not asked or shown since 2026-10-06
/// (Max's call); the codes stay reserved and never change meaning.
public enum Busyness: Int, Codable, Sendable, Hashable, CaseIterable {
    case quiet = 1
    case comfortable = 2
    case busy = 3
    case packed = 4
}

/// How long it took to get in, for people who didn't time their wait (FR-11).
public enum RecalledWait: Int, Codable, Sendable, Hashable, CaseIterable {
    case under5 = 1
    case fiveTo15 = 2
    case fifteenTo30 = 3
    case thirtyTo60 = 4
    case sixtyPlus = 5
}

/// Adjust time moves the session start back by a whole number of minutes (FR-7).
/// It's a plain number of minutes, not a code.
public enum StartOffset {
    /// The wheel offers every minute from 0 (just started) to the max.
    public static let choices = 0...maxMinutes
    /// The server accepts 0 to 90 (FR-7).
    public static let maxMinutes = 90
}

/// One answer to an optional question: a code, "I can't tell", or skipped (FR-12).
public enum Answer<Value: RawRepresentable & Sendable & Hashable>: Sendable, Hashable
where Value.RawValue == Int {
    case answered(Value)
    case cantTell
    case skipped

    public var state: AnswerState {
        switch self {
        case .answered: .answered
        case .cantTell: .cantTell
        case .skipped: .skipped
        }
    }

    /// The stored code, present only when answered.
    public var code: Int? {
        if case .answered(let value) = self { value.rawValue } else { nil }
    }
}
