import Foundation

// The writes the app sends through the offline queue (FR-16), one type per
// server function in PRD 7.2. Each carries client-generated IDs, so a retry
// never saves anything twice. `parameters` builds the exact named arguments of
// the SQL function; nil values are left out so server defaults apply.
//
// Codable conformance is for the queue's file on disk. Property names use "Id",
// not "ID", so they survive snake_case conversion.

/// Where the phone was when a report was made (FR-25). The server turns this
/// into distance and direction, then discards the coordinates (FR-26).
public struct LocationFix: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable {
        case precise
        case approximate
        case denied
        case noFix = "no_fix"
    }

    public var status: Status
    public var latitude: Double?
    public var longitude: Double?
    public var accuracyMeters: Double?
    public var ageSeconds: Double?

    public init(status: Status, latitude: Double? = nil, longitude: Double? = nil,
                accuracyMeters: Double? = nil, ageSeconds: Double? = nil) {
        self.status = status
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.ageSeconds = ageSeconds
    }

    public static let denied = LocationFix(status: .denied)
    public static let noFix = LocationFix(status: .noFix)

    var parameters: [String: JSONValue] {
        var p: [String: JSONValue] = ["p_location_status": .string(status.rawValue)]
        p["p_lat"] = latitude.map(JSONValue.number)
        p["p_lon"] = longitude.map(JSONValue.number)
        p["p_accuracy_m"] = accuracyMeters.map(JSONValue.number)
        p["p_fix_age_s"] = ageSeconds.map(JSONValue.number)
        return p
    }
}

/// Values every report carries (NFR-10).
public struct ReportMeta: Codable, Sendable, Hashable {
    public var anonId: UUID
    public var installId: UUID
    public var appVersion: String
    public var definitionsVersion: Int
    public var source: String

    public init(anonId: UUID, installId: UUID, appVersion: String,
                definitionsVersion: Int = Definitions.version, source: String = "app") {
        self.anonId = anonId
        self.installId = installId
        self.appVersion = appVersion
        self.definitionsVersion = definitionsVersion
        self.source = source
    }
}

/// Start line timer (FR-6). Re-send with the same `clientSessionId` to save
/// Adjust time (FR-7) or the first line-size answer.
public struct StartSessionCall: Codable, Sendable, Hashable {
    public var clientSessionId: UUID
    public var clientReportId: UUID
    public var barId: Int64
    public var phoneTime: Date
    public var location: LocationFix
    public var meta: ReportMeta
    public var startOffsetMinutes: Int?
    public var lineSize: Int?
    public var lineSizeState: AnswerState?

    public init(clientSessionId: UUID, clientReportId: UUID, barId: Int64, phoneTime: Date,
                location: LocationFix, meta: ReportMeta, startOffsetMinutes: Int? = nil,
                lineSize: Answer<LineSize>? = nil) {
        self.clientSessionId = clientSessionId
        self.clientReportId = clientReportId
        self.barId = barId
        self.phoneTime = phoneTime
        self.location = location
        self.meta = meta
        self.startOffsetMinutes = startOffsetMinutes
        self.lineSize = lineSize?.code
        self.lineSizeState = lineSize?.state
    }
}

/// A line-size update in an open session (FR-13 exempt). Re-send the same
/// `clientReportId` to change the answer.
public struct UpdateLineSizeCall: Codable, Sendable, Hashable {
    public var clientReportId: UUID
    public var clientSessionId: UUID
    public var phoneTime: Date
    public var location: LocationFix
    public var meta: ReportMeta
    public var lineSize: Int?
    public var lineSizeState: AnswerState

    public init(clientReportId: UUID, clientSessionId: UUID, phoneTime: Date,
                location: LocationFix, meta: ReportMeta, lineSize: Answer<LineSize>) {
        self.clientReportId = clientReportId
        self.clientSessionId = clientSessionId
        self.phoneTime = phoneTime
        self.location = location
        self.meta = meta
        self.lineSize = lineSize.code
        self.lineSizeState = lineSize.state
    }
}

/// I'm in (FR-8) or Gave up (FR-9).
public struct EndSessionCall: Codable, Sendable, Hashable {
    public enum Outcome: String, Codable, Sendable, Hashable {
        case entered
        case gaveUp = "gave_up"
    }

    public var clientSessionId: UUID
    public var anonId: UUID
    public var outcome: Outcome
    public var phoneTime: Date
    public var location: LocationFix

    public init(clientSessionId: UUID, anonId: UUID, outcome: Outcome, phoneTime: Date,
                location: LocationFix) {
        self.clientSessionId = clientSessionId
        self.anonId = anonId
        self.outcome = outcome
        self.phoneTime = phoneTime
        self.location = location
    }
}

/// Cancel a line started by mistake (FR-39): the server deletes the session and its reports.
public struct CancelSessionCall: Codable, Sendable, Hashable {
    public var clientSessionId: UUID
    public var anonId: UUID

    public init(clientSessionId: UUID, anonId: UUID) {
        self.clientSessionId = clientSessionId
        self.anonId = anonId
    }
}

/// Report conditions (FR-11): line size and crowd, either one optional, sent
/// once. It never touches a wait session.
public struct ReportConditionsCall: Codable, Sendable, Hashable {
    public var clientReportId: UUID
    public var barId: Int64
    public var phoneTime: Date
    public var location: LocationFix
    public var meta: ReportMeta
    public var lineSize: Int?
    public var lineSizeState: AnswerState
    public var busyness: Int?
    public var busynessState: AnswerState

    public init(clientReportId: UUID, barId: Int64, phoneTime: Date, location: LocationFix,
                meta: ReportMeta, lineSize: Answer<LineSize>, busyness: Answer<Busyness>) {
        self.clientReportId = clientReportId
        self.barId = barId
        self.phoneTime = phoneTime
        self.location = location
        self.meta = meta
        self.lineSize = lineSize.code
        self.lineSizeState = lineSize.state
        self.busyness = busyness.code
        self.busynessState = busyness.state
    }
}

/// I'm inside (FR-11, FR-15), or the busyness answer after I'm in. The app
/// stopped sending these on 2026-10-04 (Report conditions replaced them); the
/// type stays so a call queued by an older build still decodes and sends.
public struct SubmitReportCall: Codable, Sendable, Hashable {
    public var clientReportId: UUID
    public var barId: Int64
    public var phoneTime: Date
    public var location: LocationFix
    public var meta: ReportMeta
    public var clientSessionId: UUID?
    public var busyness: Int?
    public var busynessState: AnswerState?
    public var recalledWait: Int?
    public var recalledWaitState: AnswerState?

    public init(clientReportId: UUID, barId: Int64, phoneTime: Date, location: LocationFix,
                meta: ReportMeta, clientSessionId: UUID? = nil,
                busyness: Answer<Busyness>? = nil, recalledWait: Answer<RecalledWait>? = nil) {
        self.clientReportId = clientReportId
        self.barId = barId
        self.phoneTime = phoneTime
        self.location = location
        self.meta = meta
        self.clientSessionId = clientSessionId
        self.busyness = busyness?.code
        self.busynessState = busyness?.state
        self.recalledWait = recalledWait?.code
        self.recalledWaitState = recalledWait?.state
    }
}

/// "This looks wrong" (FR-35).
public struct SendFeedbackCall: Codable, Sendable, Hashable {
    public var anonId: UUID
    public var installId: UUID
    public var barId: Int64
    public var phoneTime: Date
    public var estimateShown: JSONValue?

    public init(anonId: UUID, installId: UUID, barId: Int64, phoneTime: Date, estimateShown: JSONValue?) {
        self.anonId = anonId
        self.installId = installId
        self.barId = barId
        self.phoneTime = phoneTime
        self.estimateShown = estimateShown
    }
}

/// On launch (FR-29, FR-30).
public struct RegisterInstallCall: Codable, Sendable, Hashable {
    public var anonId: UUID
    public var installId: UUID
    public var appVersion: String
    public var iosVersion: String
    public var deviceModel: String

    public init(anonId: UUID, installId: UUID, appVersion: String, iosVersion: String, deviceModel: String) {
        self.anonId = anonId
        self.installId = installId
        self.appVersion = appVersion
        self.iosVersion = iosVersion
        self.deviceModel = deviceModel
    }
}

/// A map or bar-sheet view (FR-34).
public struct LogViewCall: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case map
        case bar
    }

    public var anonId: UUID
    public var installId: UUID
    public var kind: Kind
    public var barId: Int64?
    public var appOpenId: UUID
    public var viewedAt: Date
    public var showedNoData: Bool
    public var estimateShown: JSONValue?
    public var logicVersion: Int?

    public init(anonId: UUID, installId: UUID, kind: Kind, barId: Int64?, appOpenId: UUID,
                viewedAt: Date, showedNoData: Bool, estimateShown: JSONValue?, logicVersion: Int?) {
        self.anonId = anonId
        self.installId = installId
        self.kind = kind
        self.barId = barId
        self.appOpenId = appOpenId
        self.viewedAt = viewedAt
        self.showedNoData = showedNoData
        self.estimateShown = estimateShown
        self.logicVersion = logicVersion
    }
}

/// One queued write.
public enum PendingCall: Codable, Sendable, Hashable {
    case startSession(StartSessionCall)
    case updateLineSize(UpdateLineSizeCall)
    case endSession(EndSessionCall)
    case submitReport(SubmitReportCall)
    case sendFeedback(SendFeedbackCall)
    case registerInstall(RegisterInstallCall)
    case logView(LogViewCall)
    case cancelSession(CancelSessionCall)
    case reportConditions(ReportConditionsCall)

    /// The SQL function this call runs.
    public var function: String {
        switch self {
        case .startSession: "start_session"
        case .updateLineSize: "update_line_size"
        case .endSession: "end_session"
        case .submitReport: "submit_report"
        case .reportConditions: "report_conditions"
        case .sendFeedback: "send_feedback"
        case .registerInstall: "register_install"
        case .logView: "log_view"
        case .cancelSession: "cancel_session"
        }
    }

    /// The function's named arguments.
    public var parameters: [String: JSONValue] {
        switch self {
        case .startSession(let c):
            var p = c.location.parameters.merging(c.meta.reportParameters) { $1 }
            p["p_client_session_id"] = .uuid(c.clientSessionId)
            p["p_client_report_id"] = .uuid(c.clientReportId)
            p["p_bar_id"] = .int(c.barId)
            p["p_phone_time"] = .date(c.phoneTime)
            p["p_start_offset_minutes"] = c.startOffsetMinutes.map { .int(Int64($0)) }
            p["p_line_size"] = c.lineSize.map { .int(Int64($0)) }
            p["p_line_size_state"] = c.lineSizeState.map { .string($0.rawValue) }
            return p
        case .updateLineSize(let c):
            var p = c.location.parameters.merging(c.meta.reportParameters) { $1 }
            p["p_client_report_id"] = .uuid(c.clientReportId)
            p["p_client_session_id"] = .uuid(c.clientSessionId)
            p["p_phone_time"] = .date(c.phoneTime)
            p["p_line_size"] = c.lineSize.map { .int(Int64($0)) }
            p["p_line_size_state"] = .string(c.lineSizeState.rawValue)
            return p
        case .cancelSession(let c):
            return [
                "p_client_session_id": .uuid(c.clientSessionId),
                "p_anon_id": .uuid(c.anonId),
            ]
        case .endSession(let c):
            var p = c.location.parameters
            p["p_client_session_id"] = .uuid(c.clientSessionId)
            p["p_anon_id"] = .uuid(c.anonId)
            p["p_outcome"] = .string(c.outcome.rawValue)
            p["p_phone_time"] = .date(c.phoneTime)
            return p
        case .submitReport(let c):
            var p = c.location.parameters.merging(c.meta.reportParameters) { $1 }
            p["p_client_report_id"] = .uuid(c.clientReportId)
            p["p_bar_id"] = .int(c.barId)
            p["p_phone_time"] = .date(c.phoneTime)
            p["p_client_session_id"] = c.clientSessionId.map(JSONValue.uuid)
            p["p_busyness"] = c.busyness.map { .int(Int64($0)) }
            p["p_busyness_state"] = c.busynessState.map { .string($0.rawValue) }
            p["p_recalled_wait"] = c.recalledWait.map { .int(Int64($0)) }
            p["p_recalled_wait_state"] = c.recalledWaitState.map { .string($0.rawValue) }
            return p
        case .reportConditions(let c):
            var p = c.location.parameters.merging(c.meta.reportParameters) { $1 }
            p["p_client_report_id"] = .uuid(c.clientReportId)
            p["p_bar_id"] = .int(c.barId)
            p["p_phone_time"] = .date(c.phoneTime)
            p["p_line_size"] = c.lineSize.map { .int(Int64($0)) }
            p["p_line_size_state"] = .string(c.lineSizeState.rawValue)
            p["p_busyness"] = c.busyness.map { .int(Int64($0)) }
            p["p_busyness_state"] = .string(c.busynessState.rawValue)
            return p
        case .sendFeedback(let c):
            var p: [String: JSONValue] = [
                "p_anon_id": .uuid(c.anonId),
                "p_install_id": .uuid(c.installId),
                "p_bar_id": .int(c.barId),
                "p_phone_time": .date(c.phoneTime),
            ]
            p["p_estimate_shown"] = c.estimateShown
            return p
        case .registerInstall(let c):
            return [
                "p_anon_id": .uuid(c.anonId),
                "p_install_id": .uuid(c.installId),
                "p_app_version": .string(c.appVersion),
                "p_ios_version": .string(c.iosVersion),
                "p_device_model": .string(c.deviceModel),
            ]
        case .logView(let c):
            var p: [String: JSONValue] = [
                "p_anon_id": .uuid(c.anonId),
                "p_install_id": .uuid(c.installId),
                "p_view_kind": .string(c.kind.rawValue),
                "p_app_open_id": .uuid(c.appOpenId),
                "p_viewed_at": .date(c.viewedAt),
                "p_showed_no_data": .bool(c.showedNoData),
            ]
            p["p_bar_id"] = c.barId.map(JSONValue.int)
            p["p_estimate_shown"] = c.estimateShown
            p["p_logic_version"] = c.logicVersion.map { .int(Int64($0)) }
            return p
        }
    }

    /// The wait session this call refers to, if any.
    public var clientSessionId: UUID? {
        switch self {
        case .startSession(let c): c.clientSessionId
        case .updateLineSize(let c): c.clientSessionId
        case .endSession(let c): c.clientSessionId
        case .cancelSession(let c): c.clientSessionId
        case .submitReport(let c): c.clientSessionId
        case .reportConditions, .sendFeedback, .registerInstall, .logView: nil
        }
    }

    /// The same call pointed at a different session. Used when the server keeps an
    /// already-open session instead of the one the phone started.
    public func replacingSession(_ old: UUID, with new: UUID) -> PendingCall {
        switch self {
        case .startSession(var c) where c.clientSessionId == old:
            c.clientSessionId = new
            return .startSession(c)
        case .updateLineSize(var c) where c.clientSessionId == old:
            c.clientSessionId = new
            return .updateLineSize(c)
        case .endSession(var c) where c.clientSessionId == old:
            c.clientSessionId = new
            return .endSession(c)
        case .submitReport(var c) where c.clientSessionId == old:
            c.clientSessionId = new
            return .submitReport(c)
        case .cancelSession(var c) where c.clientSessionId == old:
            c.clientSessionId = new
            return .cancelSession(c)
        default:
            return self
        }
    }

    /// The same call with a location attached, for calls that carry one.
    public func withLocation(_ fix: LocationFix) -> PendingCall {
        switch self {
        case .startSession(var c): c.location = fix; return .startSession(c)
        case .updateLineSize(var c): c.location = fix; return .updateLineSize(c)
        case .endSession(var c): c.location = fix; return .endSession(c)
        case .submitReport(var c): c.location = fix; return .submitReport(c)
        case .reportConditions(var c): c.location = fix; return .reportConditions(c)
        case .sendFeedback, .registerInstall, .logView, .cancelSession: return self
        }
    }
}

extension ReportMeta {
    var reportParameters: [String: JSONValue] {
        [
            "p_anon_id": .uuid(anonId),
            "p_install_id": .uuid(installId),
            "p_app_version": .string(appVersion),
            "p_definitions_version": .int(Int64(definitionsVersion)),
            "p_source": .string(source),
        ]
    }
}

extension JSONValue {
    static func uuid(_ value: UUID) -> JSONValue { .string(value.uuidString.lowercased()) }
    static func int(_ value: Int64) -> JSONValue { .number(Double(value)) }
    static func date(_ value: Date) -> JSONValue { .string(ServerDate.format(value)) }
}
