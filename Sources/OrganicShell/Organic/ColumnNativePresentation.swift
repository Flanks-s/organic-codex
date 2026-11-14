import AppKit
import QuartzCore
import CoreText

extension ColumnNode {
    /// A node may outlive its mount (Normie, Collapse or another window now owns it).
    var ownsNative: Bool { !sharedTranscript || (nativeLease?.isCurrent == true && !modeSuspended) }

    @discardableResult func mountNative(in host: NSView, configuration: NativeTranscriptSessions.Configuration, frame: CGRect? = nil, visible: Bool = true) -> Bool {
        let visible = visible && browserAttachment?.covers != true
        guard sharedTranscript else { if native.superview !== host { host.addSubview(native) }; return true }
        if nativeLease?.isCurrent == true {
            if let frame {_=nativeLease?.place(frame)}
            modeSuspended=false;_ = nativeLease?.setActive(visible)
            return true
        }
        guard let owner = transcriptSessions, owner.existingTranscript(for: conversation.id) === native,
              let lease = owner.mount(conversation, in: host, frame: frame, configuration: configuration, visible: visible) else { return false }
        nativeLease = lease
        modeSuspended=false
        let oldMask = native.layer?.mask
        lease.onUnmount { [weak self, weak native] in
            self?.finishContinuedTranscriptFlights(restoringRetiredLease:true)
            native?.layer?.removeAnimation(forKey:"column.motion.tail")
            native?.layer?.mask?.removeAnimation(forKey:"column.motion.crop")
            native?.layer?.mask = oldMask
            native?.layer?.isHidden = false
            // A motion's temporary freeze must not become the next host's policy.
            if let follow = self?.followBeforeMotion { native?.followsEnd = follow }
            self?.followBeforeMotion = nil
        }
        native.wantsLayer = true; native.layer?.mask = Self.fade()
        invalidateCaptures()
        return true
    }
    func unmountNative() {
        if ownsNative {endTranscriptMotion()}
        if let lease = nativeLease { _ = transcriptSessions?.unmount(lease) }
        nativeLease = nil
        modeSuspended=false
    }
    /// Revoke presentation cheaply. The next semantic mount retires this lease once, at its final target frame.
    /// A suspended column cannot lay out or capture the borrowed viewport from an idle/resize callback.
    func suspendNativeForMode() {
        guard sharedTranscript, let lease=nativeLease,lease.isCurrent else{return}
        endTranscriptMotion()
        _=lease.setActive(false);_=lease.setVisible(false);modeSuspended=true
    }
    func suspendNative() { setNative(visible: false) }
    private func placeNative(_ frame: CGRect) {
        if sharedTranscript { _ = nativeLease?.place(frame) }
        else { native.frame = frame }
    }
    func positionNative(_ origin: CGPoint) {
        guard ownsNative else { return }
        if sharedTranscript { placeNative(CGRect(origin: origin, size: native.frame.size)) }
        else { native.setFrameOrigin(origin) }
    }
    /// Tests have no window: at rest they show the native capture (with the goal) instead of the view.

    /// At rest while the window is being resized: the native view laid out and the brief drawn for these widths, with no
    /// captures (those are prepared only when an actual morph needs them).
    func restLayout(fullWidth: CGFloat, briefWidth: CGFloat) {
        displayWidths = (fullWidth, briefWidth)
        // Keep legacy owned first-mount geometry warm for the bounded idle-preparation contract. Later brief deltas
        // do not resize or refresh the hidden full transcript.
        if isFull || (!sharedTranscript && native.frame.size == .zero) { layoutNative(fullWidth: fullWidth) }
        let top = fullContentTop - 18
        let area = CGRect(x: 0, y: top, width: fullWidth, height: logicalBottom + 22 - top)
        let bw = max(60, briefWidth - 40)
        let layout = modeBrief(boundedSummary(columnWidth:briefWidth),width:bw,columnWidth:briefWidth)
        let clipTop = Look.contentTop.brief - 18, briefTop = logicalBottom - 22 - layout.height
        transcriptClip.frame = area
        shapeFade(transcriptClip.mask, area.size)
        if ownsNative { shapeFade(native.layer?.mask, area.size) }
        nativeArea = area
        positionNative(CGPoint(x: card.position.x + area.minX, y: card.position.y + area.minY))
        let clip = CGRect(x: 20, y: clipTop, width: bw, height: max(1, sceneHeight - clipTop))
        brief.frame = clip
        briefFade.frame = CGRect(origin: .zero, size: clip.size)
        briefFade.locations = [0, NSNumber(value: Double(16 / max(16, clip.height)))]
        // Lines move, they don't jump: what streaming added, at rest or during a transition (product: OrganicColumn's lyrics).
        let lift: CGFloat? = !isFull && !Motion.reduce && briefContent.frame.width == bw ? briefContent.frame.minY - (briefTop - clipTop) : nil
        // A new width rewraps the lines, and they can't move to their new places: the old wrap fades out and the new comes in, as a full
        // column's does (#43). It was one frame (board 10-31).
        let rewrap = !isFull && !Motion.reduce && brief.opacity > 0.5 && briefContent.frame.width != bw ? briefRewrapGhost() : nil
        briefContent.frame = CGRect(x: 0, y: briefTop - clipTop, width: bw, height: max(1, layout.height))
        applyBrief(layout, lift: lift)
        if let rewrap { Self.crossfadeBrief(rewrap, into: briefContent) }
        flownParts = []; pieces = []
        lyricSize = layout.lyricStyle.font.pointSize
        applied = nil
    }

    /// Lays out both forms for these widths, if the content or the widths changed.
    /// Sizes the native view for a full width and lays it out (without a window a new size does not lay the
    /// view out by itself); the first layout starts at the end.
    func layoutNative(fullWidth: CGFloat, contentTop: CGFloat? = nil) {
        guard ownsNative else { return }
        // Product OrganicColumn shows a question card only for a real UserInputRequest.
        // The paused C fixture has only the legacy status string, with no answer form.
        native.decisionCardsAtBottom = !conversation.approvals.isEmpty || conversation.userInput != nil
        let top = (contentTop ?? fullContentTop) - 18
        let size = CGSize(width: (fullWidth * scale).rounded() / scale, height: ((logicalBottom + 22 - top) * scale).rounded() / scale)
        guard native.frame.size != size else { return }
        let first = native.frame.size == .zero
        if !hasSnapshotContent {
            // An empty first-send viewport needs one native layout, without first displaying an empty surface.
            native.configurePresentation(allowHidden:true) {
                if sharedTranscript {placeNative(CGRect(origin:native.frame.origin,size:size))}
                else {native.setFrameSize(size)}
            }
        } else if sharedTranscript {placeNative(CGRect(origin:native.frame.origin,size:size))}
        else {native.setFrameSize(size)}
        // This is an explicit admitted capture/reflow, including an ordered-out window. Deferring until snapshot()
        // would preserve the old narrow viewport's pixel offset rather than its reading anchor at the new width.
        // A borrowed Normie/Collapse view never reaches this path (ownsNative above).
        native.refresh(preservingOffset: first ? false : nil, allowHidden: sharedTranscript)
        native.layoutSubtreeIfNeeded()
        if first { native.scrollToEnd() }
    }

    /// The native view's scroll, for checking that a capture prepared earlier still shows what is on screen.
    var nativeState: Int { (Int(native.scrollOffset.y.rounded()) &* 31 &+ Int(native.contentHeight.rounded())) &* 31 &+ native.captureRevision }

    /// Native display is current without preparing screenshots for a hypothetical future morph.
    /// Only use outside a text flight/full reflow; those retain their frozen source until settle.
    func renderDisplay(fullWidth:CGFloat,briefWidth:CGFloat,holdScroll:Bool=false,force:Bool=false) {
        resolveIdleRowConfiguration()
        if restOnSnapshot { render(fullWidth:fullWidth,briefWidth:briefWidth,holdScroll:holdScroll,force:force);return }
        let work=M10ColumnWorkTrace.scope("column.nativeUpdate",["id":conversation.id]);defer{work.end()}
        if isFull || (!sharedTranscript && native.frame.size == .zero) { layoutNative(fullWidth:fullWidth) }
        if isFull, ownsNative, native.renderedRevision != conversation.revision || native.refreshDeferred {
            native.refresh(preservingOffset:holdScroll ? true:nil,allowHidden:sharedTranscript)
        }
        if isFull {
            displayWidths=(fullWidth,briefWidth)
            let top=fullContentTop-18
            let area=CGRect(x:0,y:top,width:fullWidth,height:logicalBottom+22-top)
            transcriptClip.frame=area;shapeFade(transcriptClip.mask,area.size)
            if ownsNative {shapeFade(native.layer?.mask,area.size)}
            nativeArea=area
            positionNative(CGPoint(x:card.position.x+area.minX,y:card.position.y+area.minY))
            applied=nil;flownParts=[];pieces=[]
        } else {restLayout(fullWidth:fullWidth,briefWidth:briefWidth)}
        // Keep the source image on the layer until this transaction ends, but never reuse it for a later departure.
        restWithGoal=nil;motionBase=nil
        needsReanchor=holdScroll
    }

    func render(fullWidth: CGFloat, briefWidth: CGFloat, holdScroll: Bool = false, force: Bool = false) {
        let s = snapshot(fullWidth: fullWidth, briefWidth: briefWidth)
        if !force, !holdScroll, applied == s.key { return }
        apply(s, holdScroll: holdScroll)
    }

    func applyBrief(_ layout: BriefLayout, lift: CGFloat? = nil) {
        var kept: [String: CALayer] = [:]
        restOpacity = [:]
        let lastLine = layout.parts.map(\.line).max() ?? 0
        // How far each line that is already there moves. A row new in such a line goes with it, as in the product's stack:
        // rising on its own, it came up through the line above (board 10-31).
        var lineMove: [Int: CGFloat] = [:]
        if let lift { for part in layout.parts where lineMove[part.line] == nil { if let known = briefLayers[part.id] { lineMove[part.line] = known.frame.minY + lift - part.frame.minY } } }
        for part in layout.parts {
            let known = briefLayers[part.id]
            let layer = known ?? CALayer()
            let wasY = layer.frame.minY
            layer.anchorPoint = .zero
            layer.frame = part.frame
            if let lift {
                // The nearest line first, each line above 30 ms later.
                let delay = Double(min(max(0, lastLine - part.line), 8)) * 0.03
                if known != nil { Self.liftBrief(layer, by: wasY + lift - part.frame.minY, delay: delay) }
                else if let move = lineMove[part.line] { Self.liftBrief(layer, by: move, delay: delay); Self.fadeInBrief(layer, delay: delay) }
                else { Self.bringInBrief(layer, delay: delay) }
            } else if known != nil { Self.stopBriefMotion(layer) }
            // The text is a child, so a flight can stand in for it while the part's dots stay (they reveal with the brief).
            let text = (layer.sublayers?.first { $0.name == "text" }) ?? CALayer()
            text.name = "text"
            text.anchorPoint = .zero
            text.contentsScale = scale
            text.contentsGravity = .resize
            text.contents = part.image
            text.frame = CGRect(origin: .zero, size: part.frame.size)
            text.opacity = 1
            if text.superlayer == nil { layer.insertSublayer(text, at: 0) }
            let opacity = part.current ? 1 : Look.olderLine
            layer.opacity = opacity
            restOpacity[part.id] = opacity
            let existingDots = layer.sublayers?.first { $0 is DotsLayer && $0.name != Self.dotsLeaving } as? DotsLayer
            if lift != nil, known != nil, part.kind == .lyric, let existingDots {
                // The words, when they come, take the dots' place (product: OrganicColumn's `line.waiting`). It was a one-frame swap.
                Self.letDotsGo(existingDots); Self.riseWords(text, by: 0.2 * layout.lyricStyle.font.pointSize)
            } else if let dots = part.dots {
                let d = existingDots ?? DotsLayer()
                if d.superlayer == nil { layer.addSublayer(d) }
                d.anchorPoint = .zero
                d.frame = dots.frame
                d.configure(dots.size, color: part.kind == .dots ? Look.ink : Look.secondary, scale: scale, still: !ambient || Motion.reduce)
            } else {
                existingDots?.removeFromSuperlayer()
            }
            if layer.superlayer == nil { briefContent.addSublayer(layer) }
            kept[part.id] = layer
        }
        for (id, layer) in briefLayers where kept[id] == nil {
            guard let lift else { layer.removeFromSuperlayer(); continue }
            // Going: it stays where it was on screen and fades.
            layer.position.y += lift
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { layer.removeFromSuperlayer() } }
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = layer.opacity; fade.toValue = 0; fade.duration = 0.18
            fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "brief.out")
            CATransaction.commit()
        }
        briefLayers = kept
    }
    /// The old wrap, dots included, in its own clip: the brief's own clip already has the new width, and cut it off mid-word (board 10-31).
    private func briefRewrapGhost() -> CALayer? {
        guard !briefLayers.isEmpty, let parent = brief.superlayer else { return nil }
        let clip = CALayer(); clip.masksToBounds = true
        clip.frame = CGRect(x: brief.frame.minX, y: brief.frame.minY, width: max(brief.frame.width, briefContent.frame.width), height: brief.frame.height)
        let ghost = CALayer(); ghost.frame = briefContent.frame
        for layer in briefLayers.values {
            let copy = CALayer(); copy.frame = layer.frame; copy.opacity = layer.opacity
            if let text = layer.sublayers?.first(where: { $0.name == "text" }), text.contents != nil {
                copy.contents = text.contents; copy.contentsScale = text.contentsScale; copy.contentsGravity = .resize
            }
            if let dots = layer.sublayers?.first(where: { $0 is DotsLayer && $0.name != Self.dotsLeaving }) { dots.removeFromSuperlayer(); copy.addSublayer(dots) }
            ghost.addSublayer(copy)
        }
        clip.addSublayer(ghost)
        parent.insertSublayer(clip, below: brief)
        return clip
    }
    private static func crossfadeBrief(_ ghost: CALayer, into content: CALayer) {
        // One after the other, nearly: together they were 0.2 s of two wraps over each other, unreadable (board 10-31).
        let out = CABasicAnimation(keyPath: "opacity"); out.fromValue = 1; out.toValue = 0; out.duration = 0.09
        out.fillMode = .forwards; out.isRemovedOnCompletion = false
        ModeSignposts.frameRange(out)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { ghost.removeFromSuperlayer() } }
        ghost.add(out, forKey: "brief.rewrap.out")
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.14
        fade.beginTime = CACurrentMediaTime() + 0.07; fade.fillMode = .backwards
        ModeSignposts.frameRange(fade)
        content.add(fade, forKey: "brief.rewrap.in")
    }
    private func slideFromMotionOffset() {
        defer { motionOffset = nil }
        guard let motionOffset, !Motion.reduce, !restOnSnapshot, let layer = native.layer else { return }
        let distance = native.scrollOffset.y - motionOffset
        guard abs(distance) > 0.5, abs(distance) < 120 else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.isAdditive = true; slide.fromValue = distance; slide.toValue = 0; slide.duration = 0.22
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // From now, filling back: left to commit time, a late commit showed the end for a frame first (board 10-31).
        slide.beginTime = CACurrentMediaTime(); slide.fillMode = .backwards
        ModeSignposts.frameRange(slide)
        layer.add(slide, forKey: "column.settle.slide")
    }
    /// A hidden transcript that was at its end catches up to its end before its picture is taken. Held where it was, the picture
    /// of the way back to full showed Jump to Latest and stale rows, then one hard jump at settle (board 10-31). Not during the
    /// motion (`followBeforeMotion` is set then): a picture at a new offset under flights already on their way drew text over text.
    var catchUpHoldsOffset: Bool { !(native.isHidden && followBeforeMotion == nil && atEndBeforeMotion != false && native.shouldFollowEnd) }
    /// The lyrics' spring: unhurried, no overshoot.
    private static func lyricSpring(_ key: String) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: key), omega = 2 * Double.pi / 0.55
        spring.mass = 1; spring.stiffness = omega * omega; spring.damping = 2 * 0.92 * omega; spring.duration = spring.settlingDuration
        return spring
    }
    private static func liftBrief(_ layer: CALayer, by distance: CGFloat, delay: Double) {
        guard abs(distance) > 0.5 else { return }
        let spring = lyricSpring("position.y")
        spring.isAdditive = true; spring.fromValue = distance; spring.toValue = 0
        // Always from now, filling back: left to commit time, the first frame could show the end of the move (board 10-31).
        spring.beginTime = CACurrentMediaTime() + delay; spring.fillMode = CAMediaTimingFillMode.backwards
        ModeSignposts.frameRange(spring)
        briefMotionSerial &+= 1
        layer.add(spring, forKey: "brief.lift.\(briefMotionSerial)")
    }
    /// A new line rises in (product `LyricIn`, its 3 pt blur left out: a filter per line isn't worth it here).
    private static func bringInBrief(_ layer: CALayer, delay: Double) {
        liftBrief(layer, by: 18, delay: delay)
        fadeInBrief(layer, delay: delay)
    }
    private static func fadeInBrief(_ layer: CALayer, delay: Double) {
        let fade = lyricSpring("opacity")
        fade.isAdditive = true; fade.fromValue = -layer.opacity; fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + delay; fade.fillMode = CAMediaTimingFillMode.backwards
        ModeSignposts.frameRange(fade)
        layer.add(fade, forKey: "brief.in")
    }
    /// The dots swell and go (scale 1.32 from the leading edge, 0.3 s).
    private static func letDotsGo(_ dots: DotsLayer) {
        dots.name = dotsLeaving
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let frame = dots.frame
        dots.anchorPoint = CGPoint(x: 0, y: 0.5); dots.frame = frame
        CATransaction.commit()
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 1; scale.toValue = 1.32
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup(); group.animations = [scale, fade]; group.duration = 0.3
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards; group.isRemovedOnCompletion = false
        ModeSignposts.frameRange(group)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { dots.removeFromSuperlayer() } }
        dots.add(group, forKey: "brief.dots.out")
        CATransaction.commit()
    }
    /// The words rise in under them: 0.2 of the lyric, fading in, 0.3 s.
    private static func riseWords(_ text: CALayer, by distance: CGFloat) {
        let rise = CABasicAnimation(keyPath: "position.y"); rise.isAdditive = true; rise.fromValue = distance; rise.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity"); fade.isAdditive = true; fade.fromValue = -1; fade.toValue = 0
        let group = CAAnimationGroup(); group.animations = [rise, fade]; group.duration = 0.3
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.beginTime = CACurrentMediaTime(); group.fillMode = .backwards
        ModeSignposts.frameRange(group)
        text.add(group, forKey: "brief.words.in")
    }
    private static func stopBriefMotion(_ layer: CALayer) {
        for key in layer.animationKeys() ?? [] where key.hasPrefix("brief.") { layer.removeAnimation(forKey: key) }
    }
    /// Rest visibility for a form; while moving, the goal's words belong to the flights.
    func showRest(full: Bool) {
        if browserAttachment?.covers == true { setNative(visible: false); return }
        // Capture departure intent before hiding the native view. hideGoal runs after this in commit.
        if ownsNative,!native.isHidden,followBeforeMotion == nil {
            atEndBeforeMotion = native.shouldFollowEnd && native.isAtEnd
        }
        if let reflow=fullReflow,reflow.clipBounds != nil {
            transcriptClip.mask=reflow.previousClipMask
            transcriptClip.bounds=CGRect(origin:.zero,size:nativeArea.size);transcriptClip.position=nativeArea.origin
            shapeFade(transcriptClip.mask,nativeArea.size)
        }
        fullReflow?.layer.removeFromSuperlayer();fullReflow?.overlayLayer?.removeFromSuperlayer();fullReflow = nil; transcript.opacity = 1
        if restOnSnapshot {
            transcript.contents = full ? restWithGoal : motionBase
            transcriptClip.opacity = full ? 1 : 0
            setNative(visible: false)
        } else {
            transcriptClip.opacity = 0
            setNative(visible: full)
        }
        if ownsNative {
            native.followsEnd = followBeforeMotion ?? native.followsEnd
            followBeforeMotion = nil
            // Text that arrived during the motion left it short of the end, and following needs it at the end: it stopped
            // following, with Jump to Latest up, though the reader had done nothing (board 10-31).
            // Recorded when it was last on screen: a brief column's transcript is out of date until it is full again.
            if full {
                // At the end of a motion, all the way to the end: within isAtEnd's slack, the row that arrived was a 21 pt jump a moment later.
                if atEndBeforeMotion != false, native.shouldFollowEnd, motionOffset != nil ? native.distanceFromEnd > 0.5 : !native.isAtEnd { native.scrollToEnd() }
                atEndBeforeMotion = nil
                slideFromMotionOffset()
            } else {
                motionOffset = nil
            }
        }
        goalText.opacity = 0
        brief.opacity = full ? 0 : 1
        brief.transform = CATransform3DIdentity
        for (id, layer) in briefLayers {
            layer.opacity = restOpacity[id] ?? 1
            layer.sublayers?.first { $0.name == "text" }?.opacity = 1
        }
    }

    /// While moving, captures stand in for the native view: the base without the goal (flights carry it).
    func hideGoal() {
        goalText.opacity = 0
        for id in flownParts { briefLayers[id]?.sublayers?.first { $0.name == "text" }?.opacity = 0 }
        transcript.contents = motionBase
        if ownsNative, !native.isHidden { atEndBeforeMotion = native.shouldFollowEnd && native.isAtEnd }
        // Where the picture was taken, not where the transcript is now: committing can bring it to its end after the capture,
        // and then the slide at settle measured nothing and the picture gave way in one jump of 40 pt (board 10-31).
        if ownsNative { motionOffset = applied?.offset ?? native.scrollOffset.y }
        setNative(visible: false)
        if ownsNative {
            if followBeforeMotion == nil { followBeforeMotion = native.followsEnd }
            native.followsEnd = false
        }
    }

    /// The view's own layer too, so the swap lands in this transaction rather than AppKit's next update.
    func setNative(visible: Bool) {
        guard ownsNative else { return }
        let visible = visible && browserAttachment?.covers != true
        if sharedTranscript { _ = nativeLease?.setActive(visible); _ = nativeLease?.setVisible(visible) }
        native.isHidden = !visible
        native.layer?.isHidden = !visible
    }

}
