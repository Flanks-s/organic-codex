import Foundation

struct CoreEndpointConfiguration: Sendable {
    let baseURL: URL
    let dataDirectory: URL
    let managesLocalCore: Bool
    var runtimeDirectory: URL?
    init(baseURL: URL, dataDirectory: URL, managesLocalCore: Bool = false, runtimeDirectory: URL? = nil) {
        self.baseURL = baseURL; self.dataDirectory = dataDirectory; self.managesLocalCore = managesLocalCore; self.runtimeDirectory = runtimeDirectory
    }
    /// Resolution alone performs no networking, marker read or process launch.
    static func resolve(arguments: [String], savedURL: String?, explicitURL: URL? = nil, dataDirectory: URL, runtimeDirectory: URL? = nil) throws -> Self {
        var selected = explicitURL
        var ownsDefault = false
        if selected == nil, let index = arguments.firstIndex(of: "--core-url") {
            guard arguments.indices.contains(index + 1), let url = URL(string: arguments[index + 1]) else { throw CoreWire.failure("--core-url requires an HTTP(S) URL.") }
            selected = url
        }
        if selected == nil, let savedURL {
            guard let url = URL(string: savedURL) else { throw CoreWire.failure("The saved Core URL is invalid.") }
            selected = url
        }
        if selected == nil { ownsDefault = true }
        // v2 runs its own Core beside the product's (18793): its own port and data directory (user, 10-29).
        let url = selected ?? URL(string: "http://127.0.0.1:18794")!
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { throw CoreWire.failure("The Core address must use HTTP or HTTPS and include a host.") }
        return .init(baseURL: url, dataDirectory: dataDirectory, managesLocalCore: ownsDefault, runtimeDirectory: runtimeDirectory)
    }
    static func production() -> Self {
        // v2 owns its own data. Connecting to an existing product Core requires explicit matching configuration.
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Organic Shell v2/Core", directoryHint: .isDirectory)
        return (try? resolve(arguments: ProcessInfo.processInfo.arguments, savedURL: UserDefaults.standard.string(forKey: "core.url"), dataDirectory: directory))
            ?? .init(baseURL: URL(string: "invalid-core-url://invalid")!, dataDirectory: directory)
    }
}

@MainActor protocol CoreProcessLaunching: AnyObject {
    var isRunning: Bool { get }
    var hasExited: Bool { get }
    func launch(_ configuration: CoreEndpointConfiguration) throws
}
@MainActor final class CoreLocalProcess: CoreProcessLaunching {
    private var process: Process?, output: FileHandle?
    var isRunning: Bool { process?.isRunning == true }
    var hasExited: Bool { process != nil && !isRunning }
    func launch(_ configuration: CoreEndpointConfiguration) throws {
        guard !isRunning else { throw CoreWire.failure("The owned Core is already starting. Retry its connection.") }
        let bundled = Bundle.main.resourceURL?.appending(path: "OrganicCore", directoryHint: .isDirectory)
        guard let runtime = [configuration.runtimeDirectory, bundled].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.appending(path: "core.py").path) }) else {
            throw CoreWire.failure("Organic Core is not bundled. Supply its runtime directory in the application bootstrap.")
        }
        guard let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first(where: FileManager.default.isExecutableFile(atPath:)) else { throw CoreWire.failure("Python 3.9 or newer is required to start Organic Core.") }
        try FileManager.default.createDirectory(at: configuration.dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = configuration.dataDirectory.appending(path: "core.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let file = try FileHandle(forWritingTo: log); try file.seekToEnd()
        let child = Process(); child.executableURL = URL(fileURLWithPath: python); child.currentDirectoryURL = configuration.dataDirectory
        child.arguments = [runtime.appending(path: "core.py").path, "--port", String(configuration.baseURL.port ?? 18794), "--data-dir", configuration.dataDirectory.path]
            + ["adapters.browser.adapter", "adapters.app_server", "adapters.capture", "adapters.scheduler.adapter", "adapters.preview", "adapters.workspace"].flatMap { ["--adapter", $0] }
        var environment = ProcessInfo.processInfo.environment; environment["PYTHONDONTWRITEBYTECODE"] = "1"; child.environment = environment
        child.standardInput = FileHandle.nullDevice; child.standardOutput = file; child.standardError = file
        try child.run(); process = child; output = file
    }
    // Closing a client never calls /shutdown or terminates this process: the backend owns ongoing work.
}

struct CoreCapability: Equatable, Sendable {
    let available: Bool?
    let status: String?
    let reason: String?
    let raw: JSONValue?
}
@MainActor final class CoreService {
    enum State: Equatable, Sendable { case disconnected, connecting, connected, failed(String) }
    static let shared = CoreService()
    let configuration: CoreEndpointConfiguration
    let client: any CoreTransport
    var baseURL: URL { configuration.baseURL }
    var dataDirectory: URL { configuration.dataDirectory }
    private(set) var state: State = .disconnected { didSet { onChange?() } }
    private(set) var capabilities: JSONValue = [:]
    private(set) var health: JSONValue = .null
    private(set) var localIdentity: CoreLocalIdentity?
    var isLocalBackend: Bool { localIdentity?.verified == true }
    var runtimeVersion: String? { capabilities["version"]?.stringValue ?? health["version"]?.stringValue }
    var schedulerVersion: String? { capabilities["features"]?["scheduler"]?["version"]?.stringValue }
    var authorizationCount: Int? { health["authorizationCount"]?.intValue }
    var onChange: (() -> Void)?
    private let launcher: any CoreProcessLaunching
    private let clock: any CoreRuntimeClock
    private let marker: @MainActor () -> JSONValue?
    private var connection: Task<Void, Error>?
    private var generation = 0
    init(configuration: CoreEndpointConfiguration = .production(), transport: (any CoreTransport)? = nil,
         launcher: (any CoreProcessLaunching)? = nil, clock: any CoreRuntimeClock = CoreSystemClock(), marker: (@MainActor () -> JSONValue?)? = nil) {
        self.configuration = configuration; client = transport ?? CoreClient(baseURL: configuration.baseURL)
        self.launcher = launcher ?? CoreLocalProcess(); self.clock = clock
        self.marker = marker ?? { (try? Data(contentsOf: configuration.dataDirectory.appending(path: "runtime-instance.json"))).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
    }
    var status: String { switch state { case .disconnected: "Disconnected"; case .connecting: "Connecting…"; case .connected: "Connected"; case .failed(let message): message } }
    func capability(_ name: String) -> CoreCapability {
        let value = capabilities["features"]?[name]
        return .init(available: value?["available"]?.boolValue, status: value?["status"]?.stringValue, reason: value?["reason"]?.stringValue, raw: value)
    }
    func connect() async throws {
        if let connection { return try await connection.value }
        generation += 1; let epoch = generation
        let task = Task { @MainActor in
            state = .connecting
            do {
                guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil else { throw CoreWire.failure("The Core address must use HTTP or HTTPS.") }
                do { try await checkHealth() }
                catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .timedOut].contains(error.code) {
                    guard configuration.managesLocalCore, ["localhost", "127.0.0.1", "::1", "[::1]"].contains(baseURL.host ?? "") else { throw CoreWire.failure("Core is unreachable at the configured endpoint. No local substitute was started.") }
                    try launcher.launch(configuration)
                    var ready = false
                    for _ in 0..<100 {
                        try Task.checkCancellation()
                        if launcher.hasExited { throw CoreWire.failure("Core exited during startup. Inspect its configured core.log.") }
                        do { try await checkHealth(); ready = true; break }
                        catch let retry as URLError where [.cannotConnectToHost, .networkConnectionLost, .timedOut].contains(retry.code) { try await clock.sleep(seconds: 0.25) }
                    }
                    guard ready else { throw CoreWire.failure("Core is still starting. Retry its connection.") }
                }
                capabilities = try await client.request(path: "/capabilities"); try Task.checkCancellation()
                guard generation == epoch else { throw CancellationError() }; state = .connected
            } catch { if generation == epoch { state = error is CancellationError ? .disconnected : .failed(error.localizedDescription) }; throw error }
        }
        connection = task
        defer { if generation == epoch { connection = nil } }
        try await task.value
    }
    func checkHealth() async throws {
        let value = try await client.request(path: "/health", timeout: 2)
        guard value["name"]?.stringValue == "Organic Codex Core" else { throw CoreWire.failure("Another service is using the Core address.") }
        guard value["backendConnected"]?.boolValue == true else { throw CoreWire.failure("Core is running, but its model runtime is disconnected.") }
        health = value; localIdentity = .init(health: value, localMarker: marker(), dataDirectory: dataDirectory)
    }
    func refreshCapabilities() async throws { capabilities = try await client.request(path: "/capabilities"); onChange?() }
    func readAuthorizations() async throws -> JSONValue { try await client.request(path: "/authorizations") }
    /// Called only for an explicit user choice; capability availability never implies authorization.
    func grantAuthorization(threadID: String, app: String, connectorID: String? = nil, tools: [String]? = nil) async throws -> JSONValue {
        var body: [String: JSONValue] = ["threadId": .string(threadID), "app": .string(app)]
        if let connectorID { body["connectorId"] = .string(connectorID) }
        if let tools { body["tools"] = .array(tools.map(JSONValue.string)) }
        return try await client.request("POST", path: "/authorizations", body: .object(body))
    }
    func revokeAuthorization(_ id: String) async throws -> JSONValue { try await client.request("DELETE", path: "/authorizations/" + CoreWire.segment(id)) }
    func disconnect() { generation += 1; connection?.cancel(); connection = nil; state = .disconnected }
}
