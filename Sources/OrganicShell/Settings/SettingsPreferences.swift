import AppKit

extension JSONValue {
    var settingsText:String {
        switch self { case .string(let s):s; case .number(let n):n.rounded() == n ? String(format:"%.0f",n):String(n); case .bool(let b):b ? "On":"Off"; default:"" }
    }
    func settingsPath(_ path:String) -> JSONValue? { path.split(separator:".").reduce(Optional(self)) { $0?[String($1)] } }
}

@MainActor final class SettingsPreferences {
    static let changed=Notification.Name("organic.settings.changed")
    let defaults:UserDefaults
    private(set) var values:[String:JSONValue]=[:]
    var fixedCommand:((String)->String?)?
    var onChange:((String,JSONValue)->Void)?
    static let organicKeys=["playfulSummaries":"toggle.playfulSummaries","forceClickPeek":"toggle.forceClickPeek","identityLiquid":"toggle.identityLiquid","fullyFocused":"toggle.fullyFocused","organicFullBleed":"toggle.organicFullBleed","simulateReduceMotion":"toggle.simulateReduceMotion","compareNeverAsk":"compare.neverAsk"]
    static let standard:[String:JSONValue] = [
        "general.access":"auto","general.preventSleep":true,"general.folder":"~/Documents/Codex","general.openIn":"default","general.language":"system",
        "notifications.done":"banner","notifications.approval":"sound","notifications.error":"banner","notifications.cloud":"email","notifications.inactive":true,"notifications.badge":true,"notifications.bounce":false,
        "look.mode":"dark","look.accent":"multi","look.custom":"","look.theme":"canopy","look.code":"match","look.glass":"tinted","look.background":"","look.foreground":"","look.font":"sf","look.size":12,"look.text":1,
        "organic.playfulSummaries":true,"organic.forceClickPeek":true,"organic.identityLiquid":true,"organic.fullyFocused":false,"organic.organicFullBleed":true,"organic.simulateReduceMotion":false,"organic.compareNeverAsk":false,
        "collapseOnHoverSpace":false,"numberShortcuts":"chats","followUpDefault":"steer","coreNotifications":true
    ]
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults; values=Self.standard
        for group in ["general","notifications","look","keys"] {
            if let data=defaults.data(forKey:"settings."+group),let object=try? JSONDecoder().decode([String:JSONValue].self,from:data) {
                for (key,value) in object { values[group+"."+key]=value }
            }
        }
        for (id,value) in defaults.dictionary(forKey:"settings.jobNotifications") as? [String:String] ?? [:] {values["jobNotifications."+id] = .string(value)}
        for (key,storeKey) in Self.organicKeys {
            if let value=defaults.object(forKey:storeKey) as? Bool { values["organic."+key] = .bool(value) }
        }
        for key in ["collapseOnHoverSpace","numberShortcuts","followUpDefault","coreNotifications"] {
            if let value=defaults.string(forKey:"settings."+key),Self.standard[key]?.stringValue != nil { values[key] = .string(value) }
            else if let value=defaults.object(forKey:"settings."+key) as? Bool { values[key] = .bool(value) }
        }
        for item in NativeSettingsCatalog.shortcuts where values["keys."+item.id] == nil { values["keys."+item.id] = .string(item.key) }
    }
    subscript(_ key:String) -> JSONValue { values[key] ?? .null }
    var notificationPolicy:SettingsNotificationPolicy {
        let prefix="jobNotifications."
        return .init(enabled:self["coreNotifications"].boolValue ?? true,
                     jobs:Dictionary(uniqueKeysWithValues:values.compactMap { key,value in
                         guard key.hasPrefix(prefix),let policy=value.stringValue else{return nil}
                         return (String(key.dropFirst(prefix.count)),policy)
                     }))
    }
    func set(_ key:String,_ value:JSONValue) {
        guard values[key] != value else { return }; values[key]=value
        if key == "look.theme" { values["look.background"]=""; values["look.foreground"]="" }
        if key.hasPrefix("organic."),let storeKey=Self.organicKeys[String(key.dropFirst(8))] { defaults.set(value.boolValue,forKey:storeKey) }
        else if let dot=key.firstIndex(of:".") {
            let group=String(key[..<dot]),prefix=group+"."
            let map=Dictionary(uniqueKeysWithValues:values.filter { $0.key.hasPrefix(prefix) }.map { (String($0.key.dropFirst(prefix.count)),$0.value) })
            if group == "jobNotifications" {defaults.set(map.mapValues(\.settingsText),forKey:"settings.jobNotifications")}
            else if let data=try? JSONEncoder().encode(map) { defaults.set(data,forKey:"settings."+group) }
        } else {
            if let bool=value.boolValue { defaults.set(bool,forKey:"settings."+key) }
            else { defaults.set(value.settingsText,forKey:"settings."+key) }
        }
        onChange?(key,value); NotificationCenter.default.post(name:Self.changed,object:self,userInfo:["key":key])
    }
    func resetAppearance() { for (key,value) in Self.standard where key.hasPrefix("look.") { set(key,value) } }
    func effectiveKey(_ id:String) -> String { let key=self["keys."+id].settingsText; return id == "send" && key.isEmpty ? "⌘↩":key }
    @discardableResult func assignKey(_ id:String,_ combo:String) -> String? {
        guard NativeSettingsCatalog.shortcuts.contains(where:{ $0.id == id }) else { return "Unknown command." }
        if !combo.isEmpty && !["⌘","⌃","⌥"].contains(where:combo.contains) && id != "send" { return "Use at least one of ⌘, ⌃ or ⌥." }
        let wanted=id == "send" && combo.isEmpty ? "⌘↩":combo
        if !wanted.isEmpty {
            if let other=NativeSettingsCatalog.shortcuts.first(where:{ $0.id != id && effectiveKey($0.id) == wanted }) { return "\(wanted) is already used by \(other.name)." }
            if let command=fixedCommand?(wanted) ?? SettingsKeyCodec.fixedCommand(wanted,menu:NSApp.mainMenu) { return "\(wanted) is already used by \(command)." }
            if self["numberShortcuts"].settingsText != "off",(1...9).contains(where:{ wanted == "⌘\($0)" }) { return "\(wanted) is reserved for chats." }
        }
        set("keys."+id,.string(combo)); return nil
    }
    func setNumberKeys(_ value:String) -> String? {
        if value != "off",let command=NativeSettingsCatalog.shortcuts.first(where:{ c in (1...9).contains { effectiveKey(c.id) == "⌘\($0)" } }) { return "\(effectiveKey(command.id)) is used by \(command.name)." }
        set("numberShortcuts",.string(value)); return nil
    }
    func resetKeys() {
        guard NativeSettingsCatalog.shortcuts.allSatisfy({ item in item.key.isEmpty || (fixedCommand?(item.key) ?? SettingsKeyCodec.fixedCommand(item.key,menu:NSApp.mainMenu)) == nil }) else{return}
        for item in NativeSettingsCatalog.shortcuts {set("keys."+item.id,.string(item.key))}
    }
    static func isHex(_ text:String) -> Bool { text.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil }
}

struct SettingsNavigation:Equatable {
    private(set) var history:[String],position=0
    var pane:String { history[position] }
    var top:String { String(pane.split(separator:"/").first ?? "") }
    var canBack:Bool { position>0 }; var canForward:Bool { position+1<history.count }
    init(initial:String="general") { history=[NativeSettingsCatalog.valid(initial) ? initial:"general"] }
    mutating func go(_ route:String) { guard NativeSettingsCatalog.valid(route),route != pane else { return }; history=Array(history.prefix(position+1))+[route]; position=history.count-1 }
    mutating func back() { if canBack { position-=1 } }
    mutating func forward() { if canForward { position+=1 } }
    mutating func replace(_ route:String) { guard NativeSettingsCatalog.valid(route) else { return }; history=Array(history.prefix(position))+[route]; position=history.count-1 }
}

struct SettingsConfirmation {
    let id=UUID()
    var title:String,message:String,confirm:String
    var destructive=false
    var operation:SettingsOperation
}
enum SettingsSheetKind:String,CaseIterable { case importContent,customizeSync,importMCP,addMCP,pair,ssh,schedule,addSite,addRule }
struct SettingsSheetState {
    enum Phase:Equatable { case editing,working,done,failed(String),cancelled }
    let id=UUID()
    var kind:SettingsSheetKind,scope:SettingsScope
    var fields:[String:JSONValue]=[:]
    var phase=Phase.editing
    var message=""
    var canSubmit:Bool {
        func value(_ key:String) -> String { fields[key]?.settingsText.trimmingCharacters(in:.whitespacesAndNewlines) ?? "" }
        guard phase == .editing || { if case .failed=phase { return true }; return false }() else { return false }
        switch kind {
        case .addMCP:
            let transport=value("transport"),address=value("command")
            return !value("name").isEmpty && !address.isEmpty && (transport != "http" || (["https","http"].contains(URL(string:address)?.scheme ?? "") && URL(string:address)?.host?.isEmpty == false))
        case .ssh:return !value("host").isEmpty && !value("user").isEmpty && (Int(value("port")) ?? 0)>0 && (Int(value("port")) ?? 0)<=65535
        case .schedule:return !value("name").isEmpty && !value("prompt").isEmpty && (fields["at"]?.doubleValue ?? 0)>Date().timeIntervalSince1970 && (fields["hours"]?.doubleValue ?? 0)>=0
        case .addSite:return !value("host").isEmpty && !value("host").contains(" ")
        case .addRule:return !value("pattern").isEmpty
        case .pair:return false
        default:return true
        }
    }
}
