import Foundation
import Testing
@testable import LineMapCore

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

/// Records every call and answers from a script; unscripted calls get {"ok": true}.
final class ScriptedTransport: RPCTransport, @unchecked Sendable {
    enum Reply {
        case json(Int, String)
        case offline
    }

    private let lock = NSLock()
    private var script: [Reply] = []
    private var calls: [(function: String, parameters: [String: JSONValue])] = []
    private let delay: Duration?

    init(delay: Duration? = nil) {
        self.delay = delay
    }

    func push(_ replies: Reply...) {
        lock.withLock { script.append(contentsOf: replies) }
    }

    var sent: [(function: String, parameters: [String: JSONValue])] {
        lock.withLock { calls }
    }

    var functions: [String] { sent.map(\.function) }

    func call(_ function: String, body: Data) async throws -> RPCResponse {
        let parameters = (try? JSONDecoder().decode([String: JSONValue].self, from: body)) ?? [:]
        let reply: Reply = lock.withLock {
            calls.append((function, parameters))
            return script.isEmpty ? .json(200, #"{"ok": true}"#) : script.removeFirst()
        }
        if let delay {
            try await Task.sleep(for: delay)
        }
        switch reply {
        case .offline:
            throw URLError(.notConnectedToInternet)
        case .json(let status, let body):
            return RPCResponse(status: status, body: Data(body.utf8))
        }
    }
}

struct OfflineQueueTests {
    let clock = TestClock()
    let transport: ScriptedTransport
    let meta = ReportMeta(anonId: UUID(), installId: UUID(), appVersion: "1.0")

    init() {
        transport = ScriptedTransport()
    }

    func makeQueue(fileURL: URL? = nil, transport: ScriptedTransport? = nil) -> OfflineQueue {
        let clock = clock
        return OfflineQueue(fileURL: fileURL, client: APIClient(transport: transport ?? self.transport),
                            now: { clock.now })
    }

    func start(_ session: UUID = UUID()) -> PendingCall {
        .startSession(StartSessionCall(clientSessionId: session, clientReportId: UUID(), barId: 1,
                                       phoneTime: clock.now, location: .noFix, meta: meta))
    }

    func update(_ session: UUID) -> PendingCall {
        .updateLineSize(UpdateLineSizeCall(clientReportId: UUID(), clientSessionId: session,
                                           phoneTime: clock.now, location: .noFix, meta: meta,
                                           lineSize: .answered(.tenTo25)))
    }

    func end(_ session: UUID) -> PendingCall {
        .endSession(EndSessionCall(clientSessionId: session, anonId: meta.anonId, outcome: .entered,
                                   phoneTime: clock.now, location: .noFix))
    }

    func feedback() -> PendingCall {
        .sendFeedback(SendFeedbackCall(anonId: meta.anonId, installId: meta.installId, barId: 2,
                                       phoneTime: clock.now,
                                       estimateShown: .object(["bar_id": 2, "display": "estimate"])))
    }

    func deliveries(_ count: Int, from queue: OfflineQueue) async -> [OfflineQueue.Delivery] {
        var iterator = queue.deliveries.makeAsyncIterator()
        var result: [OfflineQueue.Delivery] = []
        for _ in 0..<count {
            if let delivery = await iterator.next() {
                result.append(delivery)
            }
        }
        return result
    }

    func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "linemap-queue-\(UUID().uuidString)")
            .appending(path: "queue.json")
    }

    // MARK: - Order and outcomes

    @Test func sendsInOrderAndEmptiesTheQueue() async {
        let queue = makeQueue()
        let session = UUID()
        await queue.enqueue(start(session))
        await queue.enqueue(feedback())
        await queue.enqueue(end(session))

        #expect(await queue.flush() == .idle)
        #expect(transport.functions == ["start_session", "send_feedback", "end_session"])
        #expect(await queue.count == 0)

        let delivered = await deliveries(3, from: queue)
        #expect(delivered.map(\.item.call.function) == ["start_session", "send_feedback", "end_session"])
        #expect(delivered.allSatisfy { if case .ok = $0.outcome { true } else { false } })
    }

    @Test func refusedReplyIsDeliveredAndRemoved() async {
        let queue = makeQueue()
        transport.push(.json(200, #"{"ok": false, "error": "rate_limited", "retry_after_seconds": 120}"#))
        await queue.enqueue(start())

        #expect(await queue.flush() == .idle)
        #expect(await queue.count == 0)
        let delivered = await deliveries(1, from: queue)
        guard case .refused(let error, let reply) = delivered.first?.outcome else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error == "rate_limited")
        #expect(reply["retry_after_seconds"]?.intValue == 120)
    }

    @Test func badInputIsRejectedAndTheNextItemStillGoes() async {
        let queue = makeQueue()
        transport.push(.json(400, #"{"code": "22023", "message": "invalid source"}"#))
        await queue.enqueue(start())
        await queue.enqueue(feedback())

        #expect(await queue.flush() == .idle)
        #expect(transport.functions == ["start_session", "send_feedback"])
        let delivered = await deliveries(2, from: queue)
        #expect(delivered.first?.outcome == .rejected(status: 400, message: "invalid source"))
        #expect(delivered.last?.outcome == .ok(.object(["ok": true])))
    }

    // MARK: - Retries

    @Test func offlineKeepsTheItemAndBacksOff() async {
        let queue = makeQueue()
        transport.push(.offline)
        await queue.enqueue(start())
        await queue.enqueue(feedback())

        #expect(await queue.flush() == .backingOff(until: clock.now + 2))
        #expect(transport.functions == ["start_session"])
        #expect(await queue.count == 2)
        #expect(await queue.items.first?.attempts == 1)

        // Still backing off: nothing is sent.
        #expect(await queue.flush() == .backingOff(until: clock.now + 2))
        #expect(transport.sent.count == 1)

        clock.advance(2)
        #expect(await queue.flush() == .idle)
        #expect(transport.functions == ["start_session", "start_session", "send_feedback"])
    }

    @Test(arguments: [500, 503, 408, 429])
    func serverErrorsAreRetried(status: Int) async {
        let queue = makeQueue()
        transport.push(.json(status, ""))
        await queue.enqueue(start())

        #expect(await queue.flush() == .backingOff(until: clock.now + 2))
        #expect(await queue.count == 1)
    }

    @Test func nonJSONSuccessIsRetried() async {
        let queue = makeQueue()
        transport.push(.json(200, "<html>Sign in to Wi-Fi</html>"))
        await queue.enqueue(start())

        #expect(await queue.flush() == .backingOff(until: clock.now + 2))
    }

    @Test func backoffDoublesUpToAMinute() {
        #expect(OfflineQueue.backoff(afterAttempts: 1) == 2)
        #expect(OfflineQueue.backoff(afterAttempts: 2) == 4)
        #expect(OfflineQueue.backoff(afterAttempts: 5) == 32)
        #expect(OfflineQueue.backoff(afterAttempts: 6) == 60)
        #expect(OfflineQueue.backoff(afterAttempts: 100) == 60)
    }

    @Test func resetBackoffSendsRightAway() async {
        let queue = makeQueue()
        transport.push(.offline)
        await queue.enqueue(start())
        _ = await queue.flush()

        await queue.resetBackoff()
        #expect(await queue.flush() == .idle)
        #expect(transport.sent.count == 2)
    }

    @Test func itemsOlderThanAWeekExpire() async {
        let queue = makeQueue()
        await queue.enqueue(feedback())
        clock.advance(8 * 24 * 60 * 60)

        #expect(await queue.flush() == .idle)
        #expect(transport.sent.isEmpty)
        let delivered = await deliveries(1, from: queue)
        #expect(delivered.first?.outcome == .rejected(status: 0, message: "expired"))
    }

    // MARK: - Location

    @Test func waitsForLocationThenSendsTheFix() async throws {
        let queue = makeQueue()
        let id = await queue.enqueue(start(), awaitingLocationUntil: clock.now + 10)
        await queue.enqueue(feedback())

        #expect(await queue.flush() == .waitingForLocation(until: clock.now + 10))
        #expect(transport.sent.isEmpty)

        let fix = LocationFix(status: .precise, latitude: 40.795, longitude: -77.86,
                              accuracyMeters: 12, ageSeconds: 3)
        await queue.attachLocation(fix, to: id)
        #expect(await queue.flush() == .idle)

        let parameters = try #require(transport.sent.first?.parameters)
        #expect(parameters["p_location_status"] == .string("precise"))
        #expect(parameters["p_lat"] == .number(40.795))
        #expect(parameters["p_accuracy_m"] == .number(12))
        #expect(transport.functions == ["start_session", "send_feedback"])
    }

    @Test func sendsWithoutAFixAfterTheDeadline() async throws {
        let queue = makeQueue()
        await queue.enqueue(start(), awaitingLocationUntil: clock.now + 10)
        clock.advance(11)

        #expect(await queue.flush() == .idle)
        let parameters = try #require(transport.sent.first?.parameters)
        #expect(parameters["p_location_status"] == .string("no_fix"))
        #expect(parameters["p_lat"] == nil)
    }

    @Test func aDenialSurvivesTheDeadline() async throws {
        let queue = makeQueue()
        let id = await queue.enqueue(start(), awaitingLocationUntil: clock.now + 10)
        await queue.attachLocation(.denied, to: id)

        #expect(await queue.flush() == .idle)
        let parameters = try #require(transport.sent.first?.parameters)
        #expect(parameters["p_location_status"] == .string("denied"))
    }

    // MARK: - Sessions

    @Test func remapPointsQueuedCallsAtTheNewSession() async {
        let queue = makeQueue()
        let old = UUID()
        let new = UUID()
        await queue.enqueue(update(old))
        await queue.enqueue(end(old))
        await queue.remapSession(old, to: new)

        #expect(await queue.flush() == .idle)
        let sessions = transport.sent.map { $0.parameters["p_client_session_id"] }
        #expect(sessions == [.string(new.uuidString.lowercased()), .string(new.uuidString.lowercased())])
    }

    @Test func followsAnAlreadyOpenSession() async {
        let queue = makeQueue()
        let mine = UUID()
        let kept = UUID()
        transport.push(.json(200, #"{"ok": true, "already_open": true, "status": "open", "client_session_id": "\#(kept.uuidString.lowercased())"}"#))
        await queue.enqueue(start(mine))
        await queue.enqueue(end(mine))

        #expect(await queue.flush() == .idle)
        #expect(transport.sent.last?.parameters["p_client_session_id"] == .string(kept.uuidString.lowercased()))
    }

    @Test func removeAllSendsNothing() async {
        let queue = makeQueue()
        await queue.enqueue(start())
        await queue.enqueue(feedback())
        await queue.removeAll()

        #expect(await queue.count == 0)
        #expect(await queue.flush() == .idle)
        #expect(transport.sent.isEmpty)
    }

    // MARK: - Saving

    @Test func survivesARestart() async {
        let url = temporaryFile()
        let first = makeQueue(fileURL: url)
        let session = UUID()
        await first.enqueue(start(session), awaitingLocationUntil: clock.now + 5)
        await first.enqueue(feedback())
        await first.enqueue(end(session))

        let second = makeQueue(fileURL: url)
        let before = await first.items
        let after = await second.items
        #expect(after == before)
        #expect(after.count == 3)
        // JSON keys inside a call stay exactly as they were.
        if case .sendFeedback(let call) = after[1].call {
            #expect(call.estimateShown?["bar_id"] == .number(2))
        } else {
            Issue.record("expected feedback second")
        }
    }

    @Test func corruptFileStartsEmpty() async throws {
        let url = temporaryFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let queue = makeQueue(fileURL: url)
        #expect(await queue.count == 0)
        await queue.enqueue(feedback())
        #expect(await makeQueue(fileURL: url).count == 1)
    }

    @Test func memoryOnlyQueueWorks() async {
        let queue = makeQueue(fileURL: nil)
        await queue.enqueue(feedback())
        #expect(await queue.flush() == .idle)
        #expect(transport.functions == ["send_feedback"])
    }

    // MARK: - Concurrency

    @Test func concurrentFlushesSendEachItemOnce() async {
        let slow = ScriptedTransport(delay: .milliseconds(20))
        let queue = makeQueue(transport: slow)
        for _ in 0..<5 {
            await queue.enqueue(feedback())
        }

        async let a = queue.flush()
        async let b = queue.flush()
        async let c = queue.flush()
        let statuses = await [a, b, c]

        #expect(statuses.allSatisfy { $0 == .idle })
        #expect(slow.sent.count == 5)
        #expect(await queue.count == 0)
    }

    @Test func itemsAddedDuringAFlushAreSent() async {
        let slow = ScriptedTransport(delay: .milliseconds(20))
        let queue = makeQueue(transport: slow)
        await queue.enqueue(feedback())

        async let flushing = queue.flush()
        await queue.enqueue(feedback())
        _ = await flushing
        // Whatever the first loop missed, the next flush sends.
        _ = await queue.flush()

        #expect(slow.sent.count == 2)
        #expect(await queue.count == 0)
    }
}

@Test func cancelSessionCallParameters() {
    let session = UUID()
    let anon = UUID()
    let call = PendingCall.cancelSession(CancelSessionCall(clientSessionId: session, anonId: anon))
    #expect(call.function == "cancel_session")
    #expect(call.parameters == [
        "p_client_session_id": .string(session.uuidString.lowercased()),
        "p_anon_id": .string(anon.uuidString.lowercased()),
    ])
    #expect(call.clientSessionId == session)
    let other = UUID()
    #expect(call.replacingSession(session, with: other).clientSessionId == other)
    #expect(call.withLocation(.denied) == call)
}
