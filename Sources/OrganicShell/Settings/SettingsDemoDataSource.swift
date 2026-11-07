import Foundation

/// Synthetic integration data, optionally over the app's actual mock conversation store. Never mutates Live models
/// and performs no filesystem/network/permission I/O. No-argument construction keeps the isolated Settings fixture.
@MainActor final class SettingsDemoDataSource:SettingsObservableDataSource {
    let mode=SettingsMode.demo,endpointIdentity="demo",connectionStatus="Prototype · synthetic settings",localFilesAvailable=false
    let supportedOperations:Set<SettingsOperation.Kind>=[.demo,.unarchive,.archiveAll,.loadArchived]
    private(set) var operations:[SettingsOperation]=[]
    var failure:String?
    private var data:[String:JSONValue]=[:]
    private var scoped:[String:[String:JSONValue]]=[:]
    private let store:ConversationStore?
    private var storeObservation:UUID?
    private var changeObservers:[UUID:(scope:SettingsScope,change:(SettingsReadResult)->Void)]=[:]
    private var lastShared:[String:JSONValue]=[:]
    private var writingStore=false
    /// A host with a removal API can supply it without changing any Settings view. It must remove from this exact
    /// store and notify its observers; a missing or unsuccessful deletion is never acknowledged as success.
    typealias RemoveConversations = (Set<String>) throws -> Void
    private let removeConversations:RemoveConversations?
    init(store:ConversationStore?=nil,removeConversations:RemoveConversations?=nil) {
        self.store=store
        self.removeConversations=removeConversations
        let global:[String:JSONValue]=["name":"Louis L.","email":"louis@example.com","plan":"Plus","profilePublic":false,"profileRange":"daily","imported":false,"importSync":false,"improveModel":false,"browserOn":true,"webLinks":"app","localLinks":"app","showFullURL":false,"annotations":"always","otherSites":"ask","pluginTab":"plugins","cuAnyApp":true,"cuWhileLocked":false,"cuExtension":false,"cuAccessibility":true,"cuScreen":false,"shotHotkey":"shift","shotDestination":"auto","shotSound":true,"allowConnections":true,"keepAwake":true,"connectionsTab":"mac","keepWorktrees":5,"usageTab":"overview"]
        let device:[String:JSONValue]=["approval":"never","sandbox":"full","web":"cached","detail":"medium","summary":"auto","model":"g61sol","effort":"high","efforts":["low","medium","high","xhigh","ultra"],"installDependencies":true,"memories":true,"toolMemories":false,"agents":"# Working agreements\n\n- Use the system controls.\n- Keep diffs small.\n- Run the relevant checks.\n"]
        var pc=device;pc["approval"]="on-request";pc["sandbox"]="workspace";pc["memories"]=false
        var server=device;server["approval"]="untrusted";server["sandbox"]="read";server["web"]="off";server["model"]="g6sol";server["toolMemories"]=true
        var preview=device;preview["web"]="live";preview["model"]="g56terra";preview["effort"]="medium"
        data["demo"]=["global":.object(global),"devices":["mac":.object(device),"pc":.object(pc),"srv":.object(server),"preview-srv":.object(preview)]]
        data["devices"]=["data":[["id":"mac","name":"This Mac","online":true,"symbol":"laptopcomputer","local":true],["id":"pc","name":"Preview PC","online":true,"symbol":"pc","local":false],["id":"srv","name":"Preview Server","online":false,"symbol":"server.rack","local":false]]]
        data["projects"]=["data":[["id":"spw","name":"Synthetic preview workspace","deviceID":"mac"],["id":"fn","name":"Field Notes","deviceID":"mac"]]]
        data["account"]=["account":["name":"Louis L.","email":"louis@example.com","planType":"plus"]]
        data["archived"]=["data":[["id":"a1","title":"Weekly digest format","projectID":"fn","deviceID":"mac","archivedAt":1730000000],["id":"a2","title":"Batch rename screenshots","projectID":"spw","deviceID":"mac","archivedAt":1729000000]]]
        data["cleanup"]=["data":[["id":"o1","title":"Weekly digest format","size":"18.2 MB","age":"Last opened 3 weeks ago"],["id":"o2","title":"Batch rename screenshots","size":"9.6 MB","age":"Last opened 2 months ago"],["id":"o3","title":"HEIC to JPEG script","size":"41.0 MB","age":"Last opened 2 months ago · 3 subagents"],["id":"o4","title":"Draft a changelog entry","size":"2.4 MB","age":"Last opened 3 months ago"]]]
        data["worktrees"]=["data":[["id":"w1","branch":"codex/sidebar-metrics","project":"Synthetic preview workspace","size":"212 MB","age":"2 hours ago"],["id":"w2","branch":"codex/approval-copy","project":"Synthetic preview workspace","size":"198 MB","age":"yesterday"],["id":"w3","branch":"codex/heic-batch","project":"Photo Library Tools","size":"64 MB","age":"6 days ago"],["id":"w4","branch":"codex/tag-cleanup","project":"Field Notes","size":"38 MB","age":"3 weeks ago"]]]
        data["storage"]=["parts":[["id":"Chats","mb":349.4,"hex":"#ffd60a"],["id":"Subagents","mb":89.2,"hex":"#da8fff"],["id":"Archived chats","mb":4.1,"hex":"#ff9f0a"],["id":"Worktrees","mb":512,"hex":"#30d158"],["id":"Logs and caches","mb":640,"hex":"#8e8e93"]]]
        data["rules"]=["data":[["id":"r1","pattern":"git status*","rule":"allow"],["id":"r2","pattern":"swift test*","rule":"allow"],["id":"r3","pattern":"curl *","rule":"ask"],["id":"r4","pattern":"rm -rf *","rule":"deny"]]]
        let names=[("design","Product Design","Explore and prototype ideas"),("git","Git Host","Triage pull requests, issues and CI runs"),("drive","Drive","Read documents, sheets and slides"),("calendar","Calendar","Read and create events"),("contacts","Contacts","Look up saved contact details"),("mail","Mail","Read and draft email"),("style","Writing Style","Write with context from your own writing"),("data","Data","Answer questions with data")]
        let plugins=names.map { id,name,detail -> JSONValue in ["id":.string(id),"name":.string(name),"installed":true,"enabled":.bool(id != "contacts"),"interface":["displayName":.string(name),"shortDescription":.string(detail)],"tools":["Search","Read","Create"],"availability":"AVAILABLE"] }
        data["plugins"]=["marketplaces":[["name":"Prototype directory","plugins":.array(plugins)]]]
        data["skills"]=["data":[["skills":[["name":"release-notes","path":"~/.codex/skills/release-notes/SKILL.md","shortDescription":"Draft release notes from merged changes","enabled":true],["name":"pdf-reader","path":"~/.codex/skills/pdf-reader/SKILL.md","shortDescription":"Read and quote PDF files","enabled":true],["name":"test-triage","path":"~/.codex/skills/test-triage/SKILL.md","shortDescription":"Group failing tests by cause","enabled":false]]]]]
        data["mcp"]=["data":[["name":"local-docs","transport":"stdio","command":"npx local-docs-mcp","runtimeStatus":"Running · 6 tools","enabled":true],["name":"staging-db","url":"https://mcp.example.dev","authStatus":"Needs sign-in","enabled":true]]]
        data["links"]=["data":[["id":"l1","title":"Release notes outline","made":"Shared 4 days ago","views":"12 views","url":"https://example.com/share/l1"],["id":"l2","title":"Explain a concurrency warning","made":"Shared 2 weeks ago","views":"3 views","url":"https://example.com/share/l2"]]]
        data["sites"]=["data":[["id":"s1","host":"docs.example.com","browse":"allow","download":"allow","upload":"ask"],["id":"s2","host":"localhost:3000","browse":"allow","download":"allow","upload":"allow"],["id":"s3","host":"staging.example.dev","browse":"ask","download":"block","upload":"block"]]]
        data["history"]=["data":[["id":"h1","title":"Settings – Example Docs","url":"docs.example.com/guide/settings","when":"Today, 10:42"],["id":"h2","title":"Preview build","url":"localhost:3000/","when":"Today, 09:15"],["id":"h3","title":"Release checklist","url":"staging.example.dev/release","when":"Yesterday, 18:03"]]]
        data["apps"]=["data":[["id":"finder","name":"Finder"],["id":"terminal","name":"Terminal"],["id":"preview","name":"Preview"],["id":"xcode","name":"Xcode"]]]
        data["controllers"]=["data":[["id":"win","name":"Windows PC","detail":"Windows 11 · Last connected 44 minutes ago"],["id":"ios","name":"iPhone","detail":"iOS 26 · Last connected 50 minutes ago"]]]
        data["ssh"]=["data":[["id":"b1","host":"build-box.local","user":"dev","port":"22","status":"Reachable (prototype)"],["id":"b2","host":"10.0.0.24","user":"ci","port":"2222","status":"Key not accepted (prototype)"]]]
        data["active"]=["data":[["id":"c1","title":"Prototype conversation","running":false,"deviceID":"mac","projectID":"spw"],["id":"c2","title":"Running prototype conversation","running":true,"deviceID":"mac","projectID":"spw"]]]
        data["limits"]=["rateLimits":["primary":["usedPercent":34,"windowDurationMins":300],"secondary":["usedPercent":58,"windowDurationMins":10080]]]
        for device in ["mac","pc","srv","preview-srv"] {scoped[device]=data.filter{["rules","storage","cleanup","worktrees"].contains($0.key)}}
        scoped["pc"]?["rules"]=["data":[["id":"r1","pattern":"pwsh -File Scripts/*","rule":"allow"]]]
        scoped["srv"]?["rules"]=["data":[]]
        scoped["preview-srv"]?["rules"]=["data":[["id":"r1","pattern":"make preview*","rule":"allow"]]]
        for (id,amounts) in [("pc",[120.6,12,0.8,2100,310]),("srv",[58.3,0,2.2,0,96]),("preview-srv",[22.7,3.1,0.4,180,41])] {
            let parts=(data["storage"]?["parts"]?.arrayValue ?? []).enumerated().map{index,part -> JSONValue in var record=part.objectValue ?? [:];record["mb"] = .number(amounts[index]);return .object(record)}
            scoped[id]?["storage"]=["parts":.array(parts)]
        }
    }
    private func projection(_ scope:SettingsScope)->[String:JSONValue] {
        var result=data;result.merge(scoped[scope.device] ?? [:]){_,new in new}
        result.merge(sharedSnapshots()){_,new in new};return result
    }
    private func sharedSnapshots()->[String:JSONValue] {
        guard let store else{return [:]}
        func chat(_ c:Conversation)->JSONValue {
            var record:[String:JSONValue]=["id":.string(c.id),"title":.string(c.title),"deviceID":.string(c.deviceID),
                "projectID":c.projectID.map{.string(store.project($0)?.id ?? $0)} ?? .null,"running":.bool(c.running)]
            if c.archived {record["archivedAt"] = .number((c.archivedAt ?? c.updated).timeIntervalSince1970)}
            return .object(record)
        }
        let archived=store.conversations.filter(\.archived).sorted {
            let a=$0.archivedAt ?? $0.updated,b=$1.archivedAt ?? $1.updated
            return a == b ? $0.id < $1.id:a > b
        }
        return ["archived":["data":.array(archived.map(chat))],
            "active":["data":.array(store.conversations.filter{!$0.archived}.map(chat))],
            "projects":["data":.array(store.projects.map{["id":.string($0.id),"name":.string($0.name),"deviceID":.string($0.deviceID)]})],
            "devices":["data":.array(store.devices.map{["id":.string($0.id),"name":.string($0.name),"online":.bool($0.online),"symbol":.string($0.symbol),"local":.bool($0.isLocal)]})]]
    }
    @discardableResult func observeChanges(scope:SettingsScope,_ change:@escaping (SettingsReadResult)->Void)->UUID {
        let id=UUID();changeObservers[id]=(scope,change)
        if storeObservation == nil,let store {
            lastShared=sharedSnapshots()
            storeObservation=store.observe{[weak self] _ in self?.publishStoreChanges()}
        }
        return id
    }
    func removeChangeObserver(_ token:UUID) {
        changeObservers[token]=nil
        if changeObservers.isEmpty {detachStore()}
    }
    private func detachStore() {if let storeObservation{store?.removeObserver(storeObservation);self.storeObservation=nil}}
    isolated deinit {detachStore()}
    private func publishStoreChanges() {
        guard !writingStore,store != nil else{return}
        let shared=sharedSnapshots();guard shared != lastShared else{return};lastShared=shared
        for id in Array(changeObservers.keys) {
            guard let observer=changeObservers[id],observer.scope.endpoint == endpointIdentity else{continue}
            observer.change(.init(snapshots:shared))
        }
    }
    private func requireMockStore(_ store:ConversationStore) throws {
        guard !store.usesLiveCore,!store.conversations.contains(where:{$0.isLiveConversation || $0.backendThreadID != nil}) else{
            throw SettingsDataError.unsupported("Demo settings cannot change Live conversations. Use the Live settings data source.")
        }
    }
    private func permanentlyRemove(_ ids:Set<String>,archivedOnly:Bool) throws {
        guard let store else{return}
        try requireMockStore(store)
        let targets=ids.compactMap(store.conversation).filter{!archivedOnly || $0.archived}
        guard !targets.isEmpty else{throw SettingsDataError.stale}
        guard let removeConversations else{throw SettingsDataError.unsupported("Permanent deletion is not connected to this conversation store.")}
        let actualIDs=Set(targets.map(\.id));writingStore=true
        defer{writingStore=false;publishStoreChanges()}
        try removeConversations(actualIDs)
        guard actualIDs.allSatisfy({store.conversation($0) == nil}) else{
            throw SettingsDataError.invalid("The deletion handler did not remove the requested conversations.")
        }
    }
    func read(_ request:SettingsReadRequest) async throws -> SettingsReadResult {
        guard request.scope.endpoint == endpointIdentity else { throw SettingsDataError.stale }
        if let failure { throw SettingsDataError.invalid(failure) }
        return .init(snapshots:projection(request.scope),notice:"Demo · prototype. These settings do not describe a Live backend.")
    }
    func perform(_ operation:SettingsOperation) async throws -> SettingsWriteResult {
        guard operation.scope.endpoint == endpointIdentity else { throw SettingsDataError.stale }
        guard supportedOperations.contains(operation.kind) else { throw SettingsDataError.unsupported("Live account, OAuth and scheduler operations are unavailable in demo.") }
        if let failure { throw SettingsDataError.invalid(failure) }; operations.append(operation)
        data.merge(scoped[operation.scope.device] ?? [:]){_,new in new}
        let p=operation.payload
        switch operation.kind {
        case .unarchive:
            if let store {
                try requireMockStore(store)
                guard let c=store.conversation(p["id"]?.settingsText ?? ""),c.archived else{throw SettingsDataError.stale}
                if let device=p["deviceID"]?.stringValue,device != c.deviceID {throw SettingsDataError.stale}
                c.archived=false;c.archivedAt=nil;store.changed(c)
            }else{
                let id=p["id"]?.settingsText ?? ""
                if let chat=records("archived").first(where:{$0["id"]?.settingsText == id}) {append("active",chat)}
                remove("archived",id:id)
            }
        case .archiveAll:
            let date=Date()
            if let store {
                try requireMockStore(store);writingStore=true
                for c in store.conversations where !c.archived {c.archived=true;c.archivedAt=date;store.changed(c)}
                writingStore=false;publishStoreChanges()
            }else{
                for c in records("active") {var archived=c.objectValue ?? [:];archived["archivedAt"] = .number(date.timeIntervalSince1970);append("archived",.object(archived))}
                data["active"]=["data":[]]
            }
        case .loadArchived: break
        case .demo:
            let action=p["action"]?.settingsText ?? ""
            switch action {
            case "set":
                let path=p["path"]?.settingsText ?? ""
                data["demo"]=Self.setting(data["demo"] ?? [:],path:path.split(separator:".").map(String.init),value:p["value"] ?? .null)
                if path == "global.name",let account=data["account"]?["account"],account != .null {data["account"]=["account":Self.setting(account,path:["name"],value:p["value"] ?? "")]}
                if path == "global.signedOut" {data["account"]=["account":.null]}
            case "remove":
                let collection=p["collection"]?.settingsText ?? "",id=p["id"]?.settingsText ?? ""
                if collection == "archived",store != nil {try permanentlyRemove([id],archivedOnly:true)}
                else{remove(collection,id:id)}
            case "clear":
                let collection=p["collection"]?.settingsText ?? "",allChats=p["allChats"]?.boolValue == true
                let ids=p["ids"]?.arrayValue.map{Set($0.compactMap(\.stringValue))}
                if collection == "archived",let store {
                    let targets=ids ?? Set(store.conversations.filter{allChats || $0.archived}.map(\.id))
                    if !targets.isEmpty{try permanentlyRemove(targets,archivedOnly:!allChats)}
                }else{
                    data[collection]=["data":.array(ids.map{wanted in records(collection).filter{!wanted.contains($0["id"]?.settingsText ?? "")}} ?? [])]
                    if allChats{data["active"]=["data":.array(ids.map{wanted in records("active").filter{!wanted.contains($0["id"]?.settingsText ?? "")}} ?? [])]}
                }
            case "account.changeEmail":return .init(snapshots:projection(operation.scope),notice:"Opened the account page. No email address was changed.",browserURL:"https://chatgpt.com/#settings/Account")
            case "account.delete":data["account"]=["account":.null]
            case "cleanup":
                let ids=Set(p["ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                data["cleanup"]=["data":.array(records("cleanup").filter { !ids.contains($0["id"]?.settingsText ?? "") })]
            case "logs":data["storage"] = Self.setting(data["storage"] ?? [:],path:["parts"],value:.array((data["storage"]?["parts"]?.arrayValue ?? []).map { part in var object=part.objectValue ?? [:]; if object["id"]?.stringValue == "Logs and caches" { object["mb"]=0.4 }; return .object(object) }))
            case "sheet.addMCP":
                let f=p["fields"] ?? [:]; append("mcp",["name":f["name"] ?? "Server","url":f["transport"]?.settingsText == "http" ? f["command"] ?? "":.null,"command":f["command"] ?? "","enabled":true,"runtimeStatus":"Running (prototype)"])
            case "sheet.ssh":var f=p["fields"]?.objectValue ?? [:]; f["id"] = .string(UUID().uuidString); f["status"]="Reachable (prototype)"; append("ssh",.object(f))
            case "sheet.addSite":var f=p["fields"]?.objectValue ?? [:]; f["id"] = .string(UUID().uuidString); f["browse"]="ask"; f["download"]="ask"; f["upload"]="block"; append("sites",.object(f))
            case "sheet.addRule":var f=p["fields"]?.objectValue ?? [:]; f["id"] = .string(UUID().uuidString); append("rules",.object(f))
            case "sheet.customizeSync":
                data["demo"]=Self.setting(data["demo"] ?? [:],path:["global","importPicks"],value:p["fields"] ?? [:])
            case "sheet.importContent","sheet.importMCP":data["demo"]=Self.setting(data["demo"] ?? [:],path:["global","imported"],value:true)
            case "sheet.pair":remove("controllers",id:"ipad"); append("controllers",["id":"ipad","name":"iPad","detail":"Paired (prototype)"])
            case "app.add":
                for (id,name) in [("textedit","TextEdit"),("notes","Notes")] where !records("apps").contains(where:{$0["id"]?.settingsText == id}) {append("apps",["id":.string(id),"name":.string(name)]);break}
            case "skill.enable":
                let groups=records("skills").map { group -> JSONValue in
                    var obj=group.objectValue ?? [:]
                    obj["skills"] = .array((group["skills"]?.arrayValue ?? []).map { skill in
                        guard skill["path"] == p["path"] else{return skill}
                        var item=skill.objectValue ?? [:];item["enabled"]=p["enabled"];return .object(item)
                    });return .object(obj)
                };data["skills"]=["data":.array(groups)]
            case "plugin.enable","plugin.remove","plugin.tool":
                var markets=data["plugins"]?["marketplaces"]?.arrayValue ?? []
                for index in markets.indices {
                    let plugins=markets[index]["plugins"]?.arrayValue ?? []
                    markets[index] = Self.setting(markets[index],path:["plugins"],value:.array(plugins.compactMap { plugin in
                        guard plugin["id"]?.settingsText == p["id"]?.settingsText else { return plugin }
                        if action == "plugin.remove" { return nil }; var object=plugin.objectValue ?? [:]
                        if action == "plugin.enable" { object["enabled"]=p["value"] ?? false }
                        else { var tools=object["toolEnabled"]?.objectValue ?? [:]; tools[p["tool"]?.settingsText ?? ""]=p["value"] ?? false; object["toolEnabled"] = .object(tools) }; return .object(object)
                    }))
                }
                data["plugins"] = Self.setting(data["plugins"] ?? [:],path:["marketplaces"],value:.array(markets))
            case "record.update":
                let key=p["collection"]?.settingsText ?? "",id=p["id"]?.settingsText ?? "",field=p["field"]?.settingsText ?? ""
                data[key] = ["data":.array(records(key).map { record in
                    let recordID=record["id"]?.settingsText ?? record["name"]?.settingsText ?? record["path"]?.settingsText ?? ""
                    guard recordID == id else { return record }; var object=record.objectValue ?? [:]; object[field]=p["value"] ?? .null; return .object(object)
                })]
            default:throw SettingsDataError.unsupported("This prototype action is unavailable.")
            }
        default:throw SettingsDataError.unsupported("This operation is not simulated.")
        }
        scoped[operation.scope.device]=data.filter{["rules","storage","cleanup","worktrees"].contains($0.key)}
        return .init(snapshots:projection(operation.scope),notice:"Prototype updated. No backend, permissions or files were changed.")
    }
    private func records(_ key:String) -> [JSONValue] { data[key]?["data"]?.arrayValue ?? [] }
    private func remove(_ key:String,id:String) { data[key] = ["data":.array(records(key).filter { ($0["id"]?.settingsText ?? $0["name"]?.settingsText) != id })] }
    private func append(_ key:String,_ record:JSONValue) { data[key] = ["data":.array(records(key)+[record])] }
    static func setting(_ root:JSONValue,path:[String],value:JSONValue) -> JSONValue {
        guard let head=path.first else { return value }; var object=root.objectValue ?? [:]
        object[head]=setting(object[head] ?? [:],path:Array(path.dropFirst()),value:value); return .object(object)
    }
}
