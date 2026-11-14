import AppKit

/// Copy/rewrite of the product Form's section and row projection. Values and actions remain the existing
/// SettingsDataSource contracts: this layer never issues a request, opens an app or fabricates a Live capability.
@MainActor struct SettingsPresentation {
    let session:SettingsSession
    let source:[SettingsRow]
    private var result:[SettingsRow]=[]
    private var sequence=0
    private var group=""
    init(session:SettingsSession,rows:[SettingsRow]){self.session=session;source=rows}
    static func make(_ rows:[SettingsRow],session:SettingsSession)->[SettingsRow]{var p=Self(session:session,rows:rows);p.build();return p.result}
    private func get(_ id:String)->SettingsRow?{source.first{$0.id == id}}
    private func has(_ id:String)->Bool{get(id) != nil}
    private func value(_ key:String)->JSONValue{session.snapshots["demo"]?["global"]?[key] ?? .null}
    private func item(_ id:String,_ title:String?=nil,_ detail:String?=nil,height:CGFloat?=nil)->SettingsRow?{
        guard var row=get(id)else{return nil};if let title{row.title=title};if let detail{row.detail=detail};row.visual.height=height;return row
    }
    private func plain(_ id:String,_ title:String,_ detail:String="",style:SettingsRowVisual.Style = .standard,height:CGFloat?=nil)->SettingsRow{
        var r=SettingsRow(id:id,title:title,detail:detail);r.visual.style=style;r.visual.height=height;return r
    }
    private mutating func section(_ title:String?=nil,_ rows:[SettingsRow?],gap:CGFloat?=nil,actions:[SettingsRow]=[],headerHeight:CGFloat?=nil){
        let rows=rows.compactMap{$0};guard !rows.isEmpty else{return};sequence+=1;group="m9.section.\(sequence)"
        let space=gap ?? (result.isEmpty ? 0:32)
        if let title {
            var h=SettingsRow(id:group+".header",title:title,kind:.heading);h.visual.style = .header;h.visual.gap=space;h.visual.height=headerHeight ?? (actions.isEmpty || actions.allSatisfy({$0.title.hasPrefix("Show All")}) ? (result.isEmpty ? 26:24):(actions.count>1 ? 28.5:28));h.visual.actions=actions;result.append(h)
        }
        for (i,var row) in rows.enumerated(){
            if ["clear.archived","reset.appearance","reset.keys","app.add","sheet.addSite","sheet.ssh"].contains(row.id),row.kind == .button{row.visual.buttonTitle=row.visual.buttonTitle ?? row.title;row.title="";row.detail="";row.visual.footer=true;row.visual.height=20}
            row.visual.group=row.visual.style == .empty || row.visual.footer || ["clear.archived","reset.appearance","reset.keys","app.add","sheet.addSite"].contains(row.id) ? "":group;if i == 0,title == nil{row.visual.gap=space};result.append(row)}
    }
    private mutating func footer(_ text:String,tint:NSColor?=nil){var r=plain(group+".footer","",text,style:.footer);r.tint=tint;r.visual.gap=8;result.append(r)}
    private func action(_ id:String,_ title:String?=nil,symbol:String="")->SettingsRow?{
        guard var r=get(id) else{return nil};r.visual.buttonTitle=title;r.visual.symbol=symbol;return r
    }
    private func withActions(_ row:SettingsRow?,_ ids:[(String,String,String)],chevron:Bool=false)->SettingsRow?{
        guard var r=row else{return nil};r.visual.actions=ids.compactMap{action($0.0,$0.1,symbol:$0.2)};r.visual.chevron=chevron;return r
    }
    private func cards(_ id:String,_ title:String,_ art:String)->SettingsRow?{guard var r=item(id,title,"",height:85)else{return nil};r.visual.style = .cards;r.visual.cardArt=art
        if art == "send"{r.choices=r.choices.map{($0.0,$0.0 == "⌘↩" ? "⌘ Return":"Return")};if !r.choices.contains(where:{$0.0 == r.value.settingsText}){r.choices.append((r.value.settingsText,"Custom"))}}
        if art == "follow"{r.choices=[("queue","Queue"),("steer","Steer")]}
        return r
    }
    private func tile(_ row:SettingsRow?,_ symbol:String,_ color:String)->SettingsRow?{guard var r=row else{return nil};r.visual.symbol=symbol;r.visual.tile=color;if ["demo.global.browserOn","demo.global.cuAnyApp","demo.global.cuWhileLocked"].contains(r.id){r.visual.tileSize=26};return r}
    private func right(_ row:SettingsRow?,_ text:String)->SettingsRow?{guard var r=row else{return nil};r.visual.rightText=text;return r}
    private func segmented(_ id:String,_ choices:[(String,String)]?=nil)->SettingsRow?{guard var r=get(id)else{return nil};r.title="";r.detail="";r.visual.style = .segmented;r.visual.height=44;r.visual.centered=true;if let choices{r.choices=choices};return r}
    private mutating func build(){
        let errors=source.filter{$0.id != "mode" && (($0.kind == .info && $0.id.hasSuffix(".error")) || $0.id.hasPrefix("source.error.") || $0.id == "notice")}
        if session.mode == .live && !["general","organic","appearance","shortcuts","archived"].contains(session.top) {
            var status=plain("m9.live.status",session.source.connectionStatus)
            var refresh=plain("m9.live.refresh","Refresh");refresh.kind = .button;refresh.enabled = !session.busy.contains("read:"+session.pane);refresh.perform={ [session] _ in Task{await session.loadNow()} };status.visual.actions=[refresh]
            section(nil,[status]+errors);live();return
        }
        if !errors.isEmpty{section(nil,errors)}
        switch session.top {
        case "account":if session.mode == .demo{account()}else{generic()}
        case "general":general()
        case "organic":organic()
        case "appearance":appearance()
        case "shortcuts":shortcuts()
        case "archived":archived()
        default:
            if session.mode == .live{generic();return}
            switch session.top {
            case "notifications":notifications()
            case "import":imports()
            case "profile":profile()
            case "storage":storage()
            case "configuration":configuration()
            case "personalization":personalization()
            case "usage":usage()
            case "data":data()
            case "plugins":plugins()
            case "computer":computer()
            case "appshots":appshots()
            case "browser":browser()
            case "connections":connections()
            case "scheduler":var empty=plain("m9.scheduler.empty","Nothing here",style:.empty,height:540);empty.visual.symbol="gearshape";section(nil,[empty])
            default:generic()
            }
        }
    }
    /// CoreSettingsPanes has a different, truthful Form from the demo fixtures. Preserve the original acknowledged
    /// row/actions, and project only their order/grouping. Additional Core-version-specific rows remain visible.
    private mutating func live(){
        let original=source
        var used=Set(source.filter{$0.kind == .heading || $0.id == "notice" || $0.id.hasSuffix(".error") || $0.id.hasPrefix("source.error.")}.map(\.id))
        func take(_ id:String,_ title:String?=nil)->SettingsRow?{guard var r=original.first(where:{$0.id == id})else{return nil};used.insert(id);if let title{r.title=title};return r}
        func valueRow(_ id:String,_ title:String?=nil)->SettingsRow?{guard var r=take(id,title)else{return nil};r.visual.rightText=r.detail;r.detail="";return r}
        func matching(_ predicate:(SettingsRow)->Bool)->[SettingsRow]{original.filter{!used.contains($0.id) && predicate($0)}.compactMap{take($0.id)}}
        func caption(_ id:String,_ text:String)->SettingsRow{var r=plain(id,"",text,style:.footer);r.visual.height=40;return r}
        func capability(_ key:String,_ title:String)->SettingsRow{let cap=session.capabilities[key];var r=plain("m9.live.capability."+key,title,cap.map{$0.available ? "Available":$0.reason ?? "Unavailable"} ?? "Not reported");r.visual.symbol=cap?.available == true ? "checkmark.circle":"info.circle";return r}
        switch session.top {
        case "account","profile":
            let a=session.snapshots["account"]?["account"],label=a?["name"]?.settingsText ?? a?["email"]?.settingsText ?? "Not signed in"
            var identity=plain("m9.live.identity","Signed in as");identity.visual.rightText=label
            var rows:[SettingsRow?]=[identity,valueRow("info.Plan")]
            used.formUnion(original.filter{$0.kind == .info}.map(\.id))
            if a?.objectValue != nil{rows.append(take("logout","Sign Out…"));used.insert("login")}else{rows.append(take("login","Sign In with ChatGPT…"))}
            rows.append(take("cancelLogin","Cancel Sign-In"));var refresh=plain("m9.live.accountRefresh","Refresh Sign-In Status");refresh.kind = .button;refresh.perform={ [session] _ in Task{await session.loadNow()} };rows.append(refresh)
            section("Account",rows)
            var web=plain("m9.live.accountWeb","Open ChatGPT Account Settings…");web.kind = .button;web.perform={ [session] _ in session.onOpenURL?(URL(string:"https://chatgpt.com/#settings")!) }
            section("Manage your account",[web,caption("m9.live.accountHelp","Name, email, subscription and account deletion are managed on the account website. Organic Codex does not change them locally.")])
            used.formUnion(["go.usage","go.data"])
        case "configuration":
            section("Models",[take("config.model","Default model"),take("config.model_reasoning_effort","Default reasoning")]);footer("Model and reasoning defaults apply to new chats. Existing chats keep their selected model.")
            section("Permissions and responses",["approval_policy","sandbox_mode","web_search","model_verbosity","model_reasoning_summary"].compactMap{take("config."+$0)})
            section("Configuration file",[take("info.User configuration"),take("config.open")]);used.insert("device")
        case "connections":
            section("Connected backend",[valueRow("info.Backend","Address"),valueRow("info.Status"),take("reconnect")])
            section("Connection address",[take("draft.endpoint"),take("endpoint.save","Save for Next Launch"),take("info.Remote connections")])
        case "storage":
            section("Backend storage",[valueRow("info.Event log on disk"),valueRow("info.Event log tail","Event buffer in memory"),valueRow("info.Stored sessions","Known sessions")]);footer("These values come from the connected backend. Total history and attachment storage is not reported by this Core version.")
            section("Manage",[take("go.archived","Archived Chats…"),take("local.data","Show Organic Core Data…")]);footer("Automatic cleanup and worktree removal are not exposed by this backend. No files are removed by this pane.");used.insert("device")
        case "personalization":
            var editor=take("draft.instructions");editor?.title="";editor?.detail="";editor?.visual.cardArt="instructions";editor?.visual.height=170
            section("Custom instructions",[editor,take("instructions.save","Save Instructions")]);footer("Saved to the connected backend’s user configuration. Project AGENTS.md files continue to apply.")
            section("Configuration file",[take("instructions.open","Open config.toml…")]);used.insert("device")
        case "data":
            section("Chats",[take("go.archived","Archived Chats…"),take("archive.all","Archive All Chats…")])
            section("Account data",matching{$0.id.hasPrefix("link.")}.map(Optional.some));footer("Training preferences, data export, shared links and account deletion are managed on the account website. This backend does not expose those operations.");used.insert("info.Data controls")
        case "notifications":
            section("Scheduled task notifications",[take("coreNotifications","Show notifications on this Mac"),valueRow("info.Permission","System permission"),take("permission","Allow Notifications…"),take("go.scheduler","Per-task preferences…")]);footer("Preferences apply while Organic Codex is connected. Results remain in the backend’s notification inbox even when banners are off.")
            section("Inbox",matching{$0.id.hasPrefix("notification.") || $0.id.hasPrefix("ack.")}.map(Optional.some))
        case "appshots":
            section("Window capture",[capability("captureWindow","Window capture")]);section("Display capture",[capability("captureScreen","Display capture")])
            section("Global Appshot shortcut",[valueRow("info.Shortcut"),valueRow("info.Status"),take("capture.thread"),take("capture.mode"),take("capture.update"),take("capture.disable"),take("capture.error"),take("info.Choose a chat")]);footer("Pressing the shortcut captures and sends directly to the selected chat. Window capture uses that chat’s normal app approval flow; display capture uses macOS screen recording permission.")
            section("macOS permissions",matching{$0.id.hasPrefix("link.")}.map(Optional.some));used.insert("appshots.preview");used.insert("info.Capture unavailable")
        case "browser":
            section("Browser",[take("info.browser")]);section("Browser extension",[take("info.browserExtension")])
            section("Browser access",[take("config.browser_use.allow_history_access","Allow browser history access"),take("config.browser_use.default_origin_policy.access","Default website access")]);footer("These preferences apply to the official browser integration. Independent browser tabs use the connected Core’s browser session.")
            section("Open browser tabs",matching{$0.id.hasPrefix("tab.") || $0.id == "info.No open tabs reported"}.map(Optional.some))
        case "computer":
            section("Computer use",[take("info.Native computer capability")]);section("Application access",[take("config.computer_use.default_app_access")]);footer("Individual application requests still follow the connected backend’s approval requirements.")
            section("Granted sessions",matching{$0.id.hasPrefix("grant.") || $0.id.hasPrefix("revoke.")}.map(Optional.some));section("macOS permissions",matching{$0.id.hasPrefix("link.")}.map(Optional.some))
        case "import":
            section("Existing configuration",[take("info.Import"),take("go.plugins/skills"),take("go.plugins/mcp"),take("go.configuration")])
        case "usage":
            var plan=plain("m9.live.plan","Current plan");plan.visual.rightText=session.snapshots["account"]?["account"]?["planType"]?.settingsText.capitalized ?? "Not reported"
            section("Plan",[plan,take("link.https://chatgpt.com/#settings/Subscription","Manage Plan…")])
            let rows=matching{$0.kind == .progress}.map{r -> SettingsRow in var r=r;r.visual.style = .meter;r.visual.height=68;r.value = .number(1-(r.value.doubleValue ?? 0));r.visual.rightText=String(format:"%.0f%% used",(r.value.doubleValue ?? 0)*100);return r}
            section("Usage limits",rows.map(Optional.some))
        case "plugins":
            liveIntegrations();return
        case "scheduler":
            section("Scheduled tasks",[capability("scheduler","Scheduled tasks")])
            var tasks:[SettingsRow?]=[]
            for job in session.records("jobs") {let id=job["id"]?.settingsText ?? "";var r=take("job."+id);let pause=get("job.pause."+id);used.insert("job.pause."+id);var button=pause;button?.kind = .button;button?.title=job["enabled"] == true ? "Pause":"Resume";button?.perform={_ in pause?.perform?(.bool(job["enabled"] == true))};r?.visual.actions=[button].compactMap{$0};tasks.append(r);tasks.append(take("job.next."+id));tasks.append(take("jobNotifications."+id));tasks += matching{$0.id.hasPrefix("run."+id+".")}.map(Optional.some)}
            section("Tasks",tasks.isEmpty ? [plain("m9.live.noTasks","No scheduled tasks.")]:tasks)
            section("New scheduled task",liveScheduleFields());footer("The connected backend must remain running. Repeats use elapsed hours from the first run.");used.insert("sheet.schedule");used.insert("info.No scheduled tasks")
        default:generic();return
        }
        let extra=original.filter{!used.contains($0.id) && $0.id != "mode" && $0.kind != .heading}
        if !extra.isEmpty{section(nil,extra.map(Optional.some))}
    }
    private func liveField(_ key:String,_ title:String,_ fallback:String="",kind:SettingsRow.Kind = .field,choices:[(String,String)]=[])->SettingsRow {
        var r=SettingsRow(id:"m9.live.field."+key,title:title,kind:kind,value:.string(session.draft(key,fallback:fallback)),choices:choices,perform:{[session] value in session.setDraft(key,value.settingsText);session.changed()})
        if kind == .editor{r.visual.height=125};return r
    }
    private func liveScheduleFields()->[SettingsRow?] {
        if session.draft("m9.schedule.at").isEmpty{session.setDraft("m9.schedule.at",String(Date().addingTimeInterval(3600).timeIntervalSince1970))}
        let name=session.draft("m9.schedule.name"),prompt=session.draft("m9.schedule.prompt"),date=Double(session.draft("m9.schedule.at")) ?? 0,hours=Double(session.draft("m9.schedule.hours",fallback:"0")) ?? 0,thread=session.draft("m9.schedule.thread")
        var at=liveField("m9.schedule.at","First run",kind:.date);at.value = .number(date)
        var create=plain("m9.live.schedule.create","Create Schedule");create.kind = .button
        create.enabled = !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && date>Date().timeIntervalSince1970 && session.allowed(.scheduleCreate)
        create.perform={[session] _ in guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,date>Date().timeIntervalSince1970 else{return};var values:[String:JSONValue]=["name":.string(name),"prompt":.string(prompt),"at":.number(date),"everySeconds":.number(hours*3600),"enabled":true];if !thread.isEmpty{values["threadId"] = .string(thread)};session.dispatch(session.operation(.scheduleCreate,.object(values)))}
        let threads=session.records("threads").compactMap{t -> (String,String)? in guard t["archived"] != true,let id=t["backendThreadID"]?.stringValue else{return nil};return(id,t["title"]?.settingsText ?? "Chat")}
        return [liveField("m9.schedule.name","Name"),liveField("m9.schedule.prompt","What should Codex do?",kind:.editor),at,liveField("m9.schedule.hours","Repeat","0",kind:.choice,choices:[("0","Once"),("1","Every hour"),("24","Every day"),("168","Every week")]),liveField("m9.schedule.thread","Conversation",kind:.choice,choices:[("","Create a new chat")]+threads),create]
    }
    private mutating func liveIntegrations(){
        let tab=session.pane == "plugins/skills" ? "skills":session.pane == "plugins/mcp" ? "mcp":"plugins"
        var tabs=plain("m9.live.integrations","",style:.segmented,height:41);tabs.kind = .choice;tabs.choices=[("plugins","Plugins"),("skills","Skills"),("mcp","MCP Servers")];tabs.value = .string(tab);tabs.visual.centered=true;tabs.perform={[session] v in session.go(v == "plugins" ? "plugins":"plugins/"+v.settingsText)}
        var search=get("listQuery");search?.visual.style = .search;search?.visual.height=41;section(nil,[tabs,search])
        if tab == "skills" {
            var install=get("skills.install");install?.title="Install Skill Folder…"
            section("Install a skill",[install ?? plain("m9.live.remoteSkill","","Install skill folders on the connected backend’s machine, then refresh.")])
            section("Skills",source.filter{$0.id.hasPrefix("skill.") || $0.id == "info.No skills"}.map(Optional.some));footer("Install additional skills through a plugin, or place a SKILL.md in your Codex skills folder and refresh.");return
        }
        if tab == "mcp" {
            var servers:[SettingsRow]=[]
            for server in session.records("mcp") {let name=server["name"]?.settingsText ?? "";guard let toggle=get("mcp."+name)else{continue};var r=plain("m9.live.mcp."+name,name,server["toolsError"]?.settingsText ?? "");r.visual.rightText=server["runtimeStatus"]?.settingsText ?? server["authStatus"]?.settingsText ?? "Unknown";var enable=toggle;enable.kind = .button;enable.title=server["runtimeStatus"] == "disabled" ? "Enable":"Disable";enable.perform={_ in toggle.perform?(.bool(server["runtimeStatus"] == "disabled"))};r.visual.actions=[get("mcp.login."+name),enable].compactMap{$0};servers.append(r)}
            section("MCP Servers",servers.isEmpty ? [get("info.No MCP servers")]:servers.map(Optional.some))
            let name=session.draft("m9.mcp.name"),url=session.draft("m9.mcp.url"),address=URL(string:url),valid = !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && ["http","https"].contains(address?.scheme ?? "") && address?.host?.isEmpty == false
            var add=plain("m9.live.mcp.add","Add Server");add.kind = .button;add.enabled=valid && session.allowed(.mcpWrite);add.perform={[session] _ in guard valid else{return};session.dispatch(session.operation(.mcpWrite,["name":.string(name.trimmingCharacters(in:.whitespacesAndNewlines)),"values":["url":.string(url),"enabled":true]]))}
            section("Add an HTTP MCP server",[liveField("m9.mcp.name","Name"),liveField("m9.mcp.url","Server URL"),add]);footer("For a local command server or environment variables, edit config.toml, then refresh.")
            if let path=session.configPath {section("Configuration file",[plain("m9.live.mcp.path",path)])};return
        }
        if session.pane.hasPrefix("plugins/detail/"){generic();return}
        var pagination=plain("m9.live.plugins.page",get("info.Plugin directory")?.detail ?? "No plugins found");pagination.visual.actions=[action("plugins.previous","Previous"),action("plugins.next","Next")].compactMap{$0};section(nil,[pagination])
        let page=SettingsPluginProjection.page(catalog:session.snapshots["plugins"] ?? .null,query:session.listQuery,requestedPage:session.pluginPage)
        for group in page.sections {let rows=group.entries.compactMap{entry -> SettingsRow? in let token=session.pluginToken(entry.id);guard var r=get("plugin.open."+token)else{return nil};r.kind = .info;r.visual.cardArt="live.plugin";r.visual.actions=[get("plugin.enabled."+token),action("plugin.remove."+token,"Remove…"),action("plugin.install."+token,"Install…")].compactMap{$0};return r};section(group.title,rows.map(Optional.some))}
        for r in source where r.id.hasPrefix("market.error.") || r.id.hasPrefix("connect.app.") || r.id.hasPrefix("link."){section(nil,[r])}
    }
    private mutating func generic(){
        var pending:[SettingsRow]=[],title:String?
        for r in source where r.id != "mode" && r.id != "notice" && !(r.kind == .info && r.id.hasSuffix(".error")) && !r.id.hasPrefix("source.error.") {
            if r.kind == .heading {if !pending.isEmpty{section(title,pending);pending=[]};title=r.title == NativeSettingsCatalog.title(session.pane) ? nil:r.title}
            else{pending.append(r)}
        };section(title,pending)
    }
    private mutating func account(){
        var plan=plain("m9.account.plan","Plan");plan.visual.rightText=value("plan").settingsText;plan.visual.actions=[action("go.usage","View Plans…")].compactMap{$0}
        var name=item("draft.account.name","Name","");var save=action("account.name.save","Save");let draft=session.draft("account.name",fallback:value("name").settingsText).trimmingCharacters(in:.whitespacesAndNewlines);save?.enabled = !draft.isEmpty && draft != value("name").settingsText;name?.visual.actions=[save].compactMap{$0}
        var username=item("info.Username","Username","");username?.visual.rightText="@louis"
        var email=plain("m9.account.email","Email");email.visual.rightText=value("email").settingsText;email.visual.actions=[action("account.email","Change…")].compactMap{$0}
        section("Account",[plan,name,username,email])
        section(nil,[item("logout","Sign out",""),item("account.delete","Delete account","")])
        for i in result.indices{if result[i].id == "logout"{result[i].visual.buttonTitle="Sign Out…"};if result[i].id == "account.delete"{result[i].visual.buttonTitle="Delete…"}}
    }
    private mutating func general(){
        if var r=get("general.daybreak"){r.visual.height=170;section(nil,[r])}
        section("Permissions",[cards("general.access","Default access","access")])
        if let warning=get("general.fullAccess"){footer(warning.detail,tint:warning.tint)}
        section("Composer",[cards("keys.send","Send messages with","send"),cards("followUpDefault","While Codex is working","follow"),item("general.preventSleep","Prevent sleep while running","")])
        section("Collapse",[item("collapseOnHoverSpace","Space over a chat collapses to it","")])
        footer("Hold a bar’s grip or an orb and press Space to collapse the window to that chat. With this on, pointing at it is enough; Space still types in the input you are writing in.")
        var folder=withActions(item("draft.folder","Chats without a project",""),[("choose.folder","Change…","")]);folder?.visual.readOnly=true
        section("Files",[folder,item("general.openIn","Open files in","")])
        section("Language",[item("general.language","App language","")])
        if has("info.Shortcut unavailable"){section(nil,[get("info.Shortcut unavailable")])}
    }
    private mutating func organic(){
        var tone=item("organic.playfulSummaries","Summary tone","")!;tone.kind = .choice;tone.value=session.preferences["organic.playfulSummaries"] == true ? "playful":"plain";tone.choices=[("playful","Playful"),("plain","Plain")];tone.perform={ [session] v in session.preferences.set("organic.playfulSummaries",.bool(v == "playful")) }
        var sample=plain("m9.organic.sample","Worked for 14s",session.preferences["organic.playfulSummaries"] == true ? "sniffed out one custom inset in SidebarView.swift and ditched it":"Found one custom inset in SidebarView.swift and removed it.",height:66.25);sample.visual.cardArt="summary"
        section("Brief",[tone,sample])
        section("Orbs",[item("organic.forceClickPeek","Peek with Force Click","Press firmly on an orb to peek at once.",height:52),item("organic.identityLiquid","Liquid in each chat’s colour","Off, every orb fills with the accent colour.",height:52)])
        section("Focused",[item("organic.fullyFocused","Fully Focused","Around the conversation, nothing orbits, sloshes, bounces or magnifies.",height:52)])
    }
    private mutating func notifications(){
        var status=plain("m9.notifications.permission","Notifications are allowed",height:40);status.visual.symbol="checkmark.circle";status.tint = .systemGreen
        var open=plain("m9.notifications.open","Notification Settings…");open.kind = .button;open.perform={ [session] _ in session.onOpenURL?(URL(string:"x-apple.systempreferences:com.apple.preference.notifications")!) };status.visual.actions=[open]
        section(nil,[status])
        section("Notify me when",[item("notifications.done","A run finishes",""),item("notifications.approval","Codex needs approval",""),item("notifications.error","A run fails or a device disconnects",""),item("notifications.cloud","A cloud task updates","")])
        for i in result.indices where result[i].kind == .choice{result[i].choices=result[i].choices.map{($0.0,$0.0 == "sound" ? "Banner & Sound":$0.0 == "both" ? "Banner & Email":$0.1)}}
        section("Options",[item("notifications.inactive","Only when Organic Codex isn’t active",""),item("notifications.badge","Show unread count on the Dock icon",""),item("notifications.bounce","Bounce the Dock icon for approvals","")])
    }
    private mutating func imports(){
        var sync=item("demo.global.importSync","Keep imports in sync","");sync?.enabled=session.offline == false
        var custom=item("sheet.customizeSync","Content to sync","",height:40);custom?.visual.buttonTitle="Customize…";custom?.enabled=value("imported") == true
        section("Automatic sync",[sync,custom])
        var claude=plain("m9.import.claude","Claude Code","3 MCP servers, 12 skills, 4 projects, 41 chats",height:52);claude.visual.actions=[action("sheet.importContent","Import…")].compactMap{$0};claude.visual.symbol="chevron.left.forwardslash.chevron.right";claude.visual.tile="#ff7b3a"
        var mcp=plain("m9.import.project","Project MCP files",".mcp.json in 2 projects",height:52);mcp.visual.actions=[action("sheet.importMCP","Import…")].compactMap{$0};mcp.visual.symbol="doc.text";mcp.visual.tile="#8e8e93"
        section("Detected on This Mac",[claude,mcp])
    }
    private mutating func profile(){
        var hero=plain("m9.profile.hero",value("name").settingsText,"@louis · "+(value("profilePublic") == true ? "Public profile":"Private profile"),style:.profile,height:179)
        var privacy=get("demo.global.profilePublic")!;privacy.visual.symbol="lock.fill";privacy.kind = .choice;privacy.choices=[("private","Private"),("public","Public")];privacy.value=value("profilePublic") == true ? "public":"private";privacy.perform={ [session] v in session.dispatch(session.operation(.demo,["action":"set","path":"global.profilePublic","value":.bool(v == "public")])) }
        hero.visual.actions=[action("go.account","Edit…",symbol:"pencil"),privacy,action("profile.share","Share…",symbol:"square.and.arrow.up")].compactMap{$0};section(nil,[hero])
        section(nil,[plain("m9.profile.statistics","",style:.statistics,height:62)],gap:10)
        var activity=get("profile.activity")!;activity.visual.style = .activity;activity.visual.height=143;activity.visual.actions=[get("demo.global.profileRange")!];section("Token activity",[activity])
        section("Top plugins",[plain("m9.profile.plugins","",style:.pluginTiles,height:94)])
        let insights=source.filter{$0.kind == .info && $0.detail.hasSuffix(" · prototype")}.map{r in var r=r;let detail=r.detail;r.detail="";r.visual.rightText=String(detail.dropLast(12));return r};section("Insights",insights)
    }
    private mutating func appearance(){
        var size=item("look.text","Text size","",height:39)!;size.visual.style = .slider
        section(nil,[size])
        var themes=get("look.theme")!;themes.visual.style = .themeStrip;themes.visual.height=97
        var all=plain("m9.themes.all",session.draft("m9.themes.all") == "yes" ? "Show Less":"Show All (29)");all.kind = .button;all.perform={ [session] _ in session.setDraft("m9.themes.all",session.draft("m9.themes.all") == "yes" ? "":"yes");session.changed() };themes.visual.showsAll=session.draft("m9.themes.all") == "yes"
        section("Window Theme",[themes],actions:[all])
        var glass=cards("look.glass","Glass","glass")!;glass.visual.height=85
        var bg=item("color.background","Background","",height:39.5)!;bg.value=session.preferences["look.background"];bg.visual.buttonTitle=session.preferences["look.background"].settingsText.isEmpty ? SettingsThemes.theme(session.preferences["look.theme"].settingsText).bg.uppercased():session.preferences["look.background"].settingsText;bg.visual.cardArt="color"
        var fg=item("color.foreground","Foreground","",height:39.5)!;fg.value=session.preferences["look.foreground"];fg.visual.buttonTitle=session.preferences["look.foreground"].settingsText.isEmpty ? SettingsThemes.theme(session.preferences["look.theme"].settingsText).fg.uppercased():session.preferences["look.foreground"].settingsText;fg.visual.cardArt="color"
        var accent=get("look.accent")!;accent.title="Accent color";accent.detail="";accent.visual.style = .accent;accent.visual.height=56;var custom=get("color.custom")!;custom.perform={ [session] _ in if !SettingsPreferences.isHex(session.preferences["look.custom"].settingsText){session.preferences.set("look.custom",.string(SettingsThemes.theme(session.preferences["look.theme"].settingsText).accent))};session.preferences.set("look.accent","custom");session.onApplicationAction?("color:look.custom") };accent.visual.menuActions=[custom]
        section(nil,[glass,bg,fg,accent],gap:10);footer("With Increase Contrast or Reduce Transparency on, the glass becomes the theme’s background, solid.")
        var code=get("look.code")!;code.kind = .themes;code.visual.style = .themeStrip;code.visual.height=97;code.visual.showsAll=session.draft("m9.code.all") == "yes"
        var ca=plain("m9.code.all",session.draft("m9.code.all") == "yes" ? "Show Less":"Show All (30)");ca.kind = .button;ca.perform={ [session] _ in session.setDraft("m9.code.all",session.draft("m9.code.all") == "yes" ? "":"yes");session.changed() }
        section("Code Theme",[code],actions:[ca]);section("Code",[item("look.font","Font",""),item("look.size","Size",""),get("code.preview")]);section(nil,[item("reset.appearance","Reset Appearance","")])
    }
    private mutating func shortcuts(){
        var search=item("listQuery","Search shortcuts","")!;search.visual.style = .search;search.visual.actions=[get("search.key")!];search.visual.height=44
        var record=get("search.key")!;record.title="";record.visual.symbol="record.circle";record.visual.cardArt="searchRecord";search.visual.actions=[record]
        var numbers=item("numberShortcuts","Number shortcuts","");if var n=numbers{n.choices=n.choices.map{($0.0,$0.0 == "chats" ? "⌘1–9 for Chats":$0.1)};numbers=n}
        section(nil,[search,numbers])
        let groups:[(String,[String])]=[("Chats",["newChat","archive","rename","pin","unread"]),("Composer",["send","attach","focus","stop"]),("Navigation",["search","sidebar","collapse","restore","inspector","settings","undo"])]
        for (title,ids) in groups {
            let keys=ids.compactMap{id -> SettingsRow? in guard var r=get("shortcut."+id)else{return nil}
                var edit=plain("m9.key.edit."+id,"");edit.kind = .button;edit.visual.symbol="pencil";edit.perform=r.perform
                r.visual.actions=[edit];if session.recording == id{r.visual.cardArt="recording";r.detail=""}
                if !r.value.settingsText.isEmpty {var trash=plain("m9.key.remove."+id,"");trash.kind = .button;trash.visual.symbol="trash";trash.perform={ [session] _ in session.keyWarning=session.preferences.assignKey(id,"");session.changed() };r.visual.actions.append(trash)}
                if let standard=NativeSettingsCatalog.shortcuts.first(where:{$0.id == id})?.key,r.value.settingsText != standard {var restore=plain("m9.key.restore."+id,"");restore.kind = .button;restore.visual.symbol="arrow.uturn.backward";restore.perform={ [session] _ in session.keyWarning=session.preferences.assignKey(id,standard);session.changed() };r.visual.actions.append(restore)}
                return r
            };section(title,keys)
        }
        if !source.contains(where:{$0.id.hasPrefix("shortcut.")}){var empty=plain("m9.shortcuts.empty","No Results",style:.empty,height:180);empty.visual.symbol="keyboard";section(nil,[empty])}
        var reset=item("reset.keys","Restore Defaults","");reset?.enabled=NativeSettingsCatalog.shortcuts.contains{session.preferences.effectiveKey($0.id) != $0.key};section(nil,[reset]);if let warning=get("info.Shortcut unavailable"){section(nil,[warning])}
    }
    private mutating func archived(){
        var search=item("listQuery","Search archived chats","")!;search.visual.style = .toolbar;search.visual.height=44;search.visual.actions=[get("archive.device"),get("project.filter")].compactMap{$0};section(nil,[search])
        var current:String?,pending:[SettingsRow]=[]
        for row in source where row.id.hasPrefix("project.") && row.kind == .heading || row.id.hasPrefix("archive.") && row.kind == .info {
            if row.kind == .heading {if !pending.isEmpty{section(current,pending);if let h=result.lastIndex(where:{$0.kind == .heading}){result[h].detail="\(pending.count) \(pending.count == 1 ? "chat":"chats")"};pending=[]};current=row.title}
            else {
                let id=String(row.id.dropFirst("archive.".count))
                var r=withActions(item(row.id,height:52),[("unarchive."+id,"Unarchive",""),("delete."+id,"","trash")])!
                if let record=session.records("archived").first(where:{$0["id"]?.settingsText == id}),let t=record["archivedAt"]?.doubleValue {
                    let days=max(0,Int((Date().timeIntervalSince1970-t)/86400));let age=days<7 ? "\(days) days ago":days<28 ? "\(max(1,days/7)) weeks ago":"\(max(1,days/30)) months ago"
                    let device=session.records("devices").first{$0["id"] == record["deviceID"]}?["name"]?.settingsText ?? "Device"
                    r.detail="Archived "+age+" · "+device
                    if record["deviceID"]?.settingsText != "mac"{r.visual.cardArt=session.records("devices").first{$0["id"] == record["deviceID"]}?["online"] == true ? "status.green":"status.orange"}
                };pending.append(r)
            }
        };if !pending.isEmpty{section(current,pending);if let h=result.lastIndex(where:{$0.kind == .heading}){result[h].detail="\(pending.count) \(pending.count == 1 ? "chat":"chats")"}}
        if let old=get("info.No archived chats"){var empty=plain(old.id,session.records("archived").isEmpty ? "No Archived Chats":"No Results",style:.empty,height:180);empty.visual.symbol=session.records("archived").isEmpty ? "archivebox":"magnifyingglass";section(nil,[empty])}
        if has("clear.archived"){var r=get("clear.archived")!;r.title="";r.visual.buttonTitle="Delete All…";r.visual.height=20;r.visual.footer=true;section(nil,[r],gap:10)}
        if has("load.archived"){section(nil,[get("load.archived")])}
    }
    private mutating func scopedDevice(){
        let device=session.records("devices").first{$0["id"]?.settingsText == session.device}
        section(nil,[tile(item("device","Device",""),device?["symbol"]?.settingsText ?? "laptopcomputer","")])
        if var warning=get("info.Device is offline"){warning.visual.symbol="exclamationmark.triangle.fill";warning.tint = .systemOrange;section(nil,[warning])}
    }
    private mutating func storage(){
        if session.pane == "storage/cleanup" {
            let saved=session.draft("m9.cleanup.selection",fallback:"o1,o2,o3"),available=Set(session.records("cleanup").compactMap{$0["id"]?.stringValue})
            session.selected=Set(saved.split(separator:",").map(String.init)).intersection(available)
            let rows=session.records("cleanup").map{chat -> SettingsRow? in let id=chat["id"]?.settingsText ?? "";var r=item("select."+id,chat["title"]?.settingsText ?? "Chat",chat["age"]?.settingsText ?? "",height:52);r?.visual.cardArt="checkbox";r?.visual.rightText=chat["size"]?.settingsText ?? "";r?.value = .bool(session.selected.contains(id));r?.perform={ [session] value in if value == true{session.selected.insert(id)}else{session.selected.remove(id)};session.setDraft("m9.cleanup.selection",session.selected.sorted().joined(separator:","));session.changed() };return r};section("Chats not opened in 3 weeks",rows)
            var remove=item("cleanup.selected","","");remove?.visual.buttonTitle="Delete \(session.selected.count) \(session.selected.count == 1 ? "Chat":"Chats")…";remove?.visual.height=20;remove?.visual.footer=true;remove?.enabled = !session.selected.isEmpty && !session.offline;remove?.perform={ [session] _ in let count=session.selected.count;guard count>0 else{return};session.ask(title:"Delete \(count) chats?",message:"They are removed from this prototype with their subagents. No user files are changed.",confirm:"Delete",destructive:true,operation:session.operation(.demo,["action":"cleanup","ids":.array(session.selected.sorted().map(JSONValue.string))])) };section(nil,[remove],gap:10);return
        }
        if session.pane == "storage/worktrees" {
            var keep=item("demo.global.keepWorktrees","Keep the newest","");keep?.visual.style = .counter;section(nil,[keep])
            let rows=session.records("worktrees").map{tree -> SettingsRow? in let id=tree["id"]?.settingsText ?? "";var r=withActions(item("worktree."+id,tree["branch"]?.settingsText ?? "Worktree",(tree["project"]?.settingsText ?? "")+" · "+(tree["age"]?.settingsText ?? ""),height:52),[("worktree.remove."+id,"Remove…","")]);r?.visual.symbol="arrow.triangle.branch";r?.visual.rightText=tree["size"]?.settingsText ?? "";return r};section("Worktrees on This Mac",rows);return
        }
        scopedDevice()
        let parts=session.snapshots["storage"]?["parts"]?.arrayValue ?? [],total=parts.reduce(0){$0+($1["mb"]?.doubleValue ?? 0)},amount=total>=1000 ? String(format:"%.1f GB",total/1000):String(format:"%.1f MB",total),device=session.records("devices").first{$0["id"]?.settingsText == session.device}?["name"]?.settingsText ?? "This Mac"
        var usage=plain("m9.storage.usage",amount+" used on "+device,style:.storage,height:100);usage.value=session.snapshots["storage"] ?? .null
        section("Usage",[usage],actions:[get("storage.refresh")].compactMap{$0})
        section(nil,[item("go.storage/cleanup","Clean up old chats",""),item("go.storage/worktrees","Worktrees",""),item("go.archived","Archived chats",""),item("logs.clear","Logs and caches","")],gap:10)
        for i in result.indices {switch result[i].id {case "go.storage/cleanup":result[i].visual.buttonTitle="Review…";case "go.storage/worktrees","go.archived":result[i].visual.buttonTitle="Manage…";case "logs.clear":result[i].visual.buttonTitle="Clear…";result[i].destructive=false;default:break}}
    }
    private mutating func configuration(){
        scopedDevice()
        var open=plain("m9.configuration.open","Open config.toml");open.kind = .button;open.visual.symbol="arrow.up.forward.square";open.enabled = !session.offline
        section("Codex",[item("demo.devices."+session.device+".approval","Approval policy",""),item("demo.devices."+session.device+".sandbox","Sandbox",""),item("demo.devices."+session.device+".web","Web search",""),item("demo.devices."+session.device+".detail","Output detail",""),item("demo.devices."+session.device+".summary","Reasoning summary","")],actions:[action("config.open","Open config.toml",symbol:"arrow.up.forward.square") ?? open])
        var levels=plain("m9.configuration.efforts","Reasoning levels in the composer");levels.kind = .choice
        let supported=["low","medium","high","xhigh","ultra"]
        levels.choices=supported.map{($0,$0.capitalized)};let selected=session.snapshots["demo"]?["devices"]?[session.device]?["efforts"]?.arrayValue?.compactMap(\.stringValue) ?? []
        levels.visual.rightText="\(selected.count) selected";levels.value = .string(selected.joined(separator:","));levels.visual.cardArt="multi";levels.visual.menuActions=source.filter{$0.id.hasPrefix("efforts.")};levels.enabled = !session.offline
        for i in result.indices where result[i].id.hasSuffix(".approval"){result[i].choices=result[i].choices.map{($0.0,$0.0 == "never" ? "Never Ask":$0.1)}}
        section("Models",[item("demo.devices."+session.device+".model","Default model",""),item("demo.devices."+session.device+".effort","Default reasoning",""),levels])
        section("Workspace",[item("demo.devices."+session.device+".installDependencies","Install dependencies automatically","")])
    }
    private mutating func personalization(){
        if session.pane == "personalization/rules" {
            let rules=session.records("rules").map{rule -> SettingsRow? in let id=rule["id"]?.settingsText ?? "";guard var r=get("draft.rule."+id)else{return nil};r.title="Pattern";r.detail="";r.visual.style = .rule;r.visual.height=42;r.visual.actions=[get("rule."+id),action("rule.remove."+id,"",symbol:"trash")].compactMap{$0};r.visual.symbol=rule["rule"] == "deny" ? "xmark.octagon.fill":rule["rule"] == "ask" ? "hand.raised.fill":"checkmark.circle";r.tint=rule["rule"] == "deny" ? .systemRed:rule["rule"] == "ask" ? .systemOrange:.systemGreen;r.perform={ [session] value in session.setDraft("rule."+id,value.settingsText);session.dispatch(session.operation(.demo,["action":"record.update","collection":"rules","id":.string(id),"field":"pattern","value":value])) };return r}
            section("Commands on \(session.records("devices").first{$0["id"]?.settingsText == session.device}?["name"]?.settingsText ?? "This Mac")",rules.isEmpty ? [plain("m9.rules.empty","No rules yet","Codex follows the approval policy for every command.")]:rules)
            var add=plain("m9.rules.add","");add.kind = .button;add.visual.buttonTitle="Add Rule";add.visual.height=32;add.visual.footer=true;add.perform={ [session] _ in session.dispatch(session.operation(.demo,["action":"sheet.addRule","fields":["pattern":"npm run *","rule":"ask"]])) };section(nil,[add],gap:10);return
        }
        if session.pane == "personalization/agents" {
            var editor=item("draft.agents","","",height:320);editor?.visual.cardArt="instructions"
            let saved=session.snapshots["demo"]?["devices"]?[session.device]?["agents"]?.settingsText ?? "",draft=session.draft("agents",fallback:saved)
            var save=item("agents.save","Save","");save?.enabled=draft != saved && !session.offline;save?.visual.cardArt="prominent"
            var revert=item("agents.revert","Revert","");revert?.enabled=draft != saved
            section("~/.codex/AGENTS.md on \(session.records("devices").first{$0["id"]?.settingsText == session.device}?["name"]?.settingsText ?? "This Mac")",[editor])
            var buttons=plain("m9.agents.buttons","",height:32);buttons.visual.actions=[revert,save].compactMap{$0};buttons.visual.footer=true;section(nil,[buttons],gap:10);return
        }
        scopedDevice()
        section("Codex memory",[item("demo.devices."+session.device+".memories","Use memories",""),item("demo.devices."+session.device+".toolMemories","Include chats that used tools",""),item("memories.clear","Delete memories","",height:40)])
        if let i=result.firstIndex(where:{$0.id == "memories.clear"}){result[i].visual.buttonTitle="Delete…"}
        var rules=item("go.personalization/rules","Custom rules","")!;rules.visual.height=36;rules.visual.rightText="\(session.records("rules").count) rules";rules.visual.chevron=true;rules.visual.buttonTitle=""
        var agents=item("go.personalization/agents","AGENTS.md","")!;agents.visual.height=36;agents.visual.chevron=true;agents.visual.buttonTitle=""
        section("Permissions",[rules]);section("Custom instructions",[agents])
    }
    private mutating func usage(){
        section(nil,[segmented("demo.global.usageTab")])
        if value("usageTab") == "analytics" {genericAnalytics();return}
        var plan=plain("m9.usage.plan",value("plan").settingsText,height:46);plan.visual.symbol="leaf.fill";plan.visual.tile="#55b990";plan.visual.tileSize=26;plan.visual.actions=[action("link.https://chatgpt.com/#settings/Subscription","Manage Plan…")].compactMap{$0};section("Your plan",[plan])
        var meters:[SettingsRow]=[]
        for (id,title,detail) in [("Usageprimary","5-hour limit","Resets in 2 h 14 min"),("Usagesecondary","Weekly limit","Resets in 5 days 18 h")] {
            if var r=get(id){r.title=title;r.detail=detail;r.visual.style = .meter;r.visual.height=67;meters.append(r)}
        }
        var ultra=plain("m9.usage.ultra","Ultra reasoning","Resets in 5 days 18 h",style:.meter,height:67);ultra.value = .number(0.14);ultra.tint = .systemOrange;meters.append(ultra);section("Plan limits",meters)
        var chart=plain("m9.usage.recent","40%","used this week",style:.usageChart,height:170);chart.value=[22,35,18,40,52,12,8,30,46,61,38,27,55,33];section("Recent usage",[chart])
    }
    private mutating func genericAnalytics(){
        for (title,_) in SettingsDemoVisuals.analytics {var rows=source.filter{$0.id.hasPrefix(title)};for i in rows.indices{rows[i].visual.style = .meter;rows[i].visual.height=52};section(title,rows)}
    }
    private mutating func data(){
        if session.pane == "data/links" {
            let rows=session.records("links").map{link -> SettingsRow? in let id=link["id"]?.settingsText ?? "";var r=withActions(get("share."+id),[("share.copy."+id,"Copy Link",""),("share.delete."+id,"","trash")]);r?.visual.symbol="link";return r}
            if rows.isEmpty{var empty=plain("m9.links.empty","No Shared Links",style:.empty,height:220);empty.visual.symbol="link";section(nil,[empty])}else{section("Links you shared",rows)};return
        }
        var improve=item("demo.global.improveModel","Improve the model for everyone","Managed by Daybreak Access",height:52)!
        improve.visual.symbol="";improve.visual.cardArt="locked"
        var archived=item("go.archived","Archived chats","\(session.records("archived").count) archived",height:52)
        if archived == nil{var route=plain("go.archived","Archived chats","\(session.records("archived").count) archived",height:52);route.kind = .button;route.perform={ [session] _ in session.go("archived") };archived=route}
        section(nil,[improve,right(item("go.data/links","Shared links","\(session.records("links").count) links",height:52),""),archived])
        section(nil,[item("archive.all","Archive all chats",""),item("chats.delete","Delete all chats",""),item("export","Export data",session.exportProgress == .preparing ? "Preparing…":"")],gap:10)
        for i in result.indices {switch result[i].id {case "go.data/links","go.archived":result[i].visual.buttonTitle="Manage…";case "archive.all":result[i].visual.buttonTitle="Archive All…";case "chats.delete":result[i].visual.buttonTitle="Delete All…";case "export":result[i].visual.buttonTitle=session.exportProgress == .preparing ? "Preparing…":"Export…";default:break}}
    }
    private mutating func plugins(){
        if session.pane.hasPrefix("plugins/detail/"){pluginDetail();return}
        let tab=session.pane == "plugins/mcp" ? "mcp":session.pane == "plugins/skills" ? "skills":value("pluginTab").settingsText
        var top=plain("m9.plugins.toolbar","",style:.toolbar,height:44);top.visual.cardArt="pluginToolbar"
        var segments=plain("m9.plugins.tabs","");segments.kind = .choice;segments.visual.style = .segmented;segments.value = .string(tab);segments.choices=[("plugins","Plugins \(session.snapshots["plugins"]?["marketplaces"]?.arrayValue?.reduce(0){$0+($1["plugins"]?.arrayValue?.count ?? 0)} ?? 0)"),("mcp","MCP Servers \(session.records("mcp").count)"),("skills","Skills \((session.records("skills").first?["skills"]?.arrayValue?.count ?? 0))")];segments.perform={ [session] v in session.dispatch(session.operation(.demo,["action":"set","path":"global.pluginTab","value":v])) }
        var search=get("listQuery")!;search.title="Search";top.visual.actions=[segments,search];section(nil,[top])
        var entries:[SettingsRow]=[]
        switch tab {
        case "mcp":
            for server in session.records("mcp") {let name=server["name"]?.settingsText ?? "";guard var r=item("mcp."+name,height:52)else{continue};r.kind = .info;r.visual.symbol="server.rack";r.visual.tile="#29292c";r.detail=(server["command"]?.settingsText ?? server["url"]?.settingsText ?? "")+" · "+(server["enabled"] == true ? server["runtimeStatus"]?.settingsText ?? server["authStatus"]?.settingsText ?? "Not reported":"Off");r.visual.actions=[action("mcp.login."+name,"Sign In…"),get("mcp."+name)].compactMap{$0};entries.append(r)}
        case "skills":
            for r in source where r.id.hasPrefix("skill.") && r.kind == .toggle {var v=r;v.kind = .info;v.visual.symbol="wand.and.stars";v.visual.tile="#ffcf5c";v.visual.height=52;v.detail=r.detail.components(separatedBy:"\n").first!+" · ~/.codex/skills";v.visual.actions=[r];entries.append(v)}
        default:
            let page=SettingsPluginProjection.page(catalog:session.snapshots["plugins"] ?? .null,query:session.listQuery,requestedPage:session.pluginPage)
            for section in page.sections {for entry in section.entries {let token=session.pluginToken(entry.id),p=entry.plugin,id=p["id"]?.settingsText ?? "",name=p["interface"]?["displayName"]?.settingsText ?? p["name"]?.settingsText ?? "Plugin";guard var r=item("plugin.open."+token,name,p["interface"]?["shortDescription"]?.settingsText ?? "",height:52)else{continue};r.kind = .info;r.visual.actions=[get("plugin.enabled."+token)].compactMap{$0};r.visual.chevron=true;let style=Self.pluginStyle(id);r.visual.symbol=style.0;r.visual.tile=style.1;entries.append(r)}}
        }
        var browse=plain("m9.plugins.browse","Browse Directory…");browse.kind = .button
        var add=plain("m9.plugins.add","Add");add.kind = .choice;add.visual.cardArt="prominent";add.choices=[("plugins","Add Plugin…"),("mcp","Add MCP Server…"),("skills","Add Skill…")];add.perform={ [session] v in if v == "mcp"{session.openSheet(.addMCP)}else{session.dispatch(session.operation(.demo,["action":"set","path":"global.pluginTab","value":v]))} }
        if entries.isEmpty {var empty=plain("m9.plugins.empty","No Results",style:.empty,height:180);empty.visual.symbol="puzzlepiece.extension.fill";section(nil,[empty])}
        else{section(tab == "mcp" ? "MCP servers on This Mac":tab == "skills" ? "Skills on This Mac":"Installed plugins",entries,actions:[browse,add],headerHeight:30.5)}
    }
    private mutating func pluginDetail(){
        let token=String(session.pane.dropFirst("plugins/detail/".count))
        guard let entry=session.pluginEntries[token]else{generic();return}
        let p=entry.plugin,name=p["interface"]?["displayName"]?.settingsText ?? p["name"]?.settingsText ?? "Plugin",style=Self.pluginStyle(p["id"]?.settingsText ?? "")
        var intro=plain("m9.plugin.intro",name,(p["interface"]?["shortDescription"]?.settingsText ?? "")+". Version 1.4 · Synthetic publisher.",height:68);intro.visual.symbol=style.0;intro.visual.tile=style.1;intro.visual.tileSize=48
        section(nil,[intro,get("plugin.enabled."+token)])
        section("Tools",source.filter{$0.id.hasPrefix("tool.")})
        var remove=get("plugin.remove."+token);remove?.title="";remove?.detail="";remove?.visual.buttonTitle="Uninstall…";remove?.visual.height=20;remove?.visual.footer=true;section(nil,[remove],gap:10)
    }
    static func pluginStyle(_ id:String)->(String,String){switch id {case "design":("paintbrush.pointed.fill","#c34cff");case "git":("arrow.triangle.branch","#29292c");case "drive":("externaldrive.fill","#31c465");case "calendar":("calendar","#f65d55");case "contacts":("person.crop.circle","#8e8e93");case "mail":("envelope.fill","#1686ff");case "style":("pencil","#d8d8db");default:("chart.bar.fill","#39b5ed")}}
    private mutating func computer(){
        func permission(_ id:String,_ title:String,_ symbol:String,_ on:Bool)->SettingsRow{var r=plain(id,title,on ? "Allowed":"Not Allowed",height:52);r.visual.symbol=symbol;r.visual.cardArt=on ? "status.green":"status.orange";return r}
        var screen=permission("m9.computer.screen","Screen & System Audio Recording","rectangle.dashed.badge.record",value("cuScreen") == true)
        var settings=plain("m9.computer.open","Open System Settings…");settings.kind = .button;settings.perform={ [session] _ in session.dispatch(session.operation(.demo,["action":"set","path":"global.cuScreen","value":true])) };if value("cuScreen") != true{screen.visual.actions=[settings]}
        section("macOS permissions",[permission("m9.computer.ax","Accessibility","accessibility",value("cuAccessibility") == true),screen])
        var ext=plain("m9.computer.extension","Browser extension",value("cuExtension") == true ? "Installed":"Not installed",height:52);ext.visual.symbol="globe";ext.visual.tile="#1686ff";ext.visual.tileSize=26;ext.visual.cardArt=value("cuExtension") == true ? "status.green":"status.red"
        var install=plain("m9.computer.install","Install…");install.kind = .button;install.perform={ [session] _ in session.startDemoFeedback(key:"demo.extension.install",seconds:1.4,operation:session.operation(.demo,["action":"set","path":"global.cuExtension","value":true])) };if value("cuExtension") != true{install.enabled = !session.busy.contains("demo.extension.install");ext.visual.actions=[install]};if session.busy.contains("demo.extension.install"){ext.detail="Installing…";ext.visual.cardArt=""}else if value("cuExtension") == true{ext.detail="Installed in your default browser"}
        section("Control",[tile(item("demo.global.cuAnyApp","Any app","",height:46),"cursorarrow.rays","#33b7b7"),ext,tile(item("demo.global.cuWhileLocked","Use while locked","",height:46),"lock.fill","#8e8e93")])
        let apps=session.records("apps").map{a -> SettingsRow in let id=a["id"]?.settingsText ?? "",name=a["name"]?.settingsText ?? "App";var r=plain("m9.computer.app."+id,name,height:46);r.visual.symbol=id == "finder" ? "face.smiling":id == "terminal" ? "terminal":id == "preview" ? "photo":id == "textedit" ? "doc.text":id == "notes" ? "note.text":"hammer.fill";r.visual.tile=["finder":"#6fc3ff","terminal":"#4a4a4f","preview":"#8fd0ff","xcode":"#5fb0ff","textedit":"#f5f5f7","notes":"#ffe27a"][id] ?? "#8e8e93";r.visual.tileSize=26;var remove=action("app.remove."+id,"",symbol:"trash");remove?.destructive=true;r.visual.actions=[remove].compactMap{$0};return r}
        section("Always allowed",apps.isEmpty ? [plain("m9.computer.noApps","No apps","Codex asks before using any app.")]:apps);var add=item("app.add","Add App…","");add?.enabled=session.records("apps").count<6;section(nil,[add],gap:10)
    }
    private mutating func appshots(){
        var preview=get("appshots.preview")!;preview.visual.style = .illustration;preview.visual.height=170;section(nil,[preview])
        var hotkey=item("demo.global.shotHotkey","Hotkey","")!;hotkey.choices=hotkey.choices.map{($0.0,$0.0 == "shift" ? "⇧ + ⇧":$0.1)}
        section(nil,[hotkey,item("demo.global.shotDestination","Send appshots to",""),item("demo.global.shotSound","Play sound","")],gap:10)
    }
    private mutating func browser(){
        if session.pane == "browser/history" {
            let rows=session.records("history").map{page -> SettingsRow? in let id=page["id"]?.settingsText ?? "";var r=withActions(item("history."+id,height:52),[("history.remove."+id,"","xmark")]);r?.visual.symbol=String((page["url"]?.settingsText ?? "").prefix(1)).uppercased();r?.visual.tile="#8e8e93";r?.visual.tileSize=26;r?.visual.cardArt="site";return r}
            if rows.isEmpty{var empty=plain("m9.history.empty","No History",style:.empty,height:220);empty.visual.symbol="clock";section(nil,[empty])}else{section("Pages visited in the built-in browser",rows,actions:[action("history.clear","Clear History…")].compactMap{$0})};return
        }
        section(nil,[tile(item("demo.global.browserOn","Built-in browser","",height:46),"globe","#1686ff")])
        let history=item("go.browser/history","Browsing history","\(session.records("history").count) pages",height:52)
        var clear=plain("m9.browser.clear","Browsing data");clear.kind = .button;clear.visual.buttonTitle="Clear…";clear.perform={ [session] _ in session.ask(title:"Clear browsing data?",message:"Clear the prototype browsing history?",confirm:"Clear",destructive:true,operation:session.operation(.demo,["action":"clear","collection":"history"])) }
        var importButton=plain("m9.browser.import","Import…");importButton.kind = .button
        section("General",[item("demo.global.webLinks","Open web links in",""),item("demo.global.localLinks","Open local URLs in",""),item("demo.global.showFullURL","Show full URL",""),item("demo.global.annotations","Screenshots with comments",""),history,clear],actions:[importButton])
        for i in result.indices{if ["demo.global.webLinks","demo.global.localLinks"].contains(result[i].id){result[i].choices=result[i].choices.map{($0.0,$0.0 == "app" ? "Organic Codex":$0.1)}};if result[i].id == "demo.global.annotations"{result[i].choices=result[i].choices.map{($0.0,$0.0 == "always" ? "Always Include":$0.1)}};if result[i].id == "go.browser/history"{result[i].visual.buttonTitle="Manage…"}}
        var sites:[SettingsRow?]=[item("demo.global.otherSites","Other sites","")]
        for site in session.records("sites") {let id=site["id"]?.settingsText ?? "",host=site["host"]?.settingsText ?? "Site";var row=plain("m9.browser.site."+id,host,height:46.25);row.visual.symbol=String(host.prefix(1)).uppercased();row.visual.tile="#8e8e93";row.visual.cardArt="site";row.kind = .choice;row.visual.tileSize=26;row.visual.menuActions=["browse","download","upload"].compactMap{get("site."+id+$0)};row.visual.rightText=["browse","download","upload"].map{(site[$0]?.settingsText ?? "ask").capitalized}.joined(separator:" · ")
            var trash=plain("m9.browser.remove."+id,"");trash.kind = .button;trash.destructive=true;trash.visual.symbol="trash";trash.perform={ [session] _ in session.dispatch(session.operation(.demo,["action":"remove","collection":"sites","id":.string(id)])) };row.visual.actions=[trash];sites.append(row)}
        section("Site permissions",sites);section(nil,[item("sheet.addSite","Add Site…","")],gap:10)
        if value("browserOn") != true{for i in result.indices where result[i].id != "demo.global.browserOn"{result[i].enabled=false;for j in result[i].visual.actions.indices{result[i].visual.actions[j].enabled=false};for j in result[i].visual.menuActions.indices{result[i].visual.menuActions[j].enabled=false}}}
    }
    private mutating func connections(){
        section(nil,[segmented("demo.global.connectionsTab")])
        if value("connectionsTab").settingsText == "devices" {
            let devices=session.records("devices").map{d -> SettingsRow? in let id=d["id"]?.settingsText ?? "",local=d["local"] == true,on=d["online"] == true;var r=item("connection."+id,d["name"]?.settingsText ?? "Device",on ? "Connected":"Offline · Last seen 2 hours ago",height:53);r?.visual.symbol=d["symbol"]?.settingsText ?? "laptopcomputer";r?.visual.tile=on ? "#30d158":"#8e8e93";r?.visual.cardArt=on ? "status.green":"status.orange";if !local{r?.visual.actions=[action("device."+id,on ? "Disconnect":"Connect")].compactMap{$0}};return r};section("Devices",devices);return
        }
        if value("connectionsTab").settingsText == "ssh" {
            let hosts=session.records("ssh").map{host -> SettingsRow? in let id=host["id"]?.settingsText ?? "";var r=withActions(item("ssh."+id,(host["user"]?.settingsText ?? "")+"@"+(host["host"]?.settingsText ?? ""),"Port "+(host["port"]?.settingsText ?? "22")+" · "+(host["status"]?.settingsText ?? "Not tested").replacingOccurrences(of:" (prototype)",with:""),height:53),[("ssh.test."+id,"Test",""),("ssh.remove."+id,"","trash")]);r?.visual.symbol="terminal";r?.visual.tile="#29292c";return r};section("SSH hosts",hosts.isEmpty ? [plain("m9.ssh.empty","No SSH hosts","Add a host to run Codex on it.")]:hosts);section(nil,[item("sheet.ssh","Add Host…","")],gap:10);return
        }
        var rows:[SettingsRow?]=[item("demo.global.allowConnections","Allow connections","")]
        for c in session.records("controllers") {let id=c["id"]?.settingsText ?? "";var r=withActions(item("controller."+id,height:52),[("controller.revoke."+id,"Revoke Access…","")]);r?.visual.symbol=id == "win" ? "pc":"iphone";if r?.visual.actions.isEmpty == false{r?.visual.actions[0].destructive=false;r?.visual.actions[0].enabled = value("allowConnections") == true};rows.append(r)}
        var refresh=plain("m9.connections.refresh","");refresh.kind = .button;refresh.visual.symbol="arrow.clockwise";refresh.visual.cardArt="iconPlate";refresh.perform={ [session] _ in Task{await session.loadNow()} }
        var pair=action("sheet.pair","Add…");pair?.enabled=value("allowConnections") == true
        section("Devices that can control this Mac",rows,actions:[refresh,pair].compactMap{$0})
        section("Other settings",[tile(item("demo.global.keepAwake","Keep this Mac awake",""),"sun.max","")])
    }
}
