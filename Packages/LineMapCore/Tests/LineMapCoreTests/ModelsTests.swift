import Foundation
import Testing
@testable import LineMapCore

private let estimatesJSON = """
{
  "logic_version": 1,
  "generated_at": "2026-10-02T02:15:00.123456+00:00",
  "window_state": "live",
  "bars": [
    {
      "bar_id": 2,
      "display": "estimate",
      "freshness": "fresh",
      "people": 3,
      "latest_at": "2026-10-02T02:09:00+00:00",
      "line_size": {"code": 2, "minutes": null, "source": "reported",
                    "at": "2026-10-02T02:09:00+00:00", "freshness": "fresh", "rule": "newest"},
      "wait": {"code": 3, "minutes": 25, "source": "measured",
               "at": "2026-10-02T02:05:00.5+00:00", "freshness": "stale", "rule": "majority"},
      "busyness": null
    },
    {
      "bar_id": 3,
      "display": "not_enough_data",
      "freshness": "none",
      "people": 0,
      "latest_at": null,
      "line_size": null,
      "wait": null,
      "busyness": null
    }
  ]
}
"""

private let outsideHoursJSON = """
{
  "logic_version": 1,
  "generated_at": "2026-10-02T14:00:00Z",
  "window_state": "outside_hours",
  "bars": [
    {"bar_id": 1, "display": "outside_hours", "freshness": "none", "people": 0,
     "latest_at": null, "line_size": null, "wait": null, "busyness": null}
  ]
}
"""

private let barsJSON = """
[
  {"id": 1, "name": "Doggie's Pub", "address": "108 S Pugh St", "door_lat": 40.7931,
   "door_lon": -77.8601, "size_class": "medium", "display_order": 1},
  {"id": 2, "name": "The Phyrst", "address": "111 E Beaver Ave", "door_lat": 40.7943,
   "door_lon": -77.8590, "size_class": "large", "display_order": 2}
]
"""

struct EstimatesDecodingTests {
    @Test func decodesRealisticEstimates() throws {
        let data = Data(estimatesJSON.utf8)
        let estimates = try JSONDecoder.lineMap.decode(Estimates.self, from: data)

        #expect(estimates.logicVersion == 1)
        #expect(estimates.windowState == .live)
        #expect(estimates.bars.count == 2)

        let base = try #require(ServerDate.parse("2026-10-02T02:15:00Z"))
        #expect(abs(estimates.generatedAt.timeIntervalSince(base) - 0.123) < 0.001)

        let phyrst = try #require(estimates.estimate(for: 2))
        #expect(phyrst.display == .estimate)
        #expect(phyrst.freshness == .fresh)
        #expect(phyrst.people == 3)
        #expect(phyrst.latestAt == ServerDate.parse("2026-10-02T02:09:00Z"))
        #expect(phyrst.busyness == nil)

        let line = try #require(phyrst.lineSize)
        #expect(line.code == 2)
        #expect(line.minutes == nil)
        #expect(line.source == .reported)
        #expect(line.freshness == .fresh)
        #expect(line.rule == .newest)

        let wait = try #require(phyrst.wait)
        #expect(wait.code == 3)
        #expect(wait.minutes == 25)
        #expect(wait.source == .measured)
        #expect(wait.freshness == .stale)
        #expect(wait.rule == .majority)
        let waitBase = try #require(ServerDate.parse("2026-10-02T02:05:00Z"))
        #expect(abs(wait.at.timeIntervalSince(waitBase) - 0.5) < 0.001)
    }

    @Test func decodesNullSignalsAndNotEnoughData() throws {
        let data = Data(estimatesJSON.utf8)
        let estimates = try JSONDecoder.lineMap.decode(Estimates.self, from: data)
        let quiet = try #require(estimates.estimate(for: 3))
        #expect(quiet.display == .notEnoughData)
        #expect(quiet.freshness == Freshness.none)
        #expect(quiet.latestAt == nil)
        #expect(quiet.lineSize == nil)
        #expect(quiet.wait == nil)
    }

    @Test func decodesOutsideHours() throws {
        let data = Data(outsideHoursJSON.utf8)
        let estimates = try JSONDecoder.lineMap.decode(Estimates.self, from: data)
        #expect(estimates.windowState == .outsideHours)
        #expect(estimates.bars.first?.display == .outsideHours)
    }

    @Test func unknownBarHasNoEstimate() throws {
        let data = Data(estimatesJSON.utf8)
        let estimates = try JSONDecoder.lineMap.decode(Estimates.self, from: data)
        #expect(estimates.estimate(for: 99) == nil)
    }

    @Test func decodesBars() throws {
        let data = Data(barsJSON.utf8)
        let bars = try JSONDecoder.lineMap.decode([Bar].self, from: data)
        #expect(bars.count == 2)
        #expect(bars[0].id == 1)
        #expect(bars[0].name == "Doggie's Pub")
        #expect(bars[0].address == "108 S Pugh St")
        #expect(bars[0].doorLat == 40.7931)
        #expect(bars[0].doorLon == -77.8601)
        #expect(bars[0].sizeClass == "medium")
        #expect(bars[1].displayOrder == 2)
    }

    @Test func rejectsBadTimestamp() {
        let json = #"{"logic_version":1,"generated_at":"yesterday","window_state":"live","bars":[]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder.lineMap.decode(Estimates.self, from: Data(json.utf8))
        }
    }
}

struct ServerDateTests {
    @Test(arguments: [
        "2026-10-02T02:15:00Z",
        "2026-10-02T02:15:00+00:00",
        "2026-10-02T02:15:00.000Z",
        "2026-10-02T02:15:00.000+00:00",
    ])
    func parsesWholeSeconds(text: String) throws {
        let date = try #require(ServerDate.parse(text))
        let reference = try #require(ServerDate.parse("2026-10-02T02:15:00Z"))
        #expect(abs(date.timeIntervalSince(reference)) < 0.001)
    }

    @Test func parsesFractionalDigits() throws {
        let base = try #require(ServerDate.parse("2026-10-02T02:15:00Z"))
        let one = try #require(ServerDate.parse("2026-10-02T02:15:00.5Z"))
        let three = try #require(ServerDate.parse("2026-10-02T02:15:00.123Z"))
        let six = try #require(ServerDate.parse("2026-10-02T02:15:00.123456+00:00"))
        #expect(abs(one.timeIntervalSince(base) - 0.5) < 0.001)
        #expect(abs(three.timeIntervalSince(base) - 0.123) < 0.001)
        #expect(abs(six.timeIntervalSince(base) - 0.123) < 0.001)
    }

    @Test func parsesOffsets() throws {
        let utc = try #require(ServerDate.parse("2026-10-02T02:15:00Z"))
        let eastern = try #require(ServerDate.parse("2026-10-01T22:15:00-04:00"))
        #expect(abs(utc.timeIntervalSince(eastern)) < 0.001)
    }

    @Test func rejectsGarbage() {
        #expect(ServerDate.parse("not a date") == nil)
        #expect(ServerDate.parse("") == nil)
    }

    @Test func formatShape() {
        #expect(ServerDate.format(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
        #expect(ServerDate.format(Date(timeIntervalSince1970: 86_400.5)) == "1970-01-02T00:00:00.500Z")
    }

    @Test func formatRoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        let parsed = try #require(ServerDate.parse(ServerDate.format(date)))
        #expect(abs(parsed.timeIntervalSince(date)) < 0.001)
    }
}

struct AnswerTests {
    @Test func answered() {
        let answer = Answer<LineSize>.answered(.tenTo25)
        #expect(answer.state == .answered)
        #expect(answer.code == 2)
    }

    @Test func cantTell() {
        let answer = Answer<Busyness>.cantTell
        #expect(answer.state == .cantTell)
        #expect(answer.code == nil)
    }

    @Test func skipped() {
        let answer = Answer<RecalledWait>.skipped
        #expect(answer.state == .skipped)
        #expect(answer.code == nil)
    }
}

/// These codes are stored on the server and must never change meaning (NFR-10).
struct AnswerCodeTests {
    @Test func lineSize() {
        #expect(LineSize.allCases.map(\.rawValue) == [0, 1, 2, 3, 6, 7, 4, 5])
        #expect(LineSize.nobody.rawValue == 0)
        #expect(LineSize.oneToTen.rawValue == 1)
        #expect(LineSize.tenTo25.rawValue == 2)
        #expect(LineSize.twentyFiveTo50.rawValue == 3)
        #expect(LineSize.fiftyPlus.rawValue == 4)
        #expect(LineSize.cantSeeEnd.rawValue == 5)
        #expect(LineSize.fiftyTo100.rawValue == 6)
        #expect(LineSize.hundredPlus.rawValue == 7)
    }

    @Test func offeredLineSizes() {
        #expect(LineSize.offered.map(\.rawValue) == [0, 1, 2, 3, 6, 7])
        #expect(LineSize.offered == [.nobody, .oneToTen, .tenTo25, .twentyFiveTo50, .fiftyTo100, .hundredPlus])
    }

    @Test(arguments: [
        (LineSize.nobody, 0), (.oneToTen, 1), (.tenTo25, 2), (.twentyFiveTo50, 3),
        (.fiftyPlus, 4), (.fiftyTo100, 4), (.cantSeeEnd, 4), (.hundredPlus, 5),
    ])
    func lineSizeRank(size: LineSize, rank: Int) {
        #expect(size.rank == rank)
        #expect(LineSize.rank(code: size.rawValue) == rank)
    }

    @Test(arguments: [8, 9, -1, 100])
    func unknownLineSizeCodeRanksBelowEverything(code: Int) {
        #expect(LineSize.rank(code: code) == -1)
    }

    @Test func busyness() {
        #expect(Busyness.allCases.map(\.rawValue) == [1, 2, 3, 4])
        #expect(Busyness.quiet.rawValue == 1)
        #expect(Busyness.comfortable.rawValue == 2)
        #expect(Busyness.busy.rawValue == 3)
        #expect(Busyness.packed.rawValue == 4)
    }

    @Test func recalledWait() {
        #expect(RecalledWait.allCases.map(\.rawValue) == [1, 2, 3, 4, 5])
        #expect(RecalledWait.under5.rawValue == 1)
        #expect(RecalledWait.fiveTo15.rawValue == 2)
        #expect(RecalledWait.fifteenTo30.rawValue == 3)
        #expect(RecalledWait.thirtyTo60.rawValue == 4)
        #expect(RecalledWait.sixtyPlus.rawValue == 5)
    }

    @Test func startOffset() {
        // The server accepts 0 to 90 minutes (FR-7).
        #expect(StartOffset.choices == 0...90)
        #expect(StartOffset.maxMinutes == 90)
    }

    @Test func answerStates() {
        #expect(AnswerState.answered.rawValue == "answered")
        #expect(AnswerState.cantTell.rawValue == "cant_tell")
        #expect(AnswerState.skipped.rawValue == "skipped")
    }

    @Test func definitionsVersion() {
        #expect(Definitions.version == 2)
    }
}
