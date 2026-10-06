import Foundation
import Testing
@testable import LineMapCore

private let anon = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
private let install = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
private let sessionA = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
private let sessionB = UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!
private let reportA = UUID(uuidString: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")!
private let openID = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
private let phoneTime = Date(timeIntervalSince1970: 1_800_000_000)

private func id(_ value: UUID) -> JSONValue { .string(value.uuidString.lowercased()) }
private let timeValue = JSONValue.string(ServerDate.format(phoneTime))
private let meta = ReportMeta(anonId: anon, installId: install, appVersion: "1.2.3")

private var metaParameters: [String: JSONValue] {
    [
        "p_anon_id": id(anon),
        "p_install_id": id(install),
        "p_app_version": .string("1.2.3"),
        "p_definitions_version": .number(2),
        "p_source": .string("app"),
    ]
}

private let deniedParameters: [String: JSONValue] = ["p_location_status": .string("denied")]

struct LocationFixTests {
    @Test func deniedHasOnlyStatus() {
        let call = PendingCall.endSession(EndSessionCall(
            clientSessionId: sessionA, anonId: anon, outcome: .entered, phoneTime: phoneTime,
            location: .denied))
        #expect(call.parameters["p_location_status"] == JSONValue.string("denied"))
        #expect(call.parameters["p_lat"] == nil)
        #expect(call.parameters["p_lon"] == nil)
        #expect(call.parameters["p_accuracy_m"] == nil)
        #expect(call.parameters["p_fix_age_s"] == nil)
    }

    @Test func noFixStatus() {
        #expect(LocationFix.noFix.parameters == ["p_location_status": .string("no_fix")])
    }

    @Test func preciseFix() {
        let fix = LocationFix(status: .precise, latitude: 40.5, longitude: -77.25,
                              accuracyMeters: 12, ageSeconds: 3)
        #expect(fix.parameters == [
            "p_location_status": .string("precise"),
            "p_lat": .number(40.5),
            "p_lon": .number(-77.25),
            "p_accuracy_m": .number(12),
            "p_fix_age_s": .number(3),
        ])
    }
}

struct CallParametersTests {
    @Test func startSessionMinimal() {
        let call = PendingCall.startSession(StartSessionCall(
            clientSessionId: sessionA, clientReportId: reportA, barId: 7, phoneTime: phoneTime,
            location: .denied, meta: meta))
        #expect(call.function == "start_session")
        var expected = metaParameters.merging(deniedParameters) { $1 }
        expected["p_client_session_id"] = id(sessionA)
        expected["p_client_report_id"] = id(reportA)
        expected["p_bar_id"] = .number(7)
        expected["p_phone_time"] = timeValue
        #expect(call.parameters == expected)
        #expect(call.parameters["p_line_size"] == nil)
        #expect(call.parameters["p_line_size_state"] == nil)
        #expect(call.parameters["p_start_offset_minutes"] == nil)
    }

    @Test func startSessionWithAnswers() {
        let fix = LocationFix(status: .precise, latitude: 40.5, longitude: -77.25,
                              accuracyMeters: 12, ageSeconds: 3)
        let call = PendingCall.startSession(StartSessionCall(
            clientSessionId: sessionA, clientReportId: reportA, barId: 7, phoneTime: phoneTime,
            location: fix, meta: meta, startOffsetMinutes: 10, lineSize: .answered(.tenTo25)))
        let p = call.parameters
        #expect(p["p_start_offset_minutes"] == JSONValue.number(10))
        #expect(p["p_line_size"] == JSONValue.number(2))
        #expect(p["p_line_size_state"] == JSONValue.string("answered"))
        #expect(p["p_lat"] == JSONValue.number(40.5))
        #expect(p["p_location_status"] == JSONValue.string("precise"))
    }

    @Test func startSessionCantTellHasStateButNoCode() {
        let call = PendingCall.startSession(StartSessionCall(
            clientSessionId: sessionA, clientReportId: reportA, barId: 7, phoneTime: phoneTime,
            location: .denied, meta: meta, lineSize: .cantTell))
        #expect(call.parameters["p_line_size"] == nil)
        #expect(call.parameters["p_line_size_state"] == JSONValue.string("cant_tell"))
    }

    @Test func updateLineSize() {
        let call = PendingCall.updateLineSize(UpdateLineSizeCall(
            clientReportId: reportA, clientSessionId: sessionA, phoneTime: phoneTime,
            location: .denied, meta: meta, lineSize: .answered(.fiftyPlus)))
        #expect(call.function == "update_line_size")
        var expected = metaParameters.merging(deniedParameters) { $1 }
        expected["p_client_report_id"] = id(reportA)
        expected["p_client_session_id"] = id(sessionA)
        expected["p_phone_time"] = timeValue
        expected["p_line_size"] = .number(4)
        expected["p_line_size_state"] = .string("answered")
        #expect(call.parameters == expected)
    }

    @Test func updateLineSizeSkippedOmitsCode() {
        let call = PendingCall.updateLineSize(UpdateLineSizeCall(
            clientReportId: reportA, clientSessionId: sessionA, phoneTime: phoneTime,
            location: .denied, meta: meta, lineSize: .skipped))
        #expect(call.parameters["p_line_size"] == nil)
        #expect(call.parameters["p_line_size_state"] == JSONValue.string("skipped"))
    }

    @Test func endSession() {
        let call = PendingCall.endSession(EndSessionCall(
            clientSessionId: sessionA, anonId: anon, outcome: .gaveUp, phoneTime: phoneTime,
            location: .noFix))
        #expect(call.function == "end_session")
        #expect(call.parameters == [
            "p_location_status": .string("no_fix"),
            "p_client_session_id": id(sessionA),
            "p_anon_id": id(anon),
            "p_outcome": .string("gave_up"),
            "p_phone_time": timeValue,
        ])
    }

    @Test func endSessionEntered() {
        let call = PendingCall.endSession(EndSessionCall(
            clientSessionId: sessionA, anonId: anon, outcome: .entered, phoneTime: phoneTime,
            location: .denied))
        #expect(call.parameters["p_outcome"] == JSONValue.string("entered"))
    }

    @Test func reopenSession() {
        let call = PendingCall.reopenSession(ReopenSessionCall(clientSessionId: sessionA, anonId: anon))
        #expect(call.function == "reopen_session")
        #expect(call.parameters == [
            "p_client_session_id": id(sessionA),
            "p_anon_id": id(anon),
        ])
        #expect(call.clientSessionId == sessionA)
        #expect(call.withLocation(.noFix) == call)
        #expect(call.replacingSession(sessionA, with: sessionB).clientSessionId == sessionB)
    }

    @Test func submitReportMinimal() {
        let call = PendingCall.submitReport(SubmitReportCall(
            clientReportId: reportA, barId: 3, phoneTime: phoneTime, location: .denied, meta: meta))
        #expect(call.function == "submit_report")
        var expected = metaParameters.merging(deniedParameters) { $1 }
        expected["p_client_report_id"] = id(reportA)
        expected["p_bar_id"] = .number(3)
        expected["p_phone_time"] = timeValue
        #expect(call.parameters == expected)
    }

    @Test func submitReportWithAnswersAndSession() {
        let call = PendingCall.submitReport(SubmitReportCall(
            clientReportId: reportA, barId: 3, phoneTime: phoneTime, location: .denied, meta: meta,
            clientSessionId: sessionA, busyness: .answered(.busy), recalledWait: .cantTell))
        let p = call.parameters
        #expect(p["p_client_session_id"] == id(sessionA))
        #expect(p["p_busyness"] == JSONValue.number(3))
        #expect(p["p_busyness_state"] == JSONValue.string("answered"))
        #expect(p["p_recalled_wait"] == nil)
        #expect(p["p_recalled_wait_state"] == JSONValue.string("cant_tell"))
    }

    @Test func reportConditionsBothAnswered() {
        let call = PendingCall.reportConditions(ReportConditionsCall(
            clientReportId: reportA, barId: 3, phoneTime: phoneTime, location: .denied, meta: meta,
            lineSize: .answered(.tenTo25), busyness: .answered(.packed)))
        #expect(call.function == "report_conditions")
        var expected = metaParameters.merging(deniedParameters) { $1 }
        expected["p_client_report_id"] = id(reportA)
        expected["p_bar_id"] = .number(3)
        expected["p_phone_time"] = timeValue
        expected["p_line_size"] = .number(2)
        expected["p_line_size_state"] = .string("answered")
        expected["p_busyness"] = .number(4)
        expected["p_busyness_state"] = .string("answered")
        #expect(call.parameters == expected)
        #expect(call.clientSessionId == nil)
    }

    @Test func reportConditionsSkippedAnswerHasStateButNoCode() {
        let call = PendingCall.reportConditions(ReportConditionsCall(
            clientReportId: reportA, barId: 3, phoneTime: phoneTime, location: .denied, meta: meta,
            lineSize: .skipped, busyness: .answered(.quiet)))
        let p = call.parameters
        #expect(p["p_line_size"] == nil)
        #expect(p["p_line_size_state"] == JSONValue.string("skipped"))
        #expect(p["p_busyness"] == JSONValue.number(1))
        #expect(p["p_busyness_state"] == JSONValue.string("answered"))
    }

    @Test func reportConditionsTakesALocation() {
        let fix = LocationFix(status: .precise, latitude: 40.5, longitude: -77.25,
                              accuracyMeters: 12, ageSeconds: 3)
        let call = PendingCall.reportConditions(ReportConditionsCall(
            clientReportId: reportA, barId: 3, phoneTime: phoneTime, location: .noFix, meta: meta,
            lineSize: .answered(.nobody), busyness: .skipped)).withLocation(fix)
        #expect(call.parameters["p_location_status"] == JSONValue.string("precise"))
        #expect(call.parameters["p_lat"] == JSONValue.number(40.5))
        // Line size 0 ("no line") is a real answer, not a missing one.
        #expect(call.parameters["p_line_size"] == JSONValue.number(0))
    }

    @Test func sendFeedback() {
        let shown = JSONValue.object(["display": .string("estimate")])
        let call = PendingCall.sendFeedback(SendFeedbackCall(
            anonId: anon, installId: install, barId: 4, phoneTime: phoneTime, estimateShown: shown))
        #expect(call.function == "send_feedback")
        #expect(call.parameters == [
            "p_anon_id": id(anon),
            "p_install_id": id(install),
            "p_bar_id": .number(4),
            "p_phone_time": timeValue,
            "p_estimate_shown": shown,
        ])
    }

    @Test func sendFeedbackWithoutEstimateOmitsKey() {
        let call = PendingCall.sendFeedback(SendFeedbackCall(
            anonId: anon, installId: install, barId: 4, phoneTime: phoneTime, estimateShown: nil))
        #expect(call.parameters["p_estimate_shown"] == nil)
    }

    @Test func registerInstall() {
        let call = PendingCall.registerInstall(RegisterInstallCall(
            anonId: anon, installId: install, appVersion: "1.2.3", iosVersion: "26.0",
            deviceModel: "iPhone17,1"))
        #expect(call.function == "register_install")
        #expect(call.parameters == [
            "p_anon_id": id(anon),
            "p_install_id": id(install),
            "p_app_version": .string("1.2.3"),
            "p_ios_version": .string("26.0"),
            "p_device_model": .string("iPhone17,1"),
        ])
    }

    @Test func logViewForBar() {
        let call = PendingCall.logView(LogViewCall(
            anonId: anon, installId: install, kind: .bar, barId: 5, appOpenId: openID,
            viewedAt: phoneTime, showedNoData: true, estimateShown: .null, logicVersion: 1))
        #expect(call.function == "log_view")
        #expect(call.parameters == [
            "p_anon_id": id(anon),
            "p_install_id": id(install),
            "p_view_kind": .string("bar"),
            "p_app_open_id": id(openID),
            "p_viewed_at": timeValue,
            "p_showed_no_data": .bool(true),
            "p_bar_id": .number(5),
            "p_estimate_shown": .null,
            "p_logic_version": .number(1),
        ])
    }

    @Test func logViewForMapOmitsOptionals() {
        let call = PendingCall.logView(LogViewCall(
            anonId: anon, installId: install, kind: .map, barId: nil, appOpenId: openID,
            viewedAt: phoneTime, showedNoData: false, estimateShown: nil, logicVersion: nil))
        #expect(call.parameters == [
            "p_anon_id": id(anon),
            "p_install_id": id(install),
            "p_view_kind": .string("map"),
            "p_app_open_id": id(openID),
            "p_viewed_at": timeValue,
            "p_showed_no_data": .bool(false),
        ])
    }

    @Test func uuidsAreLowercase() {
        let call = PendingCall.endSession(EndSessionCall(
            clientSessionId: sessionA, anonId: anon, outcome: .entered, phoneTime: phoneTime,
            location: .denied))
        #expect(call.parameters["p_anon_id"] == JSONValue.string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    }
}

struct CallEditingTests {
    private func start(session: UUID) -> PendingCall {
        .startSession(StartSessionCall(
            clientSessionId: session, clientReportId: reportA, barId: 7, phoneTime: phoneTime,
            location: .denied, meta: meta))
    }

    @Test func replacingSessionChangesMatchingCalls() {
        let calls: [PendingCall] = [
            start(session: sessionA),
            .updateLineSize(UpdateLineSizeCall(
                clientReportId: reportA, clientSessionId: sessionA, phoneTime: phoneTime,
                location: .denied, meta: meta, lineSize: .skipped)),
            .endSession(EndSessionCall(
                clientSessionId: sessionA, anonId: anon, outcome: .entered, phoneTime: phoneTime,
                location: .denied)),
            .submitReport(SubmitReportCall(
                clientReportId: reportA, barId: 7, phoneTime: phoneTime, location: .denied,
                meta: meta, clientSessionId: sessionA)),
        ]
        for call in calls {
            let replaced = call.replacingSession(sessionA, with: sessionB)
            #expect(replaced.clientSessionId == sessionB)
            #expect(replaced.function == call.function)
        }
    }

    @Test func replacingSessionLeavesOtherCallsAlone() {
        let other = start(session: sessionB)
        #expect(other.replacingSession(sessionA, with: reportA) == other)

        let noSession = PendingCall.submitReport(SubmitReportCall(
            clientReportId: reportA, barId: 7, phoneTime: phoneTime, location: .denied, meta: meta))
        #expect(noSession.replacingSession(sessionA, with: sessionB) == noSession)

        let conditions = PendingCall.reportConditions(ReportConditionsCall(
            clientReportId: reportA, barId: 7, phoneTime: phoneTime, location: .denied, meta: meta,
            lineSize: .skipped, busyness: .answered(.busy)))
        #expect(conditions.replacingSession(sessionA, with: sessionB) == conditions)

        let feedback = PendingCall.sendFeedback(SendFeedbackCall(
            anonId: anon, installId: install, barId: 4, phoneTime: phoneTime, estimateShown: nil))
        #expect(feedback.replacingSession(sessionA, with: sessionB) == feedback)
    }

    @Test func replacingSessionKeepsEverythingElse() {
        let replaced = start(session: sessionA).replacingSession(sessionA, with: sessionB)
        #expect(replaced == start(session: sessionB))
    }

    @Test func clientSessionIDs() {
        #expect(start(session: sessionA).clientSessionId == sessionA)
        let register = PendingCall.registerInstall(RegisterInstallCall(
            anonId: anon, installId: install, appVersion: "1", iosVersion: "26", deviceModel: "x"))
        #expect(register.clientSessionId == nil)
    }

    @Test func withLocationReplacesTheFix() {
        let fix = LocationFix(status: .approximate, latitude: 1, longitude: 2)
        let call = start(session: sessionA).withLocation(fix)
        #expect(call.parameters["p_location_status"] == JSONValue.string("approximate"))
        #expect(call.parameters["p_lat"] == JSONValue.number(1))
        #expect(call.parameters["p_lon"] == JSONValue.number(2))
    }

    @Test func withLocationCoversEveryLocatedCall() {
        let fix = LocationFix.noFix
        let calls: [PendingCall] = [
            .updateLineSize(UpdateLineSizeCall(
                clientReportId: reportA, clientSessionId: sessionA, phoneTime: phoneTime,
                location: .denied, meta: meta, lineSize: .skipped)),
            .endSession(EndSessionCall(
                clientSessionId: sessionA, anonId: anon, outcome: .entered, phoneTime: phoneTime,
                location: .denied)),
            .submitReport(SubmitReportCall(
                clientReportId: reportA, barId: 7, phoneTime: phoneTime, location: .denied, meta: meta)),
        ]
        for call in calls {
            #expect(call.withLocation(fix).parameters["p_location_status"] == JSONValue.string("no_fix"))
        }
    }

    @Test func withLocationLeavesUnlocatedCallsAlone() {
        let feedback = PendingCall.sendFeedback(SendFeedbackCall(
            anonId: anon, installId: install, barId: 4, phoneTime: phoneTime, estimateShown: nil))
        #expect(feedback.withLocation(.noFix) == feedback)
    }
}

struct CallEncodingTests {
    @Test func wholeNumbersHaveNoDecimalPoint() throws {
        let data = try JSONEncoder().encode(JSONValue.number(42))
        #expect(String(decoding: data, as: UTF8.self) == "42")
    }

    @Test func fractionsAreKept() throws {
        let data = try JSONEncoder().encode(JSONValue.number(40.5))
        #expect(String(decoding: data, as: UTF8.self) == "40.5")
    }

    @Test func parametersEncodeIntegersInsideObjects() throws {
        let call = PendingCall.endSession(EndSessionCall(
            clientSessionId: sessionA, anonId: anon, outcome: .entered, phoneTime: phoneTime,
            location: LocationFix(status: .precise, latitude: 40.5, longitude: -77, accuracyMeters: 10, ageSeconds: 2)))
        let data = try JSONEncoder().encode(call.parameters)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"p_accuracy_m\":10"))
        #expect(!text.contains("10.0"))
        #expect(text.contains("\"p_lat\":40.5"))
    }

    @Test func jsonValueRoundTrips() throws {
        let value = JSONValue.object([
            "a": .number(1),
            "b": .string("x"),
            "c": .bool(true),
            "d": .null,
            "e": .array([.number(2.5)]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func pendingCallRoundTrip() throws {
        let fix = LocationFix(status: .precise, latitude: 40.5, longitude: -77.25,
                              accuracyMeters: 12, ageSeconds: 3)
        let calls: [PendingCall] = [
            .startSession(StartSessionCall(
                clientSessionId: sessionA, clientReportId: reportA, barId: 7, phoneTime: phoneTime,
                location: fix, meta: meta, startOffsetMinutes: 5, lineSize: .answered(.oneToTen))),
            .updateLineSize(UpdateLineSizeCall(
                clientReportId: reportA, clientSessionId: sessionA, phoneTime: phoneTime,
                location: .denied, meta: meta, lineSize: .cantTell)),
            .endSession(EndSessionCall(
                clientSessionId: sessionA, anonId: anon, outcome: .gaveUp, phoneTime: phoneTime,
                location: .noFix)),
            .submitReport(SubmitReportCall(
                clientReportId: reportA, barId: 3, phoneTime: phoneTime, location: fix, meta: meta,
                clientSessionId: sessionB, busyness: .answered(.packed), recalledWait: .skipped)),
            .reportConditions(ReportConditionsCall(
                clientReportId: reportA, barId: 3, phoneTime: phoneTime, location: fix, meta: meta,
                lineSize: .answered(.nobody), busyness: .skipped)),
            .registerInstall(RegisterInstallCall(
                anonId: anon, installId: install, appVersion: "1.2.3", iosVersion: "26.0",
                deviceModel: "iPhone17,1")),
            .logView(LogViewCall(
                anonId: anon, installId: install, kind: .map, barId: nil, appOpenId: openID,
                viewedAt: phoneTime, showedNoData: false, estimateShown: nil, logicVersion: 1)),
            .sendFeedback(SendFeedbackCall(
                anonId: anon, installId: install, barId: 4, phoneTime: phoneTime, estimateShown: nil)),
        ]
        for call in calls {
            let data = try JSONEncoder.lineMap.encode(call)
            let decoded = try JSONDecoder.lineMap.decode(PendingCall.self, from: data)
            #expect(decoded == call)
        }
    }
}
