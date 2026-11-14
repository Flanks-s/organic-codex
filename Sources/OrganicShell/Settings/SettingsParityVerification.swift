#if SETTINGS_SELFTEST
import AppKit
import ImageIO

private actor M9SettingsClock:CoreRuntimeClock {
    private var pending:CheckedContinuation<Void,any Error>?
    private(set) var intervals:[Double]=[]
    func sleep(seconds:TimeInterval) async throws {intervals.append(seconds);try await withCheckedThrowingContinuation{pending=$0}}
    func finish(){let continuation=pending;pending=nil;continuation?.resume()}
}

@MainActor private final class M9SettingsLiveFixture:SettingsDataSource {
    let mode=SettingsMode.live,endpointIdentity="fixture://settings",connectionStatus="Connected fixture",localFilesAvailable=false
    let supportedOperations=Set(SettingsOperation.Kind.allCases.filter{$0 != .demo})
    var reads:[SettingsReadRequest]=[],writes:[SettingsOperation]=[]
    func read(_ request:SettingsReadRequest) async throws->SettingsReadResult {
        reads.append(request)
        return .init(snapshots:["account":["account":["type":"chatgpt","email":"fixture@example.invalid","planType":"plus"]],
            "devices":["data":[["id":"mac","name":"Fixture Mac","online":true]]],
            "config":["config":["model":"fixture-model","approval_policy":"on-request","sandbox_mode":"workspace-write","developer_instructions":"Fixture instructions"],"layers":[]],
            "models":["data":[["id":"fixture-model","model":"fixture-model","displayName":"Fixture Model","isDefault":true,"supportedReasoningEfforts":[["reasoningEffort":"high","description":"High"]]]]],
            "limits":["rateLimits":["primary":["usedPercent":27,"windowDurationMins":300]]],
            "health":["eventLog":["diskBytes":2048,"tailBytes":512],"sessions":[["id":"fixture-session"]]],
            "plugins":["marketplaces":[]],"skills":["data":[]],"mcp":["data":[]],"tabs":[],"threads":[],"jobs":[],"runs":[],"notifications":[],"authorizations":[],"archived":["data":[]]],capabilities:["captureWindow":.init(available:true)])
    }
    func perform(_ operation:SettingsOperation) async throws->SettingsWriteResult {writes.append(operation);throw SettingsDataError.invalid("M9 rendering must not issue writes")}
}

/// Repeated 880×660 and 760×480 captures. No NSWindow, backend, launch, native panel or user defaults are used.
/// Product images are read-only inputs. Pixel metrics are measurements, not a claim that geometry tests prove parity.
@MainActor enum SettingsM9Verification {
    private static var imageCount=0
    static let panes=["general","notifications","import","profile","appearance","organic","archived","storage","configuration","personalization","shortcuts","usage","data","plugins","computer","appshots","browser","scheduler","connections"]
    static func run(output:URL,check:(Bool,String)->Void) async {
        let name="organic.settings.m9."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let dates=Date(),archived=[("X1","Old sidebar spike",Optional("spw"),"mac",6),("X2","Try SwiftData for drafts",nil,"mac",15),("X3","Render farm notes",Optional("rs"),"pc",22)].map{id,title,project,device,days in
            let c=Conversation(id:id,identityIndex:0,title:title,projectID:project,deviceID:device,updated:dates,contextUsed:0);c.archived=true;c.archivedAt=dates.addingTimeInterval(-Double(days)*86400);return c
        }
        let active=Conversation(id:"M9-active",identityIndex:1,title:"Active mock conversation",projectID:nil,deviceID:"mac",updated:dates,contextUsed:0)
        let store=ConversationStore(conversations:archived+[active],projects:[.init(id:"spw",name:"Synthetic preview workspace",deviceID:"mac"),.init(id:"rs",name:"Render Scripts",deviceID:"pc")],devices:[.init(id:"mac",name:"This Mac",kind:.mac),.init(id:"pc",name:"Preview PC",kind:.pc),.init(id:"srv",name:"Preview Server",kind:.server,online:false)])
        let source=SettingsDemoDataSource(store:store),preferences=SettingsPreferences(defaults:defaults)
        let target=output.appendingPathComponent("m9");try? FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        var geometry:[String:Any]=[:],metrics:[String:Any]=[:]
        var titles:[String]=[]
        let productURL=URL(fileURLWithPath:ProcessInfo.processInfo.environment["SETTINGS_PARITY_REFERENCE"] ?? FileManager.default.currentDirectoryPath+"/runs/parity-settings-all")
        let landmarks:[String:(String,CGFloat,CGFloat)]=[
            "general":("general.daybreak",72,170),"notifications":("m9.notifications.permission",72,40),"import":("demo.global.importSync",98,37),"profile":("m9.profile.hero",72,179),"appearance":("look.text",72,39),"organic":("organic.playfulSummaries",98,41),"archived":("listQuery",72,44),"storage":("device",72,41),"configuration":("device",72,41),"personalization":("device",72,41),"shortcuts":("listQuery",72,44),"usage":("demo.global.usageTab",72,44),"data":("demo.global.improveModel",72,52),"plugins":("m9.plugins.toolbar",72,44),"computer":("m9.computer.ax",98,52),"appshots":("appshots.preview",72,170),"browser":("demo.global.browserOn",72,46),"scheduler":("m9.scheduler.empty",72,540),"connections":("demo.global.connectionsTab",72,44)]
        for pane in panes {
            defaults.set(pane,forKey:"settings.pane")
            let session=SettingsSession(source:source,preferences:preferences);session.prepareInitialPane(pane)
            let workbench=NativeSettingsWorkbench(session:session);workbench.automaticallyLoads=false;workbench.loadViewIfNeeded();workbench.onTitleChanged={titles.append($0)}
            _ = session.openPane(pane);await session.loadNow();workbench.render();workbench.view.frame.size=CGSize(width:880,height:660)
            let image=workbench.snapshot(scale:1);SettingsTextParityVerification.geometry(pane,workbench:workbench,scale:1,check:check);write(image,target.appendingPathComponent("settings-"+pane+"-v2.png"))
            check(image.width == 880 && image.height == 660,"M9 \(pane) repeats the full 880×660 viewport")
            check(workbench.detailScroll.frame == CGRect(x:220,y:52,width:660,height:608),"M9 \(pane) 220pt sidebar and 52pt toolbar")
            check(workbench.searchPlate.frame == CGRect(x:10,y:62,width:200,height:27),"M9 \(pane) search capsule geometry")
            check(workbench.titleLabel.stringValue == NativeSettingsCatalog.title(pane) && titles.last == workbench.titleLabel.stringValue,"M9 \(pane) publishes its window title")
            check(Set(workbench.form.rows.map{$0.spec.id}).count == workbench.form.rows.count,"M9 \(pane) projected rows have unique identities")
            check(!workbench.form.rows.contains{$0.spec.id == "mode"},"M9 \(pane) has no redesigned demo banner")
            check(workbench.form.rows.filter{$0.spec.visual.footer && $0.spec.kind == .button}.allSatisfy{$0.spec.title.isEmpty && !$0.spec.visual.buttonTitle!.isEmpty},"M9 \(pane) footer actions do not duplicate a left-hand row label")
            check(SettingsVerification.audit(workbench.view).isEmpty,"M9 \(pane) §7.5 own draw/no bezel")
            check(workbench.session.navigation.canBack == false,"M9 \(pane) initial capture has no invented navigation history")
            check(workbench.form.rows.allSatisfy{SettingsVerification.tree($0).allSatisfy{v in let r=v.frame;return [r.minX,r.minY,r.width,r.height].allSatisfy{abs($0.rounded()-$0)<0.01}}},"M9 \(pane) 1× row/control frames align to backing pixels")
            let visible=workbench.form.rows.map{row -> [String:Any] in let f=workbench.view.convert(row.bounds,from:row);return ["id":row.spec.id,"rect":[f.minX,f.minY,f.width,f.height],"style":row.spec.visual.style.rawValue]};geometry[pane]=visible
            if let key=landmarks[pane],let row=workbench.form.rows.first(where:{$0.spec.id == key.0}){let rect=workbench.view.convert(row.bounds,from:row);check(rect.minX == 240 && abs(rect.minY-key.1)<0.01 && rect.width == 620 && abs(rect.height-key.2)<0.01,"M9 \(pane) source-matched first group landmark \(rect)")}
            else{check(false,"M9 \(pane) missing its product landmark")}
            if pane == "general",let row=workbench.form.rows.first(where:{$0.spec.id == "general.access"}),let cards=row.control as? SettingsCardChoices {
                check(cards.cards.map(\.caption) == ["Read Only","Auto","Full Access"] && cards.cards.allSatisfy{$0.frame.width == 70},"M9 General has the three 70pt permission illustrations")
                let follow=workbench.form.rows.first{$0.spec.id == "followUpDefault"}?.control as? SettingsCardChoices
                check(follow?.cards.map(\.caption) == ["Queue","Steer"],"M9 follow-up cards use the product order and captions")
            }
            if pane == "appearance" {
                check(workbench.form.rows.first{$0.spec.id == "look.theme"}?.themes.count == 29,"M9 Appearance retains all 29 actual theme choices")
                check(workbench.form.rows.first{$0.spec.id == "look.code"}?.themes.first?.theme.id == "match","M9 code themes begin with Same as Window")
                if let tile=workbench.form.rows.first(where:{$0.spec.id == "look.theme"})?.themes.first{let rect=workbench.view.convert(tile.bounds,from:tile);check(abs(rect.maxX-308)<1,"M9 first selected theme has the product's partially clipped initial thumb: \(rect)")}
            }
            if pane == "configuration" {let row=workbench.form.rows.first{$0.spec.id == "m9.configuration.efforts"};check(row?.spec.visual.menuActions.count == 5,"M9 effort menu keeps all five independent checkbox actions")}
            if pane == "plugins",let row=workbench.form.rows.first(where:{$0.spec.id.hasPrefix("plugin.open.")}) {
                check(row.rowActionAvailable,"M9 plugin row keeps its native click/keyboard/AX open action")
                if let toggle=row.actionControls.first{check(toggle.frame.minY == 10,"M9 multi-line plugin toggle aligns with the measured first text baseline")}
            }
            let secondLandmark:[String:(String,CGFloat)]=["general":("general.access",298),"notifications":("notifications.done",168),"import":("m9.import.claude",232),"organic":("organic.forceClickPeek",263),"personalization":("demo.devices.mac.memories",169),"plugins":("m9.section.2.header",148),"browser":("m9.section.3.header",467),"usage":("m9.usage.ultra",410),"profile":("profile.activity",379),"connections":("demo.global.allowConnections",177)]
            if let expected=secondLandmark[pane],let row=workbench.form.rows.first(where:{$0.spec.id == expected.0}) {let r=workbench.view.convert(row.bounds,from:row);check(r.minY == expected.1,"M9 \(pane) second section landmark \(r.minY)")}
            if pane == "data"{check(workbench.form.rows.contains{$0.spec.id == "go.archived"},"M9 Data Controls retains the Archived chats row even though the old demo builder omitted it")}
            if pane == "personalization"{check(workbench.form.rows.first{$0.spec.id == "go.personalization/rules"}?.spec.visual.rightText == "4 rules","M9 Custom rules navigation preserves its trailing rule count")}
            if pane == "profile" {check(workbench.form.rows.contains{$0.spec.visual.style == .activity} && workbench.form.rows.contains{$0.spec.visual.style == .statistics},"M9 Profile has the statistics strip and year heatmap")}
            if pane == "shortcuts" {check(workbench.form.rows.filter{$0.spec.kind == .shortcut}.allSatisfy{row in guard let button=row.control as? SettingsButton else{return false};let width=(button.title as NSString).size(withAttributes:[.font:button.font!]).width;return button.bounds.width-14>=width},"M9 every key chip reserves its actual rounded font width without ellipses")}
            if let product=load(productURL.appendingPathComponent("settings-"+pane+"-product.png")) {
                write(pair(image,product),target.appendingPathComponent("settings-"+pane+"-comparison.png"));metrics[pane]=difference(image,product)
                check(product.width == 880 && product.height == 660,"M9 \(pane) comparison uses the provided same-size product image")
            } else{check(false,"M9 missing read-only product reference for "+pane)}
            let double=workbench.snapshot(scale:2);SettingsTextParityVerification.geometry(pane,workbench:workbench,scale:2,check:check);write(double,target.appendingPathComponent("settings-"+pane+"-v2@2x.png"));check(double.width == 1760 && double.height == 1320,"M9 \(pane) repeats the full viewport at 2×")
            SettingsM9CVerification.capture(pane,workbench:workbench,image:double,target:target,check:check)
            workbench.view.frame.size=CGSize(width:760,height:480)
            for scale:CGFloat in [1,2] {let small=workbench.snapshot(scale:scale);check(small.width == Int(760*scale) && small.height == Int(480*scale),"M9 \(pane) minimum viewport at \(scale)×");write(small,target.appendingPathComponent("settings-"+pane+"-minimum@\(Int(scale))x.png"))
                check(workbench.form.rows.allSatisfy{$0.frame.minX == 20 && $0.frame.maxX <= workbench.form.bounds.width-20+0.01},"M9 \(pane) minimum form stays in the detail width")}
            workbench.stop()
        }
        let session=SettingsSession(source:source,preferences:preferences);await session.loadNow()
        for kind:SettingsSheetKind in [.importContent,.customizeSync,.importMCP,.addMCP,.pair,.ssh] {
            session.openSheet(kind);guard let state=session.sheet else{check(false,"M9 sheet "+kind.rawValue);continue}
            let sheet=SettingsSheetContent(session:session,sheet:state);sheet.loadViewIfNeeded();sheet.fit(in:CGSize(width:760,height:428))
            for scale:CGFloat in [1,2]{write(sheet.snapshot(scale:scale),target.appendingPathComponent("sheet-"+kind.rawValue+"@\(Int(scale))x.png"))}
            check(sheet.view.bounds.height<=428,"M9 \(kind) sheet fits minimum host")
            check(SettingsVerification.audit(sheet.view).isEmpty,"M9 \(kind) sheet own-draw controls")
            session.cancelSheet(id:state.id)
        }
        let color=SettingsColorContent(session:session,key:"look.background");color.loadViewIfNeeded();color.viewDidLayout()
        for scale:CGFloat in [1,2]{write(NativeViewBitmap.capture(color.view,scale:scale),target.appendingPathComponent("color@\(Int(scale))x.png"))};color.disconnect()
        await interactionStates(session:session,target:target,check:check)
        await liveStates(preferences:preferences,target:target,check:check)
        let results:[String:Any]=["viewport":[880,660],"geometry":geometry,"pixels":metrics,"pixelMetric":"Mean absolute sRGB channel error in content x≥220,y≥52; measurement only, not a passing tolerance. WindowServer titlebar/glass and animation phase need real captures."]
        if let data=try? JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]){try? data.write(to:target.appendingPathComponent("geometry-and-pixels.json"))}
        session.stopPresentation();check(NSApp.windows.allSatisfy{!$0.isVisible},"M9 captures create no visible window")
        SettingsVerification.images += imageCount
    }
    private static func liveStates(preferences:SettingsPreferences,target:URL,check:(Bool,String)->Void) async {
        let source=M9SettingsLiveFixture()
        let corePages=Set(panes).subtracting(["general","organic","appearance","shortcuts","archived"])
        for page in panes {
            let session=SettingsSession(source:source,preferences:preferences);session.prepareInitialPane(page);await session.loadNow();session.setDraft("m9.schedule.at","2000003600")
            let workbench=NativeSettingsWorkbench(session:session);workbench.automaticallyLoads=false;workbench.loadViewIfNeeded();workbench.view.frame.size=CGSize(width:880,height:660);workbench.render()
            for scale:CGFloat in [1,2]{let image=workbench.snapshot(scale:scale);write(image,target.appendingPathComponent("live-fixture-"+page+"@\(Int(scale))x.png"));check(image.width == Int(880*scale) && image.height == Int(660*scale),"M9 \(page) Live fixture at \(scale)×")}
            check(!workbench.form.rows.contains{$0.spec.kind == .daybreak},"M9 \(page) Live never invents demo Daybreak access")
            check(SettingsVerification.audit(workbench.view).isEmpty,"M9 \(page) Live uses own draw/no bezel")
            if corePages.contains(page){check(workbench.form.rows.contains{$0.spec.id == "m9.live.status"},"M9 \(page) Core form retains connected status and Refresh")}
            if page == "appshots"{check(!workbench.form.rows.contains{$0.spec.id == "appshots.preview"} && workbench.form.rows.contains{$0.spec.id == "capture.thread"},"M9 Live Appshots renders its real shortcut form, not the demo animation")}
            workbench.stop()
        }
        check(source.writes.isEmpty && Set(source.reads.map(\.pane)).count == panes.count,"M9 every Live pane renders only from in-process fixtures, with no writes")
        let session=SettingsSession(source:source,preferences:preferences)
        for page in ["plugins/mcp","plugins/skills"] {
            session.prepareInitialPane(page);await session.loadNow();session.setDraft("m9.schedule.at","2000003600");let workbench=NativeSettingsWorkbench(session:session);workbench.automaticallyLoads=false;workbench.loadViewIfNeeded()
            write(workbench.snapshot(scale:1),target.appendingPathComponent("live-fixture-"+page.replacingOccurrences(of:"/",with:"-")+".png"))
            check(workbench.form.rows.contains{$0.spec.id == "m9.live.integrations"},"M9 Live \(page) keeps the product's integration tabs")
            if page == "plugins/mcp"{check(workbench.form.rows.contains{$0.spec.id == "m9.live.field.m9.mcp.url"} && workbench.form.rows.first{$0.spec.id == "m9.live.mcp.add"}?.spec.enabled == false,"M9 Live MCP has an inline HTTP form and rejects an empty submission")}
            workbench.stop()
        }
    }
    private static func interactionStates(session:SettingsSession,target:URL,check:(Bool,String)->Void) async {
        let source=session.source as! SettingsDemoDataSource
        let workbench=NativeSettingsWorkbench(session:session);workbench.automaticallyLoads=false;workbench.loadViewIfNeeded()
        func row(_ id:String)->SettingsFormRow?{workbench.form.rows.first{$0.spec.id == id}}
        func action(_ id:String)->SettingsRow?{row(id)?.spec ?? workbench.form.rows.flatMap{$0.spec.visual.actions}.first{$0.id == id}}
        func capture(_ name:String){workbench.render();for scale:CGFloat in [1,2]{write(workbench.snapshot(scale:scale),target.appendingPathComponent("state-"+name+"@\(Int(scale))x.png"))};check(SettingsVerification.audit(workbench.view).isEmpty,"M9 state \(name) own draw/no bezel")}
        func pane(_ id:String) async {session.prepareInitialPane(id);await session.loadNow();workbench.render()}
        func global(_ key:String,_ value:JSONValue) async {await session.dispatch(session.operation(.demo,["action":"set","path":.string("global."+key),"value":value])).value}
        await pane("account");capture("account")
        check(row("draft.account.name")?.control?.frame.width == 200,"M9 account name editor keeps the product's 200pt width")
        check(row("m9.account.plan")?.spec.visual.rightText == "Plus","M9 account plan is data, not a hardcoded hero")
        session.preferences.set("general.access","full");await pane("general");capture("general-full")
        check(row("m9.section.2.footer")?.spec.detail.contains("any file") == true,"M9 Full Access retains its actual permission scope warning")
        session.preferences.set("general.access","auto")
        await pane("appearance");action("m9.themes.all")?.perform?(.null);capture("themes-all")
        check(row("look.theme")?.frame.height ?? 0 > 300 && action("m9.themes.all")?.title == "Show Less","M9 Show All expands the real 29-theme grid with Show Less")
        if let tiles=row("look.theme")?.themes,let first=tiles.first{check(tiles.filter{$0.frame.minY == first.frame.minY}.count == 6,"M9 theme grid uses the product's adaptive 82pt minimum plus 6pt spacing (six columns at 880)")}
        action("m9.themes.all")?.perform?(.null)
        let slider=SettingsTextSlider();var levels:[Double]=[];slider.doubleValue=0.85;slider.changed={levels.append($0)}
        for _ in 0..<5{_ = slider.accessibilityPerformIncrement()}
        check(levels == [1,1.15,1.3,1.5,1.5],"M9 text size slider uses the five supported stops and clamps")
        let picker=SettingsColorContent(session:session,key:"look.background");picker.loadViewIfNeeded();picker.color = .systemRed;picker.revert.run?()
        check(SettingsColorContent.hex(picker.color) == SettingsThemes.theme(session.preferences["look.theme"].settingsText).bg.uppercased(),"M9 Revert restores the opening resolved colour, including a theme default")
        check(picker.view.subviews.compactMap{$0 as? SettingsPaletteDot}.count == 8,"M9 colour picker exposes the theme's eight palette swatches")
        picker.disconnect()
        await pane("shortcuts");row("shortcut.newChat")?.spec.perform?(.null);capture("shortcut-recording")
        check((row("shortcut.newChat")?.control as? SettingsButton)?.recordingShortcut == true,"M9 keyboard recording uses the product's Type Shortcut chip")
        session.recording=nil;session.changed()
        await pane("appearance");var opened="";session.onApplicationAction={opened=$0}
        let accent=row("look.accent")?.control as? SettingsAccentChoices;accent?.openCustom?()
        check(session.preferences["look.accent"] == "custom" && SettingsPreferences.isHex(session.preferences["look.custom"].settingsText) && opened == "color:look.custom","M9 first Custom accent selects the theme's accent and opens that picker's colour")
        session.onApplicationAction=nil;session.preferences.set("look.accent","multi");session.preferences.set("look.custom","")
        workbench.setSidebarWidth(280);capture("sidebar-wide")
        check(workbench.sidebarWidth == 260 && workbench.detailScroll.frame.minX == 260,"M9 sidebar resize clamps at product's 260pt maximum and moves the detail")
        workbench.setSidebarWidth(100);check(workbench.sidebarWidth == 220,"M9 sidebar resize clamps at product's 220pt minimum")
        session.setDevice("pc");await pane("configuration");capture("configuration-pc")
        check(row("demo.devices.pc.approval")?.spec.value == "on-request","M9 each demo device keeps its product-specific configuration")
        session.setDevice("srv");await pane("storage");capture("storage-offline")
        check(row("info.Device is offline") != nil,"M9 offline device retains its visible last-loaded warning")
        session.setDevice("mac");await session.loadNow()
        await pane("archived");session.listQuery="no-such-title-in-fixture";capture("archived-no-results")
        check(row("info.No archived chats")?.spec.visual.style == .empty,"M9 empty archive search paints the product's explicit No Results component")
        for tab in ["mcp","skills"] {await global("pluginTab",.string(tab));await pane("plugins");capture("plugins-"+tab)
            check(session.pane == "plugins" && row("m9.plugins.toolbar") != nil,"M9 \(tab) is an in-page demo tab, preserving Plugins title/history")
            check(workbench.form.rows.contains{$0.spec.visual.tile == (tab == "mcp" ? "#29292c":"#ffcf5c")},"M9 \(tab) tab keeps its actual native row controls")}
        await global("pluginTab","plugins");await pane("plugins")
        let opener=workbench.form.rows.first{$0.spec.id.hasPrefix("plugin.open.")}
        check(opener?.accessibilityPerformPress() == true,"M9 plugin row forwards AX Press to its native route")
        capture("plugin-detail");check(session.paneTitle == "Product Design","M9 plugin detail publishes its real plugin title")
        for tab in ["devices","ssh"] {await global("connectionsTab",.string(tab));await pane("connections");capture("connections-"+tab)
            check(!workbench.form.rows.contains{$0.spec.id == "section.Connections"},"M9 \(tab) connection tab does not duplicate the obsolete View picker")}
        for page in ["storage/cleanup","storage/worktrees","personalization/rules","personalization/agents","data/links","browser/history"] {await pane(page);capture(page.replacingOccurrences(of:"/",with:"-"));check(workbench.form.rows.count>1,"M9 subpage \(page) keeps its data/actions")}
        await pane("storage/worktrees");let stepper=row("demo.global.keepWorktrees")?.control as? SettingsCounter
        check(stepper != nil,"M9 worktrees uses the native drawn stepper")
        stepper?.integerValue=20;_ = stepper?.accessibilityPerformIncrement();check(stepper?.integerValue == 20,"M9 worktree stepper clamps at 20")
        await global("browserOn",false);await pane("browser");capture("browser-disabled")
        check(workbench.form.rows.filter{$0.spec.id != "demo.global.browserOn"}.allSatisfy{!$0.spec.enabled},"M9 disabling browser disables both General and site permission actions")
        await global("browserOn",true)
        for range in ["weekly","cumulative"] {await global("profileRange",.string(range));await pane("profile");capture("profile-"+range)}
        await global("usageTab","analytics");await pane("usage");capture("usage-analytics")
        session.openSheet(.importContent);if let state=session.sheet {
            let sheet=SettingsSheetContent(session:session,sheet:state);sheet.loadViewIfNeeded()
            for phase in [SettingsSheetState.Phase.working,.done]{session.sheet?.phase=phase;sheet.refresh();check(sheet.form.rows.filter{$0.spec.id.hasPrefix("sheet.pick.")}.count == 5,"M9 import \(phase) keeps all five choices, disabled");check(sheet.form.rows.filter{$0.spec.id.hasPrefix("sheet.pick.")}.allSatisfy{!$0.spec.enabled},"M9 import \(phase) fences edits");write(sheet.snapshot(scale:1),target.appendingPathComponent("sheet-import-\(phase).png"))}
            check(sheet.submit.title == "Done" && sheet.submit.isEnabled && sheet.cancel.isHidden,"M9 completed import keeps a single default Done action")
            sheet.submit.run?();check(session.sheet == nil,"M9 Done closes instead of issuing a second import")
        }
        let preview=SettingsAppshotPreview(frame:CGRect(x:0,y:0,width:600,height:150));preview.verificationPhase=0.8
        write(NativeViewBitmap.capture(preview,scale:1),target.appendingPathComponent("appshot-attached.png"))
        check(preview.outline.animationKeys() == nil && preview.capture.animationKeys() == nil,"M9 detached Appshot illustration installs no endless animations")
        preview.reduceMotion=true;write(NativeViewBitmap.capture(preview,scale:1),target.appendingPathComponent("appshot-reduce-motion.png"))
        check(source.operations.allSatisfy{$0.scope.endpoint == "demo"},"M9 interaction fixtures stay on the synthetic data source")
        workbench.stop()
        let clock=M9SettingsClock(),demo=SettingsDemoDataSource(),feedback=SettingsSession(source:demo,preferences:session.preferences,progressClock:clock)
        await feedback.loadNow()
        let op=feedback.operation(.demo,["action":"set","path":"global.cuExtension","value":true])
        check(feedback.startDemoFeedback(key:"extension",seconds:1.4,operation:op),"M9 synthetic extension feedback starts")
        for _ in 0..<100{if await clock.intervals.count>0{break};await Task.yield()}
        check(await clock.intervals == [1.4],"M9 extension feedback uses the product's 1.4s interval through an injected clock")
        check(feedback.busy.contains("extension") && demo.operations.isEmpty,"M9 extension wait paints Installing before acknowledgement")
        feedback.stopPresentation();await clock.finish()
        for _ in 0..<20{await Task.yield()}
        check(demo.operations.isEmpty && feedback.busy.isEmpty,"M9 closing during synthetic feedback prevents a delayed mutation")
    }
    private static func load(_ url:URL)->CGImage?{guard let source=CGImageSourceCreateWithURL(url as CFURL,nil)else{return nil};return CGImageSourceCreateImageAtIndex(source,0,nil)}
    private static func write(_ image:CGImage,_ url:URL){do{try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:url);imageCount+=1}catch{SettingsVerification.check(false,"M9 PNG write: "+url.lastPathComponent)}}
    private static func pair(_ a:CGImage,_ b:CGImage)->CGImage{let c=CGContext(data:nil,width:1760,height:660,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(a,in:CGRect(x:0,y:0,width:880,height:660));c.draw(b,in:CGRect(x:880,y:0,width:880,height:660));return c.makeImage()!}
    private static func bytes(_ image:CGImage)->[UInt8]{var data=[UInt8](repeating:0,count:880*660*4);data.withUnsafeMutableBytes{p in let c=CGContext(data:p.baseAddress,width:880,height:660,bitsPerComponent:8,bytesPerRow:880*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:880,height:660))};return data}
    private static func difference(_ a:CGImage,_ b:CGImage)->[String:Double]{let a=bytes(a),b=bytes(b);var total=0,changed=0,count=0
        for y in 52..<660 {for x in 220..<880 {let i=(y*880+x)*4;var d=0;for k in 0..<3{let v=abs(Int(a[i+k])-Int(b[i+k]));total+=v;d=max(d,v)};count+=1;if d>16{changed+=1}}}
        return ["meanAbsRGB":Double(total)/Double(max(1,count*3)),"fractionOver16":Double(changed)/Double(max(1,count))]
    }
}
#endif
