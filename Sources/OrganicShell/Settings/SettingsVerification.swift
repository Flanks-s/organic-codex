#if SETTINGS_SELFTEST
import AppKit
import ObjectiveC.runtime

/// swiftc only. Initializes AppKit without presenting windows/panels, installing a monitor or launching an .app.
@MainActor private final class SettingsVerificationSource:SettingsDataSource {
    var mode=SettingsMode.live,endpointIdentity="http://127.0.0.1:4242",connectionStatus="Connected",localFilesAvailable=false
    var supportedOperations=Set(SettingsOperation.Kind.allCases.filter{$0 != .demo})
    var result=SettingsReadResult(snapshots:[
        "account":["account":["type":"chatgpt","email":"live@example.com","planType":"plus"]],
        "config":["config":["model":"model-a","approval_policy":"on-request","sandbox_mode":"workspace-write","developer_instructions":"Loaded instructions"],"layers":[["name":["type":"user","file":"/remote/config.toml"],"version":"v7"]]],
        "models":["data":[["id":"id-a","model":"model-a","displayName":"Model A","isDefault":true,"supportedReasoningEfforts":[["reasoningEffort":"high","description":"High"]]]]],
        "devices":["data":[["id":"mac","name":"Backend device","online":true],["id":"offline","name":"Offline device","online":false]]],
        "jobs":[["id":"job1","name":"Digest","prompt":"Summarize changes","enabled":true,"nextRun":2000000000]],
        "runs":[["id":"run1","jobId":"job1","status":"submissionUnknown","error":"Backend did not confirm submission"]],
        "notifications":[["id":"n1","title":"Scheduled task","body":"Results ready","read":false]],
        "health":["eventLog":["diskBytes":2048,"tailBytes":512],"sessions":[["id":"s1"]]],
        "limits":["rateLimits":["primary":["usedPercent":27,"windowDurationMins":300],"credits":["balance":"5.00"]]],
        "permission":"notDetermined","hotkey":["enabled":false,"threadId":nil,"mode":"window","shortcut":"Control+Option+Command+S","pid":nil,"error":nil],
        "threads":[["backendThreadID":"thread1","title":"Actual backend chat"]],
        "plugins":["marketplaces":[]],"skills":["data":[]],"mcp":["data":[]],"tabs":[],"authorizations":[]
    ],capabilities:["captureWindow":.init(available:true),"scheduler":.init(available:true)])
    var writes:[SettingsOperation]=[],reads:[SettingsReadRequest]=[]
    var writeResult=SettingsWriteResult(notice:"Acknowledged"),failure:String?
    var delayRead=false,delayWrite=false
    var pendingRead:CheckedContinuation<SettingsReadResult,any Error>?
    var pendingWrite:CheckedContinuation<SettingsWriteResult,any Error>?
    func read(_ request:SettingsReadRequest) async throws -> SettingsReadResult {
        reads.append(request);if let failure{throw SettingsDataError.invalid(failure)}
        if delayRead{return try await withCheckedThrowingContinuation{pendingRead=$0}}
        return result
    }
    func perform(_ operation:SettingsOperation) async throws -> SettingsWriteResult {
        writes.append(operation);if let failure{throw SettingsDataError.invalid(failure)}
        if delayWrite{return try await withCheckedThrowingContinuation{pendingWrite=$0}}
        return writeResult
    }
}
@main @MainActor struct SettingsVerification {
    static var checks=0,failures:[String]=[],images=0
    static func check(_ condition:Bool,_ name:String){checks+=1;if !condition{failures.append(name);print("FAIL: "+name)}}
    static func png(_ image:CGImage,_ name:String,_ output:URL){
        let rep=NSBitmapImageRep(cgImage:image)
        do{try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"));images+=1}catch{check(false,"PNG "+name)}
    }
    static func tree(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(tree)}
    static func audit(_ view:NSView)->[String] {
        let draw=NSSelectorFromString("drawRect:")
        return tree(view).compactMap{v in
            let base:AnyClass?
            if v is NSTextField {base=NSTextField.self}else if v is NSButton{base=NSButton.self}else if v is NSTextView{base=NSTextView.self}else{return nil}
            guard let base,let original=class_getInstanceMethod(base,draw),let custom=class_getInstanceMethod(type(of:v),draw) else{return String(describing:type(of:v))}
            let ordinary=method_getImplementation(original) == method_getImplementation(custom)
            let bezel=(v as? NSButton)?.isBordered == true || (v as? NSTextField)?.isBezeled == true
            return ordinary || bezel ? String(describing:type(of:v)):nil
        }
    }
    static func event(_ key:String,_ flags:NSEvent.ModifierFlags=[],code:UInt16=0)->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:key,charactersIgnoringModifiers:key,isARepeat:false,keyCode:code)!
    }
    static func main() async {
        _=NSApplication.shared;NSApp.appearance=NSAppearance(named:.darkAqua)
        let output=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "/tmp/sol-settings-results")
        try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let suite="organic.settings.selftest."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let preferences=SettingsPreferences(defaults:defaults),demo=SettingsDemoDataSource(),s=SettingsSession(source:demo,preferences:preferences)
        check(NSApp.windows.isEmpty,"No windows before verification")
        await SettingsSharedStoreVerification.run(check:check){image,name in png(image,name,output)}
        await SettingsAsyncVerification.run(check:check){image,name in png(image,name,output)}
        do {
            // f147: Install skill folder asks the window for a folder first; the chosen path goes with the operation.
            let source=SettingsVerificationSource();source.localFilesAvailable=true
            let live=SettingsSession(source:source,preferences:preferences);_ = live.go("plugins/skills");await live.loadNow()
            var asked:[String]=[];live.onApplicationAction={asked.append($0)}
            let install=SettingsPanels.make(live).first{$0.id == "skills.install"}
            check(install?.enabled == true,"f147 Install skill folder is enabled on a local Core")
            install?.perform?(.null);await Task.yield()
            check(asked == ["chooseSkillFolder"] && source.writes.isEmpty,"f147 Install skill folder opens the chooser and sends nothing by itself")
            await live.installSkillFolder(URL(fileURLWithPath:"/tmp/skill folder",isDirectory:true)).value
            check(source.writes.map(\.kind) == [.skillInstall] && source.writes.first?.payload["path"]?.stringValue == "/tmp/skill folder","f147 the chosen folder's path goes with the install")
            // f149: a grant row names its application (Core's "app"), and Revoke's confirmation says Revoke.
            source.result.snapshots["authorizations"]=[["id":"cb1cf794b6898fba","threadId":"thread1","scope":"app","app":"com.apple.calculator"]]
            _ = live.go("computer");await live.loadNow()
            let rows=SettingsPanels.make(live)
            check(rows.first{$0.id == "grant.cb1cf794b6898fba"}?.title == "com.apple.calculator","f149 a grant is listed by its application, not its ID")
            rows.first{$0.id == "revoke.cb1cf794b6898fba"}?.perform?(.null)
            check(live.confirmation?.confirm == "Revoke" && live.confirmation?.destructive == true,"f149 Revoke's confirmation button says Revoke")
            // f150: Status comes from Core's enabled flag, and its error is shown.
            _ = live.go("appshots");await live.loadNow()
            check(SettingsPanels.make(live).first{$0.id == "info.Status"}?.detail == "Disabled","f150 Appshots status reads Core's enabled flag")
            source.result.snapshots["hotkey"]=["enabled":true,"threadId":"thread1","mode":"screen","shortcut":"Control+Option+Command+S","pid":7,"error":"Hotkey helper exited before registration"]
            await live.loadNow()
            let shot=SettingsPanels.make(live)
            check(shot.first{$0.id == "info.Status"}?.detail == "Enabled" && shot.first{$0.id == "capture.error"}?.detail == "Hotkey helper exited before registration","f150 an enabled shortcut says Enabled and shows Core's error")
        }
        var lifecycle=SettingsWindowLifecycle();lifecycle.present();check(!lifecycle.contentAlive,"Uninstalled lifecycle cannot present")
        lifecycle.install();check(!lifecycle.contentAlive,"Install creates no content")
        lifecycle.present();check(lifecycle.contentAlive && lifecycle.presented,"Present owns content")
        lifecycle.close();check(!lifecycle.contentAlive && lifecycle.installed,"Close releases content but retains installation")
        lifecycle.present();check(lifecycle.presentationCount == 2,"Reopen presentation")
        lifecycle.dispose();check(!lifecycle.installed && !lifecycle.contentAlive,"Dispose releases lifecycle")
        let owner=NativeSettingsWindowController.install(dataSource:demo,preferences:preferences)
        check(owner.window == nil && owner.workbench == nil,"Singleton install is lazy")
        check(NativeSettingsWindowController.install(dataSource:demo) === owner,"Install reuses singleton")
        NativeSettingsWindowController.uninstall();check(NativeSettingsWindowController.shared == nil,"Uninstall clears singleton without opening")
        check(NativeSettingsWindowController.initialSize == NSSize(width:880,height:660),"Product window dimensions")
        check(NativeSettingsWindowController.minimumSize == NSSize(width:760,height:480),"Product minimum dimensions")
        check(NativeSettingsCatalog.panes.count == 28,"Full catalog and subpages")
        check(Set(NativeSettingsCatalog.panes.map(\.id)).count == 28,"Unique catalog routes")
        check(NativeSettingsCatalog.visible(query:"",mode:.demo).count == 19,"Demo hides scheduler")
        check(NativeSettingsCatalog.visible(query:"",mode:.live).count == 20,"Live includes scheduler")
        for (word,id) in [("AGENTS","personalization"),("MCP","plugins"),("cleanup","storage"),("Force Click","organic"),("history","browser"),("配色","none")] {
            let results=NativeSettingsCatalog.visible(query:word,mode:.demo);check(id == "none" ? results.isEmpty:results.contains{$0.id == id},"Catalog search "+word)
        }
        check(NativeSettingsCatalog.visible(query:"NO-MATCH",mode:.live).isEmpty,"Empty search results")
        check(!s.go("scheduler"),"Demo cannot route to scheduler")
        check(!s.go("unknown"),"Unknown route rejected")
        var nav=SettingsNavigation();nav.go("plugins");nav.go("plugins/mcp");nav.back();check(nav.pane == "plugins" && nav.canForward,"Back preserves subpage history");nav.go("organic");check(!nav.canForward,"Branch truncates forward history");nav.back();nav.forward();check(nav.pane == "organic","Forward navigation")
        check(SettingsNavigation(initial:"invalid").pane == "general","Invalid restored route falls back")
        preferences.set("organic.fullyFocused",true);check(defaults.bool(forKey:"toggle.fullyFocused"),"Fully Focused exact key")
        preferences.set("organic.compareNeverAsk",true);check(defaults.bool(forKey:"compare.neverAsk"),"Compare exact key")
        for (name,key) in SettingsPreferences.organicKeys {preferences.set("organic."+name,false);check(defaults.bool(forKey:key) == false,"Organic key "+key)}
        check(SettingsPreferences(defaults:defaults)["organic.forceClickPeek"] == false,"Reload Organic preferences")
        preferences.set("look.background","#123456");preferences.set("look.theme","nord");check(preferences["look.background"] == "","Theme clears custom background")
        preferences.resetAppearance();check(preferences["look.theme"] == "canopy","Appearance reset")
        check(SettingsThemes.all.count == 29 && Set(SettingsThemes.all.map(\.id)).count == 29,"29 independent themes")
        for theme in SettingsThemes.all {check([theme.bg,theme.fg,theme.accent,theme.keyword,theme.type,theme.string,theme.comment,theme.function].allSatisfy(SettingsPreferences.isHex),"Theme colors "+theme.id)}
        check(SettingsPreferences.isHex("#0a84FF") && !SettingsPreferences.isHex("red"),"Color input validation")
        check(preferences.assignKey("rename","A") != nil,"Shortcut requires modifier")
        check(preferences.assignKey("rename","⌘N") != nil,"Shortcut conflicts with effective binding")
        preferences.fixedCommand={ $0 == "⌘Q" ? "Quit":nil }
        check(preferences.assignKey("rename","⌘Q") != nil,"Fixed menu collision")
        check(preferences.assignKey("rename","⌘1") != nil,"Number reservation collision")
        check(preferences.setNumberKeys("off") == nil,"Turn off number shortcuts")
        check(preferences.assignKey("rename","⌘1") == nil,"Freed number may be assigned")
        check(preferences.setNumberKeys("chats") != nil,"Cannot reclaim used number")
        preferences.assignKey("rename","");_ = preferences.setNumberKeys("chats")
        preferences.assignKey("send","↩");preferences.assignKey("rename","⌘↩")
        check(preferences.assignKey("send","") != nil,"Empty Send still reserves fallback")
        preferences.assignKey("rename","");preferences.resetKeys()
        let menu=NSMenu(),item=NSMenuItem(title:"Fixed uppercase",action:nil,keyEquivalent:"K");item.keyEquivalentModifierMask = .command;menu.addItem(item)
        check(SettingsKeyCodec.fixedCommand("⇧⌘K",menu:menu) == "Fixed uppercase","Menu uppercase normalization")
        item.identifier = .init("shortcut.rename");check(SettingsKeyCodec.fixedCommand("⇧⌘K",menu:menu) == nil,"Reassignable menu commands excluded")
        await s.loadNow()
        check(s.snapshots["account"]?["account"]?["email"] == "louis@example.com","Demo fixture explicitly loaded")
        let before=s.records("archived").count
        check(await s.execute(s.operation(.unarchive,["id":"a1"])),"Demo unarchive acknowledgement")
        check(s.records("archived").count == before-1,"Demo unarchive removes record")
        check(await s.execute(s.operation(.archiveAll)),"Demo archive all")
        check(s.records("active").isEmpty && s.records("archived").contains{$0["id"] == "c2" && $0["running"] == true},"Archive includes running conversations without stopping them")
        check(s.records("archived").contains{$0["id"] == "c1"},"Archive moves inactive conversation")
        check(!(await s.execute(s.operation(.login))),"Demo cannot call Live login")
        let rule=s.records("rules").first!,ruleID=rule["id"]!
        await s.execute(s.operation(.demo,["action":"record.update","collection":"rules","id":ruleID,"field":"rule","value":"deny"]))
        s.setDevice("pc");await s.loadNow();check(s.records("rules").first?["rule"] == "allow","Demo rules isolated by device")
        s.setDevice("mac");await s.loadNow();check(s.records("rules").first?["rule"] == "deny","Returning to device restores its rules")
        s.setDraft("agents","Draft for Mac");s.setDevice("pc");check(s.draft("agents").isEmpty,"Drafts scoped by device");s.setDevice("mac");check(s.draft("agents") == "Draft for Mac","Draft survives switching back")
        let prior=s.snapshots["demo"];demo.failure="Backend unavailable";check(!(await s.execute(s.operation(.demo,["action":"set","path":"global.name","value":"Oops"]))),"Failed mutation reported");check(s.snapshots["demo"] == prior,"Failed mutation does not change truth");demo.failure=nil
        await s.execute(s.operation(.demo,["action":"set","path":"global.name","value":"Louis L."]))
        let w=NativeSettingsWorkbench(session:s);w.automaticallyLoads=false;w.loadViewIfNeeded();w.view.frame=CGRect(x:0,y:0,width:880,height:660);w.viewDidLayout()
        check(w.table.accessibilityRole() == .outline,"Directory AX role");check(w.search.accessibilityRole() == .textField,"Search AX role")
        check(w.catalogRows.filter{$0.pane == nil}.map(\.group) == ["Personal","Integrations","Coding"],"Native catalog group headings")
        s.go("general");w.render();check(w.table.selectedRow >= 0 && w.catalogRows[w.table.selectedRow].pane?.id == "general","Selected page visible in catalog")
        s.query="MCP";w.refreshCatalog();check(w.catalog.contains{$0.id == "plugins"},"Native catalog search")
        s.query="";w.refreshCatalog()
        s.go("shortcuts");s.recording="rename"
        check(w.routeKey(event("k",.command)),"Recorder consumes shortcut")
        check(preferences["keys.rename"] == "⌘K","Recorder stores shortcut")
        s.recording="rename";check(w.routeKey(event("",code:53)) && s.recording == nil,"Esc cancels recording")
        s.recording="rename";check(w.routeKey(event("",code:51)) && preferences["keys.rename"] == "","Delete clears shortcut")
        s.searchByKeystroke=true;check(w.routeKey(event("n",.command)) && s.listQuery == "⌘N","Keystroke search")
        s.searchByKeystroke=false;s.go("general");s.go("organic")
        check(w.routeKey(event("[",.command)) && s.pane == "general","Keyboard Back")
        check(w.routeKey(event("]",.command)) && s.pane == "organic","Keyboard Forward")
        for pane in NativeSettingsCatalog.panes where pane.id != "scheduler" {
            s.go(pane.id);await s.loadNow();w.render();w.viewDidLayout()
            let specs=SettingsPanels.make(s)
            check(!specs.isEmpty,"Panel content "+pane.id)
            check(Set(specs.map(\.id)).count == specs.count,"Unique row identity "+pane.id)
            check(audit(w.view).isEmpty,"§7.5 "+pane.id)
            for scale:CGFloat in [1,2] {
                let image=w.snapshot(scale:scale,fullPanel:true)
                check(image.width == Int(ceil(w.form.bounds.width*scale)),"Snapshot resolution "+pane.id+"@\(scale)")
                png(image,"demo-"+pane.id.replacingOccurrences(of:"/",with:"-")+"@\(Int(scale))x",output)
            }
        }
        s.go("general");w.render()
        let row=w.form.rows.first{$0.spec.id == "draft.folder"}!,field=row.control as! SettingsField
        field.stringValue="Unsaved edit";field.edited?(field.stringValue)
        w.render();check(w.form.rows.first{$0.spec.id == "draft.folder"} === row,"Semantic refresh retains row")
        check((row.control as? SettingsField) === field && field.stringValue == "Unsaved edit","Refresh retains text field and draft")
        let choice=w.form.rows.first{$0.spec.id == "general.access"}!.control as! SettingsChoice
        check(choice.accessibilityRole() == .group && (choice as? SettingsCardChoices)?.cards.count == 3,"Illustrated access choices retain an AX group and three native radio buttons")
        check(choice.buildMenu().items.filter{$0.state == .on}.count == 1,"Real NSMenu selected item")
        let toggle=w.form.rows.first{$0.spec.id == "general.preventSleep"}!.control as! SettingsButton
        check(toggle.accessibilityRole() == .checkBox && !toggle.isBordered,"Toggle AX and bezel")
        w.sidebarScroll.contentView.scroll(to:.zero)
        check(w.focusChain.first === w.search && w.focusChain.contains{ $0 === choice },"Tab focus includes search, catalog and enabled controls")
        check(w.focusChain.last?.nextKeyView === w.search,"Tab focus wraps to search")
        png(w.snapshot(scale:1),"directory@1x",output);png(w.snapshot(scale:2),"directory@2x",output)
        preferences.set("look.mode","light");s.go("appearance");w.render()
        for scale:CGFloat in [1,2]{png(w.snapshot(scale:scale),"appearance-light@\(Int(scale))x",output)}
        check(w.view.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua,"Light preference remains dark in the dark-only port")
        preferences.set("look.mode","dark");preferences.set("look.theme","nord");w.render()
        check(SettingsDrawing.palette(w.form).canvas.usingColorSpace(.sRGB) == SettingsDrawing.hex("#2e3440").usingColorSpace(.sRGB),"Window theme palette applies")
        for scale:CGFloat in [1,2]{png(w.snapshot(scale:scale),"appearance-nord@\(Int(scale))x",output)}
        preferences.resetAppearance()
        s.go("plugins");w.render()
        // Tokens are random UUIDs; sort by the fixture's semantic identity.
        if let token=s.pluginEntries.keys.sorted(by:{s.pluginEntries[$0]!.plugin["id"]!.settingsText < s.pluginEntries[$1]!.plugin["id"]!.settingsText}).first {
            s.go("plugins/detail/"+token);w.render()
            let original=s.pluginEntries[token]!.plugin,pluginID=original["id"]!
            await s.execute(s.operation(.demo,["action":"plugin.enable","id":pluginID,"value":false]))
            check(s.pluginEntries[token]?.plugin["enabled"] == false,"Plugin detail refreshed after acknowledged mutation")
            for scale:CGFloat in [1,2]{png(w.snapshot(scale:scale,fullPanel:true),"plugin-detail@\(Int(scale))x",output)}
        }else{check(false,"Plugin detail route available")}
        s.openSheet(.schedule);check(s.sheet == nil,"Demo schedule sheet rejected")
        for kind in SettingsSheetKind.allCases where kind != .schedule {
            s.openSheet(kind);let id=s.sheet!.id
            if kind == .addMCP {check(!s.sheet!.canSubmit,"Empty MCP rejected");s.sheet?.fields["name"]="docs";s.sheet?.fields["transport"]="http";s.sheet?.fields["command"]="ftp://example.com";check(!s.sheet!.canSubmit,"Invalid MCP scheme rejected");s.sheet?.fields["command"]="https://example.com/mcp"}
            if kind == .ssh {s.sheet?.fields["host"]="host";s.sheet?.fields["user"]="dev";s.sheet?.fields["port"]="0";check(!s.sheet!.canSubmit,"Invalid SSH port rejected");s.sheet?.fields["port"]="22"}
            if kind == .schedule{s.sheet?.fields["name"]="Digest";s.sheet?.fields["prompt"]="Summarize"}
            if kind == .addSite{s.sheet?.fields["host"]="docs.example.com"}
            let content=SettingsSheetContent(session:s,sheet:s.sheet!);content.loadViewIfNeeded()
            check(audit(content.view).isEmpty,"Sheet §7.5 "+kind.rawValue)
            for scale:CGFloat in [1,2]{png(content.snapshot(scale:scale),"sheet-"+kind.rawValue+"@\(Int(scale))x",output)}
            if kind == .pair {await s.completeDemoPair(id:id);check(s.sheet?.phase == .done && s.records("controllers").contains{$0["id"] == "ipad"},"Demo pairing transition")}
            else {check(await s.submitSheet(id:id),"Demo sheet submit "+kind.rawValue);check(s.sheet?.phase == .done,"Demo sheet done "+kind.rawValue)}
            s.cancelSheet(id:id);check(s.sheet == nil,"Sheet cancel "+kind.rawValue)
        }
        s.openSheet(.addMCP);let oldSheet=s.sheet!.id;s.cancelSheet(id:oldSheet);check(!(await s.submitSheet(id:oldSheet)),"Cancelled sheet cannot submit")
        s.ask(title:"Delete prototype",message:"This removes a sample.",confirm:"Delete",destructive:true,operation:s.operation(.demo,["action":"clear","collection":"links"]))
        let confirmation=s.confirmation!,alert=SettingsAlerts.build(confirmation)
        check(alert.alertStyle == .warning && alert.buttons.count == 2,"Native destructive alert")
        check(alert.buttons[0].hasDestructiveAction && alert.buttons[1].title == "Cancel","Alert action semantics")
        let links=s.records("links").count
        check(!(await s.resolveConfirmation(id:confirmation.id,confirmed:false)) && s.records("links").count == links,"Cancel alert preserves state")
        s.ask(title:"Delete links",message:"Remove prototype links",confirm:"Delete",destructive:true,operation:s.operation(.demo,["action":"clear","collection":"links"]))
        check(await s.resolveConfirmation(id:s.confirmation!.id,confirmed:true),"Confirm alert executes scoped operation")
        check(s.records("links").isEmpty,"Confirmed demo delete acknowledged")
        let color=SettingsColorContent(session:s,key:"look.background");color.loadViewIfNeeded();color.viewDidLayout()
        check(audit(color.view).isEmpty,"Color editor §7.5");check(color.canvas.accessibilityRole() == .slider,"Color canvas AX")
        color.hex.edited?("#123ABC");check(preferences["look.background"] == "#123ABC","Color hex saves")
        color.hex.edited?("invalid");check(preferences["look.background"] == "#123ABC","Invalid color rejected")
        color.revert.run?();check(preferences["look.background"] == "","Color revert")
        for scale:CGFloat in [1,2]{png(NativeViewBitmap.capture(color.view,scale:scale),"color@\(Int(scale))x",output)}
        color.disconnect() // does not instantiate NSColorPanel
        let live=SettingsVerificationSource(),l=SettingsSession(source:live,preferences:preferences)
        await l.loadNow()
        check(l.configPath == "/remote/config.toml","Backend config path preserved without local resolution")
        check(await l.saveConfig(["approval_policy":"never"]),"Versioned config write")
        check(live.writes.last?.payload["expectedVersion"] == "v7","Config version fence")
        check(live.writes.last?.payload["filePath"] == "/remote/config.toml","Config file scope")
        check(live.writes.last?.payload["reloadUserConfig"] == true,"Config reload requested")
        check(l.config("approval_policy") == "on-request","No optimistic config change")
        live.writeResult = .init(snapshots:["config":["config":["approval_policy":"never"]]])
        check(await l.saveConfig(["approval_policy":"never"]),"Config readback write")
        check(l.config("approval_policy") == "never","Acknowledged config becomes truth")
        live.writeResult = .init(notice:"Acknowledged");await l.loadNow()
        for pane in NativeSettingsCatalog.panes {
            l.go(pane.id);await l.loadNow();let specs=SettingsPanels.make(l)
            check(!specs.contains{$0.id == "mode"},"No demo banner in Live "+pane.id)
            check(!specs.contains{$0.id.hasPrefix("demo.")},"No demo mutations in Live "+pane.id)
            check(specs.allSatisfy{$0.id != "profile.activity" && $0.id != "usage.chart"},"No synthetic Live analytics "+pane.id)
        }
        l.go("configuration");let configRows=SettingsPanels.make(l)
        check(configRows.first{$0.id == "config.model_reasoning_effort"}?.choices.contains{$0.0 == "high"} == true,"Efforts from selected backend model")
        check(configRows.first{$0.id == "config.model_reasoning_effort"}?.choices.contains{$0.0 == "ultra"} == false,"No invented backend effort")
        check(configRows.first{$0.id == "config.open"}?.enabled == false,"Remote config is not a local file")
        l.setDevice("offline");check(!l.allowed(.configWrite),"Offline writes disabled")
        check(l.config("model") == nil,"Switching Live devices invalidates old configuration")
        l.setDevice("mac");await l.loadNow()
        l.openSheet(.pair);check(l.sheet == nil,"Live pairing is not fabricated")
        l.openSheet(.importContent);check(l.sheet == nil,"Live import is unavailable")
        l.setDraft("m9.schedule.at","2000003600");l.openSheet(.schedule);l.sheet?.fields["at"] = .number(2000003600);l.sheet?.fields["name"]="Digest";l.sheet?.fields["prompt"]="Summarize";l.sheet?.fields["hours"]=24;l.sheet?.fields["thread"]="thread1"
        let scheduleSheet=SettingsSheetContent(session:l,sheet:l.sheet!);scheduleSheet.loadViewIfNeeded()
        check(scheduleSheet.form.rows.contains{$0.control is SettingsDatePicker},"Native schedule date picker")
        if let row=scheduleSheet.form.rows.first(where:{$0.spec.id == "sheet.prompt"}),let scroll=row.control as? NSScrollView,let editor=scroll.documentView as? SettingsEditor {
            check(editor.string == "Summarize","Prompt editor contains loaded draft")
            check(editor.frame.height >= scroll.contentSize.height && editor.frame.height > 0,"Multiline editor has visible document frame")
            check(editor.layoutManager != nil && editor.textStorage != nil,"Multiline editor retains its TextKit stack")
        }else{check(false,"Prompt editor exists")}
        check(audit(scheduleSheet.view).isEmpty,"Schedule sheet §7.5")
        for scale:CGFloat in [1,2]{png(scheduleSheet.snapshot(scale:scale),"sheet-schedule@\(Int(scale))x",output)}
        check(await l.submitSheet(id:l.sheet!.id),"Live schedule submit")
        check(live.writes.last?.kind == .scheduleCreate && live.writes.last?.payload["everySeconds"] == 86400,"Schedule elapsed-hours contract")
        check(live.writes.last?.payload["threadId"] == "thread1","Schedule real thread ID")
        l.sheet=nil;l.go("scheduler");l.setDraft("m9.schedule.at","2000003600")
        let lw=NativeSettingsWorkbench(session:l);lw.automaticallyLoads=false;lw.loadViewIfNeeded();lw.view.frame=CGRect(x:0,y:0,width:880,height:660);lw.viewDidLayout()
        for pane in ["scheduler","configuration","account","usage","connections","notifications"]{l.go(pane);await l.loadNow();l.setDraft("m9.schedule.at","2000003600");lw.render();check(audit(lw.view).isEmpty,"Live §7.5 "+pane);for scale:CGFloat in [1,2]{png(lw.snapshot(scale:scale,fullPanel:true),"live-"+pane+"@\(Int(scale))x",output)}}
        let suspended=SettingsVerificationSource();suspended.delayRead=true
        let stale=SettingsSession(source:suspended,preferences:preferences),request=Task{await stale.loadNow()}
        for _ in 0..<100 where suspended.pendingRead == nil{await Task.yield()}
        check(suspended.pendingRead != nil,"Read suspension reached")
        stale.setDevice("offline");suspended.pendingRead?.resume(returning:suspended.result);suspended.pendingRead=nil;await request.value
        check(stale.snapshots["config"] == nil,"Old-device read cannot overwrite new scope")
        suspended.delayRead=false;stale.setDevice("mac");await stale.loadNow();suspended.delayWrite=true
        let write=Task{await stale.execute(stale.operation(.logout))}
        for _ in 0..<100 where suspended.pendingWrite == nil{await Task.yield()}
        check(suspended.pendingWrite != nil,"Write suspension reached")
        stale.setSource(SettingsUnavailableDataSource());suspended.pendingWrite?.resume(returning:.init(snapshots:["account":["account":["email":"OLD"]]]));suspended.pendingWrite=nil
        check(!(await write.value) && stale.snapshots["account"] == nil,"Old-endpoint write cannot leak account")
        let unavailable=SettingsSession(source:SettingsUnavailableDataSource(),preferences:preferences);await unavailable.loadNow();check(!unavailable.errors.isEmpty && unavailable.snapshots.isEmpty,"Unavailable Live preserves unknown truth")
        check(!(await unavailable.execute(unavailable.operation(.demo))),"Live refuses demo operation")
        let largeCatalog:JSONValue=["marketplaces":[["name":"dup","plugins":.array((0..<235).map{i in ["id":.string("p\(i)"),"name":.string("Plugin \(i)"),"interface":["longDescription":.string(i == 234 ? "deep-search-match":"description")]]})],["name":"dup","plugins":[["name":"Same"],["name":"Same"]]]]]
        let page=SettingsPluginProjection.page(catalog:largeCatalog,query:"",requestedPage:9)
        check(page.index == 2 && page.matchCount == 237 && page.sections.reduce(0){$0+$1.entries.count} == 37,"Plugin bounded page and clamping")
        check(Set(page.sections.flatMap{$0.entries.map(\.id)}).count == 37,"Duplicate plugin identity remains unique")
        check(SettingsPluginProjection.page(catalog:largeCatalog,query:"deep-search-match",requestedPage:0).matchCount == 1,"Search spans full plugin catalog")
        s.go("usage");await s.execute(s.operation(.demo,["action":"set","path":"global.usageTab","value":"analytics"]))
        check(SettingsPanels.make(s).contains{$0.title == "By model"} && !SettingsPanels.make(s).contains{$0.id == "usage.chart"},"Analytics changes content")
        w.render();for scale:CGFloat in [1,2]{png(w.snapshot(scale:scale,fullPanel:true),"demo-usage-analytics@\(Int(scale))x",output)}
        check(SettingsDemoVisuals.profileGrid("daily") != SettingsDemoVisuals.profileGrid("weekly"),"Daily and weekly activity differ")
        check(SettingsDemoVisuals.profileGrid("weekly") != SettingsDemoVisuals.profileGrid("cumulative"),"Cumulative activity differs")
        for range in ["weekly","cumulative"] {
            await s.execute(s.operation(.demo,["action":"set","path":"global.profileRange","value":.string(range)]));s.go("profile");w.render()
            for scale:CGFloat in [1,2]{png(w.snapshot(scale:scale,fullPanel:true),"demo-profile-"+range+"@\(Int(scale))x",output)}
        }
        s.go("account");check(SettingsPanels.make(s).contains{$0.id == "draft.account.name"},"Demo Account name edit")
        check(SettingsPanels.make(s).contains{$0.id == "account.email"} && SettingsPanels.make(s).contains{$0.id == "account.delete"},"Demo Account email and delete confirmations")
        l.go("appshots");check(SettingsPanels.make(l).first{$0.id == "capture.update"}?.enabled == false,"Appshots cannot enable without thread")
        l.setDraft("capture.thread","thread1");check(SettingsPanels.make(l).first{$0.id == "capture.update"}?.enabled == true,"Appshots enables with real thread and capability")
        l.setDraft("capture.mode","screen");check(SettingsPanels.make(l).first{$0.id == "capture.update"}?.enabled == false,"Appshots respects selected capture capability")
        l.setDraft("capture.mode","window")
        live.result.snapshots["archived"]=["data":[["id":"ar1","title":"First","projectID":"p1","deviceID":"mac","archivedAt":3],["id":"ar2","title":"Second","projectID":"p2","deviceID":"mac","archivedAt":2],["id":"ar3","title":"Third","projectID":"p1","deviceID":"offline","archivedAt":1]]]
        live.result.snapshots["projects"]=["data":[["id":"p1","name":"Same Name"],["id":"p2","name":"Same Name"]]]
        l.go("archived");await l.loadNow();let archiveRows=SettingsPanels.make(l)
        check(archiveRows.first{$0.id == "archive.device"}?.value == "all","Archive defaults to all devices")
        check(archiveRows.filter{$0.id.hasPrefix("archive.ar")}.count == 3,"Archive includes all devices")
        check(Set(archiveRows.map(\.id)).count == archiveRows.count,"Repeated project names have distinct row identity")
        l.setDraft("archiveDevice","mac");check(SettingsPanels.make(l).filter{$0.id.hasPrefix("archive.ar")}.count == 2,"Archive device filter")
        live.result.snapshots["plugins"]=["marketplaces":[["name":"Same","plugins":[["id":"p1","name":"Same","installed":true,"enabled":true]]],["name":"Same","plugins":[["id":"p2","name":"Same","installed":true,"enabled":false]]]]]
        l.go("plugins");await l.loadNow();let repeatedMarkets=SettingsPanels.make(l)
        check(Set(repeatedMarkets.map(\.id)).count == repeatedMarkets.count,"Duplicate marketplace names have distinct native row identity")
        live.result.snapshots["limits"]=["rateLimits":["primary":["usedPercent":0]]];l.go("usage");await l.loadNow()
        check(SettingsPanels.make(l).first{$0.id == "Usageprimary"}?.value == 1,"Reported zero usage is full remaining")
        live.result.snapshots["limits"]=["rateLimits":[:]];await l.loadNow()
        check(!SettingsPanels.make(l).contains{$0.id == "Usageprimary"},"Missing quota clears previously reported capacity")
        live.result.snapshots["mcp"]=["data":[["name":"oauth-server","authStatus":"notLoggedIn","runtimeStatus":"running","toolsError":"Discovery needs authorization"]]]
        l.go("plugins/mcp");await l.loadNow()
        check(SettingsPanels.make(l).contains{$0.id == "mcp.login.oauth-server" && $0.enabled},"Live MCP Sign In accepts backend auth status vocabulary")
        check(SettingsPanels.make(l).contains{$0.id == "mcp.error.oauth-server"},"MCP tool discovery error remains visible")
        let fencedSource=SettingsVerificationSource(),fenced=SettingsSession(source:fencedSource,preferences:preferences)
        let queued=fenced.dispatch(fenced.operation(.logout));fenced.stopPresentation();await queued.value
        check(fencedSource.writes.isEmpty,"Closing cancels a queued write before dispatch")
        let switched=fenced.dispatch(fenced.operation(.logout));fenced.setSource(SettingsUnavailableDataSource());await switched.value
        check(fencedSource.writes.isEmpty,"Switching sources fences queued writes")
        check(SettingsKeyCodec.equivalent("⌘F5").0 == String(UnicodeScalar(0xf708)!),"Function key menu conversion")
        check(SettingsKeyCodec.combo(event(String(UnicodeScalar(0xf708)!),.command)) == "⌘F5","Function key recording")
        for cycle in 0..<20 {
            weak var released:NativeSettingsWorkbench?
            do {
                let temporary=NativeSettingsWorkbench(session:SettingsSession(source:demo,preferences:preferences));temporary.automaticallyLoads=false
                temporary.loadViewIfNeeded();temporary.session.go(cycle%2 == 0 ? "appearance":"plugins");temporary.render();released=temporary;temporary.stop()
            }
            check(released == nil,"Offscreen view graph released cycle \(cycle+1)")
        }
        w.stop();lw.stop()
        check(s.recording == nil && s.sheet == nil && s.onChange == nil,"Presentation teardown cancels editing and dialogs")
        check(NSApp.windows.allSatisfy{!$0.isVisible},"No window opened by verification")
        SettingsNativeAppearanceVerification.run(check:{check($0,$1)})
        await SettingsGroup1Verification.run(check:{check($0,$1)},png:{png($0,$1,output)})
        await SettingsComponentFixVerification.run(check:check){image,name in png(image,name,output)}
        await SettingsM9Verification.run(output:output,check:check)
        let report="Settings \(checks) checks / \(failures.count) failures · \(images) PNGs\n"+failures.joined(separator:"\n")+"\nOffscreen AppKit output; no Live backend, visible window, NSColorPanel or native sheet was presented.\n"
        try? report.write(to:output.appendingPathComponent("results.txt"),atomically:true,encoding:.utf8);print(report)
        exit(failures.isEmpty ? 0:1)
    }
}
#endif
