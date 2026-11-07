#if SETTINGS_SELFTEST
import AppKit

@MainActor private final class Group1Weak<T:AnyObject> { weak var value:T?;init(_ value:T){self.value=value} }
@MainActor private final class Group1Observer {
    let change:(SettingsReadResult)->Void
    init(_ change:@escaping (SettingsReadResult)->Void){self.change=change}
}
@MainActor private final class Group1SettingsSource:SettingsObservableDataSource {
    let mode:SettingsMode
    let endpointIdentity="group1-offline",connectionStatus="Offline fixture",localFilesAvailable=false
    let supportedOperations=Set(SettingsOperation.Kind.allCases)
    let demo=SettingsDemoDataSource()
    var catalog:JSONValue=[:],operations:[SettingsOperation]=[]
    var hold=false,pending:CheckedContinuation<SettingsWriteResult,Error>?
    var observers:[UUID:Group1Observer]=[:],weakObservers:[Group1Weak<Group1Observer>]=[]
    init(_ mode:SettingsMode = .demo){self.mode=mode}
    func read(_ request:SettingsReadRequest) async throws -> SettingsReadResult {
        if mode == .demo{return try await demo.read(request)}
        return .init(snapshots:["plugins":catalog,"devices":["data":[["id":"mac","online":true]]]])
    }
    func perform(_ operation:SettingsOperation) async throws -> SettingsWriteResult {
        operations.append(operation)
        if hold{hold=false;return try await withCheckedThrowingContinuation{pending=$0}}
        return .init()
    }
    func observeChanges(scope:SettingsScope,_ change:@escaping (SettingsReadResult)->Void)->UUID {
        let id=UUID(),probe=Group1Observer(change);observers[id]=probe;weakObservers.append(Group1Weak(probe));return id
    }
    func removeChangeObserver(_ token:UUID){observers[token]=nil}
    func release(error:Error?=nil){let c=pending;pending=nil;if let error {c?.resume(throwing:error);return};c?.resume(returning:.init(snapshots:["lateSheet":.string(UUID().uuidString)],notice:"LATE COMPLETION"))}
}
@MainActor private final class Group1ColorPanel:SettingsColorPanelDriver {
    var changed:((NSColor)->Void)?,callbacks:[(NSColor)->Void]=[]
    var shows=0,disconnects=0
    func show(color:NSColor,changed:@escaping (NSColor)->Void){shows+=1;self.changed=changed;callbacks.append(changed)}
    func disconnect(){disconnects+=1;changed=nil}
}

@MainActor enum SettingsGroup1Verification {
    static func run(check:(Bool,String)->Void,png:(CGImage,String)->Void) async {
        let domain="organic.group1."+UUID().uuidString,defaults=UserDefaults(suiteName:domain)!
        defer{NativeSettingsWindowController.uninstall();defaults.removePersistentDomain(forName:domain)}
        await catalog(defaults,check:check)
        await lifecycle(defaults,check:check)
        await sheets(defaults,check:check,png:png)
        colors(defaults,check:check)
        check(NSApp.windows.allSatisfy{!$0.isVisible && !($0 is NSColorPanel)},"G1 no window presented and no native NSColorPanel created")
    }
    private static func catalog(_ defaults:UserDefaults,check:(Bool,String)->Void) async {
        let source=Group1SettingsSource(.live),s=SettingsSession(source:source,preferences:SettingsPreferences(defaults:defaults))
        let _: @MainActor (SettingsOperation) async -> Bool = s.execute // Preserve the existing method-reference API.
        var markets:[JSONValue]=[]
        for market in 0..<3 {
            let start=market*3000,end=market == 2 ? 8885:start+3000
            let plugins:[JSONValue]=(start..<end).map{ i in
                let duplicate=i%3000 == 17
                return ["id":.string(duplicate ? "duplicate-id":"p\(i)"),"name":.string(duplicate ? "duplicate-internal":i == 7123 ? "internal-needle":"tool-\(i)"),
                        "availability":"available","installPolicy":"allowed","installed":false,
                        "source":["path":.string("/fixture/source-\(market)/\(i)")],
                        "interface":["displayName":.string(i == 8111 ? "Display Needle":"Plugin \(i)"),
                                     "shortDescription":.string(i == 8777 ? "short-needle":"offline"),
                                     "longDescription":.string(i == 8778 ? "long-needle":"offline detail")]]
            }
            markets.append(["name":"same-market-name","path":.string("/fixture/market-\(market)"),"plugins":.array(plugins)])
        }
        source.catalog=["marketplaces":.array(markets)];s.go("plugins");await s.loadNow()
        var seen=Set<SettingsPluginProjection.EntryID>()
        for index in 0..<89 {
            let p=SettingsPluginProjection.page(catalog:source.catalog,query:"",requestedPage:index)
            let entries=p.sections.flatMap(\.entries)
            check(p.index == index && entries.count == (index == 88 ? 85:100),"G1 f146 bounded offline page \(index)")
            entries.forEach{seen.insert($0.id)}
        }
        check(seen.count == 8885,"G1 f146 all 8885 stable identities survive duplicate names and plugin IDs")
        let last=SettingsPluginProjection.page(catalog:source.catalog,query:"",requestedPage:Int.max)
        check(last.index == 88 && last.firstResult == 8801 && last.lastResult == 8885 && !last.hasNext,"G1 f146 last page clamps and Next cannot exceed 8885")
        let w=NativeSettingsWorkbench(session:s);w.automaticallyLoads=false;w.loadViewIfNeeded()
        s.pluginPage=88;w.render()
        let next=w.form.rows.compactMap{row -> SettingsButton? in
            if row.spec.id == "plugins.next"{return row.control as? SettingsButton}
            guard let index=row.spec.visual.actions.firstIndex(where:{$0.id == "plugins.next"}),row.actionControls.indices.contains(index)else{return nil}
            return row.actionControls[index] as? SettingsButton
        }.first
        check(next?.isEnabled == false,"G1 f146 actual last-page Next control disabled")
        next?.performClick(nil);check(s.pluginPage == 88,"G1 f146 clicking disabled Next leaves page index unchanged")
        for (query,id) in [("internal-needle","p7123"),("Display Needle","p8111"),("short-needle","p8777"),("long-needle","p8778")] {
            s.pluginPage=88
            SettingsPanels.make(s).first{$0.id == "listQuery"}?.perform?(.string(query))
            let p=SettingsPluginProjection.page(catalog:source.catalog,query:s.listQuery,requestedPage:s.pluginPage)
            check(s.pluginPage == 0 && p.matchCount == 1 && p.sections.first?.entries.first?.plugin["id"] == .string(id),"G1 f146 search \(query) covers complete catalog and resets page")
        }
        SettingsPanels.make(s).first{$0.id == "listQuery"}?.perform?("duplicate-internal")
        let matches=SettingsPluginProjection.page(catalog:source.catalog,query:s.listQuery,requestedPage:0).sections
        check(matches.count == 3,"G1 f146 duplicate plugin sources remain three sections")
        for section in matches {
            _ = SettingsPanels.make(s)
            let entry=section.entries[0],token=s.pluginToken(entry.id)
            s.go("plugins/detail/"+token)
            let rows=SettingsPanels.make(s)
            rows.first{$0.id == "plugin.install."+token}?.perform?(.null)
            let op=s.confirmation?.operation
            check(op?.payload["pluginName"] == "duplicate-internal" && op?.payload["marketplacePath"] == section.marketplace["path"],"G1 f146 duplicate source install payload uses exact marketplace path")
            if let id=s.confirmation?.id{_ = await s.resolveConfirmation(id:id,confirmed:true)}
            s.go("plugins")
        }
        check(source.operations.count == 3 && Set(source.operations.compactMap{$0.payload["marketplacePath"]?.stringValue}).count == 3,"G1 f146 dispatched duplicate-source payloads do not alias")
        w.stop()
    }
    private static func lifecycle(_ defaults:UserDefaults,check:(Bool,String)->Void) async {
        NativeSettingsWindowController.uninstall()
        let source=Group1SettingsSource(),owner=NativeSettingsWindowController.install(dataSource:source,preferences:SettingsPreferences(defaults:defaults))
        var benches:[Group1Weak<NativeSettingsWorkbench>]=[]
        for cycle in 1...20 {
            autoreleasepool {
                let w=owner.acquireContent();w.automaticallyLoads=false;w.view.frame.size=NativeSettingsWindowController.minimumSize
                benches.append(Group1Weak(w))
            }
            for pane in ["general","plugins","appearance"] {owner.session.go(pane);await owner.session.loadNow();owner.workbench?.render()}
            check(benches.filter{$0.value != nil}.count == 1 && source.observers.count == 1 && source.weakObservers.filter{$0.value != nil}.count == 1,"G1 f124 open cycle \(cycle) has one workbench and one observer")
            autoreleasepool{owner.releaseContent()}
            for _ in 0..<10{await Task.yield()}
            autoreleasepool{
                check(benches.allSatisfy{$0.value == nil} && source.observers.isEmpty && source.weakObservers.allSatisfy{$0.value == nil},"G1 f124 closed cycle \(cycle) releases every workbench and observer")
            }
            check(owner.window == nil,"G1 f124 cycle \(cycle) uses actual graph boundary without constructing a window")
        }
        let retired=owner.acquireContent();retired.automaticallyLoads=false
        owner.session.go("general");owner.session.go("appearance")
        owner.releaseContent();let pane=owner.session.pane
        let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:0,context:nil,characters:"[",charactersIgnoringModifiers:"[",isARepeat:false,keyCode:33)!
        check(!retired.routeKey(key) && owner.session.pane == pane,"G1 f154 retired workbench ignores keyboard navigation after close")
        NativeSettingsWindowController.uninstall()
    }

    private static func sheets(_ defaults:UserDefaults,check:(Bool,String)->Void,png:(CGImage,String)->Void) async {
        let source=Group1SettingsSource(),s=SettingsSession(source:source,preferences:SettingsPreferences(defaults:defaults))
        await s.loadNow()
        for kind:SettingsSheetKind in [.importContent,.customizeSync,.importMCP,.pair,.ssh,.addMCP] {
            s.openSheet(kind);guard let state=s.sheet else{check(false,"G1 f154 opens \(kind)");continue}
            let c=SettingsSheetContent(session:s,sheet:state);c.loadViewIfNeeded()
            // A 760x480 titled host has at most 452 pt of content height. No NSWindow is constructed.
            c.view.frame.size=CGSize(width:480,height:452);c.viewDidLayout()
            if let row=c.form.rows.last {
                let rect=c.view.convert(row.bounds,from:row)
                let visible=CGRect(x:0,y:50,width:480,height:346)
                check(visible.contains(rect),"G1 f130/f154 \(kind) last row fully visible at minimum host \(rect)")
                if kind == .ssh || kind == .addMCP {row.spec.perform?("last-line-fixture");check(s.sheet?.fields[kind == .ssh ? "port":"command"] == "last-line-fixture","G1 f154 \(kind) edits last field")}
                else if [.importContent,.customizeSync,.importMCP].contains(kind) {row.spec.perform?(true);check(s.sheet?.fields["chats"] == true,"G1 f130 \(kind) fifth option edits correct field")}
            }
            for scale:CGFloat in [1,2]{png(c.snapshot(scale:scale),"group1-"+kind.rawValue+"@\(Int(scale))x")}
            if kind == .ssh{s.sheet?.fields["host"]="fixture.invalid";s.sheet?.fields["user"]="fixture";s.sheet?.fields["port"]="22"}
            if kind == .addMCP{s.sheet?.fields["name"]="fixture";s.sheet?.fields["command"]="https://fixture.invalid/mcp"}
            source.hold=true
            let task:Task<Bool,Never>
            if kind == .pair {task=Task{await s.completeDemoPair(id:state.id);return true}}
            else{task=Task{await s.submitSheet(id:state.id)}}
            for _ in 0..<100{if source.pending != nil{break};await Task.yield()}
            check(source.pending != nil,"G1 f130/f154 \(kind) operation suspended before acknowledgment")
            c.cancel.performClick(nil);let snapshot=s.snapshots,notice=s.notice
            source.release();_ = await task.value
            for _ in 0..<10{await Task.yield()}
            check(s.sheet == nil && s.snapshots == snapshot && s.notice == notice && !s.busy.contains("write"),"G1 f130/f154 \(kind) Cancel rejects late completion and leaves no busy state")
            check(c.form.rows.allSatisfy{$0.spec.id != "sheet.done"},"G1 f130/f154 \(kind) retained sheet never renders late Complete")
            s.openSheet(kind);let next=s.sheet!.id
            if kind == .ssh {s.sheet?.fields["host"]="fixture.invalid";s.sheet?.fields["user"]="fixture";s.sheet?.fields["port"]="22"}
            if kind == .addMCP {s.sheet?.fields["name"]="fixture";s.sheet?.fields["command"]="https://fixture.invalid/mcp"}
            source.hold=true
            let failed=Task{if kind == .pair {await s.completeDemoPair(id:next)}else{_ = await s.submitSheet(id:next)}}
            for _ in 0..<100{if source.pending != nil{break};await Task.yield()}
            check(source.pending != nil,"G1 f154 \(kind) failed acknowledgement can be delayed")
            s.cancelSheet(id:next);let errors=s.errors;s.openSheet(.importContent);let replacement=s.sheet!.id
            source.release(error:SettingsDataError.unsupported("Late fixture failure"));await failed.value
            check(s.errors == errors && s.sheet?.id == replacement && s.sheet?.phase == .editing,"G1 f154 \(kind) late error cannot overwrite replacement sheet")
            s.cancelSheet(id:replacement)

        }
        let confirmation=SettingsConfirmation(title:"Delete fixture?",message:"Offline only",confirm:"Delete",destructive:true,operation:s.operation(.demo))
        let alert=SettingsAlerts.build(confirmation)
        check(alert.buttons.count == 2 && alert.buttons[0].hasDestructiveAction && alert.buttons[1].title == "Cancel","G1 f154 native alert keeps destructive/default/cancel semantics without presenting")
        s.stopPresentation()
    }
    private static func colors(_ defaults:UserDefaults,check:(Bool,String)->Void) {
        let s=SettingsSession(source:SettingsDemoDataSource(),preferences:SettingsPreferences(defaults:defaults))
        let panel=Group1ColorPanel(),connection=SettingsColorPanelConnection(driver:panel)
        let a=SettingsColorContent(session:s,key:"look.background",colorPanel:connection)
        let b=SettingsColorContent(session:s,key:"look.foreground",colorPanel:connection)
        a.loadViewIfNeeded();b.loadViewIfNeeded()
        a.native.performClick(nil);panel.changed?(.red)
        check(s.preferences["look.background"] == "#FF0000","G1 f154 first Show Colors targets background")
        a.native.performClick(nil);b.native.performClick(nil);a.native.performClick(nil)
        let stale=panel.callbacks.last
        b.native.performClick(nil);panel.changed?(.green)
        check(s.preferences["look.foreground"] == "#00FF00","G1 f154 second Show Colors targets foreground")
        let old=s.preferences["look.background"]
        stale?(.blue)
        check(s.preferences["look.background"] == old,"G1 f154 buffered old color action cannot edit the former well")
        a.disconnect();panel.changed?(.blue)
        check(s.preferences["look.foreground"] == "#0000FF" && panel.changed != nil,"G1 f154 closing former popover does not disconnect current color well")
        let latest=panel.callbacks.last
        b.disconnect();let values=s.preferences["look.foreground"],count=panel.shows
        latest?(.orange);b.native.performClick(nil);b.hex.edited?("#123456")
        check(s.preferences["look.foreground"] == values && panel.shows == count && panel.changed == nil,"G1 f154 closed color well rejects callbacks, Show Colors and keyboard edits")
    }
}
#endif
