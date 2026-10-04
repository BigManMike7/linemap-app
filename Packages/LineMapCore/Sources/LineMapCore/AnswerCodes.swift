/// Fixed answer codes (NFR-10). These raw values are stored on the server and
/// must never change meaning. See `supabase/README.md`.
public enum Definitions {
    /// The answer definitions version every report carries.
    public static let version = 1
}

/// How a question was answered (FR-12). "I can't tell" is stored separately from skipped.
public enum AnswerState: String, Codable, Sendable, Hashable {
    case answered
    case cantTell = "cant_tell"
    case skipped
}

/// Line size, asked after Start line timer and in line-size updates (FR-6).
public enum LineSize: Int, Codable, Sendable, Hashable, CaseIterable {
    case nobody = 0
    case oneToTen = 1
    case tenTo25 = 2
    case twentyFiveTo50 = 3
    case fiftyPlus = 4
    case cantSeeEnd = 5
}

/// Busyness, relative to the bar's size (FR-11).
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
    /// The quick choices, shown as "~5 min" and "~10 min".
    public static let presets = [5, 10]
    /// The wheel under More… offers every minute after the presets, up to the max.
    public static let custom = 11...maxMinutes
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
