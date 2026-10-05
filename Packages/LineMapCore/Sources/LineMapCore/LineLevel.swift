import Foundation

/// How hard a bar is to get into, for coloring pins, Bars cards, and history
/// rows at a glance (FR-2, FR-43, FR-45). Only the line and wait count; the
/// crowd never does, since a packed bar can be the one people want (Max,
/// 2026-10-05). Cutoffs live in the app, not `config`, because they only
/// color what's shown and never change an estimate.
public enum LineLevel: Int, Sendable, Hashable, CaseIterable {
    /// A wait under 10 minutes, or 0 or 1–10 in line.
    case short
    /// A wait of 10 to 25 minutes, or 10–25 in line.
    case some
    /// A wait of 25 minutes or more, or 25 or more in line.
    case long
    /// The wait and the line size contradict each other: one is short and the
    /// other long, such as a 0-minute timer next to 50+ in line. The app
    /// doesn't pick one; the bar sheet shows both (Max, 2026-10-05).
    case uncertain

    /// "Short line", "Some line", "Long line", or "Uncertain".
    public var title: String {
        switch self {
        case .short: "Short line"
        case .some: "Some line"
        case .long: "Long line"
        case .uncertain: "Uncertain"
        }
    }

    /// The level of a wait and a line size together: uncertain when one is
    /// short and the other long, else the wait's level, else the line size's.
    public static func combining(wait: LineLevel?, lineSize: LineLevel?) -> LineLevel? {
        if let wait, let lineSize, Set([wait, lineSize]) == [.short, .long] {
            return .uncertain
        }
        return wait ?? lineSize
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

    /// A bar's level now (FR-2): the wait, else the line size, or uncertain
    /// when they contradict. Nil for no data, closed, and outside hours.
    public init?(estimate: BarEstimate?) {
        guard let estimate, estimate.display == .estimate else { return nil }
        let wait = estimate.wait.flatMap { signal in
            LineLevel(waitCode: signal.code, minutes: signal.source == .measured ? signal.minutes : nil)
                .map { (level: $0, isOlder: signal.freshness == .stale) }
        }
        let line = estimate.lineSize.flatMap { signal in
            LineLevel(lineSizeCode: signal.code).map { (level: $0, isOlder: signal.freshness == .stale) }
        }
        self.init(wait: wait, line: line)
    }

    /// The level of a past moment (FR-43), by the same rule. Nil when neither
    /// the wait nor the line size was reported.
    public init?(point: HistoryPoint) {
        let wait = point.wait.flatMap { signal in
            LineLevel(waitCode: signal.code, minutes: signal.minutes).map { (level: $0, isOlder: signal.freshness == .stale) }
        }
        let line = point.lineSize.flatMap { signal in
            LineLevel(lineSizeCode: signal.code).map { (level: $0, isOlder: signal.freshness == .stale) }
        }
        self.init(wait: wait, line: line)
    }

    /// Each signal's level and whether it's older. Uncertain is older only
    /// when both signals are.
    private init?(wait: (level: LineLevel, isOlder: Bool)?, line: (level: LineLevel, isOlder: Bool)?) {
        guard let level = LineLevel.combining(wait: wait?.level, lineSize: line?.level) else { return nil }
        let isOlder = if level == .uncertain {
            (wait?.isOlder ?? true) && (line?.isOlder ?? true)
        } else {
            // Any other level is the wait's when there is one.
            (wait ?? line)?.isOlder ?? false
        }
        self.init(level: level, isOlder: isOlder)
    }

    /// "Short line", or "Short line, older reports" for VoiceOver.
    public var spokenText: String {
        isOlder ? "\(level.title), older reports" : level.title
    }
}
