import AppKit

@MainActor extension SettingsPanelBuilder {
    mutating func account() {
        let a=session.snapshots["account"]?["account"],type=a?["type"]?.settingsText ?? ""
        heading("Account")
        if let a,a != .null {
            info(a["name"]?.settingsText ?? a["email"]?.settingsText ?? (type == "apiKey" ? "API key account":"Connected account"),a["email"]?.settingsText ?? "")
            info("Plan",a["planType"]?.settingsText ?? "Not reported")
            if demo { link("Manage plan","https://chatgpt.com/#settings/Subscription");demoCommand("logout","Sign out","Prototype account",action:"set",payload:["path":"global.signedOut","value":true],confirm:"Sign out of the prototype account?") }
            else { command("logout","Sign out",kind:.logout,confirm:"Sign out of the connected backend account?") }
        } else { info("Not signed in",demo ? "Demo account is signed out.":"The connected backend has not reported an account.") }
        if !demo { command("login","Sign in with ChatGPT",kind:.login);if let id=session.snapshots["login"]?["loginId"] { command("cancelLogin","Cancel sign-in",kind:.cancelLogin,payload:["loginId":id]) } }
        if demo {
            let s=session,fallback=sample("name").settingsText
            draft("account.name","Name",fallback)
            button("account.name.save","Save name") {let value=s.draft("account.name",fallback:fallback).trimmingCharacters(in:.whitespacesAndNewlines);guard !value.isEmpty else{return};s.dispatch(s.operation(.demo,["action":"set","path":"global.name","value":.string(value)]))}
            info("Username","@louis")
            demoCommand("account.email","Change email…","Email is managed on ChatGPT.",action:"account.changeEmail",confirm:"Open the ChatGPT account page to change your email?")
            demoCommand("account.delete","Delete account…","Prototype only",action:"account.delete",destructive:true,confirm:"Delete this prototype account? No Live account will change.")
        }
        route("usage","Usage & Billing");route("data","Data Controls")
    }
    mutating func general() {
        heading("General")
        if demo {rows.append(.init(id:"general.daybreak",title:"Daybreak Access",detail:"Daybreak Blue · Expanded cyber capabilities for approved security work. Turn it on for a chat from the model picker.",kind:.daybreak,value:sample("email")))}
        preference("general.access","Default access","New chats use this permission level.",choices:Self.access)
        if local("general.access") == "full" {rows.append(.init(id:"general.fullAccess",title:"Full Access",detail:"Codex can edit any file and run commands with network access without asking.",tint:.systemOrange))}
        preference("keys.send","Send message with",choices:[("⌘↩","Command + Return"),("↩","Return")])
        preference("followUpDefault","Follow-up messages",choices:[("steer","Steer the current response"),("queue","Add to queue")])
        if let warning=session.keyWarning { info("Shortcut unavailable",warning) }
        preference("general.preventSleep","Prevent sleep while working")
        preference("collapseOnHoverSpace","Collapse when hovering over an empty space")
        draft("folder","Default project folder",local("general.folder").settingsText)
        let s=session;button("save.folder","Use this folder") { let path=s.draft("folder",fallback:s.preferences["general.folder"].settingsText).trimmingCharacters(in:.whitespacesAndNewlines);if !path.isEmpty { s.preferences.set("general.folder",.string(path)) } }
        button("choose.folder","Choose folder…") { s.onApplicationAction?("chooseProjectFolder") }
        preference("general.openIn","Open files in",choices:[("default","Default App"),("finder","Finder"),("xcode","Xcode"),("terminal","Terminal"),("textedit","TextEdit")])
        preference("general.language","Language","Applies next time you open the app.",choices:NativeSettingsCatalog.languages)
        button("restart","Restart…","Close and reopen to apply the selected language.") { s.onApplicationAction?("restart") }
    }
    mutating func organic() {
        heading("Organic")
        preference("organic.playfulSummaries","Playful brief summaries","Turn off for plain summaries.");info("Brief summary preview",local("organic.playfulSummaries").boolValue == true ? "Polished the sidebar — fewer pixels, more room to think.":"Updated sidebar spacing and typography.")
        preference("organic.forceClickPeek","Force Click to Peek","Preview a conversation without leaving the current one.")
        preference("organic.identityLiquid","Identity liquid","Show context as liquid inside the planet.")
        preference("organic.fullyFocused","Fully Focused","Show only the active conversation in Focused layout.")
        preference("organic.compareNeverAsk","Compare without asking again","Skip the confirmation when entering Compare.")
        preference("organic.organicFullBleed","Full-bleed Organic canvas")
        preference("organic.simulateReduceMotion","Reduce Motion preview","Also respects the macOS Reduce Motion setting.")
    }
    mutating func notifications() {
        heading("Notifications")
        if demo {
            let styles=[("banner","Banner"),("sound","Sound"),("both","Banner and Sound"),("email","Email"),("off","Off")]
            for (key,name) in [("done","Response completed"),("approval","Approval needed"),("error","Response failed"),("cloud","Cloud task completed")] { preference("notifications."+key,name,choices:styles) }
            preference("notifications.inactive","Only when the app is inactive");preference("notifications.badge","Badge app icon");preference("notifications.bounce","Bounce Dock icon")
        } else {
            preference("coreNotifications","Notifications on this Mac")
            info("Permission",session.snapshots["permission"]?.settingsText ?? "Not reported")
            command("permission","Allow notifications…",kind:.notificationPermission)
            route("scheduler","Scheduled Tasks","Control notifications for each task.")
            heading("Inbox")
            for (i,n) in session.records("notifications").enumerated() {
                info(n["title"]?.settingsText ?? "Notification",n["body"]?.settingsText ?? n["status"]?.settingsText ?? "",id:"notification.\(i)")
                if let id=n["id"],n["read"]?.boolValue != true { command("ack.\(i)","Mark as read",kind:.notificationAck,payload:["id":id]) }
            };empty("notifications","No notifications")
        }
    }
    mutating func importPane() {
        heading("Import from other tools","Bring your settings, MCP servers, skills and projects into Codex.")
        guard demo else { unavailable("Import","Cross-product import is not exposed by the connected backend. Install skills or configure MCP servers instead.");route("plugins/skills","Skills");route("plugins/mcp","MCP Servers");route("configuration","Configuration");return }
        demoValue("importSync","Keep settings in sync","Sync becomes available after the first import.",enabled:sample("imported").boolValue == true)
        sheet(.customizeSync,"Customize sync…");sheet(.importContent,"Import from Claude Code…");sheet(.importMCP,"Import MCP configuration…")
        if sample("imported").boolValue == true { info("Import complete","Prototype data is ready. No files were copied.") }
    }
    mutating func profile() {
        heading("Profile")
        guard demo else {account();return}
        demoValue("profilePublic","Public profile","Your profile is private until you enable sharing.")
        route("account","Edit account")
        let profileSession=session;button("profile.share","Share…","Prototype only") {profileSession.notice="Prototype: no public profile link was published.";profileSession.changed()}
        draft("name","Display name",sample("name").settingsText)
        let s=session,sampleName=sample("name").settingsText;button("save.name","Save name") { let n=s.draft("name",fallback:sampleName).trimmingCharacters(in:.whitespacesAndNewlines);guard !n.isEmpty else{return};s.dispatch(s.operation(.demo,["action":"set","path":"global.name","value":.string(n)])) }
        heading("Activity","Synthetic preview · 23 active days · 9-day streak")
        info("2.4bn lifetime tokens","310M peak day · 3h 12m longest task · 23 days longest streak · 9 days current streak")
        demoValue("profileRange","Activity view",choices:[("daily","Daily"),("weekly","Weekly"),("cumulative","Cumulative")])
        rows.append(.init(id:"profile.activity",title:"Token activity",detail:sample("profileRange").settingsText == "daily" ? "1,284 active hours in the last year · synthetic preview":sample("profileRange").settingsText == "weekly" ? "Tokens per week · synthetic preview":"Tokens over the year · synthetic preview",kind:.chart,value:.array(SettingsDemoVisuals.profileGrid(sample("profileRange").settingsText).map{.number($0)})))
        heading("Top plugins");for name in ["Product Design","Git Host","Drive","Mail","Writing Style"] { info(name,"Used in prototype conversations") };heading("Insights");for (title,value) in [("Most used model","GPT-6.1 Sol · 54%"),("Most used reasoning","High · 46%"),("Fast or Ultrafast","18% of runs"),("Most active device","This Mac"),("Skills explored","23"),("Skills used","412 times")] {info(title,value+" · prototype")}
    }
    mutating func appearance() {
        heading("Appearance")
        preference("look.text","Text size",choices:[("0.85","85%"),("1","100%"),("1.15","115%"),("1.3","130%"),("1.5","150%")])
        // Numeric preferences are kept numeric for the host's typography adapter.
        rows[rows.count-1].perform={ [session] v in session.preferences.set("look.text",.number(Double(v.settingsText) ?? 1)) }
        heading("Window colors")
        rows.append(.init(id:"look.theme",title:"Window theme",kind:.themes,value:local("look.theme"),perform:{ [session] v in session.preferences.set("look.theme",v) }))
        preference("look.glass","Glass",choices:[("clear","Clear"),("tinted","Tinted")])
        for (key,title) in [("background","Background"),("foreground","Text"),("custom","Custom accent")] {
            let s=session;button("color."+key,title+" color…",local("look."+key).settingsText.isEmpty ? "Use theme color":local("look."+key).settingsText) { s.onApplicationAction?("color:look."+key) }
        }
        preference("look.accent","Accent color",choices:[("multi","Multicolor"),("blue","Blue"),("purple","Purple"),("pink","Pink"),("red","Red"),("orange","Orange"),("yellow","Yellow"),("green","Green"),("graphite","Graphite"),("custom","Custom")])
        heading("Code")
        preference("look.code","Code colors",choices:[("match","Match Window")]+SettingsThemes.all.map{($0.id,$0.name)})
        preference("look.font","Font",choices:[("sf","SF Mono"),("menlo","Menlo"),("monaco","Monaco"),("courier","Courier New")])
        preference("look.size","Font size",choices:(9...18).map{(String($0),"\($0) pt")})
        rows[rows.count-1].perform={ [session] v in session.preferences.set("look.size",.number(Double(v.settingsText) ?? 12)) }
        rows.append(.init(id:"code.preview",title:"Preview",kind:.code,value:.object(["theme":local("look.code").settingsText == "match" ? local("look.theme"):local("look.code"),"font":local("look.font"),"size":local("look.size")])))
        let s=session;button("reset.appearance","Reset Appearance") { s.preferences.resetAppearance() }
    }
    mutating func shortcuts() {
        heading("Keyboard Shortcuts")
        filter(session.searchByKeystroke ? "Search by keystroke":"Search commands")
        let s=session;button("search.key",s.searchByKeystroke ? "Search by name":"Record a search shortcut") { s.searchByKeystroke.toggle();s.recording=nil;s.changed() }
        if let warning=s.keyWarning { info("Shortcut unavailable",warning) }
        for c in NativeSettingsCatalog.shortcuts where matches(s.searchByKeystroke ? s.preferences.effectiveKey(c.id):c.name) {
            rows.append(.init(id:"shortcut."+c.id,title:c.name,detail:s.recording == c.id ? "Press a shortcut · Esc cancels · Delete clears":"",kind:.shortcut,value:.string(s.preferences.effectiveKey(c.id)),perform:{ _ in s.recording=c.id;s.searchByKeystroke=false;s.keyWarning=nil;s.changed() }))
        }
        preference("numberShortcuts","Command + 1–9",choices:[("chats","Switch Chats"),("off","Off")])
        button("reset.keys","Restore Defaults") { s.preferences.resetKeys();s.keyWarning=nil;s.changed() }
    }
}
