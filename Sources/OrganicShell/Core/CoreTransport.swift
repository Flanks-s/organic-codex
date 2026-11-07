import Foundation

/// One attempt only; recovery and write reconciliation belong to the runtime.
protocol CoreTransport: Sendable {
    func request(_ method: String, path: String, body: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue
    func events(since: Int, threadID: String?) -> AsyncThrowingStream<CoreEvent, Error>
}
extension CoreTransport {
    func request(_ method: String = "GET", path: String, body: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await request(method, path: path, body: body, timeout: timeout)
    }
    func rpc(_ method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await request("POST", path: "/rpc", body: ["method": .string(method), "params": .object(params)], timeout: nil)
    }
    func events(since: Int) -> AsyncThrowingStream<CoreEvent, Error> { events(since: since, threadID: nil) }
}
enum CoreWire {
    static func segment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "" }
    static func eventPage(threadID: String, since: Int, limit: Int = 100) -> String {
        var c = URLComponents(); c.path = "/events.json"
        c.queryItems = [.init(name: "threadId", value: threadID), .init(name: "since", value: String(since)), .init(name: "limit", value: String(limit))]
        return c.string!
    }
    static func failure(_ message: String) -> CoreError { .init(code: nil, message: message, data: nil, httpStatus: nil) }
    static func isAmbiguous(_ error: Error) -> Bool {
        guard let core = error as? CoreError else { return true }
        if let status = core.httpStatus, (200..<300).contains(status), core.code == nil { return true }
        return (core.httpStatus ?? 0) >= 500 || core.message.localizedCaseInsensitiveContains("timeout") || core.message.localizedCaseInsensitiveContains("timed out")
    }
}
protocol CoreRuntimeClock: Sendable { func sleep(seconds: TimeInterval) async throws }
struct CoreSystemClock: CoreRuntimeClock { func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(max(0, seconds))) } }
struct CoreReconnectPolicy: Equatable, Sendable {
    var initial: TimeInterval = 1.5
    var maximum: TimeInterval = 30
    func delay(attempt: Int) -> TimeInterval { min(maximum, initial * pow(2, Double(min(20, max(0, attempt))))) }
}
