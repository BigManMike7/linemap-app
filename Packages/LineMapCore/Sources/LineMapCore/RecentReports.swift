import Foundation

/// One of the person's own reports or finished timed waits from the last 24
/// hours, for Made a wrong report? in Settings (FR-41). Decode with
/// `JSONDecoder.lineMap`.
public struct MyReport: Decodable, Sendable, Hashable, Identifiable {
    /// What Delete removes: one report, or a whole wait session and its reports.
    public enum Target: Hashable, Sendable {
        case report(UUID)
        case wait(UUID)
    }

    public let target: Target
    public let barId: Int64
    /// Report time, or when the timer started.
    public let at: Date
    /// "conditions" or "inside" (older builds) for a report; nil for a wait.
    public let kind: String?
    /// "entered", "gave_up", or "unfinished" for a wait; nil for a report.
    public let status: String?
    public let measuredWaitSeconds: Int?
    public let lineSize: Int?
    public let busyness: Int?
    public let recalledWait: Int?

    public var id: Target { target }

    public init(target: Target, barId: Int64, at: Date, kind: String? = nil, status: String? = nil,
                measuredWaitSeconds: Int? = nil, lineSize: Int? = nil, busyness: Int? = nil,
                recalledWait: Int? = nil) {
        self.target = target
        self.barId = barId
        self.at = at
        self.kind = kind
        self.status = status
        self.measuredWaitSeconds = measuredWaitSeconds
        self.lineSize = lineSize
        self.busyness = busyness
        self.recalledWait = recalledWait
    }

    private enum CodingKeys: String, CodingKey {
        case type, kind, clientReportId, clientSessionId, barId, at, status,
             measuredWaitSeconds, lineSize, busyness, recalledWait
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "wait":
            target = .wait(try c.decode(UUID.self, forKey: .clientSessionId))
        default:
            target = .report(try c.decode(UUID.self, forKey: .clientReportId))
        }
        barId = try c.decode(Int64.self, forKey: .barId)
        at = try c.decode(Date.self, forKey: .at)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        measuredWaitSeconds = try c.decodeIfPresent(Int.self, forKey: .measuredWaitSeconds)
        lineSize = try c.decodeIfPresent(Int.self, forKey: .lineSize)
        busyness = try c.decodeIfPresent(Int.self, forKey: .busyness)
        recalledWait = try c.decodeIfPresent(Int.self, forKey: .recalledWait)
    }

    /// What the person said, e.g. "Waited 23 min · 10–25 in line" or
    /// "No line · Busy".
    public var summary: String {
        var parts: [String] = []
        if case .wait = target {
            switch status {
            case "entered":
                let minutes = Int((Double(measuredWaitSeconds ?? 0) / 60).rounded())
                parts.append("Waited \(minutes) min")
            case "gave_up": parts.append("Gave up on the line")
            default: parts.append("Timer not finished")
            }
        }
        if let size = lineSize.flatMap(LineSize.init(rawValue:)) {
            parts.append(size == .nobody ? Labels.option(size) : "\(Labels.option(size)) in line")
        }
        if let level = busyness.flatMap(Busyness.init(rawValue:)) {
            parts.append(Labels.option(level))
        }
        if let wait = recalledWait.flatMap(RecalledWait.init(rawValue:)) {
            parts.append("Got in: \(Labels.option(wait))")
        }
        if parts.isEmpty {
            parts.append(kind == "inside" ? "I'm inside" : "Report")
        }
        return parts.joined(separator: " · ")
    }
}

/// The reply to deleting one report (FR-41).
public enum DeleteReportResult: Sendable, Hashable {
    case deleted
    /// Already gone, someone else's, or older than 24 hours.
    case notFound
    /// The timer is still running; it's cancelled from the wait card instead.
    case sessionOpen
}
