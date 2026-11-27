import AppKit
import QuartzCore

extension DockNode {
    /// Admission is separate from projection: neither a display tick nor a content refresh remounts input.
    func mountPeekReply(_ composer: NativeComposer, id: String, size: CGSize) -> PeekReplyHost? {
        guard let item = items[id], item.role == .orb,
              composer.superview == nil || composer.superview === item.barFace else { return nil }
        let work = M10ColumnWorkTrace.scope("peek.reply.mount"); defer { work.end() }
        retirePeekReply()
        let host = PeekReplyHost(id: id, composer: composer, size: size)
        item.composer = composer
        watchTideEditor(composer)
        item.peekFace.addSubview(host)
        composer.removeFromSuperview(); host.addSubview(composer)
        let presentation = M10ColumnWorkTrace.scope("peek.reply.presentation")
        composer.configurePresentation {
            composer.segment = nil; composer.targetWidth = size.width
            composer.frame = host.bounds; composer.alphaValue = 1; composer.isHidden = false
        }
        composer.layoutSubtreeIfNeeded()
        presentation.end()
        let register = M10ColumnWorkTrace.scope("peek.reply.exposure.register")
        composerMotion.prepare(composer, registerOnly: true)
        register.end()
        host.returnComposer = { [weak self, weak item] source in
            guard let self, let item, self.items[id] === item else { return }
            self.composerMotion.cancelGaussian(source)
            self.restorePeekComposer(source, to: item)
        }
        peekReplyHost = host
        return host
    }
    func mountColumnReply(_ composer: NativeComposer, id: String) -> PeekReplyHost? {
        guard let item = items[id], item.role == .bar else { return nil }
        retirePeekReply()
        let (role, leading, controls) = columnReplyFacts(item)
        let clipped = item.barFace.bounds.intersection(item.barFace.convert(view.bounds, from: view))
        let segment = controls.map { PeekReplyBarTarget.Segment(frame: item.barFace.bounds, controls: $0) }
        let target = PeekReplyBarTarget.resolve(clippedBar: clipped, role: role, leading: leading, segment: segment,
            browserCovered: browserDockPort?.coversMember(id) == true,
            normieTakeover: composer.superview != nil && composer.superview !== item.barFace)
        let host = PeekReplyHost(id: id, composer: composer, size: item.barFace.bounds.size, parent: item.barFace)
        switch target {
        case .rejected: return nil
        case .inPlace:
            guard composer.superview === item.barFace else { return nil }
        case .borrow(let placement):
            let frame = composer.frame, width = composer.targetWidth, segment = composer.segment
            let wasInBar = composer.superview === item.barFace
            if !wasInBar { item.barFace.addSubview(composer) }
            composer.configurePresentation {
                composer.segment = nil
                composer.targetWidth = placement.editorFrame.width
                composer.frame = placement.editorFrame
                composer.alphaValue = 1
                composer.isHidden = false
            }
            composer.layoutSubtreeIfNeeded()
            item.label.alphaValue = 0
            host.returnComposer = { [weak self, weak item] source in
                guard let self, let item, self.items[id] === item else { return }
                self.composerMotion.cancelGaussian(source)
                source.configurePresentation {
                    source.frame = frame
                    source.targetWidth = width
                    source.segment = segment
                }
                source.alphaValue = item.full ? 1 : 0
                source.isHidden = !item.full && !source.isComposing
                item.label.alphaValue = item.full ? 0 : 1
            }
        }
        item.composer = composer
        watchTideEditor(composer)
        composerMotion.prepare(composer, registerOnly: true)
        peekReplyHost = host
        return host
    }
    func borrowsColumn(_ id: String) -> Bool { peekReplyHost?.id == id &&
        peekReplyHost?.isColumn == true && peekReplyHost?.returnComposer != nil }
    func retirePeekReply(fadeDuration: Double = 0) {
        let previous = peekReplyHost; peekReplyHost = nil
        if let previous {
            composerMotion.cancelGaussian(previous.composer)
            previous.retire(fadeDuration: fadeDuration)
        }
    }
    /// Chrome already receives the logical-to-painted shift. Never apply the glass batch's pendingShift twice.
    func placePeekReply(_ item: Item, logical: CGRect, chrome: CGRect) -> NativeComposer? {
        guard let host = peekReplyHost, host.id == item.conversation.id, host.isCurrent else { return nil }
        host.place(origin: CGPoint(x: logical.minX-chrome.minX, y: logical.minY-chrome.minY),
                   visible: chrome, in: view)
        return host.composer
    }
    func fadePeekReply(_ item: Item? = nil, visible: Bool, duration: Double) {
        guard let face = item?.peekFace ?? peekShown.flatMap({ items[$0]?.peekFace }),
              let layer = face.layer else { return }
        let curve = OverlayCurve(0, 0, 0.58, 1, duration)
        face.alphaValue = visible ? 1 : 0
        OverlayMotion.animate(layer, "opacity", from: layer.opacity, to: Float(visible ? 1 : 0), curve: curve)
    }
}
