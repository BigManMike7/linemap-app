import Foundation
import Testing
@testable import LineMapCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func bar(_ id: Int64, order: Int) -> Bar {
    Bar(id: id, name: "Bar \(id)", address: "", doorLat: 0, doorLon: 0, displayOrder: order)
}

private func wait(_ code: Int, minutes: Int? = nil, stale: Bool = false) -> Signal {
    Signal(code: code, minutes: minutes, source: minutes == nil ? .reported : .measured, at: now,
           freshness: stale ? .stale : .fresh)
}

private func line(_ code: Int, stale: Bool = false) -> Signal {
    Signal(code: code, at: now, freshness: stale ? .stale : .fresh)
}

private func estimate(_ barId: Int64, display: Display = .estimate, wait: Signal? = nil,
                      line: Signal? = nil, crowd: Signal? = nil) -> BarEstimate {
    BarEstimate(barId: barId, display: display, freshness: .fresh, people: 1, latestAt: now,
                lineSize: line, wait: wait, busyness: crowd)
}

private func order(_ bars: [Bar], _ estimates: [BarEstimate]) -> [Int64] {
    let all = Estimates(logicVersion: 1, generatedAt: now, windowState: .live, bars: estimates)
    return BarOrder.sorted(bars, estimates: all).map(\.id)
}

struct BarOrderTests {
    @Test func shortestWaitFirst() {
        let bars = [bar(1, order: 1), bar(2, order: 2), bar(3, order: 3)]
        let ids = order(bars, [
            estimate(1, wait: wait(4, minutes: 40)),
            estimate(2, wait: wait(2, minutes: 8)),
            estimate(3, wait: wait(3, minutes: 20)),
        ])
        #expect(ids == [2, 3, 1])
    }

    @Test func reportedRangesCompareByTheirMiddle() {
        let bars = [bar(1, order: 1), bar(2, order: 2)]
        // A 15–30 range sits at about 22 minutes, after a timed 12.
        #expect(order(bars, [estimate(1, wait: wait(3)), estimate(2, wait: wait(2, minutes: 12))]) == [2, 1])
    }

    @Test func freshBeforeStaleEvenWithALongerWait() {
        let bars = [bar(1, order: 1), bar(2, order: 2)]
        let ids = order(bars, [
            estimate(1, wait: wait(1, minutes: 3, stale: true)),
            estimate(2, wait: wait(4, minutes: 45)),
        ])
        #expect(ids == [2, 1])
    }

    @Test func waitsThenLineSizeOnlyThenCrowdOnly() {
        let bars = [bar(1, order: 1), bar(2, order: 2), bar(3, order: 3), bar(4, order: 4)]
        let ids = order(bars, [
            estimate(1, crowd: line(3)),
            estimate(2, line: line(3)),
            estimate(3, line: line(1)),
            estimate(4, wait: wait(5, minutes: 70)),
        ])
        #expect(ids == [4, 3, 2, 1])
    }

    @Test func uncertainComesAfterLineSizeOnlyAndBeforeCrowdOnly() {
        let bars = [bar(1, order: 1), bar(2, order: 2), bar(3, order: 3)]
        let ids = order(bars, [
            estimate(1, crowd: line(3)),
            // A 0-minute timer next to 50+ in line (FR-2).
            estimate(2, wait: wait(1, minutes: 0), line: line(4)),
            estimate(3, line: line(4)),
        ])
        #expect(ids == [3, 2, 1])
    }

    @Test func noDataComesLastInDashboardOrder() {
        let bars = [bar(1, order: 3), bar(2, order: 1), bar(3, order: 2), bar(4, order: 4)]
        let ids = order(bars, [
            estimate(1, display: .closed),
            estimate(2, display: .notEnoughData),
            estimate(3, display: .outsideHours),
            estimate(4, line: line(2, stale: true)),
        ])
        #expect(ids == [4, 2, 3, 1])
    }

    @Test func tiesKeepDashboardOrder() {
        let bars = [bar(1, order: 2), bar(2, order: 1)]
        #expect(order(bars, [estimate(1, wait: wait(2, minutes: 10)), estimate(2, wait: wait(2, minutes: 10))]) == [2, 1])
    }

    @Test func noEstimatesKeepsDashboardOrder() {
        let bars = [bar(1, order: 2), bar(2, order: 1)]
        #expect(BarOrder.sorted(bars, estimates: nil).map(\.id) == [2, 1])
    }

    @Test(arguments: [(1, 2), (2, 10), (3, 22), (4, 45), (5, 75)])
    func rangeMiddles(code: Int, minutes: Int) {
        #expect(BarOrder.comparableMinutes(wait(code)) == minutes)
    }
}
