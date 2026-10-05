import Foundation
import Testing
@testable import LineMapCore

private let historyJSON = """
{
  "logic_version": 1,
  "bar_id": 2,
  "night": "2026-10-02",
  "tonight": "2026-10-05",
  "start": "2026-10-03T01:00:00+00:00",
  "end": "2026-10-03T06:00:00+00:00",
  "nights": ["2026-10-04", "2026-10-02", "2026-09-26"],
  "points": [
    {"at": "2026-10-03T01:00:00+00:00", "people": 0, "line_size": null, "wait": null, "busyness": null},
    {"at": "2026-10-03T01:05:00+00:00", "people": 2,
     "line_size": {"code": 2, "freshness": "fresh"},
     "wait": {"code": 3, "minutes": 25, "freshness": "stale"},
     "busyness": {"code": 3, "freshness": "fresh"}},
    {"at": "2026-10-03T01:10:00+00:00", "people": 0, "line_size": null, "wait": null, "busyness": null}
  ]
}
"""

struct BarHistoryTests {
    private func decoded() throws -> BarHistory {
        try JSONDecoder.lineMap.decode(BarHistory.self, from: Data(historyJSON.utf8))
    }

    @Test func decodesTheServerShape() throws {
        let history = try decoded()
        #expect(history.barId == 2)
        #expect(history.night == NightDate(year: 2026, month: 10, day: 2))
        #expect(history.tonight == NightDate(year: 2026, month: 10, day: 5))
        #expect(history.nights.count == 3)
        #expect(history.points.count == 3)
        let point = history.points[1]
        #expect(point.people == 2)
        #expect(point.lineSize == HistorySignal(code: 2))
        #expect(point.wait == HistorySignal(code: 3, minutes: 25, freshness: .stale))
        #expect(point.busyness?.code == 3)
        #expect(history.points[0].lineSize == nil)
        #expect(history.end.timeIntervalSince(history.start) == 5 * 3600)
    }

    @Test func hasDataAndLatestPoint() throws {
        let history = try decoded()
        #expect(history.hasData)
        #expect(history.latestPointWithData?.at == history.points[1].at)

        let empty = BarHistory(logicVersion: 1, barId: 1, night: history.night, tonight: history.tonight,
                               start: history.start, end: history.end, nights: [],
                               points: [HistoryPoint(at: history.start, people: 0)])
        #expect(!empty.hasData)
        #expect(empty.latestPointWithData == nil)
    }

    @Test func pickerNightsAlwaysOfferTonightAndLastNight() throws {
        let history = try decoded()
        #expect(history.pickerNights.map(\.description) == [
            "2026-10-05", "2026-10-04", "2026-10-02", "2026-09-26",
        ])
    }

    @Test func pointAtATimeIsTheOneAtOrJustBefore() throws {
        let history = try decoded()
        let between = history.points[1].at.addingTimeInterval(120)
        #expect(history.point(at: between)?.at == history.points[1].at)
        #expect(history.point(at: history.start.addingTimeInterval(-60))?.at == history.points[0].at)
    }
}

struct NightDateTests {
    @Test func parsesAndPrints() throws {
        let date = try #require(NightDate("2026-10-02"))
        #expect(date == NightDate(year: 2026, month: 10, day: 2))
        #expect(date.description == "2026-10-02")
        #expect(NightDate("2026-13-02") == nil)
        #expect(NightDate("yesterday") == nil)
    }

    @Test func addingDaysCrossesMonthsAndYears() {
        #expect(NightDate(year: 2026, month: 10, day: 2).adding(days: -7) == NightDate(year: 2026, month: 9, day: 25))
        #expect(NightDate(year: 2026, month: 12, day: 31).adding(days: 1) == NightDate(year: 2027, month: 1, day: 1))
        // The day daylight saving ends is still one day.
        #expect(NightDate(year: 2026, month: 11, day: 1).adding(days: 1) == NightDate(year: 2026, month: 11, day: 2))
    }

    @Test func labels() {
        let tonight = NightDate(year: 2026, month: 10, day: 5)
        #expect(tonight.label(tonight: tonight) == "Tonight")
        #expect(NightDate(year: 2026, month: 10, day: 4).label(tonight: tonight) == "Last night")
        #expect(NightDate(year: 2026, month: 10, day: 2).label(tonight: tonight) == "Fri, Oct 2")
        #expect(NightDate(year: 2026, month: 10, day: 1).weekdayName == "Thursday")
    }

    @Test func ordersByDate() {
        #expect(NightDate(year: 2026, month: 9, day: 30) < NightDate(year: 2026, month: 10, day: 1))
    }

    @Test func roundTripsAsAString() throws {
        let date = NightDate(year: 2026, month: 1, day: 9)
        let data = try JSONEncoder().encode([date])
        #expect(String(decoding: data, as: UTF8.self) == #"["2026-01-09"]"#)
        #expect(try JSONDecoder().decode([NightDate].self, from: data) == [date])
    }
}

struct HistoryLabelTests {
    @Test func readoutText() {
        #expect(Labels.historyLineSize(HistorySignal(code: 0)) == "No line")
        #expect(Labels.historyLineSize(HistorySignal(code: 3)) == "25–50 in line")
        #expect(Labels.historyWait(HistorySignal(code: 3, minutes: 25)) == "25 min wait")
        #expect(Labels.historyWait(HistorySignal(code: 2)) == "5–15 min wait")
        #expect(Labels.historyBusyness(HistorySignal(code: 4)) == "Packed")
        #expect(Labels.people(1) == "1 person")
        #expect(Labels.people(3) == "3 people")
    }
}
