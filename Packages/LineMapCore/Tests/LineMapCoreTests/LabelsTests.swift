import Foundation
import Testing
@testable import LineMapCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func minutesBefore(_ minutes: Double) -> Date {
    now.addingTimeInterval(-minutes * 60)
}

private func estimate(
    display: Display = .estimate,
    freshness: Freshness = .fresh,
    people: Int = 3,
    latestAt: Date? = minutesBefore(5),
    lineSize: Signal? = nil,
    wait: Signal? = nil,
    busyness: Signal? = nil
) -> BarEstimate {
    BarEstimate(barId: 1, display: display, freshness: freshness, people: people, latestAt: latestAt,
                lineSize: lineSize, wait: wait, busyness: busyness)
}

private func signal(_ code: Int, minutes: Int? = nil, source: Signal.Source = .reported,
                    at: Date = minutesBefore(5), freshness: Freshness = .fresh) -> Signal {
    Signal(code: code, minutes: minutes, source: source, at: at, freshness: freshness)
}

struct OptionLabelTests {
    @Test(arguments: [
        (LineSize.nobody, "No line"),
        (LineSize.oneToTen, "1–10"),
        (LineSize.tenTo25, "10–25"),
        (LineSize.twentyFiveTo50, "25–50"),
        (LineSize.fiftyTo100, "50–100"),
        (LineSize.hundredPlus, "100+"),
        (LineSize.fiftyPlus, "50+"),
        (LineSize.cantSeeEnd, "Can't see the end"),
    ])
    func lineSize(value: LineSize, text: String) {
        #expect(Labels.option(value) == text)
    }

    @Test(arguments: [
        (RecalledWait.under5, "Under 5 min"),
        (RecalledWait.fiveTo15, "5–15 min"),
        (RecalledWait.fifteenTo30, "15–30 min"),
        (RecalledWait.thirtyTo60, "30–60 min"),
        (RecalledWait.sixtyPlus, "60+ min"),
    ])
    func recalledWait(value: RecalledWait, text: String) {
        #expect(Labels.option(value) == text)
    }

    @Test(arguments: [
        (0, "0 min"),
        (5, "5 min"),
        (11, "11 min"),
        (37, "37 min"),
        (90, "90 min"),
    ])
    func startOffset(minutes: Int, text: String) {
        #expect(Labels.startOffset(minutes: minutes) == text)
    }

    @Test(arguments: [
        (LineSize.nobody, "0"),
        (LineSize.oneToTen, "1–10"),
        (LineSize.fiftyPlus, "50+"),
    ])
    func shortLineSize(value: LineSize, text: String) {
        #expect(Labels.shortOption(value) == text)
    }

    @Test func fixedStrings() {
        #expect(Labels.cantTell == "I can't tell")
        #expect(Labels.skip == "Skip")
    }
}

struct AgoTests {
    @Test(arguments: [
        (0.0, "just now"),
        (59.0, "just now"),
        (60.0, "1 min ago"),
        (119.0, "1 min ago"),
        (120.0, "2 min ago"),
        (3599.0, "59 min ago"),
        (3600.0, "1 hr ago"),
        (7500.0, "2 hr ago"),
        (-300.0, "just now"),
    ])
    func boundaries(secondsAgo: Double, text: String) {
        let date = now.addingTimeInterval(-secondsAgo)
        #expect(Labels.ago(date, now: now) == text)
    }
}

struct PinLabelTests {
    @Test func nilEstimate() {
        #expect(PinLabel(estimate: nil) == PinLabel(text: "No live reports", isGrayed: false))
    }

    @Test func closed() {
        let label = PinLabel(estimate: estimate(display: .closed))
        #expect(label == PinLabel(text: "Closed", isGrayed: false))
    }

    @Test func outsideHours() {
        let label = PinLabel(estimate: estimate(display: .outsideHours))
        #expect(label == PinLabel(text: "No live reports", isGrayed: false))
    }

    @Test func notEnoughData() {
        let label = PinLabel(estimate: estimate(display: .notEnoughData, freshness: .none, latestAt: nil))
        #expect(label == PinLabel(text: "No live reports", isGrayed: false))
    }

    @Test func measuredWait() {
        let label = PinLabel(estimate: estimate(wait: signal(3, minutes: 25, source: .measured)))
        #expect(label == PinLabel(text: "25 min", isGrayed: false))
    }

    @Test func reportedWait() {
        let label = PinLabel(estimate: estimate(wait: signal(3)))
        #expect(label == PinLabel(text: "15–30 min", isGrayed: false))
    }

    @Test(arguments: [
        (1, "<5 min"),
        (2, "5–15 min"),
        (3, "15–30 min"),
        (4, "30–60 min"),
        (5, "60+ min"),
    ])
    func recalledWaitCodes(code: Int, text: String) {
        let label = PinLabel(estimate: estimate(wait: signal(code)))
        #expect(label.text == text)
    }

    @Test func waitBeatsLineSize() {
        let label = PinLabel(estimate: estimate(lineSize: signal(4), wait: signal(2)))
        #expect(label.text == "5–15 min")
    }

    @Test func aContradictionIsUncertain() {
        // A 0-minute timer next to 50+ in line (FR-2).
        let label = PinLabel(estimate: estimate(lineSize: signal(4), wait: signal(1, minutes: 0, source: .measured)))
        #expect(label == PinLabel(text: "Uncertain", isGrayed: false))
        let older = PinLabel(estimate: estimate(lineSize: signal(0, freshness: .stale),
                                                wait: signal(4, freshness: .stale)))
        #expect(older == PinLabel(text: "Uncertain", isGrayed: true))
    }

    @Test(arguments: [
        (0, "No line"),
        (1, "~1–10 in line"),
        (2, "~10–25 in line"),
        (3, "~25–50 in line"),
        (4, "50+ in line"),
        (5, "Long line"),
        (6, "~50–100 in line"),
        (7, "100+ in line"),
    ])
    func lineSizeCodes(code: Int, text: String) {
        let label = PinLabel(estimate: estimate(lineSize: signal(code)))
        #expect(label == PinLabel(text: text, isGrayed: false))
    }

    @Test func aCrowdAnswerAloneIsNoData() {
        let label = PinLabel(estimate: estimate(busyness: signal(3)))
        #expect(label == PinLabel(text: "No live reports", isGrayed: false))
    }

    @Test func staleWaitIsGrayed() {
        let label = PinLabel(estimate: estimate(wait: signal(3, minutes: 25, source: .measured, freshness: .stale)))
        #expect(label == PinLabel(text: "25 min", isGrayed: true))
    }

    @Test func staleLineSizeIsGrayed() {
        let label = PinLabel(estimate: estimate(lineSize: signal(2, freshness: .stale)))
        #expect(label == PinLabel(text: "~10–25 in line", isGrayed: true))
    }

    @Test func grayFollowsTheUsedSignal() {
        let label = PinLabel(estimate: estimate(
            lineSize: signal(2, freshness: .stale), wait: signal(3, freshness: .fresh)))
        #expect(label.isGrayed == false)
    }

    @Test func unknownCodesFallBackToNoData() {
        #expect(PinLabel(estimate: estimate(wait: signal(9))).text == "No live reports")
        #expect(PinLabel(estimate: estimate(lineSize: signal(9))).text == "No live reports")
    }

    @Test func title() {
        let label = PinLabel(text: "25 min", isGrayed: false)
        #expect(label.title(barName: "The Phyrst") == "The Phyrst · 25 min")
    }
}

struct BarSummaryTests {
    @Test func nilEstimate() {
        let summary = BarSummary(estimate: nil, now: now)
        #expect(summary.status == "No live reports")
        #expect(summary.lineSize == nil)
        #expect(summary.wait == nil)
        #expect(summary.freshness == nil)
    }

    @Test func fullEstimate() {
        let summary = BarSummary(estimate: estimate(
            lineSize: signal(2), wait: signal(3)), now: now)
        #expect(summary.status == nil)
        #expect(summary.lineSize == BarSummary.Line(text: "10–25 in line", isGrayed: false))
        #expect(summary.wait == BarSummary.Line(text: "15–30 min", isGrayed: false))
        #expect(summary.freshness == "3 people · latest 5 min ago")
    }

    @Test(arguments: [
        (0, "No line"),
        (1, "1–10 in line"),
        (2, "10–25 in line"),
        (3, "25–50 in line"),
        (4, "50+ in line"),
        (5, "Can't see the end of the line"),
        (6, "50–100 in line"),
        (7, "100+ in line"),
    ])
    func lineSizeCodes(code: Int, text: String) {
        let summary = BarSummary(estimate: estimate(lineSize: signal(code)), now: now)
        #expect(summary.lineSize?.text == text)
    }

    @Test func reportedWaitRanges() {
        #expect(BarSummary(estimate: estimate(wait: signal(1)), now: now).wait?.text == "Under 5 min")
        #expect(BarSummary(estimate: estimate(wait: signal(5)), now: now).wait?.text == "60+ min")
    }

    @Test func measuredWaitSaysWhenTheyGotIn() {
        let measured = signal(3, minutes: 25, source: .measured, at: minutesBefore(10))
        let summary = BarSummary(estimate: estimate(wait: measured), now: now)
        #expect(summary.wait?.text == "25 min, got in 10 min ago")
    }

    @Test func measuredWaitJustNow() {
        let measured = signal(3, minutes: 25, source: .measured, at: now)
        let summary = BarSummary(estimate: estimate(wait: measured), now: now)
        #expect(summary.wait?.text == "25 min, got in just now")
    }

    @Test func staleSignalsAreGrayed() {
        let summary = BarSummary(estimate: estimate(
            lineSize: signal(1, freshness: .stale),
            wait: signal(2, freshness: .fresh)), now: now)
        #expect(summary.lineSize?.isGrayed == true)
        #expect(summary.wait?.isGrayed == false)
    }

    @Test func freshnessSingularAndPlural() {
        let one = BarSummary(estimate: estimate(people: 1, latestAt: now), now: now)
        #expect(one.freshness == "1 person · latest just now")
        let many = BarSummary(estimate: estimate(people: 2, latestAt: minutesBefore(1)), now: now)
        #expect(many.freshness == "2 people · latest 1 min ago")
    }

    @Test func freshnessHiddenWithoutData() {
        #expect(BarSummary(estimate: estimate(freshness: .none), now: now).freshness == nil)
        #expect(BarSummary(estimate: estimate(latestAt: nil), now: now).freshness == nil)
    }

    @Test func notEnoughData() {
        let summary = BarSummary(
            estimate: estimate(display: .notEnoughData, freshness: .none, people: 0, latestAt: nil,
                               lineSize: signal(2)),
            now: now)
        #expect(summary.status == "No live reports")
        #expect(summary.lineSize == nil)
    }

    @Test func closed() {
        let summary = BarSummary(estimate: estimate(display: .closed, freshness: .none, latestAt: nil), now: now)
        #expect(summary.status == "Closed")
        #expect(summary.wait == nil)
    }

    @Test func outsideHours() {
        let summary = BarSummary(estimate: estimate(display: .outsideHours, freshness: .none, latestAt: nil), now: now)
        #expect(summary.status == "No live reports")
        #expect(summary.lineSize == nil)
    }
}
