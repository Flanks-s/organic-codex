import AppKit
import SwiftUI

/// M11.39 values only. Existing AutoScene meClicked/meHover/contextMenu entry points below are unchanged.
struct SunHoverAccess {
    struct Item: Equatable {
        let satellite: SunHoverSatellite
        let title: String
        let available: Bool
        let disabledInLayout: Bool
        var enabled: Bool { available && !disabledInLayout }
    }
    struct AccountItem: Equatable { let action: SunHoverAction; let title: String; let enabled: Bool; let dividerBefore: Bool }
    let satellites: [Item]
    let accountTitle: String
    let accountPlan: String?
    let accountSource: AccountUsageIdentity.Source
    let accountItems: [AccountItem]
    init(account: AccountUsage, available: Set<SunHoverSatellite>, disabledInLayout: Set<SunHoverSatellite>,
         accountActions: Set<SunHoverActionKey>, sidebarShown: Bool = false) {
        let titles = ["New Chat", "Add to Dock", "Search", sidebarShown ? "Hide Sidebar" : "Show Sidebar", "Usage", "Settings"]
        satellites = SunHoverSatellite.allCases.map {
            .init(satellite: $0, title: titles[$0.rawValue], available: available.contains($0), disabledInLayout: disabledInLayout.contains($0))
        }
        accountTitle = account.identity.name ?? "Unknown account"; accountPlan = account.identity.plan; accountSource = account.identity.source
        let items: [(SunHoverActionKey, SunHoverAction, String, Bool)] = [(.profile, .profile, accountTitle, false), (.settings, .settings, "Settings…", false),
                        (.shortcuts, .shortcuts, "Keyboard Shortcuts", false), (.collapse, .collapse, "Collapse to Side", false),
                        (.signOut, .signOut, "Sign Out", true)]
        accountItems = items.map { key, action, title, divider in
            .init(action: action, title: title, enabled: accountActions.contains(key), dividerBefore: divider)
        }
    }
}
enum SunHoverActionKey: Hashable { case profile, settings, shortcuts, collapse, signOut }

struct SunHoverUsagePanel {
    struct Row {
        let title: String
        let used: Double?
        let resetsAt: Date?
        var percentage: String { used.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
        var detail: String { used == nil ? "Not reported" : percentage }
    }
    let accountVersion: UInt64
    let currentConversationID: String?
    let rows: [Row]
    /// B passes current (the key column), never Peek's transient conversation.
    @MainActor init(account: AccountUsage, current: Conversation?) {
        accountVersion = account.version; currentConversationID = current?.id
        func title(_ window: AccountUsage.Window, fallback: String) -> String {
            guard let minutes = window.windowMinutes else { return fallback }
            if minutes == 10_080 { return "Weekly limit" }
            if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day limit" }
            if minutes % 60 == 0 { return "\(minutes / 60)-hour limit" }
            return "\(minutes)-minute limit"
        }
        var result = [Row(title: title(account.primary, fallback: "Primary limit"), used: account.primary.used, resetsAt: account.primary.resetsAt),
                      Row(title: title(account.secondary, fallback: "Secondary limit"), used: account.secondary.used, resetsAt: account.secondary.resetsAt)]
        var context: Double?
        if let current, current.backendThreadID != nil || current.items.contains(where: { $0.rowKind == .user }),
           let used = current.exactTokensUsed, used >= 0, let limit = current.contextLimit, limit > 0 {
            context = min(1, Double(used) / Double(limit))
        }
        result.append(.init(title: "Context, this conversation", used: context, resetsAt: nil)); rows = result
    }
}

// The dock's other ways in (OrganicDockProjection, OrganicDockBridge): me's account menu and quota card, a node's
// right-click menu, the sub-agents sheet, and VoiceOver's buttons with actions in place of the gestures (f008, f057,
// f073, f120, f197).

/// A menu item that runs a closure.
@MainActor final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func fire() { run() }
}

/// One dock node as VoiceOver sees it: a button over the node's current frame, pressing what a click does.
@MainActor final class DockElement: NSAccessibilityElement {
    weak var host: NSView?
    var frameInHost: () -> CGRect = { .zero }
    var press: () -> Bool = { false }
    override func accessibilityFrame() -> NSRect {
        guard let host else { return .zero }
        return NSAccessibility.screenRect(fromView: host, rect: frameInHost())
    }
    override func accessibilityParent() -> Any? { host }
    override func accessibilityPerformPress() -> Bool { press() }
}

extension AutoScene {
    // MARK: me (f008, f057)

    /// me's account menu and quota card (Sol's OrbMeController): the account's name and plan, and the tightest limits.
    func meModel() -> OrbMeController.Model {
        func shown(_ used: Double) -> Double { Double(Conversation.percent(used)) / 100 }
        // Reset dates and window lengths as reported (DockItems quota card; organic audit B14).
        let quota = OrbQuota(primaryUsed: store.quotaFiveHourReported ? shown(store.quotaFiveHour) : nil,
                             secondaryUsed: store.quotaWeekReported ? shown(store.quotaWeek) : nil,
                             primaryResetsAt: store.quotaFiveHourResetsAt, secondaryResetsAt: store.quotaWeekResetsAt,
                             primaryWindowMinutes: store.quotaFiveHourWindowMinutes, secondaryWindowMinutes: store.quotaWeekWindowMinutes)
        let identity = store.accountUsage.identity
        return .init(name: identity.name ?? "Unknown account", plan: identity.plan ?? "Plan not reported", quota: quota, organic: true, fullyFocused: fullyFocused)
    }

    /// Whether `p` is on me (SunHover02's 48 x 48 hit area).
    func isMe(at p: CGPoint) -> Bool { dock.draggable(at: p) == DockNode.meID }

    /// A click on me: the account menu, above it (OrganicDockProjection click).
    func meClicked() {
        if let sunHover { sunHover.llClick(); return }
        guard let frame = dock.meFrame else { return }
        meController.update(meModel())
        meController.presentAccountMenu(anchor: frame, in: overlayPlane)
    }

    /// The pointer over me for half a second shows the quota card; leaving, pressing or dragging takes it away.
    func meHover(_ p: CGPoint?) {
        if let sunHover {
            let point = p == nil && drag?.id == DockNode.meID && drag?.began == false ? lastPointer : p
            sunHover.pointerChanged(point); return
        }
        let inside = p.map { isMe(at: $0) } ?? false
        guard inside != meHovered, let frame = dock.meFrame else { return }
        meHovered = inside
        if inside { meController.update(meModel()) }
        meController.hover(inside, anchor: frame, in: overlayPlane)
    }

    // MARK: A node's menu (f073)

    /// Right-click on a dock node: me's account menu, or the conversation's (OrganicDockBridge.identityMenu):
    /// Customize Chat…, its symbol, its colour, and its sub-agents.
    func contextMenu(at p: CGPoint) -> NSMenu? {
        if isMe(at: p) { sunHover?.retire(); meController.update(meModel()); return meController.makeAccountMenu() }
        guard let id = dock.hoverNode(at: p)?.id, let c = conversation(id) else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(ActionMenuItem("Customize Chat…") { [weak self] in self?.customize(id) })
        let identity = orbIdentity(of: c)
        let symbols = NSMenu()
        for bodyID in BodyIdentityAdapter.choices {
            let item = ActionMenuItem(bodyID.capitalized) { [weak self] in self?.setIdentity(id, bodyID:bodyID) }
            item.isEnabled=store.canSelectBodyIdentity
            item.image = BodyResources.shared.menuImage(bodyID); item.state = identity.resolvedBodyID == bodyID ? .on : .off
            symbols.addItem(item)
        }
        let symbolItem = NSMenuItem(title: "Symbol", action: nil, keyEquivalent: ""); symbolItem.submenu = symbols; menu.addItem(symbolItem)
        let colors = NSMenu()
        for tint in OrbTint.allCases {
            let item = ActionMenuItem(String(describing: tint).capitalized) { [weak self] in self?.setIdentity(id, tint: tint) }
            item.image = Self.swatchImage(tint); item.state = (identity.tintID ?? String(describing:identity.tint)) == String(describing:tint) ? .on : .off
            colors.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: ""); colorItem.submenu = colors; menu.addItem(colorItem)
        if !c.satellites.isEmpty {
            menu.addItem(ActionMenuItem("Show Sub-agents") { [weak self] in
                guard let self, let frame = self.dock.frame(of: id) else { return }
                self.showSubAgents(id, from: frame, upward: true)
            })
        }
        return menu
    }

    /// The symbol or the colour alone, as Customize writes them (Core identitySymbol / identityTint).
    func setIdentity(_ id: String, symbol: OrbCelestialBody? = nil, tint: OrbTint? = nil, bodyID: String? = nil) {
        guard let c = conversation(id),store.canSelectBodyIdentity else { return }
        let bodyID=bodyID ?? symbol.map { String(describing:$0) }
        if let bodyID { guard BodyIdentityAdapter.choices.contains(bodyID) else { return }; c.identitySymbol=bodyID }
        if let tint { c.identityTint = String(describing: tint) }
        store.changed(c)
        onIdentityChanged?(c)
        dock.refreshOrbs()
    }

    /// The planet's glyph as a template image, as the product's Identity.menuImage.
    static func menuImage(_ symbol: OrbCelestialBody) -> NSImage {
        BodyResources.shared.menuImage(String(describing:symbol)) ?? NSImage(size:CGSize(width:16,height:16))
    }

    /// The colour as a filled dot, as the product's Identity.swatchImage.
    static func swatchImage(_ tint: OrbTint) -> NSImage {
        NSImage(size: CGSize(width: 14, height: 14), flipped: false) { rect in
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { tint.color.setFill() }
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
    }

    // MARK: Sub-agents sheet (f120)

    /// The sub-agents sheet (SubAgentsOpener): from `anchor` (scene coordinates), up or down, starting on `select`; a
    /// row opens that sub-agent's read-only window. A peek closes first.
    func showSubAgents(_ id: String, from anchor: CGRect, upward: Bool, select: String? = nil, in host: NSView? = nil) {
        guard let c = conversation(id), !c.satellites.isEmpty, (host ?? sceneView).window != nil else { return }
        dismissPeek()
        subAgentsSheet.resolveIdentity = { orbIdentity(of: $0) }
        subAgentsSheet.onOpenWindow = { [weak self] sub, c in self?.subAgentWindows.present(subagentID: sub, of: c) }
        subAgentsSheet.present(conversation: c, anchor: anchor, upward: upward, in: host ?? overlayPlane, select: select)
    }

    // MARK: VoiceOver (f197)

    /// What an orb reads (OrbStack.spokenLabel): its title, its state, its badge, its running sub-agents.
    static func spokenLabel(_ c: Conversation) -> String {
        var parts = [c.title]
        if !c.approvals.isEmpty { parts.append("waiting for approval") }
        else if c.running { parts.append("running") }
        else if c.question != nil { parts.append("asking") }
        else if c.error == .stopped { parts.append("stopped") }
        else { parts.append("idle") }
        if let badge = c.badge, !badge.meaning.isEmpty { parts.append(badge.meaning) }
        let running = c.satellitesRetired ? 0 : c.runningSatellites
        if running > 0 { parts.append(running == 1 ? "1 sub-agent running" : "\(running) sub-agents running") }
        return parts.joined(separator: ", ")
    }

    /// me, each bar and each orb as a button, in dock order, with the product's actions: in Auto an orb shows full or
    /// is focused, a bar is focused; in Focused an orb joins the Split and a Split member leaves it; me leaves Focused.
    func dockAccessibilityChildren() -> [Any] {
        func element(_ id: String) -> DockElement {
            if let e = accessibilityNodes[id] { return e }
            let e = DockElement()
            e.host = dockView
            e.setAccessibilityRole(.button)
            accessibilityNodes[id] = e
            return e
        }
        func action(_ name: String, _ run: @escaping @MainActor () -> Void) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: name) { run(); return true }
        }
        var out: [DockElement] = []
        let focused = scheme.mode == .focused
        let me = element(DockNode.meID)
        me.frameInHost = { [weak self] in self?.dock.meFrame ?? .zero }
        me.setAccessibilityLabel(focused ? "Me, in the bar" : "Me. Account and settings")
        me.press = { [weak self] in self?.meClicked(); return true }
        me.setAccessibilityCustomActions(focused ? [action("Leave Focused") { [weak self] in self?.leaveFocused(reason: "accessibility") }] : [])
        out.append(me)
        for id in order {
            guard let c = conversation(id), let item = dock.items[id] else { continue }
            let e = element(id)
            e.frameInHost = { [weak self] in self?.dock.frame(of: id) ?? .zero }
            if focused && scheme.split.contains(id) {
                e.setAccessibilityLabel(scheme.split.count > 1 ? "\(c.title), in Split" : c.title)
                e.press = { [weak self] in self?.focusMember(id); return true }
                e.setAccessibilityCustomActions(scheme.split.count > 1 ? [action("Remove from Split") { [weak self] in self?.ungraft(id, reason: "accessibility") }] : [])
            } else if focused {
                e.setAccessibilityLabel(Self.spokenLabel(c))
                let add: @MainActor () -> Void = { [weak self] in guard let self else { return }; self.graft(id, at: self.scheme.split.count, reason: "accessibility") }
                e.press = { add(); return true }
                e.setAccessibilityCustomActions([action("Add to Split", add)])
            } else if item.role == .bar {
                e.setAccessibilityLabel(id == current ? "Move \(c.title)" : "Move \(c.title), brief")
                e.press = { [weak self] in self?.activate(id, reason: "accessibility"); return true }
                e.setAccessibilityCustomActions([action("Focus") { [weak self] in self?.enterFocused(id, reason: "accessibility") }])
            } else {
                e.setAccessibilityLabel(Self.spokenLabel(c))
                e.press = { [weak self] in self?.land(id, reason: "accessibility"); return true }
                e.setAccessibilityCustomActions([action("Show Full") { [weak self] in self?.land(id, reason: "accessibility") },
                                                 action("Focus") { [weak self] in self?.enterFocused(id, reason: "accessibility") }])
            }
            out.append(e)
        }
        let shown = Set(out.compactMap { e in accessibilityNodes.first { $0.value === e }?.key })
        accessibilityNodes = accessibilityNodes.filter { shown.contains($0.key) }
        return out
    }
}
