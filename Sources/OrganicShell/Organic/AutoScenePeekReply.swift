import AppKit

extension AutoScene {
    func projectPeekReply(id: String?, size: CGSize) {
        guard let id, peeking == id, peekOpen, let c = conversation(id),
              orbMenuPeekColumn == id || dock.items[id]?.role == .orb else { return retirePeekReply() }
        if let host = peekReply, host.id == id, host.isCurrent { return }
        retirePeekReply()
        let lookup = M10ColumnWorkTrace.scope("peek.reply.lookup")
        let composer = composer(for: c); lookup.end()
        let host = orbMenuPeekColumn == id ? dock.mountColumnReply(composer, id: id)
            : dock.mountPeekReply(composer, id: id, size: size)
        guard let host else { return peekNode.setReplyPassage(.zero) }
        peekReply = host
        if host.isColumn {
            dock.tideCanDismiss = { [weak self] in
                guard let self else { return false }
                if let host = self.peekReply, host.isColumn, host.isCurrent { return false }
                return !self.tideHasForegroundSurface
            }
        }
        for island in columns.compactMap(\.island) + [peekNode.header] {
            island.yieldPeekReplyEscape = { [weak self, weak host] in
                guard let self, let host, host.isColumn, host.isCurrent, self.peeking == host.id,
                      let responder = host.composer.window?.firstResponder as? NSView else { return false }
                return responder === host.composer || responder.isDescendant(of: host.composer)
            }
        }
        host.onGeometry = { [weak self, weak host] rect in
            guard let self, self.peekReply === host else { return }
            self.peekNode.setReplyPassage(rect)
        }
        host.onRetire = { [weak self] retired in
            guard let self, self.peekReply === retired else { return }
            self.peekReply = nil; self.peekNode.setReplyPassage(.zero); self.syncPeekIslandHold()
        }
        host.onHold = { [weak self] in self?.syncPeekIslandHold() }
        host.onCancel = { [weak self] in self?.setPeeking(nil) }
        let interaction = M10ColumnWorkTrace.scope("peek.reply.interaction")
        host.install(); interaction.end()
        host.superview?.alphaValue = peekContentVisible ? 1 : 0
        // No focus request at mount. The ordinary native controls and blank host click own focus.
        syncPeekIslandHold()
    }
    func retirePeekReply(animated: Bool = false) {
        let old = peekReply; peekReply = nil
        let work = old.map { _ in M10ColumnWorkTrace.scope("peek.reply.retire") }; defer { work?.end() }
        dock.retirePeekReply(fadeDuration: animated ? 0.07 : 0); old?.retire()
        peekNode.setReplyPassage(.zero); syncPeekIslandHold()
    }
    var peekReplyFrame: CGRect? {
        guard let host = peekReply, host.isCurrent else { return nil }
        if let p = host.parent {
            return dockView.convert(host.composer.frame.intersection(p.bounds), from: p).intersection(dockView.bounds)
        }
        guard let parent = host.superview else { return nil }
        return dockView.convert(host.bounds, from: host).intersection(dockView.convert(parent.bounds, from: parent))
    }
}
