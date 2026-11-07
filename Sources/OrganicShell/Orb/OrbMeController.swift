import AppKit
import QuartzCore

/// Product QuotaHover's deterministic state. Press/drag cancels the pending hover, not just the visible card.
struct OrbMeHoverState {
    private(set) var visible=false,dragging=false,deadline:Double?
    mutating func hover(_ inside:Bool,now:Double) { visible=false; deadline=inside && !dragging ? now+0.5:nil }
    mutating func advance(to now:Double,mouseButtonsDown:Bool) {
        guard let deadline,now>=deadline else { return }; self.deadline=nil
        visible = !dragging && !mouseButtonsDown
    }
    mutating func cancel() { visible=false; deadline=nil }
    mutating func setDragging(_ value:Bool) { dragging=value; if value { cancel() } }
}

@MainActor final class OrbMeController {
    struct Model {
        var name:String,plan:String,quota:OrbQuota
        var organic=true,fullyFocused=false
    }
    enum Action:Equatable { case newChat,showSidebar,collapse,profile,usage,settings,fullyFocused,shortcuts,signOut }
    var onAction:((Action)->Void)?
    var now:()->Double = { CACurrentMediaTime() }
    let card=OrbQuotaCard(frame:CGRect(x:0,y:0,width:264,height:220))
    private(set) var state=OrbMeHoverState()
    private var model:Model,anchor=CGRect.zero,timer:Timer?
    private weak var host:NSView?
    private var exitTask:DispatchWorkItem?
    private var displayObservation:UUID?
    init(model:Model) {
        self.model=model; card.update(model.quota)
        displayObservation=OrbDisplayEnvironment.shared.observe { [weak self] in self?.card.displayOptionsChanged() }
    }
    isolated deinit { timer?.invalidate(); exitTask?.cancel(); card.removeFromSuperview(); if let displayObservation { OrbDisplayEnvironment.shared.removeObserver(displayObservation) } }
    var isQuotaPresented:Bool { state.visible && card.superview != nil }
    func update(_ next:Model) { model=next; card.update(next.quota) }
    /// anchor is me's rectangle in the supplied top overlay plane. The card never takes pointer or key focus.
    func hover(_ inside:Bool,anchor:CGRect,in host:NSView,at time:Double?=nil) {
        self.host=host; self.anchor=anchor; state.hover(inside,now:time ?? now()); synchronize(animateExit:!inside); schedule()
    }
    private func placeCard() {
        guard let host else { return }; let s=host.window?.backingScaleFactor ?? 2
        let y=host.isFlipped ? anchor.minY-10-card.frame.height:anchor.maxY+10
        card.drawingScale=s; card.setFrameOrigin(CGPoint(x:(anchor.minX*s).rounded()/s,y:(y*s).rounded()/s))
    }
    func advance(to time:Double,mouseButtonsDown:Bool=false) { state.advance(to:time,mouseButtonsDown:mouseButtonsDown); synchronize(); schedule() }
    func setDragging(_ value:Bool) { state.setDragging(value); synchronize(); schedule() }
    func dismiss() { state.cancel(); synchronize(); schedule() }
    func makeAccountMenu()->NSMenu {
        dismiss(); let menu=NSMenu(); menu.autoenablesItems=false
        func action(_ title:String,_ symbol:String,_ value:Action)->NSMenuItem {
            let item=OrbAccountMenuItem(title) { [weak self] in self?.onAction?(value) }
            item.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil); item.isEnabled=onAction != nil; menu.addItem(item); return item
        }
        if model.organic {
            _=action("New Chat","square.and.pencil",.newChat); _=action("Show Sidebar","sidebar.left",.showSidebar)
            _=action("Collapse to Side","rectangle.righthalf.inset.filled",.collapse); menu.addItem(.separator())
        }
        menu.addItem(.sectionHeader(title:model.name+" · "+model.plan))
        _=action("Profile","person.crop.circle",.profile)
        let usage=action("Usage & Billing","gauge.medium",.usage); usage.subtitle=model.quota.summary
        _=action("Settings…","gearshape.fill",.settings); menu.addItem(.separator())
        let focused=action("Fully Focused","moon",.fullyFocused); focused.state=model.fullyFocused ? .on:.off
        focused.toolTip="In Focused and Split, everything around the conversation holds still: no orbiting, sloshing or bouncing, no magnifying."
        menu.addItem(.separator()); _=action("Keyboard Shortcuts","keyboard",.shortcuts)
        let help=NSMenuItem(title:"Help",action:nil,keyEquivalent:""); help.isEnabled=false; menu.addItem(help)
        menu.addItem(.separator()); _=action("Sign Out…","rectangle.portrait.and.arrow.right",.signOut)
        return menu
    }
    func presentAccountMenu(anchor:CGRect,in view:NSView) {
        let menu=makeAccountMenu()
        menu.popUp(positioning:nil,at:CGPoint(x:anchor.minX,y:view.isFlipped ? anchor.minY:anchor.maxY),in:view)
    }
    private func schedule() {
        timer?.invalidate(); timer=nil; guard let deadline=state.deadline else { return }
        let t=Timer(timeInterval:max(0.001,deadline-now()),repeats:false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.advance(to:self.now(),mouseButtonsDown:NSEvent.pressedMouseButtons != 0) }
        }
        timer=t; RunLoop.main.add(t,forMode:.common)
    }
    private func synchronize(animateExit:Bool=false) {
        let wasExiting=exitTask != nil; exitTask?.cancel(); exitTask=nil
        guard state.visible,let host else {
            if animateExit,card.superview != nil {
                card.setAccessibilityHidden(true)
                let fade=CABasicAnimation(keyPath:"opacity"); fade.fromValue=card.layer?.presentation()?.opacity ?? 1; fade.toValue=0; fade.duration=0.15; fade.timingFunction=CAMediaTimingFunction(name:.easeOut)
                CATransaction.begin(); CATransaction.setDisableActions(true); card.layer?.opacity=0; card.layer?.add(fade,forKey:"quota.out"); CATransaction.commit()
                let task=DispatchWorkItem { [weak self] in self?.card.removeFromSuperview(); self?.exitTask=nil }
                exitTask=task; DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:task)
            } else { card.layer?.removeAllAnimations(); card.removeFromSuperview() }
            return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); card.layer?.opacity=1; CATransaction.commit(); card.setAccessibilityHidden(false)
        if card.superview !== host || wasExiting {
            card.removeFromSuperview(); host.addSubview(card); placeCard()
            let scale=CASpringAnimation(keyPath:"transform"),omega=2*Double.pi/0.28
            scale.mass=1; scale.stiffness=omega*omega; scale.damping=2*0.86*omega; scale.duration=scale.settlingDuration
            // Keep the lower-left corner fixed, regardless of AppKit’s backing-layer anchor point.
            let a=card.layer?.anchorPoint ?? .zero,p=CGPoint(x:-a.x*card.bounds.width,y:(1-a.y)*card.bounds.height)
            scale.fromValue=NSValue(caTransform3D:CATransform3DMakeAffineTransform(CGAffineTransform(a:0.92,b:0,c:0,d:0.92,tx:p.x*0.08,ty:p.y*0.08)))
            scale.toValue=NSValue(caTransform3D:CATransform3DIdentity)
            let fade=CABasicAnimation(keyPath:"opacity"); fade.fromValue=0; fade.toValue=1; fade.duration=0.15
            card.layer?.add(scale,forKey:"quota.in.scale"); card.layer?.add(fade,forKey:"quota.in.opacity")
        } else { placeCard() }
    }
}

@MainActor final class OrbQuotaCard:NSView {
    private let glass=NSGlassEffectView(),drawing=OrbQuotaDrawing()
    override var isFlipped:Bool { true }
    var drawingScale:CGFloat=2 { didSet { drawing.scale=drawingScale; drawing.needsDisplay=true } }
    override init(frame:NSRect) {
        super.init(frame:frame); wantsLayer=true; appearance=NSAppearance(named:.darkAqua)
        glass.style = .regular; glass.cornerRadius=14; addSubview(glass); addSubview(drawing)
        setAccessibilityElement(true); setAccessibilityRole(.group); displayOptionsChanged()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect:NSRect) { super.draw(dirtyRect) }
    #if ORB_SELFTEST
    var verificationDrawing:NSView { drawing }
    #endif
    override func hitTest(_ point:NSPoint)->NSView? { nil }
    func update(_ quota:OrbQuota) { drawing.quota=quota; setAccessibilityLabel(drawing.spoken); needsLayout=true }
    func displayOptionsChanged() {
        appearance=NSAppearance(named:OrbDisplayEnvironment.shared.options.increaseContrast ? .accessibilityHighContrastDarkAqua:.darkAqua)
        glass.tintColor=nil; layer?.shadowOpacity=OrbDisplayEnvironment.shared.options.opaqueSurfaces ? 0:0.25
        layer?.shadowRadius=16; layer?.shadowOffset=CGSize(width:0,height:8); drawing.needsDisplay=true
    }
    override func layout() { super.layout(); glass.frame=bounds; drawing.frame=bounds }
}
@MainActor private final class OrbQuotaDrawing:NSView {
    var scale:CGFloat=2
    var quota=OrbQuota(primaryUsed:nil,secondaryUsed:nil) { didSet { needsDisplay=true } }
    override var isFlipped:Bool { true }
    private func reset(_ date:Date?)->String { date.map { "Resets "+$0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? "Reset time not reported" }
    var spoken:String {
        "Usage limits. "+[(quota.primaryTitle,quota.primaryUsed,quota.primaryResetsAt),(quota.secondaryTitle,quota.secondaryUsed,quota.secondaryResetsAt)].map {
            $0.0+", "+($0.1?.isFinite == true ? "\(Int((min(1,max(0,$0.1!))*100).rounded()))% used":"Not reported")+", "+reset($0.2)
        }.joined(separator:". ")
    }
    override init(frame:NSRect) { super.init(frame:frame); setAccessibilityElement(false) }
    convenience init() { self.init(frame:.zero) }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect:NSRect) {
        func text(_ value:String,_ rect:CGRect,_ size:CGFloat,_ color:NSColor,_ weight:NSFont.Weight = .regular) {
            let style=NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
            (value as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color,.paragraphStyle:style])
        }
        text("Usage limits",CGRect(x:14,y:14,width:236,height:18),12,.labelColor,.semibold)
        for (index,row) in [(quota.primaryTitle,quota.primaryUsed,quota.primaryResetsAt),(quota.secondaryTitle,quota.secondaryUsed,quota.secondaryResetsAt)].enumerated() {
            let y=CGFloat(44+index*62),reported=row.1?.isFinite == true,used=reported ? min(1,max(0,row.1!)):0
            text(row.0,CGRect(x:14,y:y,width:142,height:18),12,.labelColor)
            text(reported ? "\(Int((used*100).rounded()))% used":"Not reported",CGRect(x:156,y:y,width:94,height:18),11,.secondaryLabelColor)
            if reported {
                OrbDisplayEnvironment.surface(.white,opacity:0.12).setFill(); NSBezierPath(roundedRect:CGRect(x:14,y:y+22,width:236,height:4),xRadius:2,yRadius:2).fill()
                (used>=0.8 ? NSColor.systemOrange:NSColor(srgbRed:0x2b/255,green:0x8a/255,blue:0x7a/255,alpha:1)).setFill()
                NSBezierPath(roundedRect:CGRect(x:14,y:y+22,width:(236*used*scale).rounded()/scale,height:4),xRadius:2,yRadius:2).fill()
            }
            text(reset(row.2),CGRect(x:14,y:y+31,width:236,height:18),10,.secondaryLabelColor)
        }
        text(quota.tightestUsed == nil ? "Usage has not been reported by Core.":"me’s liquid shows the tighter reported limit.",CGRect(x:14,y:177,width:236,height:30),10,.tertiaryLabelColor)
    }
}
@MainActor private final class OrbAccountMenuItem:NSMenuItem {
    private let invoke:()->Void
    init(_ title:String,_ invoke:@escaping ()->Void) { self.invoke=invoke; super.init(title:title,action:#selector(run),keyEquivalent:""); target=self }
    required init(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func run() { invoke() }
}
