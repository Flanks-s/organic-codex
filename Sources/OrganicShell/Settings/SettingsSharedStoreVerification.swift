#if SETTINGS_SELFTEST
import AppKit

@MainActor private final class RetiredSettingsSource:SettingsObservableDataSource {
    let mode=SettingsMode.demo,endpointIdentity="retired",connectionStatus="Fixture",localFilesAvailable=false
    let supportedOperations=Set<SettingsOperation.Kind>()
    var retired:((SettingsReadResult)->Void)?,removed=0
    func read(_ request:SettingsReadRequest) async throws->SettingsReadResult{.init(snapshots:[:])}
    func perform(_ operation:SettingsOperation) async throws->SettingsWriteResult{throw SettingsDataError.stale}
    func observeChanges(scope:SettingsScope,_ change:@escaping(SettingsReadResult)->Void)->UUID{retired=change;return UUID()}
    func removeChangeObserver(_ token:UUID){removed+=1}
}

@MainActor enum SettingsSharedStoreVerification {
    static func run(check:(Bool,String)->Void,capture:(CGImage,String)->Void) async {
        let suite="organic.settings.shared."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let dateBase=1_793_145_600.0
        let a=Conversation(id:"shared-a",title:"A real mock title"),b=Conversation(id:"shared-b",title:"Running mock")
        let c=Conversation(id:"shared-c",title:"Archived in workspace"),d=Conversation(id:"shared-d",title:"No project, offline device")
        a.projectID="workspace";b.running=true;b.draft="Keep my draft"
        c.archived=true;c.projectID="workspace";c.archivedAt=Date(timeIntervalSince1970:dateBase+100)
        d.archived=true;d.deviceID="offline";d.updated=Date(timeIntervalSince1970:dateBase+200)
        let store=ConversationStore(conversations:[a,b,c,d],projects:[Project(id:"workspace",name:"Actual Workspace",deviceID:"mac")],
            devices:[Device(id:"mac",name:"Actual Mac",kind:.mac),Device(id:"offline",name:"Offline Server",kind:.server,online:false)])
        let source=SettingsDemoDataSource(store:store),preferences=SettingsPreferences(defaults:defaults)
        let s=SettingsSession(source:source,preferences:preferences)
        _ = s.go("archived");await s.loadNow()
        check(s.records("archived").compactMap{$0["id"]?.stringValue} == [d.id,c.id],"shared archive reads store and falls back to updated date")
        check(Set(s.records("active").compactMap{$0["id"]?.stringValue}) == [a.id,b.id],"shared active list has no c1/c2 fixtures")
        check(s.records("projects").first?["name"] == "Actual Workspace" && s.records("devices").first?["name"] == "Actual Mac","shared filters use store projects and devices")
        check(!s.records("archived").contains{$0["id"] == "a1" || $0["id"] == "a2"},"shared archive has no a1/a2 fixtures")
        s.setDraft("project","none")
        check(SettingsPanels.make(s).filter{$0.id.hasPrefix("archive.shared-")}.map(\.id) == ["archive."+d.id],"null project matches No Project filter")
        s.setDraft("project","workspace")
        check(SettingsPanels.make(s).contains{$0.id == "archive."+c.id} && !SettingsPanels.make(s).contains{$0.id == "archive."+d.id},"shared project filter uses canonical IDs")
        s.setDraft("project","all");s.setDraft("archiveDevice","offline")
        check(SettingsPanels.make(s).filter{$0.id.hasPrefix("archive.shared-")}.count == 1,"shared archive device filter")
        s.setDraft("archiveDevice","all");s.listQuery="workspace"
        check(SettingsPanels.make(s).contains{$0.id == "archive."+c.id} && !SettingsPanels.make(s).contains{$0.id == "archive."+d.id},"shared archive title search")
        s.listQuery=""
        let w=NativeSettingsWorkbench(session:s);w.automaticallyLoads=false;w.loadViewIfNeeded()
        w.view.frame=CGRect(x:0,y:0,width:880,height:660);w.viewDidLayout();w.render()
        check(SettingsVerification.audit(w.view).isEmpty,"shared archive §7.5 static controls")
        for scale:CGFloat in [1,2]{capture(w.snapshot(scale:scale,fullPanel:true),"shared-archive@\(Int(scale))x")}

        a.archived=true;a.archivedAt=Date(timeIntervalSince1970:dateBase+300);store.changed(a)
        check(s.records("archived").first?["id"] == .string(a.id),"external Sidebar archive appears without manual Settings reload")
        a.archived=false;a.archivedAt=nil;store.changed(a)
        check(!s.records("archived").contains{$0["id"] == .string(a.id)},"external archive Undo removes Settings row")
        check(await s.execute(s.operation(.unarchive,["id":.string(c.id),"deviceID":"mac"])),"shared unarchive acknowledged")
        check(store.conversation(c.id) === c && !c.archived && c.archivedAt == nil,"unarchive mutates original store object")
        check(s.records("active").contains{$0["id"] == .string(c.id)},"unarchive readback includes restored active chat")
        check(!(await s.execute(s.operation(.unarchive,["id":.string(d.id),"deviceID":"wrong"])) ) && d.archived,"mismatched device cannot restore another chat")
        s.setDevice("offline")
        check(s.offline && s.allowed(.unarchive),"offline Settings scope still permits local demo archive metadata")
        check(await s.execute(s.operation(.unarchive,["id":.string(d.id),"deviceID":"offline"])),"mock offline device chat can be unarchived without a network request")
        s.setDevice("mac")
        check(!(await s.execute(s.operation(.unarchive,["id":"missing"]))),"missing archive fails instead of synthesizing a chat")
        var events=0
        let observer=source.observeChanges(scope:s.scope){_ in events+=1}
        a.items.append(.init(id:"stream-only",kind:.assistant,text:"Streaming content",running:false));store.changed(a)
        check(events == 0,"stream-only updates do not rebuild Settings conversation projections")
        check(await s.execute(s.operation(.archiveAll)),"shared archive all acknowledged")
        check(store.conversations.allSatisfy(\.archived) && s.records("active").isEmpty,"Archive All includes every chat including running ones")
        check(b.running && b.draft == "Keep my draft","Archive All leaves running turn and draft intact")
        check(events == 1,"bulk archive publishes one Settings snapshot")
        source.removeChangeObserver(observer)
        a.archived=false;a.archivedAt=nil;store.changed(a)
        check(events == 1,"removed data-source observer gets no more updates")

        let second=SettingsSession(source:source,preferences:SettingsPreferences(defaults:defaults));await second.loadNow()
        s.stopPresentation();let stopped=s.snapshots
        c.archived=false;c.archivedAt=nil;store.changed(c)
        check(s.snapshots == stopped,"closed Settings session unsubscribes from shared store")
        check(second.records("active").contains{$0["id"] == .string(c.id)},"another Settings subscriber remains active")
        await s.loadNow()
        check(s.records("active").contains{$0["id"] == .string(c.id)},"reopened session reloads current store and resubscribes")
        c.archived=true;store.changed(c)
        check(s.records("archived").contains{$0["id"] == .string(c.id)},"reopened session receives future archives")
        _ = s.go("archived")
        let deletion=SettingsPanels.make(s).first{$0.id == "delete."+c.id}!
        let writes=source.operations.count
        deletion.perform?(.null)
        check(s.confirmation?.destructive == true && store.conversation(c.id) === c && source.operations.count == writes,"shared Delete opens confirmation before any store operation")
        check(!(await s.resolveConfirmation(id:s.confirmation!.id,confirmed:false)) && store.conversation(c.id) === c,"cancel shared Delete preserves conversation")
        let all=SettingsPanels.make(s).first{$0.id == "clear.archived"}!
        all.perform?(.null)
        let confirmedIDs=Set(s.confirmation!.operation.payload["ids"]!.arrayValue!.compactMap(\.stringValue))
        let late=Conversation(id:"late-archive",title:"Arrived after confirmation");late.archived=true;store.add(late);store.changed(late)
        check(!confirmedIDs.contains(late.id) && confirmedIDs.contains(c.id),"Delete All confirmation freezes only reviewed archive IDs")
        _ = await s.resolveConfirmation(id:s.confirmation!.id,confirmed:false)
        var removalRequests:[Set<String>]=[]
        let unimplemented=SettingsDemoDataSource(store:store,removeConversations:{removalRequests.append($0)})
        let failed=SettingsSession(source:unimplemented,preferences:SettingsPreferences(defaults:defaults));await failed.loadNow()
        check(!(await failed.execute(failed.operation(.demo,["action":"remove","collection":"archived","id":.string(c.id)]))) && removalRequests == [[c.id]],"unacknowledged host removal cannot report success")
        check(store.conversation(c.id) === c && !failed.errors.isEmpty,"failed host removal leaves visible source of truth intact")
        failed.stopPresentation()
        store.usesLiveCore=true
        check(!(await s.execute(s.operation(.unarchive,["id":.string(c.id)]))) && c.archived,"shared demo refuses Live store mutation")
        store.usesLiveCore=false;c.backendThreadID="live-thread"
        check(!(await s.execute(s.operation(.archiveAll))) && !a.archived,"shared demo refuses mixed Live conversation mutation")
        c.backendThreadID=nil

        let old=RetiredSettingsSource(),fenced=SettingsSession(source:old,preferences:SettingsPreferences(defaults:defaults))
        check(old.retired == nil,"installing Settings session creates no store subscription")
        await fenced.loadNow()
        let retired=old.retired;fenced.setSource(SettingsUnavailableDataSource())
        retired?(.init(snapshots:["archived":["data":[["id":"stale"]]]]))
        check(old.removed == 1 && fenced.snapshots.isEmpty,"retired source callback cannot repopulate a new backend")
        fenced.stopPresentation();second.stopPresentation();s.stopPresentation();w.stop()
    }
}
#endif
