import AppKit

struct SettingsPane: Equatable {
    let id:String, name:String, group:String, symbol:String, tint:String, search:String
    var top:String { String(id.split(separator:"/").first ?? "") }
}
enum NativeSettingsCatalog {
    static let panes:[SettingsPane] = [
        .init(id:"account",name:"Account",group:"",symbol:"person.crop.circle.fill",tint:"#57c27a",search:"plan name email sign in sign out delete account"),
        .init(id:"general",name:"General",group:"Personal",symbol:"gearshape.fill",tint:"#8e8e93",search:"Daybreak access permissions read only auto full composer send Return queue steer sleep collapse folder files language"),
        .init(id:"notifications",name:"Notifications",group:"Personal",symbol:"bell.badge.fill",tint:"#ff453a",search:"banner sound email approvals failure scheduled inbox unread Dock bounce"),
        .init(id:"import",name:"Import",group:"Personal",symbol:"square.and.arrow.down",tint:"#0a84ff",search:"Claude Code sync MCP skills projects chats"),
        .init(id:"profile",name:"Profile",group:"Personal",symbol:"person.text.rectangle",tint:"#8587ff",search:"public private share tokens activity daily weekly cumulative plugins insights"),
        .init(id:"appearance",name:"Appearance",group:"Personal",symbol:"circle.lefthalf.filled",tint:"#5a5a60",search:"auto light dark text size window theme glass background foreground accent code font colors reset"),
        .init(id:"organic",name:"Organic",group:"Personal",symbol:"leaf.fill",tint:"#57c27a",search:"brief summary tone playful plain orbs Force Click peek identity liquid Fully Focused Compare"),
        .init(id:"archived",name:"Archived Chats",group:"Personal",symbol:"archivebox.fill",tint:"#b4946c",search:"search device project unarchive delete all load more"),
        .init(id:"storage",name:"Storage",group:"Personal",symbol:"internaldrive.fill",tint:"#8e8e93",search:"usage cleanup old chats worktrees logs caches refresh"),
        .init(id:"configuration",name:"Configuration",group:"Personal",symbol:"slider.horizontal.3",tint:"#8e8e93",search:"config.toml approval policy sandbox web search output detail reasoning summary model dependencies"),
        .init(id:"personalization",name:"Personalization",group:"Personal",symbol:"sparkles",tint:"#bf5af2",search:"memory tools custom rules instructions AGENTS.md"),
        .init(id:"shortcuts",name:"Keyboard Shortcuts",group:"Personal",symbol:"keyboard",tint:"#8e8e93",search:"keys recording search keystroke number chat send attach focus stop sidebar collapse restore undo reset"),
        .init(id:"usage",name:"Usage & Billing",group:"Personal",symbol:"gauge.medium",tint:"#0a84ff",search:"overview analytics plan limits five hour weekly ultra recent model device project credits"),
        .init(id:"data",name:"Data Controls",group:"Personal",symbol:"hand.raised.fill",tint:"#0a84ff",search:"training Daybreak improve shared links archive delete export"),
        .init(id:"plugins",name:"Plugins",group:"Integrations",symbol:"puzzlepiece.extension.fill",tint:"#ff9f0a",search:"skills MCP servers catalog installed install uninstall enable tools directory"),
        .init(id:"computer",name:"Computer Use",group:"Integrations",symbol:"cursorarrow.rays",tint:"#30c6bc",search:"accessibility screen recording audio app control locked browser extension sessions grants"),
        .init(id:"appshots",name:"Appshots",group:"Integrations",symbol:"camera.viewfinder",tint:"#50b8ed",search:"capture hotkey shortcut screen window destination sound"),
        .init(id:"browser",name:"Browser",group:"Integrations",symbol:"globe",tint:"#0a84ff",search:"web local URL comments history data site permissions tabs origin download upload"),
        .init(id:"scheduler",name:"Scheduled Tasks",group:"Coding",symbol:"calendar.badge.clock",tint:"#8587ff",search:"schedule jobs repeat hour daily weekly prompt task runs notifications"),
        .init(id:"connections",name:"Connections",group:"Coding",symbol:"network",tint:"#30d158",search:"backend Core address endpoint reconnect SSH pairing devices allow awake"),
        .init(id:"storage/cleanup",name:"Clean Up Old Chats",group:"",symbol:"trash",tint:"#8e8e93",search:"old chats delete selection"),
        .init(id:"storage/worktrees",name:"Worktrees",group:"",symbol:"arrow.triangle.branch",tint:"#30d158",search:"keep newest remove branch working copy"),
        .init(id:"personalization/rules",name:"Custom Rules",group:"",symbol:"checkmark.shield",tint:"#bf5af2",search:"command patterns allow ask deny"),
        .init(id:"personalization/agents",name:"AGENTS.md",group:"",symbol:"doc.text",tint:"#bf5af2",search:"instructions editor save revert"),
        .init(id:"data/links",name:"Shared Links",group:"",symbol:"link",tint:"#0a84ff",search:"copy delete views"),
        .init(id:"plugins/skills",name:"Skills",group:"",symbol:"wand.and.stars",tint:"#ffd60a",search:"install SKILL.md enable folder refresh"),
        .init(id:"plugins/mcp",name:"MCP Servers",group:"",symbol:"server.rack",tint:"#8e8e93",search:"stdio HTTP OAuth sign in server command URL"),
        .init(id:"browser/history",name:"Browsing History",group:"",symbol:"clock",tint:"#0a84ff",search:"pages visited clear remove")
    ]
    static func pane(_ id:String) -> SettingsPane? { panes.first { $0.id == id } }
    static func valid(_ id:String) -> Bool { pane(id) != nil || id.hasPrefix("plugins/detail/") }
    static func title(_ id:String) -> String { pane(id)?.name ?? (id.hasPrefix("plugins/detail/") ? "Plugin":"Settings") }
    static func visible(query:String,mode:SettingsMode) -> [SettingsPane] {
        let q=query.trimmingCharacters(in:.whitespacesAndNewlines)
        return panes.filter { pane in
            guard !pane.id.contains("/"),mode == .live || pane.id != "scheduler" else { return false }
            let words=panes.filter { $0.top == pane.id }.map { $0.name+" "+$0.search }.joined(separator:" ")
            return q.isEmpty || (pane.name+" "+words).localizedCaseInsensitiveContains(q)
        }
    }
    static let shortcuts:[(id:String,name:String,key:String)] = [
        ("newChat","New Chat","⌘N"),("archive","Archive Chat","⌘⌫"),("rename","Rename Chat",""),("pin","Pin Chat",""),("unread","Mark as Unread","⇧⌘U"),
        ("send","Send Message","⌘↩"),("attach","Attach Files","⇧⌘A"),("focus","Focus Composer","⌘L"),("stop","Stop Response","⌘."),
        ("search","Search Chats","⌘F"),("sidebar","Toggle Sidebar","⌃⌘S"),("collapse","Collapse to Side","⌥⌘↓"),("restore","Restore Window","⌥⌘↑"),
        ("inspector","Show Changes","⌥⌘I"),("settings","Settings","⌘,"),("undo","Undo","⌘Z")
    ]
    static let languages=[("system","System Default (English)"),("en","English"),("zh-Hans","简体中文"),("zh-Hant","繁體中文"),("ja","日本語"),("ko","한국어"),("de","Deutsch"),("fr","Français"),("es","Español")]
}

struct SettingsTheme: Equatable {
    let id:String,name:String,organic:Bool,bg:String,fg:String,accent:String,keyword:String,type:String,string:String,comment:String,function:String
}
enum SettingsThemes {
    static func t(_ id:String,_ name:String,_ organic:Bool,_ bg:String,_ fg:String,_ accent:String,_ kw:String,_ ty:String,_ str:String,_ com:String,_ fn:String) -> SettingsTheme {
        .init(id:id,name:name,organic:organic,bg:bg,fg:fg,accent:accent,keyword:kw,type:ty,string:str,comment:com,function:fn)
    }
    // Independent data copy of SettingsCatalog's dark theme palette; no product module dependency.
    static let all:[SettingsTheme] = [
        t("canopy", "Canopy", true, "#1e1e1e", "#ffffff", "#3478f6", "#ff7ab2", "#6bdfff", "#fc8a6d", "#7f8c98", "#a6e3a1"),
        t("chatgpt", "ChatGPT", true, "#212121", "#ececec", "#339cff", "#ff7b72", "#79c0ff", "#a5d6ff", "#8b949e", "#d2a8ff"),
        t("absolutely", "Absolutely", false, "#2b2a27", "#f5f2ea", "#d97757", "#e58f6b", "#e0b36a", "#b8c98a", "#8a857a", "#9fb7d9"),
        t("ayu", "Ayu", false, "#0b0e14", "#bfbdb6", "#e6b450", "#ff8f40", "#59c2ff", "#aad94c", "#5c6773", "#ffb454"),
        t("catppuccin", "Catppuccin", false, "#1e1e2e", "#cdd6f4", "#cba6f7", "#cba6f7", "#f9e2af", "#a6e3a1", "#6c7086", "#89b4fa"),
        t("dracula", "Dracula", false, "#282a36", "#f8f8f2", "#ff79c6", "#ff79c6", "#8be9fd", "#f1fa8c", "#6272a4", "#50fa7b"),
        t("everforest", "Everforest", false, "#2d353b", "#d3c6aa", "#a7c080", "#e67e80", "#83c092", "#a7c080", "#859289", "#dbbc7f"),
        t("github", "GitHub", false, "#0d1117", "#e6edf3", "#2f81f7", "#ff7b72", "#ffa657", "#a5d6ff", "#8b949e", "#d2a8ff"),
        t("gruvbox", "Gruvbox", false, "#282828", "#ebdbb2", "#83a598", "#fb4934", "#fabd2f", "#b8bb26", "#928374", "#8ec07c"),
        t("linear", "Linear", false, "#16171d", "#e2e3e9", "#5e6ad2", "#9ba3f7", "#4cb782", "#f2c94c", "#6b6f80", "#b4b8f5"),
        t("lobster", "Lobster", false, "#1f1b1b", "#f2e8e6", "#ef4444", "#ff6b6b", "#ffb37a", "#f6d38b", "#8b7a77", "#ff9e9e"),
        t("material", "Material", false, "#263238", "#eeffff", "#80cbc4", "#c792ea", "#ffcb6b", "#c3e88d", "#546e7a", "#82aaff"),
        t("matrix", "Matrix", false, "#030a05", "#a8f5bb", "#22e35a", "#22e35a", "#7dffa0", "#d2ffdd", "#2f7a46", "#5cff8a"),
        t("monokai", "Monokai", false, "#272822", "#f8f8f2", "#a6e22e", "#f92672", "#66d9ef", "#e6db74", "#75715e", "#a6e22e"),
        t("nightowl", "Night Owl", false, "#011627", "#d6deeb", "#82aaff", "#c792ea", "#ffcb8b", "#ecc48d", "#637777", "#82aaff"),
        t("nord", "Nord", false, "#2e3440", "#d8dee9", "#88c0d0", "#81a1c1", "#8fbcbb", "#a3be8c", "#616e88", "#88c0d0"),
        t("notion", "Notion", false, "#191919", "#e3e2e0", "#2383e2", "#e0796c", "#79b8e7", "#c6a96a", "#7d7c78", "#9a8fe0"),
        t("og", "OG", false, "#171d1b", "#ececf1", "#10a37f", "#19c37d", "#7fd8c4", "#e6c07b", "#6b7a76", "#8fd4ff"),
        t("one", "One", false, "#282c34", "#abb2bf", "#61afef", "#c678dd", "#e5c07b", "#98c379", "#5c6370", "#61afef"),
        t("oscurange", "Oscurange", false, "#0e0d10", "#e6e1dc", "#f9b98c", "#f9b98c", "#ffd7a8", "#b5cea8", "#6f6a66", "#f6a27a"),
        t("raycast", "Raycast", false, "#1a1a1a", "#e8e8e8", "#ff6363", "#ff6363", "#ffc531", "#59d499", "#7a7a7a", "#56c2ff"),
        t("rosepine", "Rose Pine", false, "#191724", "#e0def4", "#ebbcba", "#31748f", "#9ccfd8", "#f6c177", "#6e6a86", "#ebbcba"),
        t("sentry", "Sentry", false, "#1d1127", "#ebe6ef", "#7553ff", "#a68cff", "#ff70bc", "#f8d77a", "#7f6e8c", "#6fd3ff"),
        t("solarized", "Solarized", false, "#002b36", "#93a1a1", "#cb4b16", "#859900", "#268bd2", "#2aa198", "#586e75", "#b58900"),
        t("temple", "Temple", false, "#030f0b", "#d7e8de", "#d6f22b", "#d6f22b", "#6fe3c2", "#f1d48a", "#567a6c", "#9bf0a8"),
        t("tokyonight", "Tokyo Night", false, "#1a1b26", "#c0caf5", "#7aa2f7", "#bb9af7", "#2ac3de", "#9ece6a", "#565f89", "#7aa2f7"),
        t("vercel", "Vercel", false, "#000000", "#ededed", "#0a72ef", "#ff4d8d", "#52a8ff", "#62c073", "#7a7a7a", "#c472fb"),
        t("vscodeplus", "VS Code Plus", false, "#1e1e1e", "#d4d4d4", "#0078d4", "#569cd6", "#4ec9b0", "#ce9178", "#6a9955", "#dcdcaa"),
        t("xcode", "Xcode", false, "#1f1f24", "#f2f2f5", "#0a84ff", "#fc5fa3", "#5dd8ff", "#fc6a5d", "#6c7986", "#67b7a4"),
    ]
    static func theme(_ id:String) -> SettingsTheme { all.first { $0.id == id } ?? all[0] }
}
