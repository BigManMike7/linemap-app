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
