import AppKit

/// SidebarView's IdentityMenuItems. Identity is local presentation state; Customize's sheet belongs to the host.
@MainActor extension NormieSidebarController {
    func appendIdentityMenu(to menu: NSMenu, conversation c: Conversation) {
        menu.addItem(NormieMenuItem("Customize Chat…", enabled: onCustomize != nil) { [weak self, weak c] in
            guard let self, let c, self.model.store.conversation(c.id) === c else { return }
            self.onCustomize?(c)
        })
        let identity = NormieDrawing.identity(c), symbols = NSMenu(title: "Symbol"), colors = NSMenu(title: "Color")
        symbols.autoenablesItems = false; colors.autoenablesItems = false
        for symbol in OrbCelestialBody.allCases {
            let item = NormieMenuItem(symbol.name) { [weak self, weak c] in
                guard let self, let c, self.model.store.conversation(c.id) === c else { return }
                c.identitySymbol = String(describing: symbol); self.model.store.changed(c); self.model.refresh()
            }
            item.state = identity.symbol == symbol ? .on : .off
            let path = OrbCelestialGlyph(symbol: symbol).path(in: CGRect(x: 0, y: 0, width: 16, height: 16)).cgPath
            item.image = NSImage(size: CGSize(width: 16, height: 16), flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.addPath(path); context.setStrokeColor(NSColor.black.cgColor)
                context.setLineWidth(16.0 / 24.0 * 1.9); context.setLineCap(.round); context.setLineJoin(.round); context.strokePath(); return true
            }
            item.image?.isTemplate = true; symbols.addItem(item)
        }
        for tint in OrbTint.allCases {
            let item = NormieMenuItem(String(describing: tint).capitalized) { [weak self, weak c] in
                guard let self, let c, self.model.store.conversation(c.id) === c else { return }
                c.identityTint = String(describing: tint); self.model.store.changed(c); self.model.refresh()
            }
            item.state = identity.tint == tint ? .on : .off
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
