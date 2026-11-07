#if SETTINGS_SELFTEST
import AppKit

@MainActor enum SettingsComponentFixVerification {
    static func run(check:(Bool,String)->Void,capture:(CGImage,String)->Void) async {
        let suite="organic.settings.component-fix."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let preferences=SettingsPreferences(defaults:defaults),source=SettingsDemoDataSource()
        let s=SettingsSession(source:source,preferences:preferences)
        let fixed=NSMenu()
        for (title,key,flags) in [("Split with Next Conversation","\\",NSEvent.ModifierFlags([.option,.command])),("Focus Conversation","\r",[.shift,.command]),("Next Split Pane","\t",[.control])] {
            let item=NSMenuItem(title:title,action:nil,keyEquivalent:key);item.identifier = .init("command."+title);item.keyEquivalentModifierMask=flags;fixed.addItem(item)
        }
        preferences.fixedCommand={SettingsKeyCodec.fixedCommand($0,menu:fixed)}
        for (combo,title) in [("⌥⌘\\","Split with Next Conversation"),("⇧⌘↩","Focus Conversation"),("⌃⇥","Next Split Pane")] {
            check(preferences.assignKey("rename",combo)?.contains(title) == true,"C01 fixed \(combo) reports its owning command")
            check(preferences.effectiveKey("rename").isEmpty,"C01 conflicting layout shortcut is not saved")
        }
        for (combo,expected) in [("⌘↩","\r"),("⌃⇥","\t"),("⌘⌫","\u{8}"),("⌘⌦","\u{7f}"),("⌘←","\u{f702}"),("⌘→","\u{f703}"),("⌘↓","\u{f701}"),("⌘↑","\u{f700}")] {
            check(SettingsKeyCodec.equivalent(combo).0.utf8.elementsEqual(expected.utf8),"C01 \(combo) uses actual AppKit control characters")
        }
        let canvas=SettingsColorCanvas(frame:CGRect(x:0,y:0,width:268,height:170))
        canvas.color=NSColor(hue:0.2,saturation:0.25,brightness:0.4,alpha:0.8)
        var emitted:NSColor?;canvas.changed={emitted=$0}
        let mouse=NSEvent.mouseEvent(with:.leftMouseDown,location:canvas.convert(CGPoint(x:150,y:160),to:nil),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        canvas.mouseDown(with:mouse)
        let mouseColor=emitted!.usingColorSpace(.deviceRGB)!
        check(abs(mouseColor.saturationComponent-0.25)<0.001 && abs(mouseColor.brightnessComponent-0.4)<0.001,"C11 hue strip drag preserves saturation and brightness")
        check(abs(mouseColor.alphaComponent-0.8)<0.001,"C11 hue drag preserves alpha")
        for key:UInt16 in [123,124]{canvas.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:key)!)
            let color=emitted!.usingColorSpace(.deviceRGB)!
            check(abs(color.saturationComponent-0.25)<0.001 && abs(color.brightnessComponent-0.4)<0.001,"C11 keyboard hue \(key) preserves saturation and brightness")
        }
        _ = s.go("plugins");await s.loadNow()
        var builder=SettingsPanelBuilder(session:s)
        let contacts=s.snapshots["plugins"]!["marketplaces"]!.arrayValue!.first!["plugins"]!.arrayValue!.first{$0["id"] == "contacts"}!
        builder.plugin(contacts,market:[:],id:"contacts",detail:true)
        let disabled=builder.rows.filter{$0.id.hasPrefix("tool.")}
        check(disabled.count == 3 && disabled.allSatisfy{!$0.enabled},"C13 disabled plugin disables every demo tool")
        var enabled=contacts.objectValue!;enabled["enabled"]=true;builder.rows=[];builder.plugin(.object(enabled),market:[:],id:"contacts",detail:true)
        check(builder.rows.filter{$0.id.hasPrefix("tool.")}.allSatisfy(\.enabled),"C13 enabling plugin restores tool controls")
        _ = s.go("general");await s.loadNow();preferences.set("general.access","full")
        let rows=SettingsPanels.make(s),warning=rows.first{$0.id == "general.fullAccess"}
        check(warning?.detail == "Codex can edit any file and run commands with network access without asking." && warning?.tint == .systemOrange,"C14 Full Access shows exact orange product scope explanation")
        check(rows.contains{$0.id == "general.daybreak" && $0.kind == .daybreak && $0.value == "louis@example.com"},"C15 demo General reports the prototype account's Daybreak Access")
        let form=SettingsForm(frame:CGRect(x:0,y:0,width:620,height:600));form.fill=NSColor(white:0.055,alpha:1);form.configure(rows);form.layoutSubtreeIfNeeded()
        let art=form.rows.first{$0.spec.id == "general.daybreak"}!
        check(art.frame.height == 150 && art.control?.accessibilityLabel()?.contains("approved for louis@example.com") == true,"C15 Daybreak has its 150pt card and combined approval semantics")
        check(SettingsVerification.audit(form).isEmpty,"C14/C15 §7.5 card uses only own-draw controls with no bezel")
        for scale:CGFloat in [1,2]{capture(NativeViewBitmap.capture(form,scale:scale),"component-general@\(Int(scale))x")}
        preferences.set("general.access","auto")
        check(!SettingsPanels.make(s).contains{$0.id == "general.fullAccess"},"C14 scope explanation is conditional on Full Access")
        let live=SettingsSession(source:SettingsUnavailableDataSource(),preferences:preferences);_ = live.go("general")
        check(!SettingsPanels.make(live).contains{$0.kind == .daybreak},"C15 Live never fabricates prototype Daybreak approval")
        #if COMPONENT_STORE_SELFTEST
        let a=Conversation(id:"permanent-archive",title:"Archived"),b=Conversation(id:"permanent-active",title:"Active"),c=Conversation(id:"restored-before-confirm",title:"Restored")
        a.archived=true;c.archived=true
        let store=ConversationStore(conversations:[a,b,c])
        let shared=SettingsDemoDataSource(store:store,removeConversations:{_ = try store.remove(ids:$0)})
        let sharedSession=SettingsSession(source:shared,preferences:preferences);_ = sharedSession.go("archived");await sharedSession.loadNow()
        check(await sharedSession.execute(sharedSession.operation(.demo,["action":"remove","collection":"archived","id":.string(a.id)])),"permanent delete acknowledges a real same-store removal")
        check(store.conversation(a.id) == nil && a.archived && !sharedSession.records("archived").contains{$0["id"] == .string(a.id)},"permanent deletion retires retained object and refreshes Settings observers")
        c.archived=false;store.changed(c)
        let newArchive=Conversation(id:"new-archive",title:"New archive");newArchive.archived=true;store.add(newArchive);store.changed(newArchive)
        check(!(await sharedSession.execute(sharedSession.operation(.demo,["action":"clear","collection":"archived","ids":[.string(c.id)]]))) && store.conversation(c.id) === c,"old Archived confirmation cannot remove a restored conversation")
        check(store.conversation(newArchive.id) === newArchive,"frozen delete IDs cannot sweep in a newer archive")
        check(await sharedSession.execute(sharedSession.operation(.demo,["action":"clear","collection":"archived","allChats":true,"ids":[.string(b.id),.string(c.id)]])),"Delete All can remove its confirmed active IDs through the same API")
        check(store.conversations.map(\.id) == [newArchive.id],"Delete All preserves conversations outside its confirmed set")
        sharedSession.stopPresentation()
        #endif
        s.stopPresentation();live.stopPresentation()
    }
}
#endif
