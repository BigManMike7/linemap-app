import Foundation

/// The phone's outbox for every write (FR-16, NFR-2).
///
/// Calls are sent strictly in the order they were added, because session events
/// (start, line-size updates, end) must reach the server in order. A head that
/// can't be sent yet blocks the items behind it. Every call carries client IDs,
/// so sending one again after a lost reply never saves it twice.
///
/// The queue is saved to disk after every change, so it survives restarts. It
/// never waits forever: a missing location falls back to "no fix" at its
/// deadline, network failures back off for at most 60 seconds, and items older
/// than 7 days are dropped.
///
/// Every item that leaves the queue (sent, refused, rejected, or expired) yields
/// exactly one `Delivery` on `deliveries`. `removeAll()` yields none.
public actor OfflineQueue {
    /// One queued call.
    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public internal(set) var call: PendingCall
        public let enqueuedAt: Date
        /// Failed attempts that will be retried (offline, timeouts, server errors).
        public internal(set) var attempts: Int
        /// While set and in the future, the item waits for `attachLocation(_:to:)`.
        public internal(set) var awaitingLocationUntil: Date?
        /// After a failed attempt, the item isn't sent again before this time.
        public internal(set) var nextAttemptAt: Date?
    }

    /// What happened to an item that left the queue.
    public enum Outcome: Sendable, Hashable {
        /// The server saved it. The reply, with its snake_case keys unchanged.
        case ok(JSONValue)
        /// The server answered `{"ok": false, "error": ...}`, for example
        /// `rate_limited`, `session_not_found`, or `session_not_open`.
        case refused(error: String, reply: JSONValue)
        /// The server rejected the call (an HTTP 4xx, such as bad input), or the
        /// item expired before it could be sent (`status` 0, message "expired").
        case rejected(status: Int, message: String)
    }

    public struct Delivery: Sendable, Hashable {
        /// The item as it was sent.
        public let item: Item
        public let outcome: Outcome
    }

    /// Why `flush()` stopped.
    public enum FlushStatus: Sendable, Hashable {
        /// Everything was sent.
        case idle
        /// The head is waiting for a location. Flush again at `until` at the latest.
        case waitingForLocation(until: Date)
        /// The head failed and is backing off. Flush again at `until`.
        case backingOff(until: Date)
    }

    /// Items older than this are dropped instead of sent.
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// The longest wait between retries.
    public static let maxBackoff: TimeInterval = 60

    /// Items leaving the queue, in order. Meant for one consumer (the app's model).
    public nonisolated let deliveries: AsyncStream<Delivery>

    /// The queued items, oldest first.
    public private(set) var items: [Item]

    public var count: Int { items.count }

    private let continuation: AsyncStream<Delivery>.Continuation
    private let fileURL: URL?
    private let client: APIClient
    private let clock: @Sendable () -> Date
    /// The send loop, while one is running. Only one runs at a time.
    private var running: Task<FlushStatus, Never>?

    /// - Parameters:
    ///   - fileURL: Where the queue is saved. `nil` keeps it in memory only (UI tests).
    ///     An unreadable file starts an empty queue.
    ///   - client: Sends the calls.
    ///   - now: The current time. Tests pass a fake clock.
    public init(fileURL: URL?, client: APIClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.client = client
        self.clock = now
        self.items = OfflineQueue.load(from: fileURL)
        let (stream, continuation) = AsyncStream.makeStream(of: Delivery.self)
        self.deliveries = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    // MARK: - Changing the queue

    /// Adds a call to the end of the queue and returns the item's ID.
    ///
    /// Pass `awaitingLocationUntil` when the report's location is still being
    /// captured. The item then holds the queue until `attachLocation(_:to:)` or
    /// the deadline, whichever comes first (FR-25, NFR-2).
    @discardableResult
    public func enqueue(_ call: PendingCall, awaitingLocationUntil: Date? = nil) -> UUID {
        let item = Item(id: UUID(), call: call, enqueuedAt: clock(), attempts: 0,
                        awaitingLocationUntil: awaitingLocationUntil, nextAttemptAt: nil)
        items.append(item)
        save()
        return item.id
    }

    /// Sets a queued call's location and stops it waiting. Does nothing if the
    /// item has already left the queue.
    public func attachLocation(_ fix: LocationFix, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].call = items[index].call.withLocation(fix)
        items[index].awaitingLocationUntil = nil
        save()
    }

    /// Points every queued call for session `old` at session `new`.
    ///
    /// The queue does this by itself when `start_session` replies that the server
    /// kept an already-open session, so the calls behind it follow at once.
    public func remapSession(_ old: UUID, to new: UUID) {
        guard old != new else { return }
        remap(old, to: new)
        save()
    }

    /// Drops every item without delivering it. Used by Delete my data (FR-32).
    /// A call already on its way to the server is not delivered either.
    public func removeAll() {
        items.removeAll()
        save()
    }

    /// Lets items that are backing off be sent on the next flush, for example
    /// when the network comes back.
    public func resetBackoff() {
        guard items.contains(where: { $0.nextAttemptAt != nil }) else { return }
        for index in items.indices {
            items[index].nextAttemptAt = nil
        }
        save()
    }

    // MARK: - Sending

    /// Sends queued calls in order until the queue is empty or the head has to wait.
    ///
    /// Safe to call from several places at once: only one send loop runs, and a
    /// call made while it runs waits for it and returns its result. Items added
    /// while the loop runs are sent by that loop.
    @discardableResult
    public func flush() async -> FlushStatus {
        if let running {
            return await running.value
        }
        // An unstructured task, so a cancelled caller never abandons a send halfway.
        let task = Task { await self.drain() }
        running = task
        return await task.value
    }

    private enum Step {
        case stop(FlushStatus)
        case send(Item)
    }

    private func drain() async -> FlushStatus {
        while true {
            switch nextStep() {
            case .stop(let status):
                // Cleared in the same synchronous step that found nothing to send,
                // so a later flush() always starts a fresh loop.
                running = nil
                return status
            case .send(let item):
                let response = try? await client.send(item.call)
                finish(item, outcome: OfflineQueue.classify(response))
            }
        }
    }

    /// Decides what to do with the head. Synchronous, so it sees one consistent state.
    private func nextStep() -> Step {
        let now = clock()

        var expired: [Item] = []
        while let head = items.first, now.timeIntervalSince(head.enqueuedAt) > OfflineQueue.maxAge {
            expired.append(items.removeFirst())
        }
        if !expired.isEmpty {
            save()
            for item in expired {
                continuation.yield(Delivery(item: item, outcome: .rejected(status: 0, message: "expired")))
            }
        }

        guard var head = items.first else { return .stop(.idle) }

        if let deadline = head.awaitingLocationUntil {
            if now < deadline {
                return .stop(.waitingForLocation(until: deadline))
            }
            // No fix in time: send without one. The server marks it uncertain (FR-27).
            head.call = head.call.withLocation(OfflineQueue.fallbackLocation(for: head.call))
            head.awaitingLocationUntil = nil
            items[0] = head
            save()
        }

        if let retryAt = head.nextAttemptAt, now < retryAt {
            return .stop(.backingOff(until: retryAt))
        }
        return .send(head)
    }

    /// Records the result of sending `sent`. `outcome` is nil for a failure worth retrying.
    private func finish(_ sent: Item, outcome: Outcome?) {
        // Gone means removeAll() ran while the call was in flight: drop the result.
        guard let index = items.firstIndex(where: { $0.id == sent.id }) else { return }

        guard let outcome else {
            items[index].attempts += 1
            items[index].nextAttemptAt = clock() + OfflineQueue.backoff(afterAttempts: items[index].attempts)
            save()
            return
        }

        items.remove(at: index)
        // The server kept an already-open session at this bar: send the rest there.
        if case .startSession(let start) = sent.call, case .ok(let reply) = outcome,
           let kept = reply["client_session_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
           kept != start.clientSessionId {
            remap(start.clientSessionId, to: kept)
        }
        save()
        continuation.yield(Delivery(item: sent, outcome: outcome))
    }

    private func remap(_ old: UUID, to new: UUID) {
        for index in items.indices {
            items[index].call = items[index].call.replacingSession(old, with: new)
        }
    }

    // MARK: - Rules

    /// Turns a reply into an outcome, or nil when the call should be retried:
    /// no HTTP response (offline, timeout), 408, 425, 429, 5xx, any other
    /// non-2xx non-4xx status, or a 2xx body that isn't JSON (a captive portal
    /// page, not our server).
    static func classify(_ response: RPCResponse?) -> Outcome? {
        guard let response else { return nil }
        switch response.status {
        case 200..<300:
            if response.body.isEmpty { return .ok(.null) }
            // A plain decoder keeps the reply's snake_case keys.
            guard let reply = try? JSONDecoder().decode(JSONValue.self, from: response.body) else {
                return nil
            }
            if reply["ok"]?.boolValue == false {
                return .refused(error: reply["error"]?.stringValue ?? "unknown", reply: reply)
            }
            return .ok(reply)
        case 408, 425, 429:
            return nil
        case 400..<500:
            return .rejected(status: response.status, message: APIClient.message(in: response.body))
        default:
            return nil
        }
    }

    /// 2, 4, 8, 16, 32, then 60 seconds.
    static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        let exponent = min(max(attempts, 0), 30)
        return min(TimeInterval(1 << exponent), maxBackoff)
    }

    /// The location to send when the deadline passes: a denial or a fix with
    /// coordinates already on the call is kept, anything else becomes "no fix".
    static func fallbackLocation(for call: PendingCall) -> LocationFix {
        guard let current = call.queuedLocation else { return .noFix }
        if current.status == .denied || current.latitude != nil { return current }
        return .noFix
    }

    // MARK: - Saving

    /// The file format. A plain encoder keeps JSON keys inside calls (such as an
    /// estimate's `bar_id`) exactly as they are, and dates as exact numbers.
    private struct Stored: Codable {
        var version: Int
        var items: [Item]
    }

    private static let fileVersion = 1

    private static func load(from fileURL: URL?) -> [Item] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == fileVersion
        else { return [] }
        return stored.items
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(Stored(version: OfflineQueue.fileVersion, items: items))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Keep going from memory; the next change tries to save again.
        }
    }
}

extension PendingCall {
    /// The location a call carries, if it carries one.
    fileprivate var queuedLocation: LocationFix? {
        switch self {
        case .startSession(let c): c.location
        case .updateLineSize(let c): c.location
        case .endSession(let c): c.location
        case .submitReport(let c): c.location
        case .reportConditions(let c): c.location
        case .sendFeedback, .registerInstall, .logView, .cancelSession, .reopenSession: nil
        }
    }
}
