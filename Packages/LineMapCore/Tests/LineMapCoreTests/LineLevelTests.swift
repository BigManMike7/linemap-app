import Foundation
import Testing
@testable import LineMapCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func signal(_ code: Int, minutes: Int? = nil, source: Signal.Source = .reported,
                    freshness: Freshness = .fresh) -> Signal {
    Signal(code: code, minutes: minutes, source: source, at: now, freshness: freshness)
}

private func estimate(display: Display = .estimate, lineSize: Signal? = nil, wait: Signal? = nil,
                      busyness: Signal? = nil) -> BarEstimate {
    BarEstimate(barId: 1, display: display, freshness: .fresh, people: 2, latestAt: now,
                lineSize: lineSize, wait: wait, busyness: busyness)
}

struct LineLevelTests {
    @Test(arguments: [
        (0, LineLevel.short), (9, .short), (10, .some), (24, .some), (25, .long), (90, .long),
    ])
    func measuredWaitCutoffs(minutes: Int, expected: LineLevel) {
        #expect(LineLevel(waitMinutes: minutes) == expected)
    }

    @Test(arguments: [
        (1, LineLevel.short), (2, .some), (3, .some), (4, .long), (5, .long),
    ])
    func reportedWaitRangesUseTheirMidpoint(code: Int, expected: LineLevel) {
        #expect(LineLevel(waitCode: code) == expected)
    }

    @Test(arguments: [
        (0, LineLevel.short), (1, .short), (2, .some), (3, .long), (4, .long), (5, .long),
    ])
    func lineSizes(code: Int, expected: LineLevel) {
        #expect(LineLevel(lineSizeCode: code) == expected)
    }

    @Test func unknownCodesHaveNoLevel() {
        #expect(LineLevel(waitCode: 0) == nil)
        #expect(LineLevel(waitCode: 6) == nil)
        #expect(LineLevel(lineSizeCode: 6) == nil)
    }

    @Test func titles() {
        #expect(LineLevel.allCases.map(\.title) == ["Short line", "Some line", "Long line", "Uncertain"])
    }

    @Test(arguments: [
        (LineLevel.short, LineLevel.long, LineLevel.uncertain),
        (.long, .short, .uncertain),
        (.short, .some, .short),      // one level apart: the wait wins
        (.long, .some, .long),
        (.some, .short, .some),
        (.long, .long, .long),
    ])
    func combiningAWaitAndALineSize(wait: LineLevel, lineSize: LineLevel, expected: LineLevel) {
        #expect(LineLevel.combining(wait: wait, lineSize: lineSize) == expected)
    }

    @Test func combiningWithOneSignal() {
        #expect(LineLevel.combining(wait: .long, lineSize: nil) == .long)
        #expect(LineLevel.combining(wait: nil, lineSize: .short) == .short)
        #expect(LineLevel.combining(wait: nil, lineSize: nil) == nil)
    }
}

struct LineStatusTests {
    @Test func theWaitWinsOverTheLineSize() throws {
        let status = try #require(LineStatus(estimate: estimate(
            lineSize: signal(2), wait: signal(3, minutes: 40, source: .measured))))
        #expect(status == LineStatus(level: .long, isOlder: false))
    }

    @Test func aZeroMinuteTimerNextTo50PlusIsUncertain() throws {
        let status = try #require(LineStatus(estimate: estimate(
            lineSize: signal(4), wait: signal(1, minutes: 0, source: .measured))))
        #expect(status == LineStatus(level: .uncertain, isOlder: false))
    }

    @Test func uncertainIsOlderOnlyWhenBothSignalsAre() throws {
        let oneFresh = try #require(LineStatus(estimate: estimate(
            lineSize: signal(4), wait: signal(1, freshness: .stale))))
        #expect(oneFresh == LineStatus(level: .uncertain, isOlder: false))
        let bothOld = try #require(LineStatus(estimate: estimate(
            lineSize: signal(4, freshness: .stale), wait: signal(1, freshness: .stale))))
        #expect(bothOld == LineStatus(level: .uncertain, isOlder: true))
    }

    @Test func aMeasuredWaitUsesItsMinutesNotItsRange() throws {
        // Its range, 5–15 (code 2), would be "some"; its 8 minutes are short.
        let status = try #require(LineStatus(estimate: estimate(wait: signal(2, minutes: 8, source: .measured))))
        #expect(status.level == .short)
    }

    @Test func aReportedWaitIgnoresMinutes() throws {
        let status = try #require(LineStatus(estimate: estimate(wait: signal(4, minutes: 3))))
        #expect(status.level == .long)
    }

    @Test func theLineSizeCountsWhenThereIsNoWait() throws {
        let status = try #require(LineStatus(estimate: estimate(lineSize: signal(2, freshness: .stale))))
        #expect(status == LineStatus(level: .some, isOlder: true))
    }

    @Test func theCrowdNeverCounts() {
        #expect(LineStatus(estimate: estimate(busyness: signal(4))) == nil)
    }

    @Test(arguments: [Display.notEnoughData, .closed, .outsideHours])
    func noLevelWithoutAnEstimate(display: Display) {
        #expect(LineStatus(estimate: estimate(display: display, lineSize: signal(4))) == nil)
        #expect(LineStatus(estimate: nil) == nil)
    }

    @Test func historyPointsUseTheSameRule() throws {
        let point = HistoryPoint(at: now, people: 3,
                                 lineSize: HistorySignal(code: 2),
                                 wait: HistorySignal(code: 2, minutes: 6, freshness: .stale),
                                 busyness: HistorySignal(code: 4))
        #expect(LineStatus(point: point) == LineStatus(level: .short, isOlder: true))

        let contradiction = HistoryPoint(at: now, people: 2, lineSize: HistorySignal(code: 0),
                                         wait: HistorySignal(code: 4, minutes: 40))
        #expect(LineStatus(point: contradiction)?.level == .uncertain)

        let lineOnly = HistoryPoint(at: now, people: 1, lineSize: HistorySignal(code: 3))
        #expect(LineStatus(point: lineOnly)?.level == .long)

        let crowdOnly = HistoryPoint(at: now, people: 1, busyness: HistorySignal(code: 1))
        #expect(LineStatus(point: crowdOnly) == nil)
    }

    @Test func spokenText() {
        #expect(LineStatus(level: .some, isOlder: false).spokenText == "Some line")
        #expect(LineStatus(level: .long, isOlder: true).spokenText == "Long line, older reports")
    }
}
