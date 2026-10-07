import Foundation
import Testing
@testable import LineMapCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func minutesBefore(_ minutes: Double) -> Date {
    now.addingTimeInterval(-minutes * 60)
}

struct LineSizeSaveTests {
    @Test func aDifferentSizeAlwaysSends() {
        #expect(LineSizeSave.sends(.twentyFiveTo50, last: .tenTo25, lastSentAt: minutesBefore(1), now: now))
        #expect(LineSizeSave.sends(.oneToTen, last: nil, lastSentAt: nil, now: now))
    }

    @Test func theFirstAnswerOnTheOpeningNoLineIsNoChange() {
        #expect(!LineSizeSave.sends(.nobody, last: nil, lastSentAt: nil, now: now))
    }

    @Test(arguments: [0.0, 1, 4.99])
    func theSameSizeWithin5MinutesIsNoChange(minutes: Double) {
        #expect(!LineSizeSave.sends(.tenTo25, last: .tenTo25, lastSentAt: minutesBefore(minutes), now: now))
    }

    @Test(arguments: [5.0, 6, 30])
    func theSameSizeAfter5MinutesSends(minutes: Double) {
        #expect(LineSizeSave.sends(.tenTo25, last: .tenTo25, lastSentAt: minutesBefore(minutes), now: now))
    }

    @Test func aSendStartsThe5MinutesOver() {
        // Sent again 6 minutes later, then a mid-spin Save 1 minute after that.
        let resentAt = minutesBefore(1)
        #expect(!LineSizeSave.sends(.tenTo25, last: .tenTo25, lastSentAt: resentAt, now: now))
    }

    @Test func aClockThatWentBackIsNoChange() {
        #expect(!LineSizeSave.sends(.tenTo25, last: .tenTo25, lastSentAt: now.addingTimeInterval(600), now: now))
    }

    @Test func theThankYouNamesTheSize() {
        #expect(LineSizeSave.thanks(.tenTo25, online: true) == "Thanks! 10–25 in line is now visible to everyone.")
        #expect(LineSizeSave.thanks(.nobody, online: true) == "Thanks! No line is now visible to everyone.")
        #expect(LineSizeSave.thanks(.hundredPlus, online: false) == "Thanks! 100+ in line will send when you're back online.")
    }
}
