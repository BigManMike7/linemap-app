import Foundation

/// The order of the Bars list (FR-45).
///
/// 1. Fresh estimates, then grayed-out (stale) ones.
/// 2. Within each: bars with a wait, shortest first; then bars with only a
///    line size, smallest first; then Uncertain bars, whose wait and line size
///    contradict (FR-2); then bars with only a crowd answer.
/// 3. Bars showing Not enough data, Closed, or Outside hours come last.
///
/// Ties keep the dashboard order (`displayOrder`), then the bar ID.
public enum BarOrder {
    public static func sorted(_ bars: [Bar], estimates: Estimates?) -> [Bar] {
        bars.sorted { lhs, rhs in
            let left = Key(bar: lhs, estimate: estimates?.estimate(for: lhs.id))
            let right = Key(bar: rhs, estimate: estimates?.estimate(for: rhs.id))
            return left < right
        }
    }

    /// Minutes used to compare a wait: the measured minutes, or the middle of a
    /// reported range.
    static func comparableMinutes(_ wait: Signal) -> Int {
        if wait.source == .measured, let minutes = wait.minutes {
            return minutes
        }
        return switch wait.code {
        case 1: 2
        case 2: 10
        case 3: 22
        case 4: 45
        default: 75
        }
    }

    private struct Key: Comparable {
        /// 0 fresh, 1 grayed out, 2 nothing to show.
        var freshness: Int
        /// 0 wait, 1 line size only, 2 uncertain, 3 crowd only.
        var kind: Int
        var value: Int
        var displayOrder: Int
        var id: Int64

        init(bar: Bar, estimate: BarEstimate?) {
            displayOrder = bar.displayOrder
            id = bar.id
            guard let estimate, estimate.display == .estimate else {
                (freshness, kind, value) = (2, 0, 0)
                return
            }
            if let status = LineStatus(estimate: estimate), status.level == .uncertain {
                (freshness, kind, value) = (status.isOlder ? 1 : 0, 2, 0)
            } else if let wait = estimate.wait {
                (freshness, kind, value) = (Self.tier(wait), 0, BarOrder.comparableMinutes(wait))
            } else if let line = estimate.lineSize {
                (freshness, kind, value) = (Self.tier(line), 1, line.code)
            } else if let crowd = estimate.busyness {
                (freshness, kind, value) = (Self.tier(crowd), 3, crowd.code)
            } else {
                (freshness, kind, value) = (2, 0, 0)
            }
        }

        private static func tier(_ signal: Signal) -> Int {
            signal.freshness == .stale ? 1 : 0
        }

        static func < (lhs: Key, rhs: Key) -> Bool {
            (lhs.freshness, lhs.kind, lhs.value, lhs.displayOrder, lhs.id)
                < (rhs.freshness, rhs.kind, rhs.value, rhs.displayOrder, rhs.id)
        }
    }
}
