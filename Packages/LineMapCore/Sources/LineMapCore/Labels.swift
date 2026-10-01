import Foundation

/// English display strings for answer options (FR-6, FR-11) and relative times.
public enum Labels {
    public static func option(_ value: LineSize) -> String {
        switch value {
        case .nobody: "No line"
        case .oneToTen: "1–10"
        case .tenTo25: "10–25"
        case .twentyFiveTo50: "25–50"
        case .fiftyPlus: "50+"
        case .cantSeeEnd: "Can't see the end"
        }
    }

    public static func option(_ value: Busyness) -> String {
        switch value {
        case .quiet: "Quiet"
        case .comfortable: "Comfortable"
        case .busy: "Busy"
        case .packed: "Packed"
        }
    }

    public static func option(_ value: RecalledWait) -> String {
        switch value {
        case .under5: "Under 5 min"
        case .fiveTo15: "5–15 min"
        case .fifteenTo30: "15–30 min"
        case .thirtyTo60: "30–60 min"
        case .sixtyPlus: "60+ min"
        }
    }

    public static func option(_ value: StartOffset) -> String {
        switch value {
        case .five: "~5 min"
        case .ten: "~10 min"
        case .twenty: "~20 min"
        }
    }

    public static let cantTell = "I can't tell"
    public static let skip = "Skip"

    /// "just now" under 1 minute, "1 min ago", "N min ago" under 60, "1 hr ago", "N hr ago" after.
    /// Dates in the future read "just now".
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return minutes == 1 ? "1 min ago" : "\(minutes) min ago"
        }
        let hours = minutes / 60
        return hours == 1 ? "1 hr ago" : "\(hours) hr ago"
    }
}

/// The text on a bar's map pin (FR-2).
public struct PinLabel: Sendable, Hashable {
    public let text: String
    public let isGrayed: Bool

    public init(text: String, isGrayed: Bool) {
        self.text = text
        self.isGrayed = isGrayed
    }

    public init(estimate: BarEstimate?) {
        guard let estimate else {
            self.init(text: "No data", isGrayed: false)
            return
        }
        switch estimate.display {
        case .closed:
            self.init(text: "Closed", isGrayed: false)
        case .outsideHours:
            self.init(text: "Outside hours", isGrayed: false)
        case .notEnoughData:
            self.init(text: "No data", isGrayed: false)
        case .estimate:
            if let wait = estimate.wait, let text = PinLabel.waitText(wait) {
                self.init(text: text, isGrayed: wait.freshness == .stale)
            } else if let line = estimate.lineSize, let text = PinLabel.lineText(line.code) {
                self.init(text: text, isGrayed: line.freshness == .stale)
            } else {
                self.init(text: "No data", isGrayed: false)
            }
        }
    }

    /// "The Phyrst · 25 min"
    public func title(barName: String) -> String {
        "\(barName) · \(text)"
    }

    private static func waitText(_ wait: Signal) -> String? {
        if wait.source == .measured, let minutes = wait.minutes {
            return "\(minutes) min"
        }
        switch wait.code {
        case 1: return "<5 min"
        case 2: return "5–15 min"
        case 3: return "15–30 min"
        case 4: return "30–60 min"
        case 5: return "60+ min"
        default: return nil
        }
    }

    private static func lineText(_ code: Int) -> String? {
        switch code {
        case 0: return "No line"
        case 1: return "~1–10 in line"
        case 2: return "~10–25 in line"
        case 3: return "~25–50 in line"
        case 4: return "50+ in line"
        case 5: return "Long line"
        default: return nil
        }
    }
}

/// The bar sheet's text (FR-3).
public struct BarSummary: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        public let text: String
        public let isGrayed: Bool

        public init(text: String, isGrayed: Bool) {
            self.text = text
            self.isGrayed = isGrayed
        }
    }

    public let lineSize: Line?
    public let wait: Line?
    public let busyness: Line?
    public let freshness: String?
    public let status: String?

    public init(estimate: BarEstimate?, now: Date) {
        guard let estimate else {
            lineSize = nil
            wait = nil
            busyness = nil
            freshness = nil
            status = "Not enough data"
            return
        }

        switch estimate.display {
        case .estimate:
            status = nil
            if let signal = estimate.lineSize, let text = BarSummary.lineSizeText(signal.code) {
                lineSize = Line(text: text, isGrayed: signal.freshness == .stale)
            } else {
                lineSize = nil
            }
            if let signal = estimate.wait, let text = BarSummary.waitText(signal, now: now) {
                wait = Line(text: text, isGrayed: signal.freshness == .stale)
            } else {
                wait = nil
            }
            if let signal = estimate.busyness, let level = Busyness(rawValue: signal.code) {
                busyness = Line(text: Labels.option(level), isGrayed: signal.freshness == .stale)
            } else {
                busyness = nil
            }
        case .notEnoughData:
            status = "Not enough data"
            lineSize = nil
            wait = nil
            busyness = nil
        case .closed:
            status = "Closed"
            lineSize = nil
            wait = nil
            busyness = nil
        case .outsideHours:
            status = "Outside usual hours, no recent reports"
            lineSize = nil
            wait = nil
            busyness = nil
        }

        if estimate.freshness != .none, let latest = estimate.latestAt {
            let people = estimate.people == 1 ? "1 person" : "\(estimate.people) people"
            freshness = "\(people) · latest \(Labels.ago(latest, now: now))"
        } else {
            freshness = nil
        }
    }

    private static func lineSizeText(_ code: Int) -> String? {
        guard let size = LineSize(rawValue: code) else { return nil }
        switch size {
        case .nobody: return "No line"
        case .oneToTen, .tenTo25, .twentyFiveTo50, .fiftyPlus: return "\(Labels.option(size)) in line"
        case .cantSeeEnd: return "Can't see the end of the line"
        }
    }

    private static func waitText(_ signal: Signal, now: Date) -> String? {
        if signal.source == .measured, let minutes = signal.minutes {
            return "\(minutes) min, got in \(Labels.ago(signal.at, now: now))"
        }
        guard let recalled = RecalledWait(rawValue: signal.code) else { return nil }
        return Labels.option(recalled)
    }
}
