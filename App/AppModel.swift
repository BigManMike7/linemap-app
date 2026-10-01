import Foundation
import LineMapCore
import Network
import Observation
import UIKit

/// The open wait session on this phone (FR-4). Saved to disk so the wait card
/// comes back every time the app opens.
nonisolated struct ActiveWait: Codable, Hashable {
    var clientSessionId: UUID
    var startReportId: UUID
    var barId: Int64
    var startedAt: Date
    var offset: StartOffset?

    var timer: WaitTimer { WaitTimer(startedAt: startedAt, offset: offset) }
}

/// An I'm inside report whose answers are still being given. Each answer re-sends
/// the same report ID, so it is saved as soon as it's given (FR-12).
nonisolated struct InsideReport: Hashable {
    let reportId: UUID
    let barId: Int64
    let phoneTime: Date
    /// Set for the busyness answer after I'm in.
    let sessionId: UUID?
    /// False when the wait was timed (FR-11).
    let asksRecalledWait: Bool
    /// The busyness question after I'm in sends nothing until it's answered.
    var isSent: Bool
    var busyness: Answer<Busyness>?
}

/// A question shown in a sheet.
nonisolated enum Question: Hashable {
    case lineSize(LineSizeQuestion)
    case startOffset
    case busyness(InsideReport)
    case recalledWait(InsideReport)
}

nonisolated enum LineSizeQuestion: Hashable {
    /// The first answer after I'm in line, saved on the session's start report.
    case start
    /// An update from the wait card.
    case update
}

nonisolated enum AppSheet: Hashable, Identifiable {
    case bar(Int64)
    case question(Question)
    case settings

    var id: Self { self }
}

nonisolated struct AppAlert: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let message: String
    /// Close the open question when the person taps OK (the report was refused).
    var closesQuestion = false
}

/// App state and every action the screens can take. The server is the source
/// of truth; writes go through the offline queue (FR-16).
@Observable
final class AppModel {
    // Server data
    private(set) var bars: [Bar] = []
    private(set) var estimates: Estimates?
    private(set) var lastRefreshFailed = false
    private(set) var isLoaded = false

    // Reporting
    private(set) var activeWait: ActiveWait?
    var sheet: AppSheet?
    var alert: AppAlert?
    private(set) var isDeleting = false

    let location: LocationService

    private let api: APIClient
    private let queue: OfflineQueue
    private let anonStore = AnonymousIDStore()
    private let isUITesting: Bool
    @ObservationIgnored private var anonId: UUID?
    @ObservationIgnored private var installId = UUID()
    @ObservationIgnored private var appOpenId = UUID()
    @ObservationIgnored private var enqueueChain: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var refreshSoonTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refusedReports: Set<UUID> = []
    private let pathMonitor = NWPathMonitor()
    private let appVersion = AppVersion(infoDictionary: Bundle.main.infoDictionary).label

    init(uiTesting: Bool = AppConfig.isUITesting) {
        isUITesting = uiTesting
        let transport: any RPCTransport = uiTesting
            ? FixtureTransport()
            : HTTPTransport(baseURL: AppConfig.supabaseURL, apiKey: AppConfig.supabaseKey)
        api = APIClient(transport: transport)
        queue = OfflineQueue(fileURL: uiTesting ? nil : Storage.queueURL, client: api)
        location = LocationService(enabled: !uiTesting)
        if !uiTesting {
            activeWait = Storage.load(ActiveWait.self, from: Storage.activeWaitURL)
            bars = Storage.load([Bar].self, from: Storage.barsURL) ?? []
            estimates = Storage.load(Estimates.self, from: Storage.estimatesURL)
        }
    }

    // MARK: - Lifecycle

    /// Called once when the map first appears.
    func start() async {
        guard !started else { return }
        started = true

        if isUITesting {
            anonId = UUID(uuidString: "00000000-0000-4000-8000-000000000001")
        } else {
            anonId = try? await anonStore.load()
            installId = InstallID.load()
        }
        registerInstall()

        Task { [weak self] in
            guard let deliveries = self?.queue.deliveries else { return }
            for await delivery in deliveries {
                self?.handle(delivery)
            }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            // Back online: send queued reports now instead of waiting out the backoff.
            Task { @MainActor in
                guard let self else { return }
                await self.queue.resetBackoff()
                await self.flushQueue()
            }
        }
        pathMonitor.start(queue: .main)

        await refresh()
        logMapView()
        await flushQueue()
    }

    /// Called when the app comes back to the foreground.
    func becameActive() async {
        guard started else { return }
        appOpenId = UUID()
        await refresh()
        logMapView()
        await flushQueue()
    }

    /// Loads bars and estimates. The map shows the cached ones meanwhile (NFR-1).
    func refresh() async {
        let api = api
        let anonId = anonId
        do {
            async let freshBars = api.bars(anonId: anonId)
            async let freshEstimates = api.estimates(anonId: anonId)
            let (newBars, newEstimates) = try await (freshBars, freshEstimates)
            bars = newBars
            estimates = newEstimates
            lastRefreshFailed = false
            if !isUITesting {
                Storage.save(newBars, to: Storage.barsURL)
                Storage.save(newEstimates, to: Storage.estimatesURL)
            }
        } catch {
            lastRefreshFailed = true
        }
        isLoaded = true
    }

    // MARK: - Lookups

    func bar(_ id: Int64) -> Bar? {
        bars.first { $0.id == id }
    }

    func estimate(for barId: Int64) -> BarEstimate? {
        estimates?.estimate(for: barId)
    }

    var activeWaitBar: Bar? {
        activeWait.flatMap { bar($0.barId) }
    }

    func dismissAlert() {
        if alert?.closesQuestion == true, case .question = sheet {
            sheet = nil
        }
        alert = nil
    }

    // MARK: - Reporting

    /// I'm in line (FR-6). Starting a line at another bar ends the old one as
    /// gave up on the server (FR-14).
    func startLine(at bar: Bar) {
        guard let meta = reportMeta() else { return }
        if activeWait?.barId == bar.id {
            sheet = nil
            return
        }
        let now = Date()
        let wait = ActiveWait(clientSessionId: UUID(), startReportId: UUID(), barId: bar.id,
                              startedAt: now, offset: nil)
        setActiveWait(wait)
        sheet = .question(.lineSize(.start))
        enqueue(.startSession(startCall(for: wait, meta: meta)), locate: true)
    }

    /// I'm inside (FR-11). With an open session at this bar it counts as I'm in (FR-15).
    func reportInside(at bar: Bar) {
        guard let meta = reportMeta() else { return }
        let now = Date()
        let timedSession = activeWait?.barId == bar.id ? activeWait : nil
        let report = InsideReport(reportId: UUID(), barId: bar.id, phoneTime: now,
                                  sessionId: timedSession?.clientSessionId,
                                  asksRecalledWait: timedSession == nil, isSent: true)
        if timedSession != nil {
            setActiveWait(nil)
        }
        sheet = .question(.busyness(report))
        enqueue(.submitReport(insideCall(report, meta: meta)), locate: true)
    }

    /// I'm in (FR-8), then the optional busyness question.
    func imIn() {
        guard let wait = activeWait, let anonId else { return }
        let now = Date()
        setActiveWait(nil)
        enqueue(.endSession(EndSessionCall(clientSessionId: wait.clientSessionId, anonId: anonId,
                                           outcome: .entered, phoneTime: now, location: .noFix)),
                locate: true)
        let report = InsideReport(reportId: UUID(), barId: wait.barId, phoneTime: now,
                                  sessionId: wait.clientSessionId, asksRecalledWait: false,
                                  isSent: false)
        sheet = .question(.busyness(report))
    }

    /// Gave up (FR-9).
    func gaveUp() {
        guard let wait = activeWait, let anonId else { return }
        setActiveWait(nil)
        enqueue(.endSession(EndSessionCall(clientSessionId: wait.clientSessionId, anonId: anonId,
                                           outcome: .gaveUp, phoneTime: Date(), location: .noFix)),
                locate: true)
    }

    /// Opens the line-size question from the wait card.
    func askLineSizeUpdate() {
        guard activeWait != nil else { return }
        sheet = .question(.lineSize(.update))
    }

    func answerLineSize(_ answer: Answer<LineSize>, for question: LineSizeQuestion) {
        guard let wait = activeWait, let meta = reportMeta() else {
            sheet = nil
            return
        }
        switch question {
        case .start:
            var call = startCall(for: wait, meta: meta)
            call.lineSize = answer.code
            call.lineSizeState = answer.state
            enqueue(.startSession(call))
            sheet = .question(.startOffset)
        case .update:
            sheet = nil
            // Skipping an update has nothing to save.
            guard answer != .skipped else { return }
            enqueue(.updateLineSize(UpdateLineSizeCall(
                clientReportId: UUID(), clientSessionId: wait.clientSessionId, phoneTime: Date(),
                location: .noFix, meta: meta, lineSize: answer)), locate: true)
        }
    }

    /// "Been here a while?" (FR-7). Nil means just got here.
    func answerStartOffset(_ offset: StartOffset?) {
        sheet = nil
        guard var wait = activeWait, let offset, let meta = reportMeta() else { return }
        wait.offset = offset
        setActiveWait(wait)
        var call = startCall(for: wait, meta: meta)
        call.startOffsetMinutes = offset.rawValue
        enqueue(.startSession(call))
    }

    func answerBusyness(_ answer: Answer<Busyness>, for report: InsideReport) {
        var report = report
        report.busyness = answer
        if let meta = reportMeta() {
            // After I'm in, this is the first send, so it also takes a location.
            enqueue(.submitReport(insideCall(report, meta: meta)), locate: !report.isSent)
            report.isSent = true
        }
        sheet = report.asksRecalledWait ? .question(.recalledWait(report)) : nil
    }

    func answerRecalledWait(_ answer: Answer<RecalledWait>, for report: InsideReport) {
        sheet = nil
        guard let meta = reportMeta() else { return }
        var call = insideCall(report, meta: meta)
        call.recalledWait = answer.code
        call.recalledWaitState = answer.state
        enqueue(.submitReport(call))
    }

    /// "This looks wrong" (FR-35).
    func sendFeedback(for bar: Bar) {
        guard let anonId else { return }
        let shown = estimate(for: bar.id).flatMap { try? JSONValue(encoding: $0) }
        enqueue(.sendFeedback(SendFeedbackCall(anonId: anonId, installId: installId, barId: bar.id,
                                               phoneTime: Date(), estimateShown: shown)))
        alert = AppAlert(title: "Thanks", message: "We'll take a look at \(bar.name).")
    }

    // MARK: - Views (FR-34)

    func logBarView(_ bar: Bar) {
        guard let anonId else { return }
        let shown = estimate(for: bar.id)
        enqueue(.logView(LogViewCall(
            anonId: anonId, installId: installId, kind: .bar, barId: bar.id, appOpenId: appOpenId,
            viewedAt: Date(), showedNoData: shown?.display != .estimate,
            estimateShown: shown.flatMap { try? JSONValue(encoding: $0) },
            logicVersion: estimates?.logicVersion)))
    }

    private func logMapView() {
        guard let anonId, isLoaded else { return }
        let showedData = estimates?.bars.contains { $0.display == .estimate } ?? false
        enqueue(.logView(LogViewCall(
            anonId: anonId, installId: installId, kind: .map, barId: nil, appOpenId: appOpenId,
            viewedAt: Date(), showedNoData: !showedData,
            estimateShown: estimates.flatMap { try? JSONValue(encoding: $0) },
            logicVersion: estimates?.logicVersion)))
    }

    // MARK: - Delete my data (FR-32)

    func deleteMyData() async {
        guard let oldId = anonId, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        // Drop queued writes first so nothing recreates data after the delete.
        await enqueueChain?.value
        await queue.removeAll()
        // Let a send already in flight finish before deleting.
        _ = await queue.flush()
        do {
            let removed = try await api.deleteMyData(anonId: oldId)
            if isUITesting {
                anonId = UUID()
            } else {
                anonId = try await anonStore.replace()
            }
            setActiveWait(nil)
            refusedReports.removeAll()
            registerInstall()
            alert = AppAlert(
                title: "Your data was deleted",
                message: removed == 1 ? "1 item was removed." : "\(removed) items were removed.")
        } catch {
            alert = AppAlert(
                title: "Couldn't delete your data",
                message: "Check your connection and try again.")
        }
    }

    // MARK: - Queue

    private func registerInstall() {
        guard let anonId else { return }
        enqueue(.registerInstall(RegisterInstallCall(
            anonId: anonId, installId: installId, appVersion: appVersion,
            iosVersion: UIDevice.current.systemVersion, deviceModel: DeviceInfo.model)))
    }

    /// Adds a write to the queue in call order. With `locate`, the queue holds the
    /// call until a location fix arrives or the deadline passes (FR-25, NFR-2).
    private func enqueue(_ call: PendingCall, locate: Bool = false) {
        let previous = enqueueChain
        // The first report waits longer, since it shows the permission prompt.
        let deadline = Date().addingTimeInterval(location.needsPermission ? 60 : 12)
        enqueueChain = Task {
            await previous?.value
            let id = await queue.enqueue(call, awaitingLocationUntil: locate ? deadline : nil)
            if locate {
                Task {
                    let fix = await location.currentFix()
                    await queue.attachLocation(fix, to: id)
                    await flushQueue()
                }
            }
            await flushQueue()
        }
    }

    private func flushQueue() async {
        let status = await queue.flush()
        let retryAt: Date? = switch status {
        case .idle: nil
        case .waitingForLocation(let until): until
        case .backingOff(let until): until
        }
        retryTask?.cancel()
        guard let retryAt else { return }
        retryTask = Task {
            try? await Task.sleep(for: .seconds(max(1, retryAt.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await flushQueue()
        }
    }

    private func handle(_ delivery: OfflineQueue.Delivery) {
        let call = delivery.item.call
        switch delivery.outcome {
        case .ok(let reply):
            if case .startSession(let start) = call,
               reply["already_open"]?.boolValue == true,
               let kept = reply["client_session_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
               kept != start.clientSessionId {
                // The server kept a session it already had open here.
                Task { await queue.remapSession(start.clientSessionId, to: kept) }
                if var wait = activeWait, wait.clientSessionId == start.clientSessionId {
                    wait.clientSessionId = kept
                    setActiveWait(wait)
                }
            }
            if case .endSession(let end) = call, end.outcome == .entered,
               reply["status"]?.stringValue == "unfinished" {
                alert = AppAlert(
                    title: "Timer not counted",
                    message: "Waits over 90 minutes aren't counted.")
            }
            refreshSoon()
        case .refused(let error, let reply):
            handleRefusal(error, reply: reply, call: call)
        case .rejected:
            break
        }
    }

    private func handleRefusal(_ error: String, reply: JSONValue, call: PendingCall) {
        switch error {
        case "rate_limited":
            let reportId: UUID?
            switch call {
            case .startSession(let c): reportId = c.clientReportId
            case .submitReport(let c): reportId = c.clientReportId
            default: reportId = nil
            }
            if case .startSession(let c) = call, activeWait?.clientSessionId == c.clientSessionId {
                setActiveWait(nil)
            }
            // Answers re-send the same report, so tell the person only once.
            guard let reportId, refusedReports.insert(reportId).inserted else { return }
            let seconds = reply["retry_after_seconds"]?.intValue ?? 600
            let minutes = max(1, Int((Double(seconds) / 60).rounded(.up)))
            alert = AppAlert(
                title: "Already reported",
                message: "You can report this bar again in \(minutes) min.",
                closesQuestion: true)
        case "session_not_found", "session_not_open":
            if let session = call.clientSessionId, activeWait?.clientSessionId == session {
                setActiveWait(nil)
            }
        default:
            break
        }
    }

    /// Refreshes estimates shortly after reports land, batching several.
    private func refreshSoon() {
        refreshSoonTask?.cancel()
        refreshSoonTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    // MARK: - Helpers

    private func reportMeta() -> ReportMeta? {
        guard let anonId else { return nil }
        return ReportMeta(anonId: anonId, installId: installId, appVersion: appVersion)
    }

    private func startCall(for wait: ActiveWait, meta: ReportMeta) -> StartSessionCall {
        StartSessionCall(clientSessionId: wait.clientSessionId, clientReportId: wait.startReportId,
                         barId: wait.barId, phoneTime: wait.startedAt, location: .noFix, meta: meta)
    }

    private func insideCall(_ report: InsideReport, meta: ReportMeta) -> SubmitReportCall {
        SubmitReportCall(clientReportId: report.reportId, barId: report.barId,
                         phoneTime: report.phoneTime, location: .noFix, meta: meta,
                         clientSessionId: report.sessionId, busyness: report.busyness)
    }

    private func setActiveWait(_ wait: ActiveWait?) {
        activeWait = wait
        guard !isUITesting else { return }
        if let wait {
            Storage.save(wait, to: Storage.activeWaitURL)
        } else {
            Storage.remove(Storage.activeWaitURL)
        }
    }
}

/// Small JSON files in Application Support (queue, wait session) and Caches (last data).
nonisolated enum Storage {
    static var queueURL: URL { appSupport.appending(path: "queue.json") }
    static var activeWaitURL: URL { appSupport.appending(path: "active-wait.json") }
    static var barsURL: URL { caches.appending(path: "bars.json") }
    static var estimatesURL: URL { caches.appending(path: "estimates.json") }

    private static var appSupport: URL {
        URL.applicationSupportDirectory.appending(path: "LineMap", directoryHint: .isDirectory)
    }

    private static var caches: URL {
        URL.cachesDirectory.appending(path: "LineMap", directoryHint: .isDirectory)
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.lineMap.decode(T.self, from: data)
    }

    static func save(_ value: some Encodable, to url: URL) {
        guard let data = try? JSONEncoder.lineMap.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
