import AppKit

/// Declarative native rows. Values are backend acknowledgements or local preferences; editing drafts is separate.
@MainActor struct SettingsRow {
    enum Kind:String { case heading,info,button,toggle,choice,field,date,editor,progress,themes,code,chart,shortcut,daybreak }
    var id:String,title:String,detail:String="",kind:Kind = .info,value:JSONValue = .null
    var choices:[(String,String)]=[]
    var tint:NSColor?
    var enabled=true,destructive=false
    var perform:((JSONValue)->Void)?
    /// Presentation belongs to Settings, not to the acknowledged Live data source. The same semantic row/action is
    /// projected into the product's grouped Form, including rows with several independent trailing actions.
    var visual=SettingsRowVisual()
}

struct SettingsRowVisual {
    enum Style: String { case standard, header, footer, cards, modes, segmented, slider, accent, search, toolbar, themeStrip,
        profile, statistics, activity, pluginTiles, storage, usageChart, meter, illustration, empty, counter, rule }
    var style=Style.standard
    var group="",symbol="",tile="",buttonTitle:String?,rightText="",cardArt=""
    var height:CGFloat?,gap:CGFloat=0,footer=false,chevron=false,readOnly=false
    var compact=false,centered=false,showsAll=false
    var tileSize:CGFloat=32
    var placeholder=""
    var menuActions:[SettingsRow]=[]
    var actions:[SettingsRow]=[]
}
@MainActor struct SettingsPanelBuilder {
    let session:SettingsSession
    var rows:[SettingsRow]=[]
    var demo:Bool { session.mode == .demo }
    var writable:Bool { !session.offline && !session.busy.contains("write") }
    func local(_ key:String) -> JSONValue { session.preferences[key] }
    func sample(_ key:String,device:Bool=false) -> JSONValue {
        session.snapshots["demo"]?.settingsPath((device ? "devices."+session.device+".":"global.")+key) ?? .null
    }
    mutating func heading(_ title:String,_ detail:String="",id:String?=nil) { rows.append(.init(id:id ?? "section."+title,title:title,detail:detail,kind:.heading)) }
    mutating func info(_ title:String,_ detail:String="",id:String?=nil) { rows.append(.init(id:id ?? "info."+title,title:title,detail:detail)) }
    mutating func button(_ id:String,_ title:String,_ detail:String="",enabled:Bool=true,destructive:Bool=false,_ action:@escaping()->Void) {
        rows.append(.init(id:id,title:title,detail:detail,kind:.button,enabled:enabled,destructive:destructive,perform:{ _ in action() }))
    }
    mutating func route(_ id:String,_ title:String,_ detail:String="") { let s=session; button("go."+id,title,detail) { s.go(id) } }
    mutating func sheet(_ kind:SettingsSheetKind,_ title:String,_ detail:String="",enabled:Bool=true) { let s=session; button("sheet."+kind.rawValue,title,detail,enabled:enabled && writable) { s.openSheet(kind) } }
    mutating func link(_ title:String,_ address:String,_ detail:String="") { let s=session; button("link."+address,title,detail) { if let url=URL(string:address) { s.onOpenURL?(url) } } }
    mutating func command(_ id:String,_ title:String,_ detail:String="",kind:SettingsOperation.Kind,payload:JSONValue=[:],destructive:Bool=false,confirm:String?=nil,localFile:Bool=false) {
        let s=session,op=s.operation(kind,payload)
        button(id,title,detail,enabled:s.allowed(kind,localFile:localFile),destructive:destructive) {
            // The alert's button names the action (Revoke, Uninstall…), not always "Delete".
            if let confirm { s.ask(title:title,message:confirm,confirm:destructive ? title.trimmingCharacters(in:CharacterSet(charactersIn:"…")):"Continue",destructive:destructive,operation:op) }
            else { s.dispatch(op) }
        }
    }
    mutating func demoCommand(_ id:String,_ title:String,_ detail:String="",action:String,payload:[String:JSONValue]=[:],destructive:Bool=false,confirm:String?=nil) {
        var p=payload;p["action"] = .string(action)
        command(id,title,detail,kind:.demo,payload:.object(p),destructive:destructive,confirm:confirm)
    }
    mutating func preference(_ key:String,_ title:String,_ detail:String="",choices:[(String,String)]=[],enabled:Bool=true) {
        let s=session; rows.append(.init(id:key,title:title,detail:detail,kind:choices.isEmpty ? .toggle:.choice,value:key == "keys.send" ? .string(s.preferences.effectiveKey("send")):local(key),choices:choices,enabled:enabled,perform:{ v in
            if key == "numberShortcuts" { s.keyWarning=s.preferences.setNumberKeys(v.settingsText);s.changed() }
            else if key == "keys.send" { s.keyWarning=s.preferences.assignKey("send",v.settingsText);s.changed() }
            else { s.preferences.set(key,v) }
        }))
    }
    mutating func demoValue(_ key:String,_ title:String,_ detail:String="",device:Bool=false,choices:[(String,String)]=[],enabled:Bool=true) {
        let s=session,path=(device ? "devices."+s.device+".":"global.")+key
        rows.append(.init(id:"demo."+path,title:title,detail:detail,kind:choices.isEmpty ? .toggle:.choice,value:sample(key,device:device),choices:choices,enabled:enabled && writable,perform:{ v in s.dispatch(s.operation(.demo,["action":"set","path":.string(path),"value":v])) }))
    }
    mutating func config(_ key:String,_ title:String,_ detail:String="",choices:[(String,String)]=[],isBoolean:Bool=false) {
        let s=session,current=s.config(key) ?? .null,scope=session.scope
        var options=choices
        if !isBoolean {
            options.insert(("__default__","Backend default"),at:0)
            if let str=current.stringValue,!options.contains(where:{ $0.0 == str }) { options.append((str,str+" (current)")) }
        }
        rows.append(.init(id:"config."+key,title:title,detail:detail,kind:isBoolean ? .toggle:.choice,value:current == .null && !isBoolean ? .string("__default__"):current,choices:options,enabled:s.allowed(.configWrite) && s.snapshots["config"] != nil,perform:{ v in s.dispatchConfig([key:v.settingsText == "__default__" ? .null:v],scope:scope) }))
    }
    mutating func draft(_ key:String,_ title:String,_ fallback:String="",editor:Bool=false,detail:String="") {
        let s=session; rows.append(.init(id:"draft."+key,title:title,detail:detail,kind:editor ? .editor:.field,value:.string(s.draft(key,fallback:fallback)),enabled:writable,perform:{ v in s.setDraft(key,v.settingsText) }))
    }
    mutating func devicePicker() {
        let s=session,devices=s.records("devices")
        if !devices.isEmpty { rows.append(.init(id:"device",title:"Device",kind:.choice,value:.string(s.device),choices:devices.map { ($0["id"]?.settingsText ?? "",($0["name"]?.settingsText ?? "Device")+($0["online"]?.boolValue == false ? " · Offline":"")) },perform:{ v in s.setDevice(v.settingsText);Task { await s.loadNow() } })) }
        if s.offline { info("Device is offline","Last loaded copy. Changes are unavailable until the device reconnects.") }
    }
    mutating func filter(_ title:String="Search") {
        let s=session; rows.append(.init(id:"listQuery",title:title,kind:.field,value:.string(s.listQuery),perform:{ v in s.listQuery=v.settingsText;s.pluginPage=0;s.changed() }))
    }
    func matches(_ value:String) -> Bool { session.listQuery.isEmpty || value.localizedCaseInsensitiveContains(session.listQuery) }
    mutating func unavailable(_ title:String,_ reason:String) { info(title,reason) }
    mutating func empty(_ key:String,_ message:String) { if session.records(key).isEmpty { info(message,session.busy.contains("read:"+session.pane) ? "Loading…":"No records were reported by this backend.") } }
    static let access=[("read","Read Only"),("auto","Auto"),("full","Full Access")]
    static let policies=[("allow","Allow"),("ask","Ask"),("deny","Deny")]
}

@MainActor enum SettingsPanels {
    static func make(_ s:SettingsSession) -> [SettingsRow] {
        var b=SettingsPanelBuilder(session:s)
        if s.mode == .demo { b.info("Demo · prototype","Sample account, devices and statistics. Demo changes do not alter a Live backend.",id:"mode") }
        if let error=s.errors["read:"+s.pane] { b.info("Couldn’t load settings",error,id:"read.error") }
        if let error=s.errors["write"] { b.info("Couldn’t save",error,id:"write.error") }
        for key in ["login","oauth","notifications"] {
            let relevant=key == "login" ? ["account","profile"].contains(s.top):key == "oauth" ? s.top == "plugins":["notifications","scheduler"].contains(s.top)
            if relevant,let error=s.errors[key] {b.info("Couldn’t complete the request",error,id:"source.error."+key)}
        }
        if let notice=s.notice,!notice.hasPrefix("Demo · prototype") { b.info("Connection",notice,id:"notice") }
        switch s.top {
        case "account":b.account()
        case "general":b.general()
        case "notifications":b.notifications()
        case "import":b.importPane()
        case "profile":b.profile()
        case "appearance":b.appearance()
        case "organic":b.organic()
        case "archived":b.archived()
        case "storage":b.storage()
        case "configuration":b.configuration()
        case "personalization":b.personalization()
        case "shortcuts":b.shortcuts()
        case "usage":b.usage()
        case "data":b.dataControls()
        case "plugins":b.plugins()
        case "computer":b.computer()
        case "appshots":b.appshots()
        case "browser":b.browser()
        case "scheduler":b.scheduler()
        case "connections":b.connections()
        default:b.info("Select a settings page")
        }
        return b.rows
    }
}
