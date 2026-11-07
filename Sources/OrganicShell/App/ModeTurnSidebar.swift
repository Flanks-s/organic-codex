import AppKit
import QuartzCore

/// One sidebar owner across a turn. Native layout can change behind the content curtain.
@MainActor final class ModeTurnSidebar {
    var now:()->Double = {CACurrentMediaTime()}
    let view=ModeFlight.Plane()
    private let image=CALayer()
    private let materialCarrier=ModeFlight.Plane(),backdrop=NSVisualEffectView()
    private var material:CALayer {materialCarrier.layer!}
    private weak var source:NSView?
    private var savedOpacity:Float=1
    private weak var nativeHost:NSView?
    private weak var nativeContent:NSView?
    private weak var nativeRoot:NSView?
    private var nativeFrom:CGFloat=0,nativeTo:CGFloat=0,nativeStart=0.0,nativeEnd=0.0
    private var nativeIncoming=false,nativeWidth:CGFloat=0
    private(set) var nativeClockRevision:UInt64=0
    /// Bind the public arranged-subview boundary once. Its system descendants never move between parents.
    func bindNative(host:NSView,content:NSView,in root:NSView) {
        precondition(nativeHost == nil)
        nativeHost=host;nativeContent=content;nativeRoot=root;nativeWidth=host.bounds.width
        host.wantsLayer=true
    }
    var usesNativeHost:Bool {nativeHost != nil}
    var visibilityEndsAt:Double? {usesNativeHost ? (nativeEnd>0 ? nativeEnd:nil):(end>0 ? end:nil)}
    var verificationSafeNativeHost:NSView? {nativeHost}
    private var nativePose:CGFloat {
        guard let layer=nativeHost?.layer else {return nativeTo}
        if nativeEnd == 0 {return nativeIncoming ? 0:-((nativeHost?.bounds.width ?? nativeWidth)+8)}
        if now()>=nativeEnd {return nativeTo}
        if let shown=layer.presentation() {return CGFloat(shown.value(forKeyPath:"transform.translation.x") as? NSNumber ?? 0)}
        // An uncommitted/hidden surface has no presentation tree. Sample its active CA clock, not its final model pose.
        if layer.animation(forKey:"mode.turn.sidebar") != nil {return rowOffset(at:now())}
        return CGFloat(layer.value(forKeyPath:"transform.translation.x") as? NSNumber ?? 0)
    }
    private func nativeClock(from:CGFloat,to:CGFloat,alpha:Float,toAlpha:Float,duration:Double,delay:Double=0) {
        guard let layer=nativeHost?.layer else {return}
        nativeClockRevision &+= 1
        nativeFrom=from;nativeTo=to;nativeStart=now()+delay;nativeEnd=nativeStart+duration
        let position=CABasicAnimation(keyPath:"transform.translation.x");position.fromValue=from;position.toValue=to
        let opacity=CABasicAnimation(keyPath:"opacity");opacity.fromValue=alpha;opacity.toValue=toAlpha
        let clock=CAAnimationGroup();clock.animations=[position,opacity];clock.beginTime=nativeStart;clock.duration=duration
        clock.timingFunction=CAMediaTimingFunction(controlPoints:0.3,0,0.15,1);clock.fillMode = .both;clock.isRemovedOnCompletion=false
        ModeSignposts.frameRange(clock)
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer.setValue(to,forKeyPath:"transform.translation.x");layer.opacity=toAlpha
        layer.add(clock,forKey:"mode.turn.sidebar");CATransaction.commit()
    }
    func moveNative(incoming:Bool) {
        guard let host=nativeHost,let layer=host.layer else {return}
        if nativeEnd>0,nativeIncoming == incoming {return}
        generation+=1
        let from=nativePose,alpha=(layer.presentation() ?? layer).opacity
        nativeIncoming=incoming;nativeWidth=host.bounds.width
        nativeClock(from:from,to:incoming ? 0:-(nativeWidth+8),alpha:1,toAlpha:1,duration:incoming ? 0.42:0.46,delay:!incoming && abs(from)<0.01 ? 0.14:0)
    }
    func settleNative(incoming:Bool) {
        guard let host=nativeHost,let layer=host.layer else {return}
        CATransaction.begin();CATransaction.setDisableActions(true)
        nativeClockRevision &+= 1
        nativeIncoming=incoming;nativeWidth=host.bounds.width;nativeEnd=0
        nativeFrom=incoming ? 0:-(nativeWidth+8);nativeTo=nativeFrom
        layer.removeAnimation(forKey:"mode.turn.sidebar");layer.setValue(nativeTo,forKeyPath:"transform.translation.x");layer.opacity=incoming ? 1:0
        CATransaction.commit()
    }
    private func resizeNative() {
        guard let host=nativeHost,host.bounds.width != nativeWidth else {return}
        if nativeEnd>now(),let layer=host.layer {
            let from=nativePose,alpha=(layer.presentation() ?? layer).opacity,remaining=max(0.001,nativeEnd-now())
            nativeWidth=host.bounds.width
            nativeClock(from:from,to:nativeIncoming ? 0:-(nativeWidth+8),alpha:1,toAlpha:1,duration:remaining)
        } else {settleNative(incoming:nativeIncoming)}
    }
    private let replicaGlass=NSGlassEffectView()
    /// Copy public rendering configuration. System split descendants never leave their layout engine.
    private func configureBackground(from source:NSView) {
        var ancestor:NSView?=source
        replicaGlass.isHidden=true
        while let current=ancestor {
            if let glass=current as? NSGlassEffectView {
                replicaGlass.style=glass.style;replicaGlass.tintColor=glass.tintColor
                replicaGlass.cornerRadius=glass.cornerRadius;replicaGlass.appearance=glass.effectiveAppearance
                replicaGlass.isHidden=false;return
            }
            ancestor=current.superview
        }
    }
    var canRetire:(()->Bool)?
    private var settledCompletions:[@MainActor ()->Void]=[]
    private var end=0.0,generation=0
    private var incoming=false
    private var motionStart=0.0,motionDuration=0.25,motionFrom:CGFloat=0,motionTo:CGFloat=0
    private var displayObserver:UUID?
    init() {
        view.wantsLayer=true;materialCarrier.wantsLayer=true
        materialCarrier.addSubview(backdrop);materialCarrier.addSubview(replicaGlass);view.addSubview(materialCarrier);view.layer?.addSublayer(image)
        image.anchorPoint = .zero;image.zPosition=1;material.anchorPoint = .zero
        backdrop.material = .sidebar;backdrop.blendingMode = .behindWindow;backdrop.state = .followsWindowActiveState
        updateMaterial()
        displayObserver=NativeDisplayOptions.shared.observe { [weak self] in self?.updateMaterial() }
    }
    isolated deinit {if let displayObserver {NativeDisplayOptions.shared.removeObserver(displayObserver)}}
    private func updateMaterial() {
        CATransaction.begin();CATransaction.setDisableActions(true)
        let reduced=NativeDisplayOptions.shared.state.reducesEffects
        backdrop.isHidden=reduced || !replicaGlass.isHidden
        // Live windows use the same system material, never an approximation of its sampled color.
        // A detached surface uses Native sidebar's own cacheDisplay background policy.
        let appearance=source?.effectiveAppearance ?? NativeDisplayOptions.appearance ?? NSAppearance(named:.darkAqua)!
        appearance.performAsCurrentDrawingAppearance {
        material.backgroundColor=(reduced ? NSColor.windowBackgroundColor.withAlphaComponent(1):
            (source?.window == nil ? NSColor(srgbRed:0.153,green:0.169,blue:0.176,alpha:1):NSColor.clear)).cgColor
        }
        CATransaction.commit()
    }
    private func moveMaterial(from origin:CGPoint,to target:CGPoint,like clock:CAAnimationGroup) {
        motionStart=clock.beginTime;motionDuration=clock.duration;motionFrom=origin.x;motionTo=target.x
        materialCarrier.setFrameSize(image.bounds.size);backdrop.frame=materialCarrier.bounds;replicaGlass.frame=materialCarrier.bounds
        material.bounds=image.bounds;material.position=target
        let position=CABasicAnimation(keyPath:"position");position.fromValue=origin;position.toValue=target
        let opacity=CABasicAnimation(keyPath:"opacity")
        if let sourceOpacity=clock.animations?.first(where:{$0 is CABasicAnimation && ($0 as? CABasicAnimation)?.keyPath == "opacity"}) as? CABasicAnimation {
            opacity.fromValue=sourceOpacity.fromValue;opacity.toValue=sourceOpacity.toValue
        }
        material.opacity=image.opacity
        let group=CAAnimationGroup();group.animations=[position,opacity];group.duration=clock.duration;group.beginTime=clock.beginTime
        group.timingFunction=clock.timingFunction;group.fillMode = .both;group.isRemovedOnCompletion=false
        material.add(group,forKey:"mode.turn.material")
    }
    func begin(_ bitmap:CGImage,source:NSView,in host:NSView,below:NSView,rect:CGRect,alpha:Float,incoming:Bool,scale:CGFloat) {
        if usesNativeHost {moveNative(incoming:incoming);return}
        CATransaction.begin();CATransaction.setDisableActions(true)
        defer {CATransaction.commit()}
        finish()
        updateMaterial()
        let rect = incoming && alpha<0.001 ? CGRect(x:-rect.width,y:rect.minY,width:rect.width,height:rect.height):rect
        self.incoming=incoming
        self.source=source;savedOpacity=1
        configureBackground(from:source)
        backdrop.appearance=source.effectiveAppearance
        var parent:NSView?=source
        while let current=parent {
            if let native=current as? NSVisualEffectView {
                backdrop.material=native.material;backdrop.blendingMode=native.blendingMode;backdrop.state=native.state;backdrop.isEmphasized=native.isEmphasized
                break
            }
            parent=current.superview
        }
        updateMaterial()
        view.frame=host.bounds;view.layer?.zPosition=ModePlaneOrder.source+0.5
        image.contents=bitmap;image.contentsScale=scale;image.bounds=CGRect(origin:.zero,size:rect.size)
        let target=CGPoint(x:incoming ? 0:-rect.width,y:rect.minY)
        image.position=target;image.opacity=incoming ? 1:0
        let position=CABasicAnimation(keyPath:"position");position.fromValue=rect.origin;position.toValue=target
        let opacity=CABasicAnimation(keyPath:"opacity");opacity.fromValue=alpha;opacity.toValue=incoming ? 1:0
        let group=CAAnimationGroup();group.animations=[position,opacity];group.duration=0.25
        group.beginTime=now();end=group.beginTime+group.duration;group.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
        group.fillMode = .both;group.isRemovedOnCompletion=false;ModeSignposts.frameRange(group)
        image.add(group,forKey:"mode.turn.sidebar")
        moveMaterial(from:rect.origin,to:target,like:group)
        host.addSubview(view,positioned:.below,relativeTo:below);source.layer?.opacity=0
        let lease=generation
        DispatchQueue.main.asyncAfter(deadline:.now()+group.duration) { [weak self] in
            guard let self,self.generation == lease,self.canRetire?() ?? true else {return}
            self.retireSettled()
        }
    }
    private func retireSettled() {
        let callbacks=settledCompletions;settledCompletions=[]
        finish();for callback in callbacks {callback()}
    }
    func needsResize(host:CGSize,source:CGSize)->Bool {
        !usesNativeHost && view.superview != nil && image.bounds.size != source
    }
    func resize(_ bitmap:CGImage,host:CGSize,source:CGSize,scale:CGFloat) {
        if usesNativeHost {resizeNative();return}
        guard view.superview != nil else {return}
        // Take the pose after rebaking. Preserve the current origin and the original retirement deadline.
        let pose=image.presentation() ?? image,origin=pose.frame.origin,alpha=pose.opacity
        CATransaction.begin();CATransaction.setDisableActions(true)
        defer {CATransaction.commit()}
        view.setFrameSize(host);image.contents=bitmap;image.contentsScale=scale
        image.bounds=CGRect(origin:.zero,size:source)
        let target=CGPoint(x:incoming ? 0:-source.width,y:origin.y)
        image.position=target;image.opacity=incoming ? 1:0
        let position=CABasicAnimation(keyPath:"position");position.fromValue=origin;position.toValue=target
        let opacity=CABasicAnimation(keyPath:"opacity");opacity.fromValue=alpha;opacity.toValue=incoming ? 1:0
        let group=CAAnimationGroup();group.animations=[position,opacity];group.duration=max(0.001,end-now())
        group.beginTime=now();group.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
        group.fillMode = .both;group.isRemovedOnCompletion=false;ModeSignposts.frameRange(group)
        image.add(group,forKey:"mode.turn.sidebar")
        moveMaterial(from:origin,to:target,like:group)
    }
    func rowOffset(at time:Double)->CGFloat {
        if usesNativeHost {
            guard nativeEnd>nativeStart else {return nativeTo}
            let k=ModeOrreryFlight.bezier(0.3,0,0.15,1,(time-nativeStart)/(nativeEnd-nativeStart))
            return nativeFrom+(nativeTo-nativeFrom)*CGFloat(k)
        }
        guard isActive else {return 0}
        let k=ModeOrreryFlight.bezier(0.42,0,0.58,1,(time-motionStart)/max(0.001,motionDuration))
        return motionFrom+(motionTo-motionFrom)*CGFloat(k)
    }
    var isActive:Bool {usesNativeHost ? nativeEnd>now():view.superview != nil}
    func resizeHost(_ size:CGSize) {if usesNativeHost {resizeNative()} else if isActive {view.setFrameSize(size)}}
    func reframe(source:CGSize) {
        if usesNativeHost {resizeNative();return}
        guard let bitmap=image.contents else {return}
        resize(bitmap as! CGImage,host:view.bounds.size,source:source,scale:image.contentsScale)
    }
    var presentedRect:CGRect? {
        if let host=nativeHost,let root=nativeRoot {return M10SidebarExposure.presentedRect(host,in:root)}
        return view.superview == nil ? nil:(image.presentation() ?? image).frame
    }
    var presentedAlpha:Float? {
        if let layer=nativeHost?.layer {return (layer.presentation() ?? layer).opacity}
        return view.superview == nil ? nil:(image.presentation() ?? image).opacity
    }
    func suppressNative() {if !usesNativeHost {source?.layer?.opacity=0}}
    func finishWhenSettled(_ completion:@escaping @MainActor ()->Void) {
        if usesNativeHost {
            let lease=generation,remaining=max(0,nativeEnd-now())
            DispatchQueue.main.asyncAfter(deadline:.now()+remaining) { [weak self] in
                guard let self,self.generation == lease else {return}
                self.finish();completion()
            }
            return
        }
        settledCompletions.append(completion)
        let lease=generation
        let retire:@MainActor ()->Void = { [weak self] in
            guard let self,self.generation == lease else {return}
            self.retireSettled()
        }
        let remaining=max(0,end-now())
        if remaining == 0 {retire()}
        else {DispatchQueue.main.asyncAfter(deadline:.now()+remaining) {retire()}}
    }
    func finish() {
        if usesNativeHost {generation+=1;settleNative(incoming:nativeIncoming);return}
        CATransaction.begin();CATransaction.setDisableActions(true)
        defer {CATransaction.commit()}
        generation+=1;end=0;settledCompletions=[]
        source?.alphaValue=CGFloat(savedOpacity);source?.layer?.opacity=savedOpacity;source=nil
        view.removeFromSuperview();image.removeAllAnimations();material.removeAllAnimations();image.contents=nil
    }
    #if M11_MODE_SELFTEST
    var verificationNativeHost:NSView? {nativeHost}
    var verificationNativeContent:NSView? {nativeContent}
    var verificationImage:CALayer {nativeHost?.layer ?? image}
    var verificationMaterial:CALayer {nativeHost?.layer ?? material}
    var verificationNativeMaterial:NSVisualEffectView {backdrop}
    var verificationBorrowedGlass:NSGlassEffectView? {nil}
    var verificationReplicaGlass:NSGlassEffectView {replicaGlass}
    var verificationRoot:CALayer {view.layer!}
    var verificationEnd:Double {end}
    var verificationSingleOwner:Bool {
        if let host=nativeHost,let content=nativeContent {return content.isDescendant(of:host) && host.superview != nil}
        return view.superview != nil && source?.layer?.opacity == 0 && image.contents != nil
    }
    #endif
}
