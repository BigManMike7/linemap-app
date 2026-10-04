import Foundation
import Testing
@testable import LineMapCore

private let anon = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
private let reportId = UUID(uuidString: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")!
private let sessionId = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
private let at = Date(timeIntervalSince1970: 1_800_000_000)

private func report(lineSize: Int? = nil, busyness: Int? = nil, recalledWait: Int? = nil,
                    kind: String = "conditions") -> MyReport {
    MyReport(target: .report(reportId), barId: 1, at: at, kind: kind, lineSize: lineSize,
             busyness: busyness, recalledWait: recalledWait)
}

private func wait(status: String, seconds: Int? = nil, lineSize: Int? = nil, busyness: Int? = nil) -> MyReport {
    MyReport(target: .wait(sessionId), barId: 1, at: at, status: status, measuredWaitSeconds: seconds,
             lineSize: lineSize, busyness: busyness)
}

struct MyReportDecodingTests {
    @Test func decodesBothShapes() throws {
        let json = """
            [
              {"type": "wait", "client_session_id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc", "bar_id": 2,
               "at": "2026-10-03T22:42:00-04:00", "ended_at": "2026-10-03T23:05:00-04:00",
               "status": "entered", "measured_wait_seconds": 1380, "start_offset_minutes": 0,
               "line_size": 2, "busyness": null},
              {"type": "report", "kind": "conditions", "client_report_id": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
               "bar_id": 1, "at": "2026-10-03T22:30:00-04:00", "line_size": 0, "busyness": 3,
               "recalled_wait": null}
            ]
            """
        let items = try JSONDecoder.lineMap.decode([MyReport].self, from: Data(json.utf8))
        #expect(items.count == 2)
        #expect(items[0].target == .wait(sessionId))
        #expect(items[0].barId == 2)
        #expect(items[0].status == "entered")
        #expect(items[0].measuredWaitSeconds == 1380)
        #expect(items[0].lineSize == 2)
        #expect(items[0].busyness == nil)
        #expect(items[1].target == .report(reportId))
        #expect(items[1].kind == "conditions")
        #expect(items[1].lineSize == 0)
        #expect(items[1].busyness == 3)
        let expected = try #require(ServerDate.parse("2026-10-03T22:30:00-04:00"))
        #expect(items[1].at == expected)
    }

    @Test func decodesAnEmptyList() throws {
        let items = try JSONDecoder.lineMap.decode([MyReport].self, from: Data("[]".utf8))
        #expect(items.isEmpty)
    }
}

struct MyReportSummaryTests {
    @Test(arguments: [
        (report(lineSize: 2, busyness: 3), "10–25 in line · Busy"),
        (report(lineSize: 0), "No line"),
        (report(busyness: 4), "Packed"),
        (report(busyness: 1, recalledWait: 2, kind: "inside"), "Quiet · Got in: 5–15 min"),
        (report(kind: "inside"), "I'm inside"),
        (wait(status: "entered", seconds: 1380, lineSize: 1), "Waited 23 min · 1–10 in line"),
        (wait(status: "entered", seconds: 1410, busyness: 2), "Waited 24 min · Comfortable"),
        (wait(status: "gave_up"), "Gave up on the line"),
        (wait(status: "unfinished"), "Timer not finished"),
    ])
    func summary(item: MyReport, text: String) {
        #expect(item.summary == text)
    }
}

struct DeleteReportTests {
    @Test func sendsTheReportID() async throws {
        let transport = ScriptedTransport()
        transport.push(.json(200, #"{"ok": true, "rows_removed": 1}"#))
        let result = try await APIClient(transport: transport).deleteReport(anonId: anon, target: .report(reportId))
        #expect(result == .deleted)
        #expect(transport.functions == ["delete_report"])
        let parameters = try #require(transport.sent.first?.parameters)
        #expect(parameters["p_anon_id"] == .string(anon.uuidString.lowercased()))
        #expect(parameters["p_client_report_id"] == .string(reportId.uuidString.lowercased()))
        #expect(parameters["p_client_session_id"] == nil)
    }

    @Test func sendsTheSessionID() async throws {
        let transport = ScriptedTransport()
        transport.push(.json(200, #"{"ok": true, "rows_removed": 3}"#))
        _ = try await APIClient(transport: transport).deleteReport(anonId: anon, target: .wait(sessionId))
        let parameters = try #require(transport.sent.first?.parameters)
        #expect(parameters["p_client_session_id"] == .string(sessionId.uuidString.lowercased()))
        #expect(parameters["p_client_report_id"] == nil)
    }

    @Test(arguments: [
        (#"{"ok": false, "error": "not_found"}"#, DeleteReportResult.notFound),
        (#"{"ok": false, "error": "session_open"}"#, DeleteReportResult.sessionOpen),
    ])
    func refusals(body: String, result: DeleteReportResult) async throws {
        let transport = ScriptedTransport()
        transport.push(.json(200, body))
        let reply = try await APIClient(transport: transport).deleteReport(anonId: anon, target: .report(reportId))
        #expect(reply == result)
    }

    @Test func unknownErrorThrows() async {
        let transport = ScriptedTransport()
        transport.push(.json(200, #"{"ok": false, "error": "something_else"}"#))
        await #expect(throws: APIError.badReply) {
            try await APIClient(transport: transport).deleteReport(anonId: anon, target: .report(reportId))
        }
    }

    @Test func listsRecentReports() async throws {
        let transport = ScriptedTransport()
        transport.push(.json(200, "[]"))
        let items = try await APIClient(transport: transport).myRecentReports(anonId: anon)
        #expect(items.isEmpty)
        #expect(transport.functions == ["my_recent_reports"])
    }
}
