import Foundation

/// The running timer on the wait card (FR-4, FR-7).
public struct WaitTimer: Sendable, Hashable {
    public let startedAt: Date
    public var offset: StartOffset?

    public init(startedAt: Date, offset: StartOffset? = nil) {
        self.startedAt = startedAt
        self.offset = offset
    }

    /// now - startedAt + offset minutes, never negative.
    public func elapsed(at now: Date) -> TimeInterval {
        let offsetSeconds = Double(offset?.rawValue ?? 0) * 60
        return max(0, now.timeIntervalSince(startedAt) + offsetSeconds)
    }

    /// "m:ss" under an hour ("0:07", "12:05"), "h:mm:ss" from an hour ("1:02:05").
    public func text(at now: Date) -> String {
        let total = Int(elapsed(at: now))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let ss = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        if hours == 0 {
            return "\(minutes):\(ss)"
        }
        let mm = minutes < 10 ? "0\(minutes)" : "\(minutes)"
        return "\(hours):\(mm):\(ss)"
    }

    /// The server ends sessions 90 minutes after the start, not counting the offset (FR-10).
    public func isPastTimeout(at now: Date, timeoutMinutes: Int = 90) -> Bool {
        now.timeIntervalSince(startedAt) >= Double(timeoutMinutes) * 60
    }
}
