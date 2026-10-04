import Foundation
import Testing
@testable import LineMapCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

struct WaitTimerTests {
    @Test func elapsedWithoutOffset() {
        let timer = WaitTimer(startedAt: start)
        #expect(timer.elapsed(at: start.addingTimeInterval(125)) == 125)
    }

    @Test func elapsedWithOffset() {
        let timer = WaitTimer(startedAt: start, offsetMinutes: 10)
        #expect(timer.elapsed(at: start.addingTimeInterval(30)) == 630)
    }

    @Test func offsetCanBeSetLater() {
        var timer = WaitTimer(startedAt: start)
        timer.offsetMinutes = 5
        #expect(timer.elapsed(at: start) == 300)
    }

    @Test func neverNegative() {
        let timer = WaitTimer(startedAt: start)
        #expect(timer.elapsed(at: start.addingTimeInterval(-50)) == 0)
        #expect(timer.text(at: start.addingTimeInterval(-50)) == "0:00")
    }

    @Test(arguments: [
        (0.0, "0:00"),
        (7.0, "0:07"),
        (7.9, "0:07"),
        (65.0, "1:05"),
        (725.0, "12:05"),
        (3599.0, "59:59"),
        (3600.0, "1:00:00"),
        (3725.0, "1:02:05"),
        (36_000.0, "10:00:00"),
    ])
    func textFormats(seconds: Double, text: String) {
        let timer = WaitTimer(startedAt: start)
        #expect(timer.text(at: start.addingTimeInterval(seconds)) == text)
    }

    @Test func textIncludesOffset() {
        let timer = WaitTimer(startedAt: start, offsetMinutes: 20)
        #expect(timer.text(at: start.addingTimeInterval(5)) == "20:05")
    }

    @Test func textWithTheLongestOffset() {
        let timer = WaitTimer(startedAt: start, offsetMinutes: StartOffset.maxMinutes)
        #expect(timer.text(at: start.addingTimeInterval(65)) == "1:31:05")
    }

    @Test func timeoutBoundary() {
        let timer = WaitTimer(startedAt: start)
        #expect(timer.isPastTimeout(at: start.addingTimeInterval(89 * 60 + 59)) == false)
        #expect(timer.isPastTimeout(at: start.addingTimeInterval(90 * 60)) == true)
    }

    @Test func timeoutIgnoresOffset() {
        let timer = WaitTimer(startedAt: start, offsetMinutes: 20)
        #expect(timer.isPastTimeout(at: start.addingTimeInterval(89 * 60 + 59)) == false)
        #expect(timer.isPastTimeout(at: start.addingTimeInterval(90 * 60)) == true)
    }

    @Test func customTimeout() {
        let timer = WaitTimer(startedAt: start)
        #expect(timer.isPastTimeout(at: start.addingTimeInterval(60), timeoutMinutes: 1) == true)
    }
}
