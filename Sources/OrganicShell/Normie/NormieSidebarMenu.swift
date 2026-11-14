import AppKit

/// SidebarView's IdentityMenuItems. Identity is local presentation state; Customize's sheet belongs to the host.
@MainActor extension NormieSidebarController {
    func appendIdentityMenu(to menu: NSMenu, conversation c: Conversation) {
        menu.addItem(NormieMenuItem("Customize Chat…", enabled: onCustomize != nil && model.store.canSelectBodyIdentity) { [weak self, weak c] in
            guard let self, let c,self.model.store.canSelectBodyIdentity, self.model.store.conversation(c.id) === c else { return }
            self.onCustomize?(c)
        })
        let identity = NormieDrawing.identity(c), symbols = NSMenu(title: "Symbol"), colors = NSMenu(title: "Color")
        symbols.autoenablesItems = false; colors.autoenablesItems = false
        for bodyID in BodyIdentityAdapter.choices {
            let item = NormieMenuItem(bodyID.capitalized,enabled:model.store.canSelectBodyIdentity) { [weak self, weak c] in
                guard let self, let c, self.model.store.canSelectBodyIdentity,self.model.store.conversation(c.id) === c else { return }
                c.identitySymbol = bodyID; self.model.store.changed(c); self.model.refresh()
            }
            item.state = identity.resolvedBodyID == bodyID ? .on : .off
            item.image=BodyResources.shared.menuImage(bodyID); symbols.addItem(item)
        }
        for tint in OrbTint.allCases {
            let item = NormieMenuItem(String(describing: tint).capitalized, enabled:model.store.canSelectBodyIdentity) { [weak self, weak c] in
                guard let self, let c, self.model.store.canSelectBodyIdentity, self.model.store.conversation(c.id) === c else { return }
                c.identityTint = String(describing: tint); self.model.store.changed(c); self.model.refresh()
            }
            item.state = (identity.tintID ?? String(describing:identity.tint)) == String(describing:tint) ? .on : .off
            let color = tint.color
            item.image = NSImage(size: CGSize(width: 16, height: 16), flipped: true) { _ in
                color.setFill(); NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 12, height: 12)).fill(); return true
            }
            colors.addItem(item)
        }
        let symbol = NSMenuItem(title: "Symbol", action: nil, keyEquivalent: ""); symbol.submenu = symbols
        let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: ""); color.submenu = colors
        menu.addItem(symbol); menu.addItem(color)
    }
}
