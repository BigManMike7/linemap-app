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

    /// 9 p.m. on the test night; the night day starts 17 hours earlier, at 4 a.m.
    private static let nine = Date(timeIntervalSince1970: 1_800_000_000)

    /// A quarter hour's time: 0 is 9:00 p.m., -28 is 2:00 p.m., 19 is 1:45 a.m.
    private static func quarter(_ index: Int) -> Date {
        nine.addingTimeInterval(Double(index) * 900)
    }

    /// A full night day as the server sends it: 96 points every 15 minutes
    /// from 4 a.m. (index -68) to 3:45 a.m. (index 27), or fewer for tonight.
    private func day(through last: Int = 27, _ signal: (Int) -> HistoryPoint? = { _ in nil }) -> BarHistory {
        let points = (-68...last).map { index in
            signal(index) ?? HistoryPoint(at: Self.quarter(index), people: 0)
        }
        return BarHistory(logicVersion: 1, barId: 1, night: NightDate(year: 2026, month: 10, day: 2),
                          tonight: NightDate(year: 2026, month: 10, day: 5), start: Self.nine,
                          end: Self.nine.addingTimeInterval(5 * 3600), nights: [], points: points)
    }

    private static func reported(_ index: Int, line: Int = 1, wait: Int? = nil) -> HistoryPoint {
        HistoryPoint(at: quarter(index), people: 2, lineSize: HistorySignal(code: line),
                     wait: wait.map { HistorySignal(code: $0) })
    }

    @Test func rowsCoverTheUsualWindowAndCollapseEmptyStretches() {
        // One report at 10:00 p.m.
        let history = day { $0 == 4 ? Self.reported(4) : nil }
        #expect(history.rows == [
            .noReports(from: Self.quarter(0), to: Self.quarter(3)),     // 9:00–9:45
            .point(Self.reported(4)),                                    // 10:00
            .noReports(from: Self.quarter(5), to: Self.quarter(19)),    // 10:15–1:45
        ])
    }

    @Test func rowsStretchToAnAfternoonCrowd() {
        // A football Saturday: reports at 2:00 and 2:15 p.m., then 9:15 p.m.
        let history = day { [-28, -27, 1].contains($0) ? Self.reported($0) : nil }
        #expect(history.rows == [
            .point(Self.reported(-28)),
            .point(Self.reported(-27)),
            .noReports(from: Self.quarter(-26), to: Self.quarter(0)),   // 2:30–9:00
            .point(Self.reported(1)),
            .noReports(from: Self.quarter(2), to: Self.quarter(19)),
        ])
    }

    @Test func aLoneEmptyQuarterHourStaysARow() {
        // Reports at 9:00 and 9:30 p.m., nothing at 9:15.
        let history = day { [0, 2].contains($0) ? Self.reported($0) : nil }
        #expect(Array(history.rows.prefix(3)) == [
            .point(Self.reported(0)),
            .point(HistoryPoint(at: Self.quarter(1), people: 0)),
            .point(Self.reported(2)),
        ])
    }

    @Test func rowsStretchPastTheUsualEnd() {
        let history = day { $0 == 22 ? Self.reported(22) : nil }       // 2:30 a.m.
        #expect(history.rows.last == .point(Self.reported(22)))
        #expect(history.rows.dropLast().last == .noReports(from: Self.quarter(0), to: Self.quarter(21)))
    }

    @Test func tonightStopsAtNow() {
        // Points only through 10:30 p.m.
        let history = day(through: 6) { $0 == 2 ? Self.reported(2) : nil }
        #expect(history.rows.last == .noReports(from: Self.quarter(3), to: Self.quarter(6)))
    }

    @Test func fiveMinutePointsFromOlderServersStillGiveQuarterHours() {
        let points = (0...60).map { index in
            index == 3
                ? HistoryPoint(at: Self.nine.addingTimeInterval(Double(index) * 300), people: 1,
                               lineSize: HistorySignal(code: 2))
                : HistoryPoint(at: Self.nine.addingTimeInterval(Double(index) * 300), people: 0)
        }
        let history = BarHistory(logicVersion: 1, barId: 1, night: NightDate(year: 2026, month: 10, day: 2),
                                 tonight: NightDate(year: 2026, month: 10, day: 5), start: Self.nine,
                                 end: Self.nine.addingTimeInterval(5 * 3600), nights: [], points: points)
        let rows = history.rows
        #expect(rows.first == .point(HistoryPoint(at: Self.nine, people: 0)))
        #expect(rows.dropFirst().first?.id == Self.quarter(1))
        #expect(rows.last == .noReports(from: Self.quarter(2), to: Self.quarter(19)))
    }

    @Test func busiestIsTheBiggestLineThenTheLongestWait() {
        let history = day { index in
            switch index {
            case -28: Self.reported(-28, line: 2, wait: 2)   // 2:00 p.m.
            case 4: Self.reported(4, line: 3, wait: 2)       // 10:00
            case 6: Self.reported(6, line: 3, wait: 4)       // 10:30: same line, longer wait
            case 8: Self.reported(8, line: 3, wait: 4)       // 11:00: a tie goes to the earlier
            default: nil
            }
        }
        #expect(history.busiestRow?.at == Self.quarter(6))
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
