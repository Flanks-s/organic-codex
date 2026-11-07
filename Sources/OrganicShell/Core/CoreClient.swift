import Foundation

/// One HTTP attempt per call. The runtime owns reconnect/backoff and write reconciliation.
/// URLSession is Sendable; the client has no mutable decoder or connection state.
struct CoreClient: CoreTransport, Sendable {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// ORGANIC_READ_ONLY=1 (tools/m11/long-real.sh): a scripted run on real threads. Whatever gets pressed or typed, only reads
    /// and lists reach Core, so a keystroke meant for another app can't become a real model call.
    private static let readOnly = ProcessInfo.processInfo.environment["ORGANIC_READ_ONLY"] == "1"
    private static func refused(_ method: String, _ path: String, _ body: JSONValue?) -> Bool {
        guard readOnly, method != "GET" else { return false }
        guard path == "/rpc", let name = body?["method"]?.stringValue else { return true }
        return !(name.hasSuffix("/read") || name.hasSuffix("/list"))
    }

    func request(_ method: String = "GET", path: String, body: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        if Self.refused(method, path, body) { throw CoreWire.failure("Read-only run: \(method) \(path) refused") }
        var request = URLRequest(url: try endpoint(path))
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = try httpStatus(response)
        return try Self.result(data, status: status)
    }

    func rpc(_ method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await request("POST", path: "/rpc", body: ["method": .string(method), "params": .object(params)])
    }

    func events(since: Int, threadID: String? = nil) -> AsyncThrowingStream<CoreEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard var components = URLComponents(url: try endpoint("/events"), resolvingAgainstBaseURL: true) else {
                        throw URLError(.badURL)
                    }
                    components.queryItems = [URLQueryItem(name: "since", value: String(since))]
                    if let threadID { components.queryItems?.append(URLQueryItem(name: "threadId", value: threadID)) }
                    guard let url = components.url else { throw URLError(.badURL) }
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(String(since), forHTTPHeaderField: "Last-Event-ID")
                    // Core emits a keepalive every 15 seconds. URLSession cancellation cancels
                    // the underlying request while awaiting headers or consuming AsyncBytes.
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = try httpStatus(response)
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw Self.failure(body, status: status)
                    }
                    guard let http = response as? HTTPURLResponse,
                          http.mimeType?.lowercased() == "text/event-stream" else {
                        throw CoreError(code: nil, message: "Core did not return an event stream.", data: nil, httpStatus: status)
                    }
                    var parser = CoreSSEParser(since: since)
                    // Feed complete transport lines, preserving CRLF and UTF-8 for the parser.
                    // Parsing per byte would allocate a Data and result array for each byte.
                    var chunk = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if byte == 10 || byte == 13 {
                            for event in try parser.append(chunk) {
                                if case .terminated = continuation.yield(event) { return }
                            }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { _ = try parser.append(chunk) }
                    parser.finish()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port else {
            throw URLError(.badURL)
        }
        return url
    }

    private func httpStatus(_ response: URLResponse) throws -> Int {
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return response.statusCode
    }

    private static func result(_ data: Data, status: Int) throws -> JSONValue {
        guard (200..<300).contains(status) else { throw failure(data, status: status) }
        let envelope: JSONValue
        do { envelope = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw CoreError(code: nil, message: "Core returned invalid JSON.", data: .string(String(decoding: data, as: UTF8.self)), httpStatus: status) }
        if envelope["error"] != nil { throw failure(data, status: status) }
        guard let result = envelope["result"] else {
            throw CoreError(code: nil, message: "Core response is missing result.", data: envelope, httpStatus: status)
        }
        return result
    }

    private static func failure(_ data: Data, status: Int) -> CoreError {
        let envelope = try? JSONDecoder().decode(JSONValue.self, from: data)
        let error = envelope?["error"]
        return CoreError(code: error?["code"]?.intValue,
                         message: error?["message"]?.stringValue ?? "Core HTTP request failed (\(status)).",
                         data: error?["data"] ?? envelope ?? .string(String(decoding: data, as: UTF8.self)),
                         httpStatus: status)
    }
}
