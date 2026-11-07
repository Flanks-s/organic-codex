import AppKit

/// Root of a retained native presentation. Motion hosts may revoke a semantic lease without replacing the editor.
/// Geometry changes only update the clip; hidden/remounted/mode-switched roots retire all previously exported AX nodes.
@MainActor class NativeInteractionSurface:NativeFlippedView {
    private(set) var presentationEpoch:UInt64=0
    var presentationActive=true {didSet{if presentationActive != oldValue{invalidateAccessibilityLease();presentationVisibilityDidChange()}}}
    var presentationClip:CGRect?
    var presentationContext:String? {didSet{if presentationContext != oldValue{invalidateAccessibilityLease()}}}
    /// Offscreen verification only. Production always uses the actual window's screen conversion.
    var verificationAXScreenOrigin:CGPoint?
    private var proxies:[NSObject:NativeInteractionProxy]=[:]
    private var ancestorObservations:[NSKeyValueObservation]=[]
    private var windowNotifications:[NSObjectProtocol]=[]
    private var windowWasVisible=false,windowClosing=false
    /// Mirrors an enclosing window during offscreen admission checks; production derives this from NSWindow.
    var verificationWindowVisible:Bool?{didSet{if verificationWindowVisible != oldValue{invalidateAccessibilityLease();presentationVisibilityDidChange()}}}
    private var windowAdmitted:Bool {
        if let verificationWindowVisible{return verificationWindowVisible}
        guard let window else{return true}
        return window.isVisible && !window.isMiniaturized && !windowClosing
    }
    /// Visibility without requiring a nonempty frame; first layout must still be admitted for a fresh view.
    var isPresentationVisible:Bool{
        guard presentationActive,windowAdmitted,!isHiddenOrHasHiddenAncestor,alphaValue>0.001 else{return false}
        var parent=superview;while let view=parent{if view.alphaValue<=0.001{return false};parent=view.superview};return true
    }
    isolated deinit{for token in windowNotifications{NotificationCenter.default.removeObserver(token)}}
    override init(frame:NSRect){super.init(frame:frame);clipsToBounds=true;setAccessibilityRole(.group)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    var modeContentInputBlocked=false
    var effectiveInteractionClip:CGRect {
        if modeContentInputBlocked {return .zero}
        guard presentationActive,windowAdmitted,!isHiddenOrHasHiddenAncestor,alphaValue>0.001 else{return .zero}
        var clip=bounds.intersection(visibleRect)
        if let presentationClip{clip=clip.intersection(presentationClip)}
        var ancestor=superview
        while let v=ancestor {if v.isHidden || v.alphaValue<=0.001 || (v as? NativeInteractionSurface)?.modeContentInputBlocked == true{return .zero};clip=clip.intersection(convert(v.bounds,from:v));ancestor=v.superview}
        return clip.isNull || clip.isInfinite ? .zero:clip
    }
    var screenClip:CGRect {
        let clip=effectiveInteractionClip
        guard !clip.isEmpty else{return .zero}
        if let window{return window.convertToScreen(convert(clip,to:nil))}
        if let origin=verificationAXScreenOrigin{return clip.offsetBy(dx:origin.x,dy:origin.y)}
        return .zero
    }
    func sourceFrame(_ source:NSObject)->CGRect? {
        if let v=source as? NSView {
            guard admits(v),!v.isHiddenOrHasHiddenAncestor,v.alphaValue>0.001 else{return nil}
            let local=convert(v.bounds,from:v).intersection(convert(v.visibleRect,from:v))
            if let window{return window.convertToScreen(convert(local,to:nil))}
            if let origin=verificationAXScreenOrigin{return local.offsetBy(dx:origin.x,dy:origin.y)}
        }
        return nativeInteractionAXFrame(source)
    }
    func admits(_ source:NSObject)->Bool {
        guard presentationActive,!effectiveInteractionClip.isEmpty else{return false}
        if let view=source as? NSView{return view !== self && view.isDescendant(of:self)}
        return true // Native virtual elements follow the canonical proxy parent chain.
    }
    @discardableResult func invalidateAccessibilityLease()->UInt64 {
        presentationEpoch &+= 1
        for proxy in proxies.values{proxy.disconnect()}
        proxies.removeAll()
        // A menu that belongs to a retiring mount cannot dispatch into its next mount.
        func cancelMenus(_ view:NSView){view.menu?.cancelTrackingWithoutAnimation();view.subviews.forEach(cancelMenus)}
        subviews.forEach(cancelMenus)
        return presentationEpoch
    }
    /// Retiring a virtual cell must retire its old AX leaves before the same AppKit controls represent another item.
    /// Other cells (including an active selection/menu) keep their canonical proxies.
    func retireAccessibilitySubtree(_ view: NSView) {
        for proxy in Array(proxies.values) {
            if let source = proxy.source as? NSView, source === view || source.isDescendant(of: view) { discard(proxy) }
        }
    }
    func presentationVisibilityDidChange(){}
    override var isHidden:Bool{didSet{if isHidden != oldValue{invalidateAccessibilityLease();presentationVisibilityDidChange()}}}
    override var alphaValue:CGFloat{didSet{if (alphaValue<=0.001) != (oldValue<=0.001){invalidateAccessibilityLease();presentationVisibilityDidChange()}}}
    override func viewWillMove(toSuperview next:NSView?){invalidateAccessibilityLease();ancestorObservations=[];super.viewWillMove(toSuperview:next)}
    override func viewDidMoveToSuperview(){
        super.viewDidMoveToSuperview();invalidateAccessibilityLease();observeAncestors();presentationVisibilityDidChange()
    }
    override func viewWillMove(toWindow next:NSWindow?){
        for token in windowNotifications{NotificationCenter.default.removeObserver(token)};windowNotifications=[]
        invalidateAccessibilityLease();super.viewWillMove(toWindow:next)
    }
    override func viewDidMoveToWindow(){
        super.viewDidMoveToWindow();invalidateAccessibilityLease();observeAncestors();windowClosing=false
        windowWasVisible=windowAdmitted
        presentationVisibilityDidChange()
        guard let window else{return}
        for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification] {
            windowNotifications.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main){[weak self] notification in
                let closing=notification.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated{
                    guard let self else{return}
                    self.windowClosing=closing
                    let visible=self.windowAdmitted
                    if !visible || visible != self.windowWasVisible{self.invalidateAccessibilityLease()}
                    self.windowWasVisible=visible;self.presentationVisibilityDidChange()
                }
            })
        }
    }
    private func observeAncestors(){
        ancestorObservations=[]
        var ancestor=superview
        while let view=ancestor {
            ancestorObservations.append(view.observe(\.isHidden,options:[.old,.new]){ [weak self] _,change in
                MainActor.assumeIsolated{if change.oldValue != change.newValue{self?.invalidateAccessibilityLease();self?.presentationVisibilityDidChange()}}
            })
            ancestorObservations.append(view.observe(\.alphaValue,options:[.old,.new]){ [weak self] _,change in
                MainActor.assumeIsolated{if (change.oldValue ?? 1)<=0.001 || (change.newValue ?? 1)<=0.001{self?.invalidateAccessibilityLease();self?.presentationVisibilityDidChange()}}
            })
            ancestor=view.superview
        }
    }
    override func setFrameSize(_ size:NSSize){
        let wasEmpty=bounds.isEmpty;super.setFrameSize(size)
        if wasEmpty != bounds.isEmpty{invalidateAccessibilityLease()}
    }
    func containsVisiblePoint(_ point:CGPoint)->Bool{effectiveInteractionClip.contains(point)}
    func containsScreenPoint(_ point:CGPoint)->Bool{!screenClip.isEmpty && screenClip.contains(point)}
    override func hitTest(_ point:NSPoint)->NSView?{
        guard containsVisiblePoint(convert(point,from:superview)),NativePointerShield.permits(self,localPoint:convert(point,from:superview))else{return nil}
        let result=super.hitTest(point);return result === self ? nil:result
    }
    override func accessibilityFrame()->NSRect{screenClip}
    override func isAccessibilityElement()->Bool{!screenClip.isEmpty}
    override func isAccessibilityHidden()->Bool{screenClip.isEmpty}
    override func accessibilityChildren()->[Any]?{
        guard !screenClip.isEmpty else{return []}
        let children=subviews.flatMap{v -> [Any] in guard !v.isHiddenOrHasHiddenAncestor else{return []};return v.isAccessibilityElement() ? [v]:v.accessibilityChildren() ?? []}
        return visibleProxies(children,parent:self,pruneChildren:true)
    }
    override var accessibilityFocusedUIElement:Any? {
        nativeInteractionAXResult {
            guard let focused=window?.firstResponder as? NSView,focused.isDescendant(of:self)else{return nil}
            return proxy(focused,parent:self,adoptParent:false)
        }
    }
    override func accessibilityHitTest(_ point:NSPoint)->Any? {
        nativeInteractionAXResult {
            guard containsScreenPoint(point)else{return nil}
            for child in accessibilityChildren() ?? [] {if let hit=(child as? NativeInteractionProxy)?.accessibilityHitTest(point){return hit}}
            return self
        }
    }
    func proxy(_ value:Any,parent:AnyObject,adoptParent:Bool=true)->NativeInteractionProxy? {
        guard let source=value as? NSObject,admits(source),let sourceFrame=sourceFrame(source)else{return nil}
        let frame=sourceFrame.intersection(screenClip);guard !frame.isNull,!frame.isEmpty else{return nil}
        if let old=proxies[source]{if adoptParent,old !== parent{old.parent=parent};return old}
        let result=NativeInteractionProxy(source:source,owner:self,parent:parent);proxies[source]=result
        if !adoptParent,let nativeParent=((source as AnyObject).accessibilityParent?() ?? source.accessibilityAttributeValue(.parent)) as? NSObject,nativeParent !== source {
            if nativeParent === self {result.parent=self}
            else if let parentProxy=proxy(nativeParent,parent:self,adoptParent:false){result.parent=parentProxy}
        }
        return result
    }
    func visibleProxies(_ values:[Any],parent:AnyObject,pruneChildren:Bool=false,adoptParent:Bool=true)->[Any] {
        let visible=values.compactMap{proxy($0,parent:parent,adoptParent:adoptParent)}
        if pruneChildren {
            let keep=Set(visible.map(ObjectIdentifier.init))
            for old in Array(proxies.values) where old.parent === parent && !keep.contains(ObjectIdentifier(old)){discard(old)}
        }
        return visible
    }
    private func discard(_ proxy:NativeInteractionProxy){
        for child in Array(proxies.values) where child.parent === proxy{discard(child)}
        if let source=proxy.source{proxies.removeValue(forKey:source)};proxy.disconnect()
    }
    static func permits(_ view:NSView)->Bool {
        guard !view.isHiddenOrHasHiddenAncestor,view.alphaValue>0.001 else{return false}
        var ancestor=view.superview
        while let next=ancestor {
            if let root=next as? NativeInteractionSurface{return root.admits(view) && !root.effectiveInteractionClip.intersection(root.convert(view.bounds,from:view)).isEmpty}
            if next.alphaValue<=0.001{return false};ancestor=next.superview
        }
        return true // Existing standalone native controls retain their AppKit contract.
    }
}
