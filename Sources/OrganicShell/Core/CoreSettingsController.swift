import Foundation

enum CoreNotificationDeliveryResult:Equatable,Sendable {
    case delivered
    case notAuthorized(String)
    case suppressed
}

/// Product CoreSettingsController adapted to the current SettingsDataSource contract.
/// UI effects (OAuth browser, notification permission, local file reveal) are explicit host callbacks.
@MainActor final class CoreSettingsController: SettingsObservableDataSource, SettingsNotificationPolicyDataSource {
    let mode=SettingsMode.live
    private(set) var endpointIdentity="unconfigured"
    var connectionStatus:String { service?.status ?? (client == nil ? "Not connected":"Connected Core endpoint") }
    var localFilesAvailable:Bool { service?.isLocalBackend == true }
    private(set) var snapshots:[String:JSONValue]=[:],errors:[String:String]=[:],busy:Set<String>=[]
    private(set) var pendingLoginID:String?
    var notice:String?,notificationPermission="Not checked"
    var notificationsEnabled=true,jobNotificationPolicies:[String:String]=[:]
    var onChange:(()->Void)?
    /// Compatibility hook; SettingsSession now subscribes directly, so App need not reload on every event.
    var onInvalidation:((Set<String>)->Void)?
    var onNotification:((JSONValue)->Void)?
    var onPermissionRequest:(() async throws -> Bool)?
    /// Read current OS authorization without prompting. No callback is invoked by configure/receive.
    var onPermissionStatus:(() async throws -> String)?
    /// Preferred OS delivery bridge. It must check current authorization without asking for permission.
    var onDeliverNotification:((JSONValue) async throws -> CoreNotificationDeliveryResult)?
    /// Optional dynamic host policy (for example, inactive-app-only delivery).
    var notificationPolicyProvider:(() -> SettingsNotificationPolicy)?
    var onSaveEndpoint:((URL) async throws -> Void)?
    var onOpenLocal:((URL) async throws -> Void)?
    var onInstallSkillFolder:((URL) async throws -> JSONValue)?
    private var reconnectAction:(() async throws -> Void)?
    private var client:(any CoreTransport)?
    private weak var runtime:(any ConversationRuntime)?
    private var service:CoreService?
    private var generation=0
    var coreDeviceID="mac"
    private var observers:[UUID:(scope:SettingsScope,change:(SettingsReadResult)->Void)]=[:]
    private var paneVersions:[String:Int]=[:],resourceVersions:[String:Int]=[:]
    private var completedLogins:[String:JSONValue]=[:]
    private var asynchronousErrors:[String:String]=[:]
    private var notificationTasks:[String:Task<Void,Never>]=[:]
    private var deliveredNotifications:Set<String>=[],deliveryOrder:[String]=[]
    isolated deinit { for task in notificationTasks.values {task.cancel()} }
    var changeObserverCount:Int { observers.count }
    func setNotificationPolicy(_ policy:SettingsNotificationPolicy) {
        notificationsEnabled=policy.enabled;jobNotificationPolicies=policy.jobs
    }
    @discardableResult func observeChanges(scope:SettingsScope,_ change:@escaping (SettingsReadResult)->Void)->UUID {
        let token=UUID();observers[token]=(scope,change);return token
    }
    func removeChangeObserver(_ token:UUID) { observers[token]=nil }
    private func publish(_ result:SettingsReadResult) {
        for token in Array(observers.keys) {
            guard let observer=observers[token],observer.scope.endpoint == endpointIdentity,observer.scope.device == coreDeviceID else{continue}
            observer.change(result)
        }
    }
    private func invalidate(_ panes:Set<String>,values:[String:JSONValue]=[:],eventErrors:[String:String]=[:],cleared:Set<String>=[]) {
        for pane in panes {paneVersions[pane,default:0]+=1}
        for key in values.keys {resourceVersions[key,default:0]+=1}
        snapshots.merge(values){_,new in new}
        for key in cleared {errors[key]=nil;asynchronousErrors[key]=nil}
        errors.merge(eventErrors){_,new in new};asynchronousErrors.merge(eventErrors){_,new in new}
        notice=nil
        publish(.init(snapshots:values,invalidatedPanes:panes,errors:eventErrors,clearedErrors:cleared,clearsNotice:true))
        onInvalidation?(panes)
    }
    private func publishAsyncError(_ message:String?,key:String) {
        errors[key]=message;asynchronousErrors[key]=message
        publish(.init(snapshots:[:],errors:message.map{[key:$0]} ?? [:],clearedErrors:message == nil ? [key]:[]))
    }
    /// Also usable when the OS authorization changes while Settings is already open.
    func updateNotificationPermission(_ status:String) {
        resourceVersions["permission",default:0]+=1
        notificationPermission=status;snapshots["permission"] = .string(status)
        publish(.init(snapshots:["permission":.string(status)]));onChange?()
    }
    var supportedOperations:Set<SettingsOperation.Kind> {
        guard client != nil else { return [] }
        var result:Set<SettingsOperation.Kind>=[.login,.cancelLogin,.logout,.configWrite,.skillWrite,.pluginInstall,.pluginUninstall,.pluginEnable,.mcpWrite,.mcpLogin,.hotkeyWrite,.scheduleCreate,.schedulePause,.notificationAck,.authorizationRevoke,.unarchive,.archiveAll,.loadArchived]
        if reconnectAction != nil { result.insert(.reconnect) }
        if onSaveEndpoint != nil { result.insert(.endpointSave) }
        if onPermissionRequest != nil { result.insert(.notificationPermission) }
        if localFilesAvailable,onOpenLocal != nil { result.insert(.openLocal) }
        if localFilesAvailable { result.insert(.skillInstall) }
        return result
    }
    func configure(client:any CoreTransport,runtime:(any ConversationRuntime)?=nil,endpoint:String,service:CoreService?=nil,reconnect:(() async throws -> Void)?=nil) {
        let withdrawn=Dictionary(uniqueKeysWithValues:snapshots.keys.map{($0,JSONValue.null)})
        generation+=1;for task in notificationTasks.values{task.cancel()};notificationTasks=[:]
        self.client=client; self.runtime=runtime; self.service=service; endpointIdentity=endpoint
        reconnectAction=reconnect; snapshots=[:]; errors=[:]; busy=[]; pendingLoginID=nil; notice=nil
        paneVersions=[:];resourceVersions=[:];completedLogins=[:];asynchronousErrors=[:];deliveredNotifications=[];deliveryOrder=[]
        notificationPermission="Not checked"
        invalidate(Set(["account","profile","usage","plugins","plugins/mcp","notifications","scheduler"]),values:withdrawn,cleared:["login","oauth","notifications"])
        snapshots=[:] // A new configuration owns no acknowledged data from the old connection.
        onChange?()
    }
    subscript(_ key:String)->JSONValue { snapshots[key] ?? .null }
    var userLayer:JSONValue? { Self.userLayer(in:snapshots["config"] ?? .null) }
    var configPath:String? { userLayer?["name"]?["file"]?.stringValue }
    private static func userLayer(in value:JSONValue)->JSONValue? { value["layers"]?.arrayValue?.first { $0["name"]?["type"] == "user" && $0["name"]?["profile"]?.stringValue == nil } }
    private func validate(_ scope:SettingsScope,epoch:Int?=nil) throws {
        guard scope.endpoint == endpointIdentity,scope.device == coreDeviceID,epoch == nil || epoch == generation else { throw SettingsDataError.stale }
    }
    private func requiredClient() throws -> any CoreTransport { guard let client else { throw CoreWire.failure("Connect to Core first.") }; return client }
    /// Product threadOptions: loaded, unarchived conversations with an actual backend identity.
    /// Local draft IDs must never become Appshots/scheduler targets.
    private var threadOptions:JSONValue {
        .array((runtime?.store.conversations ?? []).compactMap { conversation in
            guard !conversation.archived,let id=conversation.backendThreadID,!id.isEmpty else { return nil }
            return ["id":.string(conversation.id),"backendThreadID":.string(id),"title":.string(conversation.title),"archived":false]
        })
    }
    /// Settings records accepts arrays or `data`; retain the wire envelope and its metadata as well.
    private static func browserTabs(_ value:JSONValue) throws -> JSONValue {
        if let tabs=value["tabs"]?.arrayValue {
            var result=value.objectValue ?? [:]; result["data"] = .array(tabs); return .object(result)
        }
        if value.arrayValue != nil || value["data"]?.arrayValue != nil { return value }
        throw CoreWire.failure("Core returned no browser tabs list.")
    }
    private func paginated(_ method:String,client:any CoreTransport,params:[String:JSONValue]=[:]) async throws -> JSONValue {
        var values:[JSONValue]=[],cursor:String?,seen:Set<String>=[]
        repeat {
            var p=params; p["limit"]=100; if let cursor { p["cursor"] = .string(cursor) }
            let result=try await client.rpc(method,params:p); values += result["data"]?.arrayValue ?? []
            cursor=result["nextCursor"]?.stringValue
            if let cursor,!seen.insert(cursor).inserted { throw CoreWire.failure("Core repeated a settings-list cursor.") }
        } while cursor != nil
        return ["data":.array(values)]
    }
    func read(_ request:SettingsReadRequest) async throws -> SettingsReadResult {
        try Task.checkCancellation();try validate(request.scope); let client=try requiredClient(),epoch=generation,key="read:"+request.pane
        guard !busy.contains(key) else { throw CoreWire.failure("This settings pane is already loading.") }
        busy.insert(key); onChange?(); defer { if epoch == generation { busy.remove(key); onChange?() } }
        let version=paneVersions[request.pane,default:0],permissionVersion=resourceVersions["permission",default:0]
        var values:[String:JSONValue]=[:],failures:[String:String]=[:]
        func get(_ key:String,_ body:() async throws -> JSONValue) async {
            do {values[key]=try await body()} catch {
                if ["account","limits"].contains(key) {values[key] = .null}
                failures[key]=error.localizedDescription
            }
        }
        // The capability document is preserved verbatim; absent availability is not authorization.
        await get("capabilities") { try await client.request(path:"/capabilities") }
        switch request.pane {
        case "account","profile": await get("account") { try await client.rpc("account/read") }
        case "usage":
            await get("account") { try await client.rpc("account/read") }; await get("limits") { try await client.rpc("account/rateLimits/read") }
        case "configuration":
            await get("config") { try await client.rpc("config/read",params:["includeLayers":true]) }
            await get("models") { try await paginated("model/list",client:client) }
        case "plugins":
            await get("plugins") { try await client.request("POST",path:"/app-server/plugins/list",body:[:]) }
            await get("skills") { try await client.request("POST",path:"/app-server/skills/list",body:["forceReload":true]) }
            await get("mcp") { try await paginated("mcpServerStatus/list",client:client) }
            await get("config") { try await client.rpc("config/read",params:["includeLayers":true]) }
        case "plugins/skills":
            await get("skills") { try await client.request("POST",path:"/app-server/skills/list",body:["forceReload":true]) }
        case "plugins/mcp":
            await get("mcp") { try await paginated("mcpServerStatus/list",client:client) }
            await get("config") { try await client.rpc("config/read",params:["includeLayers":true]) }
        case "personalization","personalization/rules","personalization/agents","computer","browser":
            await get("config") { try await client.rpc("config/read",params:["includeLayers":true]) }
            if request.pane == "browser" { await get("tabs") { try Self.browserTabs(try await client.request(path:"/browser/tabs")) } }
            if request.pane == "computer" { await get("authorizations") { try await client.request(path:"/authorizations") } }
        case "appshots": await get("hotkey") { try await client.request(path:"/capture/hotkey") }
        case "scheduler","notifications":
            await get("jobs") { try await client.request(path:"/scheduler/jobs") }
            await get("runs") { try await client.request(path:"/scheduler/runs") }
            await get("notifications") { try await client.request(path:"/notifications") }
            values["permission"] = .string("Not checked")
            await get("permission") { .string(try await onPermissionStatus?() ?? notificationPermission) }
        case "storage","storage/cleanup","storage/worktrees","connections": await get("health") { try await client.request(path:"/health") }
        case "data","data/archived","archived": await get("archived") { try await client.rpc("thread/list",params:["archived":true,"limit":50,"sortKey":"updated_at"]) }
        default: break
        }
        try Task.checkCancellation();try validate(request.scope,epoch:epoch)
        guard version == paneVersions[request.pane,default:0] else {throw SettingsDataError.superseded}
        if values["permission"] != nil,permissionVersion != resourceVersions["permission",default:0] {
            values["permission"] = .string(notificationPermission);failures["permission"]=nil
        } else if failures["permission"] != nil {values["permission"] = "Not checked"}
        if let permission=values["permission"]?.stringValue {notificationPermission=permission}
        values["threads"]=threadOptions
        // A closed SettingsSession missed completions; its next read must replace old Cancel/error state too.
        values["login"]=pendingLoginID.map { snapshots["login"] ?? ["loginId":.string($0)] } ?? .null
        if let store=runtime?.store {
            values["devices"] = .array(store.devices.map { ["id":.string($0.id),"name":.string($0.name),"online":.bool($0.online),"local":.bool(localFilesAvailable && $0.id == coreDeviceID)] })
            values["projects"] = .array(store.projects.map { ["id":.string($0.id),"name":.string($0.name),"deviceID":.string($0.deviceID)] })
        }
        snapshots.merge(values) { _,v in v }
        for key in values.keys {errors[key]=nil};errors.merge(failures){_,new in new}
        errors.merge(asynchronousErrors){_,new in new}
        var capabilities:[String:SettingsCapability]=[:]
        for (name,value) in values["capabilities"]?["features"]?.objectValue ?? [:] {
            if let available=value["available"]?.boolValue { capabilities[name] = .init(available:available,reason:value["reason"]?.stringValue) }
        }
        let message=failures.keys.sorted().map { $0+": "+failures[$0]! }.joined(separator:"\n")
        let eventKeys:Set<String>=["login","oauth","notifications"]
        let eventErrors=asynchronousErrors
        let result=SettingsReadResult(snapshots:values,capabilities:capabilities,notice:message.isEmpty ? nil:message,
                                      errors:eventErrors,clearedErrors:eventKeys.subtracting(eventErrors.keys),clearsNotice:true)
        publish(result);return result
    }
    func perform(_ operation:SettingsOperation) async throws -> SettingsWriteResult {
        try validate(operation.scope)
        guard supportedOperations.contains(operation.kind),!busy.contains("write") else { throw SettingsDataError.unsupported("This operation is unavailable or another write is pending.") }
        let client=try requiredClient(),epoch=generation,p=operation.payload,versions=resourceVersions
        busy.insert("write"); errors["write"]=nil; onChange?()
        defer { if epoch == generation { busy.remove("write"); onChange?() } }
        var values:[String:JSONValue]=[:],message:String?,browser:String?
        func rpc(_ method:String,_ params:JSONValue) async throws -> JSONValue { try validate(operation.scope,epoch:epoch); return try await client.rpc(method,params:params.objectValue ?? [:]) }
        func archiveAcknowledged(_ id:String,_ archived:Bool) throws {
            try validate(operation.scope,epoch:epoch)
            if let store=runtime?.store,let conversation=store.backendConversation(id) {
                conversation.archived=archived; conversation.archivedAt=archived ? Date():nil; store.changed(conversation)
            }
        }
        func saveConfig(_ input:JSONValue) async throws {
            guard input["edits"]?.arrayValue?.isEmpty == false else { throw CoreWire.failure("Configuration edits are empty.") }
            var args=input.objectValue ?? [:]
            // Preserve the UI's expectedVersion. If absent, capture the actual writable user layer once.
            if args["expectedVersion"] == nil {
                let current=try await client.rpc("config/read",params:["includeLayers":true])
                let user=Self.userLayer(in:current)
                if let path=user?["name"]?["file"] { args["filePath"]=path }
                if let version=user?["version"] { args["expectedVersion"]=version }
            }
            try validate(operation.scope,epoch:epoch)
            _ = try await client.rpc("config/batchWrite",params:args)
            values["config"]=try await client.rpc("config/read",params:["includeLayers":true])
        }
        func edits(_ key:String,_ value:JSONValue) -> JSONValue { ["edits":[["keyPath":.string(key),"value":value,"mergeStrategy":"upsert"]],"reloadUserConfig":true] }
        do {
            switch operation.kind {
            case .login:
                guard pendingLoginID == nil else { throw CoreWire.failure("A sign-in is already pending.") }
                let result=try await rpc("account/login/start",["type":"chatgpt"]); values["login"]=result
                browser=result["authUrl"]?.stringValue ?? result["browserURL"]?.stringValue
                guard let address=browser,let url=URL(string:address),["http","https"].contains(url.scheme ?? "") else { throw CoreWire.failure("Core returned no valid sign-in URL.") }
            case .cancelLogin:
                guard let id=p["loginId"]?.stringValue ?? pendingLoginID else { throw CoreWire.failure("There is no pending sign-in.") }
                _ = try await rpc("account/login/cancel",["loginId":.string(id)]); values["login"] = .null
            case .logout:
                _ = try await client.rpc("account/logout"); values["account"]=try await client.rpc("account/read"); values["limits"] = .null
            case .configWrite: try await saveConfig(p); message="Saved by Core; new defaults apply to new chats."
            case .skillWrite: _ = try await rpc("skills/config/write",p); values["skills"]=try await client.request("POST",path:"/app-server/skills/list",body:["forceReload":true])
            case .skillInstall:
                guard localFilesAvailable,let source=p["path"]?.stringValue else { throw SettingsDataError.unsupported("Install skill folders on the verified Core host.") }
                if let onInstallSkillFolder { values["skills"]=try await onInstallSkillFolder(URL(fileURLWithPath:source)) }
                else {
                    let config=try await client.rpc("config/read",params:["includeLayers":true])
                    try validate(operation.scope,epoch:epoch)
                    guard localFilesAvailable,let path=Self.userLayer(in:config)?["name"]?["file"]?.stringValue else { throw SettingsDataError.unsupported("The verified local Core has no writable user config layer.") }
                    values["skills"]=try await CoreSkillFolderInstaller.install(source:URL(fileURLWithPath:source),configPath:path) {
                        try await client.request("POST",path:"/app-server/skills/list",body:["forceReload":true])
                    }
                }
                message="Skill installed and discovered by the connected backend."
            case .pluginInstall: values["installation"]=try await rpc("plugin/install",p); values["plugins"]=try await client.request("POST",path:"/app-server/plugins/list",body:[:])
            case .pluginUninstall: _ = try await rpc("plugin/uninstall",p); values["plugins"]=try await client.request("POST",path:"/app-server/plugins/list",body:[:])
            case .pluginEnable:
                guard let id=p["pluginId"]?.stringValue,let enabled=p["enabled"]?.boolValue else { throw CoreWire.failure("Plugin ID and enabled value are required.") }
                try await saveConfig(edits("plugins",.object([id:["enabled":.bool(enabled)]])))
                values["plugins"]=try await client.request("POST",path:"/app-server/plugins/list",body:[:])
            case .mcpWrite:
                guard let name=p["name"]?.stringValue,!name.isEmpty,let settings=p["values"]?.objectValue else { throw CoreWire.failure("MCP name and values are required.") }
                try await saveConfig(edits("mcp_servers",.object([name:.object(settings)])))
                _ = try await client.rpc("config/mcpServer/reload"); values["mcp"]=try await paginated("mcpServerStatus/list",client:client)
            case .mcpLogin:
                let result=try await rpc("mcpServer/oauth/login",p); browser=result["authorizationUrl"]?.stringValue
                guard let browser,let url=URL(string:browser),["http","https"].contains(url.scheme ?? "") else { throw CoreWire.failure("Core returned no authorization URL.") }
            case .hotkeyWrite:
                let result=try await client.request("POST",path:"/capture/hotkey",body:p)
                guard result["enabled"] == p["enabled"],result["error"]?.stringValue == nil else { throw CoreWire.failure(result["error"]?.stringValue ?? "The shortcut did not reach the requested state.") }; values["hotkey"]=result
            case .scheduleCreate:
                _ = try await client.request("POST",path:"/scheduler/jobs",body:p); values["jobs"]=try await client.request(path:"/scheduler/jobs")
            case .schedulePause:
                _ = try await client.request("POST",path:"/scheduler/pause",body:p); values["jobs"]=try await client.request(path:"/scheduler/jobs")
            case .notificationAck:
                _ = try await client.request("POST",path:"/notifications/ack",body:p); values["notifications"]=try await client.request(path:"/notifications")
            case .notificationPermission:
                guard let onPermissionRequest else { throw SettingsDataError.unsupported("Notification permission belongs to the application.") }
                let granted=try await onPermissionRequest()
                try validate(operation.scope,epoch:epoch)
                if versions["permission",default:0] == resourceVersions["permission",default:0] {
                    notificationPermission=granted ? "Allowed":"Not allowed"
                }
                values["permission"] = .string(notificationPermission);message=notificationPermission
            case .authorizationRevoke:
                guard let id=p["id"]?.stringValue else { throw CoreWire.failure("An authorization ID is required.") }
                _ = try await client.request("DELETE",path:"/authorizations/"+CoreWire.segment(id)); values["authorizations"]=try await client.request(path:"/authorizations")
            case .reconnect: try await reconnectAction?(); values["health"]=try await client.request(path:"/health")
            case .endpointSave:
                guard let raw=p["url"]?.stringValue,let url=URL(string:raw),["http","https"].contains(url.scheme ?? ""),url.host != nil,url.user == nil,url.password == nil,url.query == nil,url.fragment == nil,url.path.isEmpty || url.path == "/" else { throw CoreWire.failure("Enter an HTTP(S) server root without credentials or query parameters.") }
                try await onSaveEndpoint?(url); message="Address saved. Reconnect or restart to use it."
            case .unarchive:
                guard let id=p["id"]?.stringValue else { throw CoreWire.failure("A thread ID is required.") }
                _ = try await rpc("thread/unarchive",["threadId":.string(id)])
                try archiveAcknowledged(id,false)
                values["archived"]=try await client.rpc("thread/list",params:["archived":true,"limit":50,"sortKey":"updated_at"])
            case .archiveAll:
                let listing=try await paginated("thread/list",client:client,params:["archived":false])
                for thread in listing["data"]?.arrayValue ?? [] {
                    guard let id=thread["id"]?.stringValue else { continue }
                    _ = try await rpc("thread/archive",["threadId":.string(id)])
                    try archiveAcknowledged(id,true)
                }
                values["archived"]=try await client.rpc("thread/list",params:["archived":true,"limit":50])
            case .loadArchived:
                var params:[String:JSONValue]=["archived":true,"limit":50,"sortKey":"updated_at"]
                if let cursor=p["cursor"]?.stringValue { params["cursor"] = .string(cursor) }
                let page=try await client.rpc("thread/list",params:params)
                var merged=page.objectValue ?? [:],rows=(p["cursor"]?.stringValue != nil ? snapshots["archived"]?["data"]?.arrayValue:[]) ?? []
                let ids=Set(rows.compactMap { $0["id"]?.stringValue }); rows += (page["data"]?.arrayValue ?? []).filter { !ids.contains($0["id"]?.stringValue ?? "") }
                merged["data"] = .array(rows); values["archived"] = .object(merged)
            case .openLocal:
                guard localFilesAvailable,let onOpenLocal else { throw SettingsDataError.unsupported("This Core has not been verified as the local instance.") }
                let path=p["target"] == "data" ? service?.dataDirectory.path:p["path"]?.stringValue
                guard let path,!path.isEmpty else { throw CoreWire.failure("There is no local path to reveal.") }; try await onOpenLocal(URL(fileURLWithPath:path))
            case .demo: throw SettingsDataError.unsupported("Prototype mutations are unavailable in Live.")
            }
            try validate(operation.scope,epoch:epoch)
            var cleared=Set<String>()
            if operation.kind == .login {
                pendingLoginID=values["login"]?["loginId"]?.stringValue
                if let id=pendingLoginID,completedLogins[id] != nil {pendingLoginID=nil;values["login"] = .null;browser=nil}
                else {errors["login"]=nil;asynchronousErrors["login"]=nil;cleared.insert("login")}
            }
            if operation.kind == .cancelLogin || operation.kind == .logout {pendingLoginID=nil;values["login"] = .null}
            // An event can supersede readbacks during a write. Never reinstall the withdrawn old account/limits.
            for key in Array(values.keys) where versions[key,default:0] != resourceVersions[key,default:0] && key != "login" && key != "permission" {values[key]=nil}
            values["threads"]=threadOptions
            snapshots.merge(values) { _,new in new };notice=message
            publish(.init(snapshots:values,notice:message,clearedErrors:cleared))
            return .init(snapshots:values,notice:message,browserURL:browser)
        } catch {
            if epoch == generation { errors["write"]=error.localizedDescription }; throw error
        }
    }
    /// Uses the runtime's existing SSE feed; never creates a stream or fetches while Settings is closed.
    func receive(_ event:CoreEvent) {
        guard client != nil else{return}
        switch event.method {
        case "account/login/completed":
            let id=event.params["loginId"]?.stringValue
            if let id {completedLogins[id]=event.params;if completedLogins.count>128 {completedLogins=Dictionary(uniqueKeysWithValues:completedLogins.suffix(64))}}
            var values:[String:JSONValue]=["account":.null,"limits":.null],eventErrors:[String:String]=[:],cleared=Set<String>()
            if pendingLoginID == nil || id == pendingLoginID {
                pendingLoginID=nil;values["login"] = .null
                if event.params["success"] == false {eventErrors["login"]=event.params["error"]?.stringValue ?? "Sign-in did not complete."}
                else {cleared.insert("login")}
            }
            invalidate(["account","profile","usage"],values:values,eventErrors:eventErrors,cleared:cleared)
        case "account/updated":
            invalidate(["account","profile","usage"],values:["account":.null,"limits":.null])
        case "account/rateLimits/updated":
            // The event is a report, but Usage also needs the current account and full limits document.
            invalidate(["usage"],values:["limits":.null])
        case "mcpServer/oauth/login/completed":
            let failed=event.params["success"] == false
            invalidate(["plugins","plugins/mcp"],values:["mcp":.null,"config":.null],
                       eventErrors:failed ? ["oauth":event.params["error"]?.stringValue ?? "Authorization did not complete."]:[:],cleared:failed ? []:["oauth"])
        case "core/notification":
            invalidate(["notifications","scheduler"],values:["notifications":.null,"runs":.null,"jobs":.null])
            deliverNotification(event)
        default:return
        }
        onChange?()
    }
    private var deliveryPolicy:SettingsNotificationPolicy {
        notificationPolicyProvider?() ?? .init(enabled:notificationsEnabled,jobs:jobNotificationPolicies)
    }
    private func rememberDelivery(_ id:String) {
        deliveredNotifications.insert(id);deliveryOrder.append(id)
        if deliveryOrder.count>1024 {deliveredNotifications.remove(deliveryOrder.removeFirst())}
    }
    private func deliverNotification(_ event:CoreEvent) {
        let id=event.params["id"]?.stringValue ?? "core-event-\(event.id)"
        var payload=event.params.objectValue ?? [:];payload["id"] = .string(id)
        let value=JSONValue.object(payload)
        guard deliveryPolicy.allows(jobID:value["jobId"]?.stringValue,status:value["status"]?.stringValue),
              !deliveredNotifications.contains(id),notificationTasks[id] == nil else{return}
        guard let sink=onDeliverNotification else {
            if let onNotification {onNotification(value);rememberDelivery(id)}
            return
        }
        let epoch=generation
        notificationTasks[id]=Task{[weak self] in
            await Task.yield()
            guard let self else{return}
            defer{if self.generation == epoch {self.notificationTasks[id]=nil}}
            guard self.generation == epoch,!Task.isCancelled,
                  self.deliveryPolicy.allows(jobID:value["jobId"]?.stringValue,status:value["status"]?.stringValue) else{return}
            do {
                let result=try await sink(value)
                guard self.generation == epoch,!Task.isCancelled else{return}
                switch result {
                case .delivered,.suppressed:
                    self.rememberDelivery(id);self.publishAsyncError(nil,key:"notifications")
                case .notAuthorized(let reason):
                    self.updateNotificationPermission("Not allowed");self.publishAsyncError(reason,key:"notifications")
                }
            } catch {
                guard self.generation == epoch,!Task.isCancelled else{return}
                self.publishAsyncError(error.localizedDescription,key:"notifications")
            }
            self.onChange?()
        }
    }
}
