import Foundation

/// Sends one RPC call to the server. Tests substitute a fake.
public protocol RPCTransport: Sendable {
    /// Calls `function` with a JSON object of named arguments. Returns the HTTP
    /// status and body, or throws when the request never got an HTTP response
    /// (offline, timeout).
    func call(_ function: String, body: Data) async throws -> RPCResponse
}

public struct RPCResponse: Sendable, Hashable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Supabase PostgREST: `POST {url}/rest/v1/rpc/{function}` with the publishable key.
public struct HTTPTransport: RPCTransport {
    public let baseURL: URL
    public let apiKey: String
    public let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func call(_ function: String, body: Data) async throws -> RPCResponse {
        let url = baseURL.appending(path: "rest/v1/rpc/\(function)")
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return RPCResponse(status: status, body: data)
    }
}

public enum APIError: Error, Sendable, Hashable {
    /// The server answered with an HTTP error (bad input is 400).
    case http(status: Int, message: String)
    /// The reply wasn't the expected JSON.
    case badReply
}

/// The calls that need an answer right away and don't go through the queue:
/// reading bars and estimates, Delete my data, and Made a wrong report?.
public struct APIClient: Sendable {
    public let transport: any RPCTransport

    public init(transport: any RPCTransport) {
        self.transport = transport
    }

    public func bars(anonId: UUID?) async throws -> [Bar] {
        try await read("get_bars", anonId: anonId)
    }

    public func estimates(anonId: UUID?) async throws -> Estimates {
        try await read("get_estimates", anonId: anonId)
    }

    /// One night of a bar's history (FR-43). Leave `night` out for tonight.
    public func barHistory(anonId: UUID?, barId: Int64, night: NightDate?) async throws -> BarHistory {
        var parameters: [String: JSONValue] = ["p_bar_id": .int(barId)]
        parameters["p_anon_id"] = anonId.map(JSONValue.uuid)
        parameters["p_night"] = night.map { .string($0.description) }
        return try await send("bar_history", parameters)
    }

    /// Deletes everything tied to the ID (FR-32). Returns the number of rows removed.
    public func deleteMyData(anonId: UUID) async throws -> Int {
        // Replies read as JSONValue keep their snake_case keys, so use a plain decoder.
        let reply: JSONValue = try await send("delete_my_data", ["p_anon_id": .uuid(anonId)],
                                              decoder: JSONDecoder())
        guard reply["ok"]?.boolValue == true, let rows = reply["rows_removed"]?.intValue else {
            throw APIError.badReply
        }
        return rows
    }

    /// The person's own reports and finished waits from the last 24 hours, newest first (FR-41).
    public func myRecentReports(anonId: UUID) async throws -> [MyReport] {
        try await send("my_recent_reports", ["p_anon_id": .uuid(anonId)])
    }

    /// Deletes one report, or a finished wait and its reports, for good (FR-41).
    public func deleteReport(anonId: UUID, target: MyReport.Target) async throws -> DeleteReportResult {
        var parameters: [String: JSONValue] = ["p_anon_id": .uuid(anonId)]
        switch target {
        case .report(let id): parameters["p_client_report_id"] = .uuid(id)
        case .wait(let id): parameters["p_client_session_id"] = .uuid(id)
        }
        let reply: JSONValue = try await send("delete_report", parameters, decoder: JSONDecoder())
        if reply["ok"]?.boolValue == true { return .deleted }
        switch reply["error"]?.stringValue {
        case "not_found": return .notFound
        case "session_open": return .sessionOpen
        default: throw APIError.badReply
        }
    }

    /// Sends one queued call. Used by `OfflineQueue`.
    public func send(_ call: PendingCall) async throws -> RPCResponse {
        try await transport.call(call.function, body: Self.body(call.parameters))
    }

    private func read<T: Decodable>(_ function: String, anonId: UUID?) async throws -> T {
        var parameters: [String: JSONValue] = [:]
        parameters["p_anon_id"] = anonId.map(JSONValue.uuid)
        return try await send(function, parameters)
    }

    private func send<T: Decodable>(_ function: String, _ parameters: [String: JSONValue],
                                    decoder: JSONDecoder = .lineMap) async throws -> T {
        let response = try await transport.call(function, body: Self.body(parameters))
        guard (200..<300).contains(response.status) else {
            throw APIError.http(status: response.status, message: Self.message(in: response.body))
        }
        do {
            return try decoder.decode(T.self, from: response.body)
        } catch {
            throw APIError.badReply
        }
    }

    static func body(_ parameters: [String: JSONValue]) -> Data {
        // Encoding a dictionary of JSONValue cannot fail.
        (try? JSONEncoder().encode(parameters)) ?? Data("{}".utf8)
    }

    /// The `message` field of a PostgREST error body, or the raw text.
    static func message(in body: Data) -> String {
        if let json = try? JSONDecoder().decode(JSONValue.self, from: body),
           let message = json["message"]?.stringValue {
            return message
        }
        return String(decoding: body, as: UTF8.self)
    }
}
