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

    @Test func hasData() throws {
        let history = try decoded()
        #expect(history.hasData)
        #expect(history.points[1].hasData)
        #expect(!history.points[0].hasData)

        let empty = BarHistory(logicVersion: 1, barId: 1, night: history.night, tonight: history.tonight,
                               start: history.start, end: history.end, nights: [],
                               points: [HistoryPoint(at: history.start, people: 0)])
        #expect(!empty.hasData)
        #expect(empty.busiestRow == nil)
    }

    /// A full night: 61 points every 5 minutes from 9 p.m. through 2 a.m.
    private func fullNight(_ signal: (Int) -> HistoryPoint?) -> BarHistory {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = (0...60).map { index in
            signal(index) ?? HistoryPoint(at: start.addingTimeInterval(Double(index) * 300), people: 0)
        }
        return BarHistory(logicVersion: 1, barId: 1, night: NightDate(year: 2026, month: 10, day: 2),
                          tonight: NightDate(year: 2026, month: 10, day: 5), start: start,
                          end: start.addingTimeInterval(5 * 3600), nights: [], points: points)
    }

    @Test func halfHourRowsRunFrom9To130() {
        let history = fullNight { _ in nil }
        let rows = history.halfHourRows
        #expect(rows.count == 10)
        #expect(rows.first?.at == history.start)
        #expect(rows.last?.at == history.start.addingTimeInterval(4.5 * 3600))
    }

    @Test func busiestIsTheBiggestLineThenTheLongestWait() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func point(_ index: Int, line: Int, wait: Int) -> HistoryPoint {
            HistoryPoint(at: start.addingTimeInterval(Double(index) * 300), people: 2,
                         lineSize: HistorySignal(code: line), wait: HistorySignal(code: wait))
        }
        let history = fullNight { index in
            switch index {
            case 12: point(12, line: 3, wait: 2)   // 10:00
            case 18: point(18, line: 3, wait: 4)   // 10:30: same line, longer wait
            case 24: point(24, line: 3, wait: 4)   // 11:00: a tie goes to the earlier
            case 25: point(25, line: 4, wait: 5)   // 11:05: not a half hour
            default: nil
            }
        }
        #expect(history.busiestRow?.at == start.addingTimeInterval(18 * 300))
    }

    @Test func grayedOnlyWhenEveryValueIsOlder() {
        let at = Date(timeIntervalSince1970: 0)
        #expect(HistoryPoint(at: at, people: 1, lineSize: HistorySignal(code: 1, freshness: .stale)).isGrayed)
        #expect(!HistoryPoint(at: at, people: 1, lineSize: HistorySignal(code: 1, freshness: .stale),
                              busyness: HistorySignal(code: 2)).isGrayed)
        #expect(!HistoryPoint(at: at, people: 0).isGrayed)
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

    @Test func nightOfAMomentUsesTheFourAMBoundary() throws {
        let eastern = try #require(TimeZone(identifier: "America/New_York"))
        // 1 a.m. Sunday Oct 4, 2026 EDT is 05:00 UTC: still Saturday night.
        let lateSaturday = try #require(ServerDate.parse("2026-10-04T05:00:00Z"))
        #expect(NightDate(nightOf: lateSaturday, timeZone: eastern) == NightDate(year: 2026, month: 10, day: 3))
        // 5 a.m. Sunday is Sunday.
        let sundayMorning = try #require(ServerDate.parse("2026-10-04T09:00:00Z"))
        #expect(NightDate(nightOf: sundayMorning, timeZone: eastern) == NightDate(year: 2026, month: 10, day: 4))
        // 1:30 a.m. on the night daylight saving ends (Nov 1, EDT → EST) is still Saturday Oct 31.
        let fallBack = try #require(ServerDate.parse("2026-11-01T05:30:00Z"))
        #expect(NightDate(nightOf: fallBack, timeZone: eastern) == NightDate(year: 2026, month: 10, day: 31))
    }

    @Test func noonRoundTripsThroughTheCalendar() throws {
        let eastern = try #require(TimeZone(identifier: "America/New_York"))
        for date in [NightDate(year: 2026, month: 3, day: 8), NightDate(year: 2026, month: 11, day: 1),
                     NightDate(year: 2026, month: 10, day: 3)] {
            #expect(NightDate(calendarDateOf: date.noon(in: eastern), timeZone: eastern) == date)
        }
    }

    @Test func nightTitle() {
        #expect(NightDate(year: 2026, month: 10, day: 3).nightTitle == "Saturday night, Oct 3")
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
        let row = HistoryPoint(at: Date(timeIntervalSince1970: 0), people: 2,
                               lineSize: HistorySignal(code: 2), wait: HistorySignal(code: 3),
                               busyness: HistorySignal(code: 3))
        #expect(Labels.historyRow(row) == "10–25 in line · 15–30 min wait · Busy")
        #expect(Labels.historyRow(HistoryPoint(at: Date(timeIntervalSince1970: 0), people: 0)) == "No reports")
        #expect(Labels.people(1) == "1 person")
        #expect(Labels.people(3) == "3 people")
    }
}
