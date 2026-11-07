import Foundation

enum SettingsMode: String,Sendable { case demo, live }
struct SettingsScope: Equatable,Sendable { var endpoint:String,device:String }
struct SettingsReadRequest: Equatable,Sendable { var pane:String,scope:SettingsScope }
struct SettingsReadResult: Sendable {
    var snapshots:[String:JSONValue]
    var capabilities:[String:SettingsCapability] = [:]
    var notice:String?
    /// Invalidations are not readbacks. A visible matching pane coalesces them into a new read.
    /// Null snapshot values withdraw stale account/usage/OAuth data immediately.
    var invalidatedPanes:Set<String> = []
    var errors:[String:String] = [:]
    var clearedErrors:Set<String> = []
    var clearsNotice=false
}
struct SettingsCapability: Equatable,Sendable { var available:Bool; var reason:String? }
struct SettingsOperation: Equatable,Sendable {
    enum Kind:String,CaseIterable,Sendable {
        case login="account/login/start",cancelLogin="account/login/cancel",logout="account/logout"
        case configWrite="config/batchWrite",skillWrite="skills/config/write",skillInstall="skills/installFolder"
        case pluginInstall="plugin/install",pluginUninstall="plugin/uninstall",pluginEnable="plugin/config/write"
        case mcpWrite="mcp/config/write",mcpLogin="mcpServer/oauth/login"
        case hotkeyWrite="capture/hotkey",scheduleCreate="scheduler/jobs",schedulePause="scheduler/pause"
        case notificationAck="notifications/ack",notificationPermission="notifications/requestPermission"
        case authorizationRevoke="authorizations/revoke",reconnect="connection/reconnect",endpointSave="connection/saveEndpoint"
        case unarchive="thread/unarchive",archiveAll="thread/archiveAll",loadArchived="thread/listArchived"
        case openLocal="local/open",demo="demo/mutation"
    }
    var kind:Kind
    var payload:JSONValue = [:]
    var scope:SettingsScope
}
struct SettingsWriteResult: Sendable {
    /// Acknowledged readback only. Never optimistically turn a Live control on.
    var snapshots:[String:JSONValue] = [:]
    var notice:String?
    var browserURL:String?
}

/// Live adapter maps these requests to CoreSettingsController's operations. No networking or local file I/O in views.
/// read must load every backend cursor page for model/list and mcpServerStatus/list. Snapshot shapes are the product's
/// account/config/layers/limits/models/plugins/skills/mcp/health/jobs/runs/notifications/tabs/hotkey/authorizations.
@MainActor protocol SettingsDataSource:AnyObject {
    var mode:SettingsMode { get }
    var endpointIdentity:String { get }
    var connectionStatus:String { get }
    var localFilesAvailable:Bool { get }
    var supportedOperations:Set<SettingsOperation.Kind> { get }
    func read(_ request:SettingsReadRequest) async throws -> SettingsReadResult
    func perform(_ operation:SettingsOperation) async throws -> SettingsWriteResult
}

/// Optional in-process change stream. Each subscriber owns its scope and token; callbacks contain acknowledged
/// snapshots, never optimistic UI edits. Removing a token must stop delivery, including while Settings is closed.
@MainActor protocol SettingsObservableDataSource:SettingsDataSource {
    @discardableResult func observeChanges(scope:SettingsScope,_ change:@escaping (SettingsReadResult)->Void)->UUID
    func removeChangeObserver(_ token:UUID)
}

/// Local delivery preferences, separate from Core's inbox and the OS authorization state.
struct SettingsNotificationPolicy:Equatable,Sendable {
    var enabled=true
    var jobs:[String:String]=[:]
    func allows(jobID:String?,status:String?)->Bool {
        enabled && Self.allows(policy:jobs[jobID ?? ""] ?? "all",status:status)
    }
    static func allows(policy:String,status:String?)->Bool {
        let needsAttention=["failed","submissionFailed","submissionUnknown","submissionUnconfirmed","interrupted"].contains(status ?? "")
        return policy != "off" && (policy != "failed" || needsAttention)
    }
}
@MainActor protocol SettingsNotificationPolicyDataSource:SettingsDataSource {
    func setNotificationPolicy(_ policy:SettingsNotificationPolicy)
}

enum SettingsDataError:LocalizedError {
    case unsupported(String),invalid(String),stale,superseded
    var errorDescription:String? {
        switch self { case .unsupported(let reason),.invalid(let reason):reason; case .stale:"The connection or device changed. Refresh before trying again.";case .superseded:"Settings changed while loading. Refreshing the current state." }
    }
}

@MainActor final class SettingsUnavailableDataSource:SettingsDataSource {
    let mode=SettingsMode.live,endpointIdentity="unconfigured",connectionStatus="Not connected",localFilesAvailable=false
    let supportedOperations=Set<SettingsOperation.Kind>()
    func read(_ request:SettingsReadRequest) async throws -> SettingsReadResult { throw SettingsDataError.unsupported("Connect to Organic Core first.") }
    func perform(_ operation:SettingsOperation) async throws -> SettingsWriteResult { throw SettingsDataError.unsupported("Connect to Organic Core first.") }
}
