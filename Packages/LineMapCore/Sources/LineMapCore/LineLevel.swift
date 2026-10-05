import Foundation

/// How hard a bar is to get into, for coloring pins, Bars cards, and history
/// rows at a glance (FR-2, FR-43, FR-45). Only the line and wait count; the
/// crowd never does, since a packed bar can be the one people want (Max,
/// 2026-10-05). Cutoffs live in the app, not `config`, because they only
/// color what's shown and never change an estimate.
public enum LineLevel: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// A wait under 10 minutes, or 0 or 1–10 in line.
    case short
    /// A wait of 10 to 25 minutes, or 10–25 in line.
    case some
    /// A wait of 25 minutes or more, or 25 or more in line.
    case long

    public static func < (lhs: LineLevel, rhs: LineLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// "Short line", "Some line", or "Long line".
    public var title: String {
        switch self {
        case .short: "Short line"
        case .some: "Some line"
        case .long: "Long line"
        }
    }

    /// A measured wait in minutes.
    public init(waitMinutes minutes: Int) {
        switch minutes {
        case ..<10: self = .short
        case ..<25: self = .some
        default: self = .long
        }
    }

    /// A reported wait range (`RecalledWait` code), leveled by its midpoint:
    /// under 5 is short, 5–15 and 15–30 are some, 30–60 and 60+ are long.
    public init?(waitCode code: Int) {
        guard let range = RecalledWait(rawValue: code) else { return nil }
        switch range {
        case .under5: self = .short
        case .fiveTo15, .fifteenTo30: self = .some
        case .thirtyTo60, .sixtyPlus: self = .long
        }
    }

    /// A line size (`LineSize` code). "Can't see the end", from older builds, is long.
    public init?(lineSizeCode code: Int) {
        guard let size = LineSize(rawValue: code) else { return nil }
        switch size {
        case .nobody, .oneToTen: self = .short
        case .tenTo25: self = .some
        case .twentyFiveTo50, .fiftyPlus, .cantSeeEnd: self = .long
        }
    }

    /// A wait: its measured minutes when there are some, else its range.
    init?(waitCode code: Int, minutes: Int?) {
        if let minutes {
            self.init(waitMinutes: minutes)
        } else {
            self.init(waitCode: code)
        }
    }
}

/// A bar's line level and whether it comes from reports 30–60 minutes old
/// (FR-17), which show faded.
public struct LineStatus: Sendable, Hashable {
    public let level: LineLevel
    public let isOlder: Bool

    public init(level: LineLevel, isOlder: Bool) {
        self.level = level
        self.isOlder = isOlder
    }

    /// The level of what the pin label shows (FR-2): the wait, else the line
    /// size. Nil for no data, closed, and outside hours.
    public init?(estimate: BarEstimate?) {
        guard let estimate, estimate.display == .estimate else { return nil }
        if let wait = estimate.wait,
           let level = LineLevel(waitCode: wait.code, minutes: wait.source == .measured ? wait.minutes : nil) {
            self.init(level: level, isOlder: wait.freshness == .stale)
        } else if let line = estimate.lineSize, let level = LineLevel(lineSizeCode: line.code) {
            self.init(level: level, isOlder: line.freshness == .stale)
        } else {
            return nil
        }
    }

    /// The level of a past moment (FR-43), by the same rule: the wait, else
    /// the line size. Nil when neither was reported.
    public init?(point: HistoryPoint) {
        if let wait = point.wait, let level = LineLevel(waitCode: wait.code, minutes: wait.minutes) {
            self.init(level: level, isOlder: wait.freshness == .stale)
        } else if let line = point.lineSize, let level = LineLevel(lineSizeCode: line.code) {
            self.init(level: level, isOlder: line.freshness == .stale)
        } else {
            return nil
        }
    }

    /// "Short line", or "Short line, older reports" for VoiceOver.
    public var spokenText: String {
        isOlder ? "\(level.title), older reports" : level.title
    }
}
