import AppKit
import QuartzCore

/// Keep the departing editor's transparent ink on its original moving bar while its lease is elsewhere.
/// Glass is never captured or borrowed. Both the retained ink and native editor inherit the same Dock clock.
@MainActor final class ModeComposerInkRetainer {
    private final class Surface:NSView {
        override var isFlipped:Bool {true}
        override func hitTest(_ point:NSPoint)->NSView? {nil}
    }
    @MainActor private final class Entry {
        weak var source:NativeComposer?
        weak var host:NSView?
        let view=Surface(),image=CALayer()
        var detached=false,returnedAt:Double?
        let nativeMask=CALayer()
        var savedMask:CALayer?,masked=false,readyAt:Double?
        func maskNative(_ on:Bool) {
            guard let layer=source?.layer else {return}
            if on,(!masked || layer.mask !== nativeMask) {savedMask=layer.mask;layer.mask=nativeMask;masked=true}
            else if !on,masked {if layer.mask === nativeMask {layer.mask=savedMask};savedMask=nil;masked=false}
        }
        init(source:NativeComposer,host:NSView,picture:CGImage,scale:CGFloat,id:String) {
            self.source=source;self.host=host
            nativeMask.name="mode.composer.ink.hold"
            view.identifier=NSUserInterfaceItemIdentifier("mode.composer.ink."+id)
            view.wantsLayer=true;view.frame=source.frame;view.isHidden=true
            image.frame=view.bounds;image.contents=picture;image.contentsScale=scale;image.isGeometryFlipped=true
            view.layer?.addSublayer(image);view.setAccessibilityHidden(true)
            host.addSubview(view,positioned:.above,relativeTo:source)
        }
    }
    private var entries:[String:Entry]=[:]
    private weak var dock:DockNode?
    private var wake:DispatchWorkItem?
    func retain(from dock:DockNode,scale:CGFloat) {
        self.dock=dock
        for (id,item) in dock.items where item.full && item.role == .bar {
            guard entries[id] == nil,let source=item.ownComposer,!source.isHidden,
                  let image=M10DockPicture.draw(source,scale:scale,plates:false) else {continue}
            entries[id]=Entry(source:source,host:item.barFace,picture:image,scale:scale,id:id)
        }
    }
    func refresh() {
        wake?.cancel();wake=nil
        CATransaction.begin();CATransaction.setDisableActions(true);defer {CATransaction.commit()}
        var needsFrame=false
        for (id,e) in entries {
            guard let source=e.source,let host=e.host,let item=dock?.items[id],item.full,item.role == .bar else {remove(id);continue}
            let nativeOwns=source.superview === host
            if !nativeOwns {e.detached=true;e.maskNative(false);e.readyAt=nil}
            guard e.detached else {continue}
            let alpha=nativeOwns && !source.isHidden && source.layer?.isHidden != true
                ? min(source.alphaValue,CGFloat(source.layer?.presentation()?.opacity ?? source.layer?.opacity ?? 1)):0
            // Complementary view alpha is not complementary pixel coverage under source-over blending.
            // Keep one ink owner until the returned native surface has crossed a display commit.
            if nativeOwns {
                if !e.masked {dock?.composerMotion?.cancelGaussian(source)}
                e.maskNative(true)
            }
            if alpha>=0.999 {
                let interval=source.window?.screen.map {DisplayProfile.of($0).frameInterval} ?? 1/60
                if let ready=e.readyAt,CACurrentMediaTime()-ready>=interval {remove(id);continue}
                if e.readyAt == nil {e.readyAt=CACurrentMediaTime()}
            } else {e.readyAt=nil}
            e.view.isHidden=false;e.view.alphaValue=1
            if nativeOwns,e.returnedAt == nil {e.returnedAt=CACurrentMediaTime()}
            needsFrame = needsFrame || (nativeOwns && CACurrentMediaTime()-(e.returnedAt ?? 0)<0.6)
        }
        if needsFrame {
            let task=DispatchWorkItem { [weak self] in self?.refresh() };wake=task
            DispatchQueue.main.asyncAfter(deadline:.now()+1/120,execute:task)
        }
    }
    private func remove(_ id:String) {
        guard let entry=entries.removeValue(forKey:id) else {return}
        entry.maskNative(false);entry.view.removeFromSuperview()
    }
    func clear() {
        CATransaction.begin();CATransaction.setDisableActions(true);defer {CATransaction.commit()}
        wake?.cancel();wake=nil;for id in Array(entries.keys) {remove(id)}
    }
}
