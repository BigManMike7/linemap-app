import Foundation
import LineMapCore

/// A stand-in server for the screenshot UI test: canned bars and estimates, and
/// every write accepted. It never touches the real database.
nonisolated struct FixtureTransport: RPCTransport {
    func call(_ function: String, body: Data) async throws -> RPCResponse {
        let reply: String
        switch function {
        case "get_bars":
            reply = Self.bars
        case "get_estimates":
            reply = Self.estimates(now: Date())
        case "start_session":
            let parameters = try? JSONDecoder().decode(JSONValue.self, from: body)
            let session = parameters?["p_client_session_id"]?.stringValue ?? ""
            reply = #"{"ok": true, "client_session_id": "\#(session)", "status": "open", "already_open": false}"#
        case "end_session":
            reply = #"{"ok": true, "status": "entered", "measured_wait_seconds": 600}"#
        case "delete_my_data":
            reply = #"{"ok": true, "rows_removed": 7}"#
        case "my_recent_reports":
            reply = Self.recentReports(now: Date())
        case "delete_report":
            reply = #"{"ok": true, "rows_removed": 1}"#
        case "reopen_session":
            reply = #"{"ok": true, "status": "open", "reopened": true}"#
        case "bar_history":
            let parameters = try? JSONDecoder().decode(JSONValue.self, from: body)
            reply = Self.history(night: parameters?["p_night"]?.stringValue)
        default:
            reply = #"{"ok": true}"#
        }
        return RPCResponse(status: 200, body: Data(reply.utf8))
    }

    private static let bars = """
        [
          {"id": 1, "name": "Doggie's Pub", "address": "108 S Pugh St, State College, PA 16801",
           "door_lat": 40.7950443, "door_lon": -77.8602538, "size_class": "medium", "display_order": 1},
          {"id": 2, "name": "The Phyrst", "address": "111 E Beaver Ave, State College, PA 16801",
           "door_lat": 40.7937487, "door_lon": -77.8600643, "size_class": "medium", "display_order": 2},
          {"id": 3, "name": "Cafe 210 West", "address": "210 W College Ave, State College, PA 16801",
           "door_lat": 40.7931773, "door_lon": -77.8630037, "size_class": "medium", "display_order": 3}
        ]
        """

    /// A Report conditions at Cafe 210 and a timed wait at Doggie's (FR-41).
    private static func recentReports(now: Date) -> String {
        func ago(_ minutes: Double) -> String {
            ServerDate.format(now.addingTimeInterval(-minutes * 60))
        }
        return """
            [
              {"type": "report", "kind": "conditions",
               "client_report_id": "11111111-1111-4111-8111-111111111111", "bar_id": 3,
               "at": "\(ago(12))", "line_size": 2, "busyness": 3, "recalled_wait": null},
              {"type": "wait", "client_session_id": "22222222-2222-4222-8222-222222222222", "bar_id": 1,
               "at": "\(ago(95))", "ended_at": "\(ago(72))", "status": "entered",
               "measured_wait_seconds": 1380, "start_offset_minutes": 0, "line_size": 1, "busyness": null}
            ]
            """
    }

    /// Every night is a football Saturday: a few reports in the afternoon,
    /// nothing until after 9 p.m., then a line and wait that build to a peak
    /// near midnight and ease off, with one contradiction at 1:15 a.m.; the
    /// crowd drops out for a stretch. Points
    /// every 15 minutes from 4 a.m., like the server.
    private static func history(night: String?) -> String {
        let eastern = TimeZone(identifier: "America/New_York") ?? .current
        let tonight = NightDate(nightOf: Date(), timeZone: eastern)
        let shown = night.flatMap { NightDate($0) } ?? tonight
        // 4 a.m. Eastern daylight time is 08:00 UTC; 9 p.m. is 17 hours later.
        let dayStart = ServerDate.parse("\(shown)T08:00:00Z") ?? Date()
        let start = dayStart.addingTimeInterval(17 * 3600)
        var points: [String] = []
        for index in 0..<96 {
            let at = ServerDate.format(dayStart.addingTimeInterval(Double(index) * 900))
            let afternoon = (40...43).contains(index)    // 2:00 to 2:45 p.m.
            guard afternoon || (69...89).contains(index) else {
                points.append(#"{"at": "\#(at)", "people": 0, "line_size": null, "wait": null, "busyness": null}"#)
                continue
            }
            let peak = afternoon ? 0.1 : 1 - abs(Double(index - 80)) / 12
            // 1:15 a.m. is a contradiction: a 2-minute timer next to 50+ in line.
            let contradiction = index == 85
            let line = contradiction ? 4 : min(4, max(0, Int((peak * 4).rounded())))
            let minutes = contradiction ? 2 : max(2, Int(peak * 40))
            let wait = minutes < 5 ? 1 : minutes < 15 ? 2 : minutes < 30 ? 3 : 4
            let stale = index % 4 == 3 ? "stale" : "fresh"
            let crowd = (82...83).contains(index) ? "null"
                : #"{"code": \#(min(4, line + 1)), "freshness": "\#(stale)"}"#
            points.append(#"""
                {"at": "\#(at)", "people": \#(1 + line), \#
                "line_size": {"code": \#(line), "freshness": "\#(stale)"}, \#
                "wait": {"code": \#(wait), "minutes": \#(minutes), "freshness": "\#(stale)"}, \#
                "busyness": \#(crowd)}
                """#)
        }
        return """
            {"logic_version": 1, "bar_id": 1, "night": "\(shown)", "tonight": "\(tonight)",
             "start": "\(ServerDate.format(start))",
             "end": "\(ServerDate.format(start.addingTimeInterval(5 * 3600)))",
             "nights": ["2026-10-02", "2026-09-26", "2026-09-25"],
             "points": [\(points.joined(separator: ","))]}
            """
    }

    /// Doggie's: a fresh measured wait. The Phyrst: older (grayed) reports. Cafe 210: no data.
    private static func estimates(now: Date) -> String {
        func ago(_ minutes: Double) -> String {
            ServerDate.format(now.addingTimeInterval(-minutes * 60))
        }
        return """
            {
              "logic_version": 1,
              "generated_at": "\(ago(0))",
              "window_state": "live",
              "bars": [
                {"bar_id": 1, "display": "estimate", "freshness": "fresh", "people": 4,
                 "latest_at": "\(ago(3))",
                 "line_size": {"code": 2, "minutes": null, "source": "reported", "at": "\(ago(3))",
                               "freshness": "fresh", "rule": "newest"},
                 "wait": {"code": 3, "minutes": 25, "source": "measured", "at": "\(ago(10))",
                          "freshness": "fresh", "rule": "newest"},
                 "busyness": {"code": 3, "minutes": null, "source": "reported", "at": "\(ago(8))",
                              "freshness": "fresh", "rule": "newest"}},
                {"bar_id": 2, "display": "estimate", "freshness": "stale", "people": 2,
                 "latest_at": "\(ago(41))",
                 "line_size": {"code": 1, "minutes": null, "source": "reported", "at": "\(ago(41))",
                               "freshness": "stale", "rule": "newest"},
                 "wait": {"code": 2, "minutes": null, "source": "reported", "at": "\(ago(45))",
                          "freshness": "stale", "rule": "newest"},
                 "busyness": null},
                {"bar_id": 3, "display": "not_enough_data", "freshness": "none", "people": 0,
                 "latest_at": null, "line_size": null, "wait": null, "busyness": null}
              ]
            }
            """
    }
}
