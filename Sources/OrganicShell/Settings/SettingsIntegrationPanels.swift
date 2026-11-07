import AppKit

@MainActor extension SettingsPanelBuilder {
    mutating func plugins() {
        let s=session;heading(NativeSettingsCatalog.title(s.pane));devicePicker()
        if s.pane == "plugins/skills" || (demo && s.pane == "plugins" && sample("pluginTab") == "skills") {skills();return}
        if s.pane == "plugins/mcp" || (demo && s.pane == "plugins" && sample("pluginTab") == "mcp") {mcp();return}
        let catalog=s.snapshots["plugins"] ?? [:]
        if s.pane.hasPrefix("plugins/detail/") {
            let token=String(s.pane.dropFirst("plugins/detail/".count))
            guard let p=s.pluginEntries[token] else {info("Plugin unavailable","This catalog entry is no longer available. Refresh the directory.");route("plugins","Plugins");return}
            plugin(p.plugin,market:p.marketplace,id:token,detail:true);return
        }
        route("plugins/skills","Skills");route("plugins/mcp","MCP Servers");filter("Search plugins")
        button("plugins.refresh","Refresh") {Task{await s.loadNow()}}
        let page=SettingsPluginProjection.page(catalog:catalog,query:s.listQuery,requestedPage:s.pluginPage)
        info("Plugin directory","\(page.matchCount) matches · \(page.firstResult)–\(page.lastResult) of \(page.catalogCount)")
        for section in page.sections {
            heading(section.title,id:"market."+String(describing:section.id))
            for entry in section.entries {
                let token=s.pluginToken(entry.id);s.pluginEntries[token] = .init(plugin:entry.plugin,marketplace:section.marketplace)
                plugin(entry.plugin,market:section.marketplace,id:token,detail:false)
            }
        }
        for (i,error) in (catalog["marketplaceLoadErrors"]?.arrayValue ?? []).enumerated(){info("Marketplace unavailable",error["message"]?.settingsText ?? "The marketplace could not be loaded.",id:"market.error.\(i)")}
        for (i,app) in (s.snapshots["installation"]?["appsNeedingAuth"]?.arrayValue ?? []).enumerated(){
            if let url=app["installUrl"]?.stringValue {link("Connect "+(app["name"]?.settingsText ?? "app")+"…",url)}
            else{info("Finish connecting",app["name"]?.settingsText ?? "Connect this app through its account settings.",id:"connect.app.\(i)")}
        }
        button("plugins.previous","Previous page",enabled:page.hasPrevious){s.pluginPage=max(0,page.index-1);s.contentRevision+=1;s.changed()}
        button("plugins.next","Next page",enabled:page.hasNext){s.pluginPage=page.index+1;s.contentRevision+=1;s.changed()}
    }
    mutating func plugin(_ p:JSONValue,market:JSONValue,id:String,detail:Bool) {
        let s=session,name=p["interface"]?["displayName"]?.settingsText ?? p["name"]?.settingsText ?? "Plugin",pid=p["id"]?.settingsText ?? p["name"]?.settingsText ?? ""
        let installed=p["installed"]?.boolValue ?? (p["installState"]?.settingsText == "installed")
        let availability=p["availability"]?.settingsText.lowercased() ?? ""
        let available = !["unavailable","disabled","hidden","disabled_by_admin"].contains(availability)
        let policy=p["installPolicy"]?.settingsText.lowercased() ?? ""
        if !detail {button("plugin.open."+id,name,p["interface"]?["shortDescription"]?.settingsText ?? "") {s.go("plugins/detail/"+id)}}
        else {info(name,p["interface"]?["longDescription"]?.settingsText ?? p["interface"]?["shortDescription"]?.settingsText ?? "")}
        if installed {
            rows.append(.init(id:"plugin.enabled."+id,title:"Enabled",kind:.toggle,value:p["enabled"] ?? false,enabled:writable && (demo || (s.allowed(.pluginEnable) && p["id"]?.stringValue != nil)),perform:{ v in
                let op=s.mode == .demo ? s.operation(.demo,["action":"plugin.enable","id":.string(pid),"value":v]):s.operation(.pluginEnable,["pluginId":.string(pid),"enabled":v]);s.dispatch(op)
            }))
            command("plugin.remove."+id,"Uninstall",kind:demo ? .demo:.pluginUninstall,payload:demo ? ["action":"plugin.remove","id":.string(pid)]:["pluginId":.string(pid)],destructive:true,confirm:"Uninstall \(name) from the selected backend?")
            if !demo,p["id"]?.stringValue == nil {rows[rows.count-1].enabled=false}
        } else {
            var args:[String:JSONValue]=["pluginName":p["name"] ?? .string(pid)]
            if let path=market["path"] {args["marketplacePath"]=path}else if let remote=market["name"]{args["remoteMarketplaceName"]=remote}
            command("plugin.install."+id,"Install",kind:.pluginInstall,payload:.object(args),confirm:"Install this plugin and its declared tools and skills? Account connections may need a separate sign-in.");rows[rows.count-1].enabled = s.allowed(.pluginInstall) && available && !["notavailable","not_available","blocked","adminonly"].contains(policy)
        }
        if detail {
            info("Availability",p["availability"]?.settingsText ?? "Not reported");info("Install policy",p["installPolicy"]?.settingsText ?? "Not reported")
            for (i,t) in (p["tools"]?.arrayValue ?? []).enumerated() {
                let title=t.stringValue ?? t["name"]?.settingsText ?? "Tool \(i+1)"
                if demo {rows.append(.init(id:"tool.\(id).\(i)",title:title,kind:.toggle,value:p["toolEnabled"]?[title] ?? true,enabled:writable && installed && p["enabled"] == true,perform:{ v in s.dispatch(s.operation(.demo,["action":"plugin.tool","id":.string(pid),"tool":.string(title),"value":v])) }))}
                else{info(title,t["description"]?.settingsText ?? "")}
            }
        }
    }
    mutating func skills() {
        filter("Search skills");let s=session
        button("skills.refresh","Refresh") {Task{await s.loadNow()}}
        // The window's folder chooser supplies the path (product: NSOpenPanel "Install Skill"); the bare operation has none.
        if !demo {button("skills.install","Install skill folder…","Choose a folder containing SKILL.md on this Mac.",enabled:s.allowed(.skillInstall,localFile:true)) {s.onApplicationAction?("chooseSkillFolder")}}
        var count=0
        for (i,group) in s.records("skills").enumerated() {
            for error in group["errors"]?.arrayValue ?? [] {info("Skill discovery error",error["message"]?.settingsText ?? error.settingsText,id:"skill.error.\(i).\(count)");count+=1}
            for (skillIndex,skill) in (group["skills"]?.arrayValue ?? []).enumerated() where matches((skill["name"]?.settingsText ?? "")+" "+(skill["shortDescription"]?.settingsText ?? "")) {
                let path=skill["path"]?.settingsText ?? "",name=skill["name"]?.settingsText ?? "Skill";count+=1
                rows.append(.init(id:"skill.\(i).\(skillIndex)."+path,title:name,detail:(skill["shortDescription"]?.settingsText ?? "")+"\n"+path,kind:.toggle,value:skill["enabled"] ?? false,enabled:writable && (demo || s.allowed(.skillWrite)),perform:{ v in s.dispatch(s.mode == .demo ? s.operation(.demo,["action":"skill.enable","path":.string(path),"enabled":v]):s.operation(.skillWrite,["path":.string(path),"enabled":v])) }))
            }
        }
        if count == 0 {info("No skills","No matching skills were reported.")}
    }
    mutating func mcp() {
        filter("Search MCP servers");let s=session
        button("mcp.refresh","Refresh") {Task{await s.loadNow()}}
        sheet(.addMCP,"Add server…",enabled:demo || s.allowed(.mcpWrite))
        if !demo {info("Stdio and environment variables","Edit these in the backend’s config.toml. HTTP servers can be added here.");route("configuration","Configuration")}
        for m in s.records("mcp") where matches(m["name"]?.settingsText ?? "") {
            let name=m["name"]?.settingsText ?? "Server",config=s.config("mcp_servers")?[name]
            rows.append(.init(id:"mcp."+name,title:name,detail:[m["url"],m["command"],m["runtimeStatus"],m["authStatus"]].compactMap{$0?.settingsText}.joined(separator:" · "),kind:.toggle,value:demo ? m["enabled"] ?? false:config?["enabled"] ?? .null,enabled:writable && (demo || s.allowed(.mcpWrite)),perform:{ v in s.dispatch(s.mode == .demo ? s.operation(.demo,["action":"record.update","collection":"mcp","id":.string(name),"field":"enabled","value":v]):s.operation(.mcpWrite,["name":.string(name),"values":["enabled":v]])) }))
            if !demo || m["authStatus"]?.settingsText.lowercased().contains("sign") == true {
                command("mcp.login."+name,"Sign in…",kind:demo ? .demo:.mcpLogin,payload:demo ? ["action":"record.update","collection":"mcp","id":.string(name),"field":"authStatus","value":"Signed in (prototype)"]:["name":.string(name)])
            }
            if let error=m["toolsError"]?.stringValue {info("Tool discovery error",error,id:"mcp.error."+name)}
            if let count=m["tools"]?.objectValue?.count {info("Tools",String(count),id:"mcp.tools."+name)}
        };empty("mcp","No MCP servers")
    }
    mutating func computer() {
        heading("Computer Use")
        if demo {
            info("Permissions","The indicators below are synthetic prototype values.")
            demoValue("cuAccessibility","Accessibility");demoValue("cuScreen","Screen Recording & System Audio");demoValue("cuAnyApp","Allow any app");demoValue("cuWhileLocked","Allow use while the Mac is locked")
            demoValue("cuExtension","Browser extension installed")
            heading("Always allowed apps")
            for app in session.records("apps") {let id=app["id"]?.settingsText ?? "";demoCommand("app.remove."+id,"Remove "+(app["name"]?.settingsText ?? "App"),action:"remove",payload:["collection":"apps","id":.string(id)])}
            let s=session;button("app.add","Add app…","TextEdit and Notes · prototype") {s.dispatch(s.operation(.demo,["action":"app.add"]))}
        } else {
            let cap=session.capabilities["nativeComputer"];info("Native computer capability",cap.map{$0.available ? "Available":$0.reason ?? "Unavailable"} ?? "Not reported")
            config("computer_use.default_app_access","Default app access",choices:[("allow","Allow"),("deny","Deny")])
            for grant in session.records("authorizations") {let id=grant["id"]?.settingsText ?? "";info(grant["app"]?.settingsText ?? "Application",id:"grant."+id);command("revoke."+id,"Revoke",kind:.authorizationRevoke,payload:["id":.string(id)],destructive:true,confirm:"Revoke this computer-use authorization?")}
            empty("authorizations","No authorizations")
            link("Accessibility settings…","x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            link("Screen Recording settings…","x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }
    mutating func appshots() {
        heading("Appshots","Capture context from the app you’re using.")
        rows.append(.init(id:"appshots.preview",title:"Appshot preview",detail:"Capture → attach → ask",kind:.chart,value:local("organic.simulateReduceMotion")))
        if demo {
            demoValue("shotHotkey","Shortcut",choices:[("shift","Double Shift"),("optionSpace","Option + Space"),("controlOptionA","Control + Option + A"),("off","Off")])
            demoValue("shotDestination","Send to",choices:[("auto","Automatic"),("current","Current Chat"),("new","New Chat")]);demoValue("shotSound","Play capture sound")
        } else {
            let s=session,h=s.snapshots["hotkey"]
            // Core's hotkey status is {enabled,threadId,mode,shortcut,pid,error}; there is no status text (product: Enabled/Disabled).
            info("Shortcut",h?["shortcut"]?.stringValue ?? "Control+Option+Command+S");info("Status",h?["enabled"]?.boolValue.map{$0 ? "Enabled":"Disabled"} ?? "Not loaded")
            if let error=h?["error"]?.stringValue,!error.isEmpty {info("Shortcut error",error,id:"capture.error")}
            let available=s.capabilities["captureWindow"]?.available == true || s.capabilities["captureScreen"]?.available == true
            if !available {info("Capture unavailable","The connected backend has not advertised a capture capability.")}
            let threads=s.records("threads").compactMap{t -> (String,String)? in
                guard t["archived"]?.boolValue != true,let id=t["backendThreadID"]?.stringValue else{return nil}
                return(id,t["title"]?.settingsText ?? "Chat")
            }
            let selected=s.draft("capture.thread",fallback:h?["threadId"]?.settingsText ?? "")
            let selectedMode=s.draft("capture.mode",fallback:h?["mode"]?.settingsText ?? "window")
            let validThread=threads.contains{$0.0 == selected}
            rows.append(.init(id:"capture.thread",title:"Send to",kind:.choice,value:.string(selected),choices:[("","Choose a chat")]+threads,perform:{v in s.setDraft("capture.thread",v.settingsText);s.changed()}))
            rows.append(.init(id:"capture.mode",title:"Capture",kind:.choice,value:.string(selectedMode),choices:[("window","Frontmost window"),("screen","Full display")],enabled:available,perform:{ v in s.setDraft("capture.mode",v.settingsText);s.changed() }))
            let modeAvailable=s.capabilities[selectedMode == "screen" ? "captureScreen":"captureWindow"]?.available == true
            button("capture.update",h?["enabled"]?.boolValue == true ? "Update Shortcut":"Enable Shortcut",enabled:validThread && modeAvailable && s.allowed(.hotkeyWrite)) {
                s.dispatch(s.operation(.hotkeyWrite,["enabled":true,"mode":.string(selectedMode),"threadId":.string(selected)]))
            }
            if h?["enabled"]?.boolValue == true {command("capture.disable","Disable Shortcut",kind:.hotkeyWrite,payload:["enabled":false,"mode":h?["mode"] ?? "window","threadId":h?["threadId"] ?? .null])}
            if !validThread {info("Choose a chat","The shortcut sends directly to the selected chat. Choose a loaded conversation before enabling it.")}
            link("Screen Recording settings…","x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }
    mutating func browser() {
        heading(NativeSettingsCatalog.title(session.pane))
        let s=session
        guard demo else {
            if s.pane == "browser/history" {info("Browsing history","The backend exposes open tabs below, but no browsing-history API.")}
            for key in ["browser","browserExtension"] {let cap=s.capabilities[key];info(key,cap.map{$0.available ? "Available":$0.reason ?? "Unavailable"} ?? "Not reported")}
            config("browser_use.allow_history_access","Allow history access",isBoolean:true)
            config("browser_use.default_origin_policy.access","Default origin access",choices:[("allow","Allow"),("deny","Deny")])
            heading("Open tabs")
            for (i,t) in s.records("tabs").enumerated() {info(t["title"]?.settingsText ?? "Tab",t["url"]?.settingsText ?? "",id:"tab.\(i)")};empty("tabs","No open tabs reported");return
        }
        if s.pane == "browser/history" {
            filter("Search history")
            for h in s.records("history") where matches((h["title"]?.settingsText ?? "")+" "+(h["url"]?.settingsText ?? "")) {let id=h["id"]?.settingsText ?? "";info(h["title"]?.settingsText ?? "Page",(h["url"]?.settingsText ?? "")+" · "+(h["when"]?.settingsText ?? ""),id:"history."+id);demoCommand("history.remove."+id,"Remove",action:"remove",payload:["collection":"history","id":.string(id)])}
            empty("history","No browsing history");demoCommand("history.clear","Clear browsing data…",action:"clear",payload:["collection":"history"],destructive:true,confirm:"Clear the prototype browsing history?");return
        }
        demoValue("browserOn","Use browser")
        demoValue("webLinks","Open web links in",choices:[("app","Codex"),("default","Default Browser")]);demoValue("localLinks","Open local links in",choices:[("app","Codex"),("default","Default App")]);demoValue("showFullURL","Show full URLs")
        demoValue("annotations","Page comments",choices:[("always","Always"),("ask","Ask"),("never","Never")]);route("browser/history","Browsing History")
        demoValue("otherSites","Other sites",choices:[("allow","Allow"),("ask","Ask"),("block","Block")])
        for site in s.records("sites") {let id=site["id"]?.settingsText ?? "";heading(site["host"]?.settingsText ?? "Site");for field in ["browse","download","upload"] {rows.append(.init(id:"site."+id+field,title:field.capitalized,kind:.choice,value:site[field] ?? "ask",choices:[("allow","Allow"),("ask","Ask"),("block","Block")],enabled:writable,perform:{ v in s.dispatch(s.operation(.demo,["action":"record.update","collection":"sites","id":.string(id),"field":.string(field),"value":v])) }))}}
        sheet(.addSite,"Add Site…")
    }
    mutating func scheduler() {
        heading("Scheduled Tasks");guard !demo else {info("Scheduled Tasks require Live","Connect to a backend to create or inspect scheduled tasks.");return}
        sheet(.schedule,"New scheduled task…",enabled:session.allowed(.scheduleCreate))
        let s=session
        for j in s.records("jobs") {
            let id=j["id"]?.settingsText ?? "";info(j["name"]?.settingsText ?? "Task",j["prompt"]?.settingsText ?? "",id:"job."+id)
            info("Next run",j["nextRun"]?.doubleValue.map{Date(timeIntervalSince1970:$0).formatted()} ?? j["at"]?.settingsText ?? "Not reported",id:"job.next."+id)
            rows.append(.init(id:"job.pause."+id,title:"Paused",kind:.toggle,value:.bool(j["enabled"]?.boolValue == false),enabled:s.allowed(.schedulePause),perform:{ v in s.dispatch(s.operation(.schedulePause,["id":.string(id),"paused":v])) }))
            preference("jobNotifications."+id,"Notifications on this Mac",choices:[("all","All results"),("failed","Failures only"),("off","Off")])
            rows[rows.count-1].value=s.preferences["jobNotifications."+id] == .null ? "all":s.preferences["jobNotifications."+id]
            for (i,r) in s.records("runs").filter({$0["jobId"]?.settingsText == id}).enumerated() {info(r["status"]?.settingsText ?? "Run",r["error"]?.settingsText ?? r["startedAt"]?.settingsText ?? "",id:"run."+id+".\(i)")}
        };empty("jobs","No scheduled tasks")
    }
    mutating func connections() {
        heading("Connections");let s=session
        guard demo else {
            info("Backend",s.source.endpointIdentity);info("Status",s.source.connectionStatus)
            command("reconnect","Reconnect",kind:.reconnect)
            draft("endpoint","Core address",s.source.endpointIdentity,detail:"HTTP(S) root address. Restart after saving.")
            button("endpoint.save","Save address for next launch",enabled:s.allowed(.endpointSave)) {
                let value=s.draft("endpoint",fallback:s.source.endpointIdentity)
                guard let c=URLComponents(string:value),["http","https"].contains(c.scheme ?? ""),c.host?.isEmpty == false,c.user == nil,c.password == nil,c.query == nil,c.fragment == nil,(c.path.isEmpty || c.path == "/") else{s.errorsForValidation("Use an HTTP(S) root address without credentials, path, query or fragment.");return}
                s.dispatch(s.operation(.endpointSave,["url":.string(value)]))
            }
            info("Remote connections","For SSH, forward the Core port and use its local HTTP address. Device pairing is not exposed by this backend.");return
        }
        demoValue("connectionsTab","View",choices:[("mac","This Mac"),("devices","Other Devices"),("ssh","SSH")])
        switch sample("connectionsTab").settingsText {
        case "devices":
            for d in s.records("devices") {let id=d["id"]?.settingsText ?? "";info(d["name"]?.settingsText ?? "Device",d["online"]?.boolValue == true ? "Online (prototype)":"Offline (prototype)",id:"connection."+id);demoCommand("device."+id,"Toggle connection",action:"record.update",payload:["collection":"devices","id":.string(id),"field":"online","value":.bool(d["online"]?.boolValue != true)])}
        case "ssh":
            for server in s.records("ssh") {let id=server["id"]?.settingsText ?? "";info((server["user"]?.settingsText ?? "")+"@"+(server["host"]?.settingsText ?? ""),server["status"]?.settingsText ?? "Not tested",id:"ssh."+id);demoCommand("ssh.test."+id,"Test connection",action:"record.update",payload:["collection":"ssh","id":.string(id),"field":"status","value":"Reachable (prototype)"]);demoCommand("ssh.remove."+id,"Remove",action:"remove",payload:["collection":"ssh","id":.string(id)],destructive:true)};sheet(.ssh,"Add SSH Server…")
        default:
            demoValue("allowConnections","Allow other devices to connect");demoValue("keepAwake","Keep this Mac awake for connections")
            for c in s.records("controllers") {let id=c["id"]?.settingsText ?? "";info(c["name"]?.settingsText ?? "Device",c["detail"]?.settingsText ?? "",id:"controller."+id);demoCommand("controller.revoke."+id,"Revoke access",action:"remove",payload:["collection":"controllers","id":.string(id)],destructive:true,confirm:"Revoke this prototype device’s access?")}
            sheet(.pair,"Pair a device…")
        }
    }
}
