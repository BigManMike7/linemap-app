import Foundation

/// The person's own time in lines, for the tracker in Settings (FR-48): every
/// timed wait that ended with I'm in or Gave up, including Adjust time.
public struct WaitStats: Sendable, Hashable, Decodable {
    public let totalSeconds: Int
    public let waits: Int
    /// Nil before any wait.
    public let longestSeconds: Int?

    public init(totalSeconds: Int, waits: Int, longestSeconds: Int?) {
        self.totalSeconds = totalSeconds
        self.waits = waits
        self.longestSeconds = longestSeconds
    }

    /// The big number: "3 hr 25 min", "45 min", "2 hr", or "Under 1 min".
    public var totalLabel: String {
        Self.duration(totalSeconds)
    }

    /// The line under it: "7 lines · longest 48 min", or "1 line" for one wait.
    public var detailLabel: String {
        let count = waits == 1 ? "1 line" : "\(waits) lines"
        guard waits > 1, let longestSeconds else { return count }
        return "\(count) · longest \(Self.duration(longestSeconds))"
    }

    static func duration(_ seconds: Int) -> String {
        let minutes = max(seconds, 0) / 60
        guard minutes > 0 else { return "Under 1 min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return switch (hours, rest) {
        case (0, _): "\(rest) min"
        case (_, 0): "\(hours) hr"
        default: "\(hours) hr \(rest) min"
        }
    }
}
