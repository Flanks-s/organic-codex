import AppKit

@MainActor extension SettingsPanelBuilder {
    mutating func archived() {
        heading("Archived Chats");filter("Search archived chats")
        let s=session,projects=s.records("projects"),devices=s.records("devices")
        rows.append(.init(id:"archive.device",title:"Device",kind:.choice,value:.string(s.draft("archiveDevice",fallback:"all")),choices:[("all","All Devices")]+devices.map{($0["id"]?.settingsText ?? "",$0["name"]?.settingsText ?? "Device")},perform:{v in s.setDraft("archiveDevice",v.settingsText);s.changed()}))
        rows.append(.init(id:"project.filter",title:"Project",kind:.choice,value:.string(s.draft("project",fallback:"all")),choices:[("all","All Projects"),("none","No Project")]+projects.map{($0["id"]?.settingsText ?? "",$0["name"]?.settingsText ?? "Project")},perform:{ v in s.setDraft("project",v.settingsText);s.changed() }))
        let project=s.draft("project",fallback:"all"),device=s.draft("archiveDevice",fallback:"all")
        let chats=s.records("archived").filter { c in
            (device == "all" || c["deviceID"]?.settingsText == device) && (project == "all" || (c["projectID"]?.stringValue ?? "none") == project) && matches(c["title"]?.settingsText ?? "")
        }.sorted { ($0["archivedAt"]?.doubleValue ?? 0)>($1["archivedAt"]?.doubleValue ?? 0) }
        let groups=Dictionary(grouping:chats){$0["projectID"]?.stringValue ?? "none"}
        var order:[String]=[];for c in chats{let key=c["projectID"]?.stringValue ?? "none";if !order.contains(key){order.append(key)}}
        for key in order {
            let name=projects.first{$0["id"]?.settingsText == key}?["name"]?.settingsText ?? "No Project"
            heading(name,id:"project."+key)
            for c in groups[key] ?? [] {
                let id=c["id"]?.settingsText ?? "",deviceName=devices.first{$0["id"] == c["deviceID"]}?["name"]?.settingsText ?? "Device"
                let relative=c["archivedAt"]?.doubleValue.map{Date(timeIntervalSince1970:$0).formatted(.relative(presentation:.named))} ?? "Date not reported"
                info(c["title"]?.settingsText ?? "Untitled","Archived "+relative+" · "+deviceName,id:"archive."+id)
                command("unarchive."+id,"Unarchive",kind:.unarchive,payload:["id":.string(id),"deviceID":c["deviceID"] ?? .null])
                if demo {demoCommand("delete."+id,"Delete permanently",action:"remove",payload:["collection":"archived","id":.string(id)],destructive:true,confirm:"Delete this archived prototype chat? This cannot be undone.")}
            }
        }
        if chats.isEmpty {info("No archived chats","Try a different project, device or search.")}
        if !demo {command("load.archived","Load more",kind:.loadArchived,payload:["cursor":s.snapshots["archived"]?["nextCursor"] ?? .null])}
        else if !s.records("archived").isEmpty {demoCommand("clear.archived","Delete all archived chats",action:"clear",payload:["collection":"archived","ids":.array(s.records("archived").compactMap{$0["id"]?.stringValue}.map(JSONValue.string))],destructive:true,confirm:"Delete all archived prototype chats? This cannot be undone.")}
    }
    mutating func storage() {
        heading(NativeSettingsCatalog.title(session.pane));devicePicker()
        guard demo else {
            let h=session.snapshots["health"]
            info("Stored sessions",h?["sessions"]?.arrayValue.map{String($0.count)} ?? h?["sessions"]?["count"]?.settingsText ?? h?["sessionCount"]?.settingsText ?? "Not reported")
            info("Event log on disk",h?["eventLog"]?["diskBytes"]?.settingsText ?? "Not reported")
            info("Event log tail",h?["eventLog"]?["tailBytes"]?.settingsText ?? "Not reported")
            route("archived","Archived Chats")
            command("local.data","Open local data folder",kind:.openLocal,payload:["target":"data"],localFile:true)
            if session.pane != "storage" { unavailable("Cleanup unavailable","This backend does not expose chat cleanup or worktree removal. No files have been removed.") }
            return
        }
        let s=session
        switch s.pane {
        case "storage/cleanup":
            info("Old chats","Choose chats to remove from this prototype.");filter("Search old chats")
            for c in s.records("cleanup") where matches(c["title"]?.settingsText ?? "") {
                let id=c["id"]?.settingsText ?? ""
                rows.append(.init(id:"select."+id,title:c["title"]?.settingsText ?? "Chat",detail:(c["size"]?.settingsText ?? "")+" · "+(c["age"]?.settingsText ?? ""),kind:.toggle,value:.bool(s.selected.contains(id)),enabled:writable,perform:{ v in if v.boolValue == true {s.selected.insert(id)}else{s.selected.remove(id)};s.changed() }))
            }
            demoCommand("cleanup.selected","Delete selected (\(s.selected.count))",action:"cleanup",payload:["ids":.array(s.selected.sorted().map{.string($0)})],destructive:true,confirm:"Delete the selected prototype chats?")
            rows[rows.count-1].enabled = writable && !s.selected.isEmpty
        case "storage/worktrees":
            demoValue("keepWorktrees","Keep newest worktrees",choices:(1...20).map{(String($0),String($0))})
            rows[rows.count-1].perform={ v in s.dispatch(s.operation(.demo,["action":"set","path":"global.keepWorktrees","value":.number(Double(v.settingsText) ?? 5)])) }
            for w in s.records("worktrees") { let id=w["id"]?.settingsText ?? "";info(w["branch"]?.settingsText ?? "Worktree",[w["project"],w["size"],w["age"]].compactMap{$0?.settingsText}.joined(separator:" · "),id:"worktree."+id);demoCommand("worktree.remove."+id,"Remove worktree",action:"remove",payload:["collection":"worktrees","id":.string(id)],destructive:true,confirm:"Remove this prototype worktree? No working copy on disk will change.") }
        default:
            let parts=s.snapshots["storage"]?["parts"]?.arrayValue ?? [],total=parts.reduce(0){$0+($1["mb"]?.doubleValue ?? 0)}
            info(String(format:"%.1f MB used",total),"On the selected prototype device")
            for p in parts { rows.append(.init(id:"storage."+(p["id"]?.settingsText ?? ""),title:p["id"]?.settingsText ?? "",detail:String(format:"%.1f MB",p["mb"]?.doubleValue ?? 0),kind:.progress,value:.number((p["mb"]?.doubleValue ?? 0)/max(1,total)))) }
            button("storage.refresh","Refresh") {Task {await s.loadNow()}}
            route("storage/cleanup","Clean Up Old Chats");route("storage/worktrees","Worktrees");route("archived","Archived Chats")
            demoCommand("logs.clear","Clear logs and caches",action:"logs",destructive:true,confirm:"Clear prototype logs and caches? No local files will be removed.")
        }
    }
    mutating func configuration() {
        heading("Configuration");devicePicker()
        if demo {
            demoValue("approval","Approval policy",device:true,choices:[("untrusted","Untrusted"),("on-request","On Request"),("never","Never")])
            demoValue("sandbox","Sandbox",device:true,choices:[("read","Read Only"),("workspace","Workspace Write"),("full","Full Access")])
            demoValue("web","Web search",device:true,choices:[("off","Off"),("cached","Cached"),("live","Live")])
            demoValue("detail","Output detail",device:true,choices:[("low","Low"),("medium","Medium"),("high","High")])
            demoValue("summary","Reasoning summary",device:true,choices:[("auto","Auto"),("concise","Concise"),("detailed","Detailed"),("none","None")])
            demoValue("model","Default model",device:true,choices:[("g61sol","GPT-6.1 Sol"),("g6astra","GPT-6 Astra"),("g6sol","GPT-6 Sol"),("g56terra","GPT-5.6 Terra")])
            let efforts=["low","medium","high","xhigh","ultra"]
            demoValue("effort","Reasoning effort",device:true,choices:efforts.map{($0,$0.capitalized)})
            for e in efforts {
                let s=session,current=sample("efforts",device:true).arrayValue?.compactMap(\.stringValue) ?? []
                rows.append(.init(id:"efforts."+e,title:e.capitalized+" available",kind:.toggle,value:.bool(current.contains(e)),enabled:writable,perform:{ v in var next=current;if v.boolValue == true {if !next.contains(e){next.append(e)}}else{next.removeAll{$0 == e}};guard !next.isEmpty else{s.notice="Keep at least one reasoning effort.";s.changed();return};s.dispatch(s.operation(.demo,["action":"set","path":.string("devices."+s.device+".efforts"),"value":.array(next.map{.string($0)})])) }))
            }
            demoValue("installDependencies","Install dependencies automatically",device:true)
        } else {
            config("approval_policy","Approval policy",choices:[("untrusted","Untrusted"),("on-request","On Request"),("never","Never")])
            config("sandbox_mode","Sandbox",choices:[("read-only","Read Only"),("workspace-write","Workspace Write"),("danger-full-access","Full Access")])
            config("web_search","Web search",choices:[("disabled","Disabled"),("cached","Cached"),("live","Live")])
            config("model_verbosity","Output detail",choices:[("low","Low"),("medium","Medium"),("high","High")])
            config("model_reasoning_summary","Reasoning summary",choices:[("auto","Auto"),("concise","Concise"),("detailed","Detailed"),("none","None")])
            let models=session.records("models"),selected=session.config("model")?.settingsText
            config("model","Default model",choices:models.map{($0["model"]?.settingsText ?? $0["id"]?.settingsText ?? "",$0["displayName"]?.settingsText ?? $0["id"]?.settingsText ?? "Model")})
            let selectedModel=models.first{($0["model"]?.settingsText ?? $0["id"]?.settingsText) == selected} ?? models.first{$0["isDefault"]?.boolValue == true}
            let levels=selectedModel?["supportedReasoningEfforts"]?.arrayValue ?? []
            config("model_reasoning_effort","Reasoning effort",choices:levels.compactMap{ e in guard let id=e["reasoningEffort"]?.stringValue else{return nil};return(id,e["description"]?.settingsText ?? id)})
            if levels.isEmpty {info("Reasoning efforts not reported","Load a model that reports supported reasoning efforts before selecting an override.");rows.firstIndex{$0.id == "config.model_reasoning_effort"}.map{rows[$0].enabled=false}}
            info("User configuration",session.configPath ?? "No user layer was reported")
            command("config.open","Open config.toml",kind:.openLocal,payload:["path":.string(session.configPath ?? "")],localFile:true)
        }
    }
    mutating func personalization() {
        heading(NativeSettingsCatalog.title(session.pane));devicePicker()
        let s=session
        guard demo else {
            if s.pane != "personalization" {info("Project instructions","AGENTS.md files and project rules are managed in the selected project. The backend exposes developer instructions below.")}
            draft("instructions","Developer instructions",s.config("developer_instructions")?.settingsText ?? "",editor:true)
            button("instructions.save","Save instructions",enabled:s.allowed(.configWrite)) {s.dispatchConfig(["developer_instructions":.string(s.draft("instructions",fallback:s.config("developer_instructions")?.settingsText ?? ""))])}
            command("instructions.open","Open user configuration",kind:.openLocal,payload:["path":.string(s.configPath ?? "")],localFile:true)
            return
        }
        if s.pane == "personalization/rules" {
            filter("Search command patterns")
            for r in s.records("rules") where matches(r["pattern"]?.settingsText ?? "") {
                let id=r["id"]?.settingsText ?? "";draft("rule."+id,"Command pattern",r["pattern"]?.settingsText ?? "");button("rule.save."+id,"Save pattern",enabled:writable) {let pattern=s.draft("rule."+id,fallback:r["pattern"]?.settingsText ?? "").trimmingCharacters(in:.whitespacesAndNewlines);guard !pattern.isEmpty else{return};s.dispatch(s.operation(.demo,["action":"record.update","collection":"rules","id":.string(id),"field":"pattern","value":.string(pattern)]))};rows.append(.init(id:"rule."+id,title:r["pattern"]?.settingsText ?? "Rule",kind:.choice,value:r["rule"] ?? "ask",choices:Self.policies,enabled:writable,perform:{ v in s.dispatch(s.operation(.demo,["action":"record.update","collection":"rules","id":.string(id),"field":"rule","value":v])) }))
                demoCommand("rule.remove."+id,"Remove rule",action:"remove",payload:["collection":"rules","id":.string(id)],destructive:true)
            };sheet(.addRule,"Add Rule…")
        } else if s.pane == "personalization/agents" {
            let fallback=sample("agents",device:true).settingsText;draft("agents","AGENTS.md",fallback,editor:true,detail:"Prototype instructions for this device")
            button("agents.save","Save",enabled:writable) {s.dispatch(s.operation(.demo,["action":"set","path":.string("devices."+s.device+".agents"),"value":.string(s.draft("agents",fallback:fallback))]))}
            button("agents.revert","Revert") {s.drafts[s.draftScope+"agents"]=nil;s.changed()}
        } else {
            demoValue("memories","Use memories",device:true);demoValue("toolMemories","Include memories from tools",device:true,enabled:sample("memories",device:true).boolValue == true)
            demoCommand("memories.clear","Delete all memories",action:"set",payload:["path":.string("devices."+s.device+".memoriesDeleted"),"value":true],destructive:true,confirm:"Delete the prototype memories for this device?")
            route("personalization/rules","Custom Rules");route("personalization/agents","AGENTS.md")
        }
    }
    mutating func usage() {
        heading("Usage & Billing")
        if demo {demoValue("usageTab","View",choices:[("overview","Overview"),("analytics","Analytics")])}
        if demo,sample("usageTab").settingsText == "analytics" {
            for (title,values) in SettingsDemoVisuals.analytics {
                heading(title,"Last 30 days · synthetic preview")
                for (name,value) in values {rows.append(.init(id:title+name,title:name,detail:"\(value)%",kind:.progress,value:.number(Double(value)/100)))}
            }
            return
        }
        let root=session.snapshots["limits"],byID=root?["rateLimitsByLimitId"]?.objectValue
        let limits=byID?.keys.sorted().map{($0,byID![$0]!)} ?? [("Usage",root?["rateLimits"] ?? .null)]
        for (name,limit) in limits {
            heading(name)
            for (key,title) in [("primary","Current window"),("secondary","Weekly window")] {
                guard let window=limit[key],let used=window["usedPercent"]?.doubleValue else{info(title,"Not reported");continue}
                var detail=String(format:"%.0f%% remaining",max(0,100-used))
                if let mins=window["windowDurationMins"]?.intValue {detail+=" · \(mins) min window"}
                if let reset=window["resetsAt"]?.doubleValue {detail+=" · resets "+Date(timeIntervalSince1970:reset).formatted(date:.abbreviated,time:.shortened)}
                rows.append(.init(id:name+key,title:title,detail:detail,kind:.progress,value:.number(max(0,min(1,(100-used)/100)))))
            }
            if let balance=limit["credits"]?["balance"] {info("Credits",balance.settingsText)}
        }
        if demo {
            info("Ultra","14% remaining · prototype")
            rows.append(.init(id:"usage.chart",title:"Last 14 days",detail:"Synthetic usage",kind:.chart,value:[22,35,18,40,52,12,8,30,46,61,38,27,55,33]))
        }
        link("Manage plan","https://chatgpt.com/#settings/Subscription")
    }
    mutating func dataControls() {
        heading(NativeSettingsCatalog.title(session.pane))
        guard demo else {
            info("Data controls","Training, exports, shared links and account deletion are managed on ChatGPT.")
            link("Open ChatGPT Data Controls","https://chatgpt.com/#settings/DataControls")
            route("archived","Archived Chats");command("archive.all","Archive all loaded chats","Running chats keep running.",kind:.archiveAll,confirm:"Archive the loaded chats on this backend? Running chats keep running.")
            return
        }
        if session.pane == "data/links" {
            for link in session.records("links") {let id=link["id"]?.settingsText ?? "";info(link["title"]?.settingsText ?? "Link",[link["made"],link["views"]].compactMap{$0?.settingsText}.joined(separator:" · "),id:"share."+id)
                let s=session;button("share.copy."+id,"Copy link") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(link["url"]?.settingsText ?? "",forType:.string);s.notice="Link copied.";s.changed()}
                demoCommand("share.delete."+id,"Delete link",action:"remove",payload:["collection":"links","id":.string(id)],destructive:true,confirm:"Delete this prototype shared link?")
            };empty("links","No shared links")
        } else {
            let s=session
            info("Daybreak","Your conversations are not used to improve models. This control is locked for the Daybreak preview.")
            demoValue("improveModel","Improve the model for everyone",enabled:false)
            route("data/links","Shared Links")
            command("archive.all","Archive all chats","Running chats keep running.",kind:.archiveAll,confirm:"Archive all prototype chats? Running chats keep running.")
            rows[rows.count-1].enabled = writable && !s.records("active").isEmpty
            demoCommand("chats.delete","Delete all chats",action:"clear",payload:["collection":"archived","allChats":true,"ids":.array((s.records("archived")+s.records("active")).compactMap{$0["id"]?.stringValue}.map(JSONValue.string))],destructive:true,confirm:"Delete all prototype chats? This cannot be undone.")
            let exportDetail:String
            switch s.exportProgress {
            case .idle:exportDetail="Prototype only"
            case .preparing:exportDetail="Preparing… · prototype"
            case .complete:exportDetail="Prototype prepared. No files were exported and no email was sent."
            case .failed(let error):exportDetail=error
            }
            button("export","Export data…",exportDetail,enabled:s.exportProgress != .preparing) {_ = s.startDemoExport()}
            if s.exportProgress == .preparing {
                rows.append(.init(id:"export.progress",title:"Preparing export…",detail:"Demo · prototype",kind:.progress,value:0))
                button("export.cancel","Cancel export") {s.cancelDemoExport()}
            }
            demoCommand("delete.account","Delete account…","Prototype only",action:"account.delete",destructive:true,confirm:"Delete this prototype account? No Live account will change.")
        }
    }
}
