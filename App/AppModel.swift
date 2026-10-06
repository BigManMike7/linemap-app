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
    /// Adjust time in minutes (FR-7); nil when just started.
    var offsetMinutes: Int?
    /// The last Line size answer, so the wheel opens on it (FR-6). Only kept on the phone.
    var lineSize: LineSize?

    var timer: WaitTimer { WaitTimer(startedAt: startedAt, offsetMinutes: offsetMinutes ?? 0) }

    // "offset" is the key builds before 2026-10-04 saved, so an open wait survives the update.
    private nonisolated enum CodingKeys: String, CodingKey {
        case clientSessionId, startReportId, barId, startedAt, lineSize
        case offsetMinutes = "offset"
    }
}

/// A question shown in a sheet.
nonisolated enum Question: Hashable {
    /// Line size, from the wait card (FR-6).
    case lineSize
    /// Adjust time, from the wait card (FR-7).
    case adjustTime
    /// Report line size, from the bar sheet (FR-11).
    case conditions(barId: Int64)
}

nonisolated enum AppSheet: Hashable, Identifiable {
    case bar(Int64)
    case question(Question)

    var id: Self { self }
}

/// The tabs along the bottom (FR-44).
nonisolated enum AppTab: Hashable {
    case map
    case bars
    case settings
}

/// The thank-you shown after a report (FR-42). After I'm in or Gave up it
/// carries the stopped timer, so Undo can bring it back (FR-47).
nonisolated struct Thanks: Identifiable, Hashable {
    let id = UUID()
    let text: String
    var undo: ActiveWait? = nil

    static let visible = "Thanks! Your update is now visible to everyone."
    static let offline = "Thanks! Your update will send when you're back online."
    /// After Save on Adjust time with the same time as before, usually because
    /// Save was tapped while the wheel still spun and the wheel hadn't picked yet.
    static let noChange = "No change. Let the wheel stop, then tap Save."
    /// After Gave up (FR-42).
    static let stopped = "Timer stopped."
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

    // Navigation
    var tab: AppTab = .map
    /// A bar the map should move to, set by the Bars list (FR-45). The map clears it.
    var mapFocus: Int64?

    // Reporting
    private(set) var activeWait: ActiveWait?
    var sheet: AppSheet?
    var alert: AppAlert?
    private(set) var thanks: Thanks?
    /// Goes up on each Save on Adjust time, which confirms with a haptic only (FR-42).
    private(set) var adjustTimeSaves = 0
    private(set) var isDeleting = false

    let location: LocationService

    private let api: APIClient
    private let queue: OfflineQueue
    private let anonStore = AnonymousIDStore()
    private let isUITesting: Bool
    /// Shown in Settings so Max can add his own ID to test_anon_ids (FR-38).
    private(set) var anonId: UUID?
    @ObservationIgnored private var installId = UUID()
    @ObservationIgnored private var appOpenId = UUID()
    @ObservationIgnored private var enqueueChain: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var refreshSoonTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refusedReports: Set<UUID> = []
    /// Reports and timers to thank for once the server accepts them, keyed by
    /// their client ID, with when they were made, what to say, and the timer
    /// Undo would bring back (FR-42, FR-47).
    @ObservationIgnored private var awaitingThanks: [UUID: (madeAt: Date, text: String, undo: ActiveWait?)] = [:]
    @ObservationIgnored private var thanksTask: Task<Void, Never>?
    @ObservationIgnored private var isOnline = true
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
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = online
                guard online else { return }
                // Back online: send queued reports now instead of waiting out the backoff.
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

    /// A card in the Bars list (FR-45): switches to the map, moves it to the
    /// bar, and opens the bar's sheet.
    func showOnMap(_ bar: Bar) {
        tab = .map
        mapFocus = bar.id
        sheet = .bar(bar.id)
    }

    /// One night of a bar's history (FR-43). Leave `night` out for tonight.
    func history(for barId: Int64, night: NightDate?) async throws -> BarHistory {
        try await api.barHistory(anonId: anonId, barId: barId, night: night)
    }

    func dismissAlert() {
        if alert?.closesQuestion == true, case .question = sheet {
            sheet = nil
        }
        alert = nil
    }

    // MARK: - Reporting

    /// Start line timer (FR-6): one tap starts the timer and nothing else is asked.
    /// Line size and Adjust time are on the wait card. Starting a line at
    /// another bar ends the old one as gave up on the server (FR-14).
    func startLine(at bar: Bar) {
        sheet = nil
        guard let meta = reportMeta(), activeWait?.barId != bar.id else { return }
        let wait = ActiveWait(clientSessionId: UUID(), startReportId: UUID(), barId: bar.id,
                              startedAt: Date(), offsetMinutes: nil)
        setActiveWait(wait)
        enqueue(.startSession(startCall(for: wait, meta: meta)), locate: true)
    }

    /// Report line size on the bar sheet (FR-11): opens the form.
    func askConditions(at bar: Bar) {
        sheet = .question(.conditions(barId: bar.id))
    }

    /// Sends Report line size once. Nothing is sent without a size (FR-12). It
    /// never touches a wait session. The crowd is always skipped (2026-10-06).
    func sendConditions(at barId: Int64, lineSize: LineSize?) {
        sheet = nil
        guard let lineSize, let meta = reportMeta() else { return }
        let reportId = UUID()
        thankWhenAccepted(reportId)
        enqueue(.reportConditions(ReportConditionsCall(
            clientReportId: reportId, barId: barId, phoneTime: Date(), location: .noFix, meta: meta,
            lineSize: .answered(lineSize), busyness: .skipped)), locate: true)
    }

    /// I'm in (FR-8): ends the timer and asks nothing.
    func imIn() {
        sheet = nil
        guard let wait = activeWait, let anonId else { return }
        setActiveWait(nil)
        thankWhenAccepted(wait.clientSessionId, undo: wait)
        enqueue(.endSession(EndSessionCall(clientSessionId: wait.clientSessionId, anonId: anonId,
                                           outcome: .entered, phoneTime: Date(), location: .noFix)),
                locate: true)
    }

    /// Undo on the message after I'm in or Gave up (FR-47): brings the same
    /// timer back, with its start time and Adjust time.
    func undoStop() {
        guard let wait = thanks?.undo, activeWait == nil, let anonId else { return }
        thanksTask?.cancel()
        thanks = nil
        setActiveWait(wait)
        enqueue(.reopenSession(ReopenSessionCall(clientSessionId: wait.clientSessionId, anonId: anonId)))
    }

    // MARK: - Thank-you (FR-42)

    /// Offline, thanks right away and says it will send later. Online, waits
    /// for the server to accept it, so "now visible" is true.
    private func thankWhenAccepted(_ id: UUID, text: String = Thanks.visible, undo: ActiveWait? = nil) {
        if isOnline {
            awaitingThanks[id] = (Date(), text, undo)
        } else {
            showThanks(Thanks.offline, undo: undo)
        }
    }

    /// Thanks for an accepted report, unless it took so long (a retry after a
    /// dropped connection) that the message would come out of nowhere.
    private func deliveredForThanks(_ id: UUID?, accepted: Bool) {
        guard let id, let waiting = awaitingThanks.removeValue(forKey: id) else { return }
        if accepted && Date().timeIntervalSince(waiting.madeAt) < 90 {
            showThanks(waiting.text, undo: waiting.undo)
        }
    }

    private func showThanks(_ text: String, undo: ActiveWait? = nil) {
        let thanks = Thanks(text: text, undo: undo)
        self.thanks = thanks
        UIAccessibility.post(notification: .announcement, argument: text)
        thanksTask?.cancel()
        // Longer with Undo, so there's time to tap it, and longer still under UI
        // testing, so the screenshot catches it after the test waits for idle.
        let shownFor: Duration = isUITesting ? .seconds(10) : (undo == nil ? .seconds(3) : .seconds(5))
        thanksTask = Task {
            try? await Task.sleep(for: shownFor)
            guard !Task.isCancelled, self.thanks?.id == thanks.id else { return }
            self.thanks = nil
        }
    }

    /// Gave up (FR-9), from the ✕ on the wait card.
    func gaveUp() {
        guard let wait = activeWait, let anonId else { return }
        setActiveWait(nil)
        // Says so, with Undo (FR-42, FR-47).
        showThanks(Thanks.stopped, undo: wait)
        enqueue(.endSession(EndSessionCall(clientSessionId: wait.clientSessionId, anonId: anonId,
                                           outcome: .gaveUp, phoneTime: Date(), location: .noFix)),
                locate: true)
    }

    /// The ✕ on the wait card (FR-39): discards a line started by mistake. The
    /// server deletes the session and its reports, so nothing from it counts.
    func cancelLine() {
        guard let wait = activeWait, let anonId else { return }
        setActiveWait(nil)
        enqueue(.cancelSession(CancelSessionCall(clientSessionId: wait.clientSessionId, anonId: anonId)))
    }

    /// Line size on the wait card (FR-6).
    func askLineSize() {
        guard activeWait != nil else { return }
        sheet = .question(.lineSize)
    }

    /// Save on the Line size wheel. Each answer is its own line-size report in
    /// the session (FR-13 exempt), confirmed by the thank-you (FR-42).
    func answerLineSize(_ size: LineSize) {
        sheet = nil
        guard var wait = activeWait, let meta = reportMeta() else { return }
        wait.lineSize = size
        setActiveWait(wait)
        let reportId = UUID()
        thankWhenAccepted(reportId)
        enqueue(.updateLineSize(UpdateLineSizeCall(
            clientReportId: reportId, clientSessionId: wait.clientSessionId, phoneTime: Date(),
            location: .noFix, meta: meta, lineSize: .answered(size))), locate: true)
    }

    /// Adjust time on the wait card (FR-7).
    func askAdjustTime() {
        guard activeWait != nil else { return }
        sheet = .question(.adjustTime)
    }

    /// Save on the Adjust time wheel: moves the timer's start back by this many
    /// minutes (0 to 90); nil or 0 undoes it. Confirmed by a short message (FR-42).
    func adjustTime(minutes: Int?) {
        sheet = nil
        let clamped = min(max(minutes ?? 0, 0), StartOffset.maxMinutes)
        let offset: Int? = clamped == 0 ? nil : clamped
        guard var wait = activeWait, let meta = reportMeta() else { return }
        // Unchanged: say so rather than confirm, so the person can try again.
        guard wait.offsetMinutes != offset else {
            showThanks(Thanks.noChange)
            return
        }
        wait.offsetMinutes = offset
        setActiveWait(wait)
        var call = startCall(for: wait, meta: meta)
        call.startOffsetMinutes = clamped
        // A haptic and no message: the wait counts only once it ends (FR-42).
        adjustTimeSaves += 1
        enqueue(.startSession(call))
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

    // MARK: - Made a wrong report? (FR-41)

    /// The person's own reports and finished waits from the last 24 hours.
    func recentReports() async throws -> [MyReport] {
        guard let anonId else { return [] }
        return try await api.myRecentReports(anonId: anonId)
    }

    /// Deletes one report or finished wait for good. Already gone counts as deleted.
    func deleteReport(_ item: MyReport) async throws -> DeleteReportResult {
        guard let anonId else { return .notFound }
        let result = try await api.deleteReport(anonId: anonId, target: item.target)
        if result == .deleted {
            refreshSoon()
        }
        return result
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
        // A start_session is thanked only when Adjust time sent it.
        let thanksId: UUID? = switch call {
        case .reportConditions(let c): c.clientReportId
        case .updateLineSize(let c): c.clientReportId
        case .startSession(let c): c.clientReportId
        case .endSession(let c) where c.outcome == .entered: c.clientSessionId
        default: nil
        }
        switch delivery.outcome {
        case .ok(let reply):
            // A timer past 90 minutes isn't counted, so it gets the alert below instead.
            deliveredForThanks(thanksId, accepted: reply["status"]?.stringValue != "unfinished")
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
            // Undo found nothing to reopen (the timer was deleted meanwhile).
            if case .reopenSession(let reopen) = call, reply["status"]?.stringValue != "open",
               activeWait?.clientSessionId == reopen.clientSessionId {
                setActiveWait(nil)
            }
            if case .endSession(let end) = call, end.outcome == .entered,
               reply["status"]?.stringValue == "unfinished" {
                alert = AppAlert(
                    title: "Timer not counted",
                    message: "Waits over 90 minutes aren't counted.")
            }
            refreshSoon()
        case .refused(let error, let reply):
            deliveredForThanks(thanksId, accepted: false)
            handleRefusal(error, reply: reply, call: call)
        case .rejected:
            deliveredForThanks(thanksId, accepted: false)
        }
    }

    private func handleRefusal(_ error: String, reply: JSONValue, call: PendingCall) {
        switch error {
        case "rate_limited":
            let reportId: UUID?
            switch call {
            case .startSession(let c): reportId = c.clientReportId
            case .submitReport(let c): reportId = c.clientReportId
            case .reportConditions(let c): reportId = c.clientReportId
            default: reportId = nil
            }
            if case .startSession(let c) = call, activeWait?.clientSessionId == c.clientSessionId {
                setActiveWait(nil)
            }
            // Answers re-send the same report, so tell the person only once.
            guard let reportId, refusedReports.insert(reportId).inserted else { return }
            let seconds = reply["retry_after_seconds"]?.intValue ?? 600
            let minutes = max(1, Int((Double(seconds) / 60).rounded(.up)))
            // Timed lines and reports have separate 10-minute limits (FR-13).
            if case .startSession = call {
                alert = AppAlert(
                    title: "Already timed here",
                    message: "You already timed a line here. You can start another in \(minutes) min.",
                    closesQuestion: true)
            } else {
                alert = AppAlert(
                    title: "Already reported",
                    message: "You already reported this bar. You can report it again in \(minutes) min.",
                    closesQuestion: true)
            }
        case "session_not_found", "session_not_open":
            if let session = call.clientSessionId, activeWait?.clientSessionId == session {
                setActiveWait(nil)
            }
        case "too_late", "other_session_open", "session_not_reopenable":
            // Undo was refused (FR-47): the timer stays stopped.
            if case .reopenSession(let reopen) = call, activeWait?.clientSessionId == reopen.clientSessionId {
                setActiveWait(nil)
                alert = AppAlert(
                    title: "Couldn't undo",
                    message: "That timer can't be brought back now. If you're still in line, start a new one.")
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
