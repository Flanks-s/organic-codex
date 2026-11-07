import AppKit

@MainActor final class SettingsSession {
    private(set) var source:any SettingsDataSource
    let preferences:SettingsPreferences
    private(set) var navigation:SettingsNavigation
    private(set) var snapshots:[String:JSONValue]=[:],capabilities:[String:SettingsCapability]=[:]
    private(set) var errors:[String:String]=[:],busy=Set<String>()
    private(set) var generation=0
    private var pendingActions:[UUID:Task<Void,Never>]=[:]
    private var sourceObservation:(source:any SettingsObservableDataSource,token:UUID)?
    private var sourceChangesActive=false
    private var invalidationTask:Task<Void,Never>?,invalidationTaskID:UUID?
    private var invalidationPending=false,readRevision=0
    private let progressClock:any CoreRuntimeClock
    enum ExportProgress:Equatable {case idle,preparing,complete,failed(String)}
    private(set) var exportProgress=ExportProgress.idle
    private var exportTask:Task<Void,Never>?,exportGeneration=0
    var contentRevision=0
    var query="",listQuery="",device="mac",pluginPage=0,selected=Set<String>()
    var recording:String?,searchByKeystroke=false,keyWarning:String?
    var notice:String?,confirmation:SettingsConfirmation?,sheet:SettingsSheetState?
    struct PluginEntry { var plugin:JSONValue,marketplace:JSONValue }
    var pluginEntries:[String:PluginEntry]=[:]
    private var pluginIDs:[SettingsPluginProjection.EntryID:String]=[:]
    func pluginToken(_ id:SettingsPluginProjection.EntryID) -> String {
        if let value=pluginIDs[id] {return value}
        let token=UUID().uuidString;pluginIDs[id]=token;return token
    }
    private func updatePluginEntries(_ values:[String:JSONValue]) {
        guard let catalog=values["plugins"] else{return}
        let all=SettingsPluginProjection.sections(catalog:catalog,query:"").sections
        var refreshed:[String:PluginEntry]=[:]
        for section in all {for entry in section.entries {if let token=pluginIDs[entry.id] {refreshed[token] = .init(plugin:entry.plugin,marketplace:section.marketplace)}}}
        pluginEntries=refreshed
    }
    func errorsForValidation(_ message:String) {errors["write"]=message;changed()}
    var drafts:[String:String]=[:]
    var onChange:(()->Void)?
    var onOpenURL:((URL)->Void)?
    var onLocalChange:((String,JSONValue)->Void)?
    var onApplicationAction:((String)->Void)?
    var mode:SettingsMode { source.mode }
    var scope:SettingsScope { .init(endpoint:source.endpointIdentity,device:device) }
    var pane:String { navigation.pane }
    var paneTitle:String {
        if pane.hasPrefix("plugins/detail/"),let entry=pluginEntries[String(pane.dropFirst("plugins/detail/".count))]{return entry.plugin["interface"]?["displayName"]?.settingsText ?? entry.plugin["name"]?.settingsText ?? "Plugin"}
        return NativeSettingsCatalog.title(pane)
    }
    var top:String { navigation.top }
    var offline:Bool { records("devices").first { $0["id"]?.stringValue == device }?["online"]?.boolValue == false }
    init(source:any SettingsDataSource,preferences:SettingsPreferences=SettingsPreferences(),progressClock:any CoreRuntimeClock=CoreSystemClock()) {
        self.source=source; self.preferences=preferences;self.progressClock=progressClock
        navigation = .init(initial:preferences.defaults.string(forKey:"settings.pane") ?? "general")
        if source.mode == .demo && navigation.pane == "scheduler" { navigation = .init() }
        preferences.onChange={ [weak self] key,value in
            self?.syncNotificationPolicy();self?.onLocalChange?(key,value);self?.changed()
        }
        syncNotificationPolicy()
    }
    isolated deinit { stopObservingSource();invalidationTask?.cancel();exportTask?.cancel() }
    private func syncNotificationPolicy() {
        (source as? any SettingsNotificationPolicyDataSource)?.setNotificationPolicy(preferences.notificationPolicy)
    }
    private func cancelInvalidation() {
        invalidationTask?.cancel();invalidationTask=nil;invalidationTaskID=nil;invalidationPending=false
    }
    private func applySourceChange(_ result:SettingsReadResult) {
        snapshots.merge(result.snapshots){_,new in new};updatePluginEntries(result.snapshots)
        capabilities.merge(result.capabilities){_,new in new}
        for key in result.clearedErrors {errors[key]=nil};errors.merge(result.errors){_,new in new}
        if result.clearsNotice {notice=nil};if let note=result.notice {notice=note}
        if result.invalidatedPanes.contains(pane) || result.invalidatedPanes.contains(top) {
            readRevision+=1;invalidationPending=true;scheduleInvalidationRead()
        }
        changed()
    }
    private func scheduleInvalidationRead() {
        guard sourceChangesActive,invalidationPending,invalidationTask == nil,
              !busy.contains("read:"+pane),!busy.contains("write") else{return}
        let id=UUID(),epoch=generation,route=pane
        invalidationTaskID=id
        invalidationTask=Task{[weak self] in
            await Task.yield()
            guard let self else{return}
            defer {
                if self.invalidationTaskID == id {
                    self.invalidationTask=nil;self.invalidationTaskID=nil
                    self.scheduleInvalidationRead()
                }
            }
            guard self.generation == epoch,self.sourceChangesActive,self.pane == route,!Task.isCancelled,
                  !self.busy.contains("read:"+route),!self.busy.contains("write") else{return}
            self.invalidationPending=false
            await self.loadNow()
        }
    }
    @discardableResult func startDemoExport()->Bool {
        guard sourceChangesActive,mode == .demo,pane == "data",exportProgress != .preparing else{return false}
        exportGeneration+=1;let token=exportGeneration,epoch=generation,scope=scope,clock=progressClock
        exportProgress = .preparing;changed()
        exportTask=Task{[weak self] in
            do {try await clock.sleep(seconds:1.6);try Task.checkCancellation()}
            catch {
                guard let self,self.exportGeneration == token,self.generation == epoch,!Task.isCancelled else{return}
                self.exportProgress = .failed(error.localizedDescription);self.exportTask=nil;self.changed();return
            }
            guard let self,self.exportGeneration == token,self.generation == epoch,self.scope == scope,!Task.isCancelled else{return}
            self.exportProgress = .complete;self.exportTask=nil;self.changed()
        }
        return true
    }
    func cancelDemoExport(notifying:Bool=true) {
        exportGeneration+=1;exportTask?.cancel();exportTask=nil;exportProgress = .idle
        if notifying {changed()}
    }
    private func stopObservingSource() {
        if let sourceObservation {sourceObservation.source.removeChangeObserver(sourceObservation.token);self.sourceObservation=nil}
    }
    private func observeSource() {
        guard sourceChangesActive,sourceObservation == nil,let observable=source as? any SettingsObservableDataSource else{return}
        let epoch=generation,scope=scope
        let token=observable.observeChanges(scope:scope){[weak self] result in
            guard let self,self.generation == epoch,self.scope == scope else{return}
            self.applySourceChange(result)
        }
        sourceObservation=(observable,token)
    }
    func changed() { onChange?() }
    func setSource(_ next:any SettingsDataSource) {
        stopObservingSource();cancelInvalidation();cancelDemoExport(notifying:false)
        generation+=1; source=next; snapshots=[:]; capabilities=[:]; pluginEntries=[:];pluginIDs=[:]; errors=[:]; busy=[]; notice=nil; confirmation=nil; sheet=nil; recording=nil; selected=[]
        if mode == .demo && top == "scheduler" { navigation.replace("general") };syncNotificationPolicy();observeSource();changed()
    }
    func setDevice(_ next:String) { guard next != device else { return };stopObservingSource();cancelInvalidation();cancelDemoExport(notifying:false);generation+=1; device=next; if mode == .live {snapshots=snapshots.filter{["devices","projects"].contains($0.key)};capabilities=[:]}; errors=[:]; busy=[]; confirmation=nil; sheet=nil; selected=[];observeSource();changed() }
    /// A command-line/deep-link capture may establish its first page before presentation, without inventing a
    /// previous General page. Normal go/back/forward retain their existing history contract.
    func prepareInitialPane(_ id:String){guard NativeSettingsCatalog.valid(id)else{return};navigation=SettingsNavigation(initial:id);didNavigate()}
    /// Explicit external entry points may name a pane that is absent from this mode's sidebar. Like the product,
    /// demo Scheduled Tasks is an empty pane, not a fabricated Live scheduler or a silently substituted General.
    @discardableResult func openPane(_ id:String)->Bool {
        if mode == .demo,id == "scheduler" {navigation.go(id);didNavigate();return true}
        return go(id)
    }
    @discardableResult func go(_ route:String) -> Bool {
        guard NativeSettingsCatalog.valid(route),mode == .live || route != "scheduler" else { return false }
        navigation.go(route); didNavigate(); return true
    }
    func back() { navigation.back(); didNavigate() }
    func forward() { navigation.forward(); didNavigate() }
    private func didNavigate() {cancelInvalidation();if exportProgress == .preparing {cancelDemoExport(notifying:false)};recording=nil; searchByKeystroke=false; keyWarning=nil; listQuery=""; pluginPage=0; selected=[]; preferences.defaults.set(top,forKey:"settings.pane"); changed() }
    func records(_ key:String) -> [JSONValue] { snapshots[key]?.arrayValue ?? snapshots[key]?["data"]?.arrayValue ?? [] }
    func config(_ key:String) -> JSONValue? { snapshots["config"]?["config"]?.settingsPath(key) }
    var userLayer:JSONValue? { snapshots["config"]?["layers"]?.arrayValue?.first { $0["name"]?["type"]?.stringValue == "user" && $0["name"]?["profile"]?.stringValue == nil } }
    var configPath:String? { userLayer?["name"]?["file"]?.stringValue }
    var draftScope:String { scope.endpoint+"|"+scope.device+"|"+pane+"|" }
    func draft(_ key:String,fallback:String="") -> String { drafts[draftScope+key] ?? fallback }
    func setDraft(_ key:String,_ value:String) { drafts[draftScope+key]=value }
    func operation(_ kind:SettingsOperation.Kind,_ payload:JSONValue=[:]) -> SettingsOperation { .init(kind:kind,payload:payload,scope:scope) }
    func allowed(_ kind:SettingsOperation.Kind,localFile:Bool=false) -> Bool {
        // Demo archive metadata is local to the shared store, even when the selected chat/device is offline.
        let localArchive=mode == .demo && (kind == .unarchive || kind == .archiveAll || (kind == .demo && ["archived","data"].contains(top)))
        return (!offline || localArchive) && source.supportedOperations.contains(kind) && (!localFile || source.localFilesAvailable) && !busy.contains("write") && (kind != .demo || mode == .demo)
    }
    func loadNow() async {
        sourceChangesActive=true
        observeSource()
        let request=SettingsReadRequest(pane:pane,scope:scope),epoch=generation,provider=source,revision=readRevision
        let key="read:"+request.pane
        guard !busy.contains(key) else { return }; busy.insert(key); errors[key]=nil; changed()
        do {
            let result=try await provider.read(request)
            guard epoch == generation,request.scope == scope else { return }
            guard revision == readRevision else {throw SettingsDataError.superseded}
            snapshots.merge(result.snapshots) { _,new in new };updatePluginEntries(result.snapshots); capabilities.merge(result.capabilities) { _,new in new }
            if let notice=result.notice { self.notice=notice }
        } catch {
            if epoch == generation,request.scope == scope {
                if case SettingsDataError.superseded=error {invalidationPending=true}
                else if !Task.isCancelled {errors[key]=error.localizedDescription}
            }
        }
        if epoch == generation {busy.remove(key);changed();scheduleInvalidationRead()}
    }
    @discardableResult func execute(_ operation:SettingsOperation) async -> Bool {
        await executeCurrent(operation,isCurrent:nil)
    }
    private func executeCurrent(_ operation:SettingsOperation,isCurrent:(()->Bool)?) async -> Bool {
        guard isCurrent?() != false else{return false}
        guard operation.scope == scope else { errors["write"]=SettingsDataError.stale.localizedDescription; changed(); return false }
        guard allowed(operation.kind,localFile:operation.kind == .skillInstall || operation.kind == .openLocal) else { errors["write"]="This operation is unavailable for the connected backend or device."; changed(); return false }
        let epoch=generation,provider=source
        busy.insert("write"); errors["write"]=nil; changed()
        do {
            let result=try await provider.perform(operation)
            guard epoch == generation,operation.scope == scope else { return false }
            guard isCurrent?() != false else {busy.remove("write");changed();scheduleInvalidationRead();return false}
            snapshots.merge(result.snapshots) { _,new in new };updatePluginEntries(result.snapshots);if pane == "storage/cleanup" {selected.formIntersection(Set(records("cleanup").compactMap{$0["id"]?.stringValue}))}; notice=result.notice
            if let address=result.browserURL,let url=URL(string:address),["https","http"].contains(url.scheme ?? "") { onOpenURL?(url) }
            busy.remove("write");changed();scheduleInvalidationRead();return true
        } catch {
            if epoch == generation,operation.scope == scope { if isCurrent?() != false {errors["write"]=error.localizedDescription};busy.remove("write");changed();scheduleInvalidationRead()};return false
        }
    }
    /// Freeze scope and epoch before scheduling. A click queued just before closing or switching a backend cannot write later.
    @discardableResult func dispatch(_ operation:SettingsOperation)->Task<Void,Never> {
        let id=UUID(),epoch=generation
        let task=Task{ [weak self] in
            guard let self else{return}
            defer{self.pendingActions[id]=nil}
            guard self.generation == epoch,!Task.isCancelled else{return}
            _ = await self.execute(operation)
        }
        pendingActions[id]=task;return task
    }
    /// Synthetic settings feedback only. Uses the injected clock and the same close/source/scope fences as writes;
    /// it never installs an extension, grants a permission, or creates a Live backend operation.
    @discardableResult func startDemoFeedback(key:String,seconds:Double,operation:SettingsOperation)->Bool {
        guard mode == .demo,operation.kind == .demo,!busy.contains(key),sourceChangesActive else{return false}
        let id=UUID(),epoch=generation,expected=scope,clock=progressClock
        busy.insert(key);changed()
        pendingActions[id]=Task{[weak self] in
            do{try await clock.sleep(seconds:seconds);try Task.checkCancellation()}catch{if let self,self.generation == epoch{self.pendingActions[id]=nil;self.busy.remove(key);if !Task.isCancelled{self.notice=error.localizedDescription};self.changed()};return}
            guard let self,self.generation == epoch,self.scope == expected,self.sourceChangesActive else{return}
            defer{self.pendingActions[id]=nil;self.busy.remove(key);self.changed()}
            _ = await self.execute(operation)
        }
        return true
    }
    /// What the folder chooser hands back for Install skill folder.
    @discardableResult func installSkillFolder(_ folder:URL)->Task<Void,Never> { dispatch(operation(.skillInstall,["path":.string(folder.path)])) }
    func dispatchConfig(_ edits:[String:JSONValue],merge:String="replace",scope expectedScope:SettingsScope?=nil) {
        guard let op=configOperation(edits,merge:merge,scope:expectedScope) else{return};dispatch(op)
    }
    private func configOperation(_ edits:[String:JSONValue],merge:String,scope expectedScope:SettingsScope?)->SettingsOperation? {
        if let expectedScope,expectedScope != scope {errorsForValidation(SettingsDataError.stale.localizedDescription);return nil}
        guard snapshots["config"]?.objectValue != nil else{errorsForValidation("Load the backend configuration first.");return nil}
        var payload:[String:JSONValue]=["edits":.array(edits.keys.sorted().map{["keyPath":.string($0),"value":edits[$0]!,"mergeStrategy":.string(merge)]}),"reloadUserConfig":true]
        if let path=configPath{payload["filePath"] = .string(path)}
        if let version=userLayer?["version"]?.stringValue{payload["expectedVersion"] = .string(version)}
        return operation(.configWrite,.object(payload))
    }
    func saveConfig(_ edits:[String:JSONValue],merge:String="replace",scope expectedScope:SettingsScope?=nil) async -> Bool {
        guard let op=configOperation(edits,merge:merge,scope:expectedScope) else{return false}
        return await execute(op)
    }
    func ask(title:String,message:String,confirm:String,destructive:Bool=false,operation:SettingsOperation) {
        confirmation = .init(title:title,message:message,confirm:confirm,destructive:destructive,operation:operation); changed()
    }
    @discardableResult func resolveConfirmation(id:UUID,confirmed:Bool) async -> Bool {
        guard let pending=confirmation,pending.id == id else { return false }; confirmation=nil
        guard confirmed else { changed(); return false }
        return await execute(pending.operation)
    }
    func openSheet(_ kind:SettingsSheetKind) {
        if kind == .schedule,mode == .demo {notice="Scheduled Tasks require a Live backend.";changed();return}
        guard mode == .demo || [.addMCP,.schedule].contains(kind) else { notice="This workflow is not exposed by the connected backend."; changed(); return }
        var sheet=SettingsSheetState(kind:kind,scope:scope)
        sheet.fields=["transport":"http","port":"22","at":.number(Date().timeIntervalSince1970+3600),"hours":0,"thread":"","rule":"ask","pattern":"npm run *"]
        if mode == .demo { sheet.fields["transport"]="stdio" }
        for key in ["settings","mcp","skills","projects"] { sheet.fields[key]=true }; sheet.fields["chats"]=false
        if kind == .customizeSync,let picks=snapshots["demo"]?["global"]?["importPicks"]?.objectValue {sheet.fields.merge(picks){_,new in new}}
        self.sheet=sheet; changed()
    }
    func cancelSheet(id:UUID) { guard sheet?.id == id else { return }; sheet=nil; changed() }
    @discardableResult func submitSheet(id:UUID) async -> Bool {
        guard var draft=sheet,draft.id == id,draft.canSubmit,draft.scope == scope else { return false }
        draft.phase = .working; sheet=draft; changed()
        let op:SettingsOperation
        if mode == .demo { op=operation(.demo,["action":.string("sheet."+draft.kind.rawValue),"fields":.object(draft.fields)]) }
        else if draft.kind == .addMCP {
            let name=draft.fields["name"]?.settingsText ?? "",url=draft.fields["command"]?.settingsText ?? ""
            op=operation(.mcpWrite,["name":.string(name),"values":["url":.string(url),"enabled":true]])
        } else if draft.kind == .schedule {
            var values=draft.fields; values["everySeconds"] = .number((values["hours"]?.doubleValue ?? 0)*3600); values["enabled"]=true
            if values["thread"]?.settingsText.isEmpty == false { values["threadId"]=values["thread"] }; op=operation(.scheduleCreate,.object(values))
        } else { return false }
        let ok=await executeCurrent(op,isCurrent:{[weak self] in self?.sheet?.id == id})
        guard sheet?.id == id else { return ok }
        sheet?.phase=ok ? .done:.failed(errors["write"] ?? "The operation did not complete.")
        sheet?.message=ok ? (mode == .demo ? "Prototype complete. No backend or files were changed.":notice ?? "Saved by the connected backend."):errors["write"] ?? ""
        changed(); return ok
    }
    func completeDemoPair(id:UUID) async {
        guard mode == .demo,sheet?.id == id,sheet?.kind == .pair,sheet?.scope == scope else{return}
        sheet?.phase = .working;changed()
        let ok=await executeCurrent(operation(.demo,["action":"sheet.pair"]),isCurrent:{[weak self] in self?.sheet?.id == id})
        guard sheet?.id == id else{return}
        sheet?.phase=ok ? .done:.failed(errors["write"] ?? "Pairing failed")
        sheet?.message=ok ? "A sample iPad was paired in the prototype. No device authorization was created.":"Pairing failed"
        changed()
    }
    func record(_ combo:String) {
        if let id=recording {
            keyWarning=preferences.assignKey(id,combo)
            if keyWarning == nil { recording=nil }
        } else if searchByKeystroke { listQuery=combo }
        changed()
    }
    func stopPresentation() {sourceChangesActive=false;stopObservingSource();cancelInvalidation();cancelDemoExport(notifying:false);generation+=1;for task in pendingActions.values{task.cancel()};pendingActions=[:];busy=[];recording=nil; searchByKeystroke=false; confirmation=nil; sheet=nil; onChange=nil }
}
