import Foundation
import Testing
@testable import LineMapCore

struct WaitStatsTests {
    @Test func decodesTheServerReply() throws {
        let json = #"{"total_seconds": 12300, "waits": 7, "longest_seconds": 2880}"#
        let stats = try JSONDecoder.lineMap.decode(WaitStats.self, from: Data(json.utf8))
        #expect(stats == WaitStats(totalSeconds: 12300, waits: 7, longestSeconds: 2880))
    }

    @Test func decodesNoWaits() throws {
        let json = #"{"total_seconds": 0, "waits": 0, "longest_seconds": null}"#
        let stats = try JSONDecoder.lineMap.decode(WaitStats.self, from: Data(json.utf8))
        #expect(stats == WaitStats(totalSeconds: 0, waits: 0, longestSeconds: nil))
    }

    @Test(arguments: [
        (0, "Under 1 min"),
        (59, "Under 1 min"),
        (60, "1 min"),
        (45 * 60 + 59, "45 min"),
        (3600, "1 hr"),
        (2 * 3600, "2 hr"),
        (3 * 3600 + 25 * 60, "3 hr 25 min"),
        (-30, "Under 1 min"),
    ])
    func duration(seconds: Int, label: String) {
        #expect(WaitStats.duration(seconds) == label)
    }

    @Test func totalAndDetail() {
        let stats = WaitStats(totalSeconds: 3 * 3600 + 25 * 60, waits: 7, longestSeconds: 48 * 60)
        #expect(stats.totalLabel == "3 hr 25 min")
        #expect(stats.detailLabel == "7 lines · longest 48 min")
    }

    @Test func oneWaitHasNoLongest() {
        let stats = WaitStats(totalSeconds: 20 * 60, waits: 1, longestSeconds: 20 * 60)
        #expect(stats.detailLabel == "1 line")
    }
}
