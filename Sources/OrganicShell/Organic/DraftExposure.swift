import AppKit
import QuartzCore

/// The draft owns its ink snapshot, not its input session. Original controls keep their hit/AX identities.
/// Capture once at a semantic/layout boundary; the frame loop writes geometry and replication only.
@MainActor final class M10DraftExposure:NSView {
    override var isFlipped:Bool { true }
    override func hitTest(_ point:NSPoint)->NSView? { nil }
    let trail=ChordTrail()
    private(set) var sample=ExposureSample.still
    private struct Ink { weak var view:NSView?;let opacity:Float;let layer:CALayer }
    private struct Glass { weak var view:NSGlassEffectView?;let frame:CGRect,bounds:CGRect;let radius:CGFloat }
    private var ink:[Ink]=[],glass:[Glass]=[]
    private(set) var lastStretch:CGFloat=0
    private var displayed=false
    override init(frame:NSRect) { super.init(frame:frame);wantsLayer=true;layer?.addSublayer(trail.layer);trail.settings=M10FExposure.settings }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func prepare(in draft:DraftColumn,scale:CGFloat) {
        reset();ink.removeAll();glass.removeAll();trail.layer.sublayers?.forEach{$0.removeFromSuperlayer()}
        frame=draft.bounds
        func collect(_ v:NSView) {
            guard !v.isHidden else { return }
            if let g=v as? NSGlassEffectView { glass.append(Glass(view:g,frame:g.frame,bounds:g.contentView?.bounds ?? .zero,radius:g.cornerRadius));return }
            if let container=v as? NSGlassEffectContainerView { if let content=container.contentView { collect(content) };return }
            if v is NativeLabel || v is NSButton {
                guard v.bounds.width>0,v.bounds.height>0 else { return }
                v.wantsLayer=true
                let image=NativeViewBitmap.capture(v,scale:scale),l=CALayer()
                guard let tile=M10DockPicture.tight(image,scale:scale) else {return}
                ReplicaContainerAudit.register(l,material:v is NSButton ? .icon:.glyph,note:"Draft own-draw transparent label/icon; tight independent alpha storage")
                l.contents=tile.image;l.contentsScale=scale
                l.frame=tile.rect.offsetBy(dx:draft.convert(v.bounds,from:v).minX,dy:draft.convert(v.bounds,from:v).minY)
                trail.layer.addSublayer(l);ink.append(Ink(view:v,opacity:v.layer?.opacity ?? 1,layer:l));return
            }
            for child in v.subviews where child !== self { collect(child) }
        }
        for v in draft.subviews where v !== self { collect(v) }
        isHidden=true
    }
    func update(in draft:DraftColumn,now:CGRect,earlier:CGRect,profile:DisplayProfile,enabled:Bool) {
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        trail.settings=M10FExposure.settings(now:now,earlier:earlier)
        trail.settings.enabled=enabled
        trail.update(now:now,earlier:earlier,profile:profile)
        sample=M10FExposure.sample(now:now,earlier:earlier,profile:profile,settings:trail.settings)
        M10FExposure.apply(sample,to:trail,now:now,earlier:earlier)
        let wanted=sample.count>1
        let wasDisplayed=displayed
        if wanted != displayed {
            displayed=wanted;isHidden = !wanted
            for item in ink { item.view?.layer?.opacity=wanted ? 0:item.opacity }
        }
        lastStretch=0
        if !wanted && !wasDisplayed { return }
        for item in glass {
            guard let view=item.view,let parent=view.superview else { continue }
            let base=draft.convert(item.frame,from:parent)
            let global=base.offsetBy(dx:now.minX,dy:now.minY),old=base.offsetBy(dx:earlier.minX,dy:earlier.minY)
            let r=M10FExposure.stretch(now:global,earlier:old,profile:profile,settings:trail.settings)
            var local=item.frame.offsetBy(dx:r.minX-global.minX,dy:r.minY-global.minY);local.size=r.size
            let s=max(1,draft.window?.backingScaleFactor ?? draft.island.configuration?.scale ?? 1)
            let x=floor(local.minX*s)/s,y=floor(local.minY*s)/s
            local=CGRect(x:x,y:y,width:ceil(local.maxX*s)/s-x,height:ceil(local.maxY*s)/s-y)
            view.frame=local;view.cornerRadius=min(local.width,local.height)/2
            // Keep the native body at its nominal position inside the stretched material.
            view.contentView?.setBoundsOrigin(CGPoint(x:item.bounds.minX+local.minX-item.frame.minX,y:item.bounds.minY+local.minY-item.frame.minY))
            lastStretch=max(lastStretch,max(local.width-item.frame.width,local.height-item.frame.height))
            if !wanted { view.frame=item.frame;view.cornerRadius=item.radius;view.contentView?.bounds=item.bounds }
        }
    }
    func reset() {
        CATransaction.begin();CATransaction.setDisableActions(true)
        for item in ink { item.view?.layer?.opacity=item.opacity }
        for item in glass { item.view?.frame=item.frame;item.view?.cornerRadius=item.radius;item.view?.contentView?.bounds=item.bounds }
        trail.reset();sample = .still;displayed=false;isHidden=true;lastStretch=0
        CATransaction.commit()
    }
}
