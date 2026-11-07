import AppKit
import QuartzCore

/// Product Popover/SendOptions:153–154. The normal native tracking path and the overlay's captured long press can
/// use this same spring. No timer, new editor, glass transform, or spatial blur is involved.
@MainActor final class NativeComposerPressMotion {
    weak var button:NSButton?
    init(_ button:NSButton){self.button=button}
    var layer:CALayer?{button?.layer}
    var bounds:CGRect{button?.bounds ?? .zero}
    static let response=0.22,damping=0.55
    var usesPressSpring=true{didSet{if oldValue != usesPressSpring && !usesPressSpring{setPressed(false,animated:false)}}}
    private(set) var pressed=false
    func setPressed(_ value:Bool,animated:Bool=true){
        if value && !usesPressSpring{return}
        if value == pressed {if !animated{CATransaction.begin();CATransaction.setDisableActions(true);for key in ["transform.scale","transform.translation.x","transform.translation.y"]{layer?.removeAnimation(forKey:"composer.press."+key)};layer?.setValue(value ? 0.88:1,forKeyPath:"transform.scale");if !value{layer?.setValue(0,forKeyPath:"transform.translation.x");layer?.setValue(0,forKeyPath:"transform.translation.y")};CATransaction.commit()};return};pressed=value;button?.wantsLayer=true
        guard let layer else{return}
        let target:CGFloat=value ? 0.88:1
        CATransaction.begin();CATransaction.setDisableActions(true)
        let x=(1-target)*bounds.width*(0.5-layer.anchorPoint.x),y=(1-target)*bounds.height*(0.5-layer.anchorPoint.y)
        for (key,end) in [("transform.scale",target),("transform.translation.x",x),("transform.translation.y",y)]{
            let previous=layer.presentation()?.value(forKeyPath:key) ?? layer.value(forKeyPath:key)
            layer.setValue(end,forKeyPath:key)
            if animated,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let spring=CASpringAnimation(keyPath:key),omega=2*Double.pi/Self.response
                spring.mass=1;spring.stiffness=omega*omega;spring.damping=2*Self.damping*omega
                spring.fromValue=previous;spring.toValue=end;spring.duration=spring.settlingDuration
                layer.add(spring,forKey:"composer.press."+key)
            }else{layer.removeAnimation(forKey:"composer.press."+key)}
        }
        CATransaction.commit()
    }
    isolated deinit{setPressed(false,animated:false)}
}

/// Preserve NativePrimaryButton and its native action/AX path. NSButtonCell owns mouse tracking, so this is the
/// exact entry/exit around a normal press, even when AppKit consumes mouseUp in its internal tracking loop.
@MainActor final class NativeComposerSendCell:NSButtonCell{
    weak var motion:NativeComposerPressMotion?
    override func trackMouse(with event:NSEvent,in cellFrame:NSRect,of controlView:NSView,untilMouseUp flag:Bool)->Bool{
        motion?.setPressed(true);defer{motion?.setPressed(false)}
        return super.trackMouse(with:event,in:cellFrame,of:controlView,untilMouseUp:flag)
    }
}

/// Product Organic/DockItems:489–509. Seven solid capsules, each with its own .easeInOut duration and autoreverse.
/// Maximum 60Hz edge step is below the physical onset; therefore M10 must NOT add copies/stretch to this waveform.
@MainActor final class NativeComposerVoiceWaveform: NativeFlippedView {
    static let low:[CGFloat]=[6,9,12,7,14,6,11],high:[CGFloat]=[10,16,8,18,12,15,9]
    private let bars=(0..<7).map{_ in CALayer()}
    private var running=false
    private var heldAnimations: [CAAnimation] = []
    private lazy var animationVisibility = OrbAnimationVisibilityObservation(view: self) { [weak self] in self?.synchronize() }
    private var displayObservation:NSObjectProtocol?
    var active=false { didSet { synchronize() } }
    override init(frame:NSRect){super.init(frame:frame);wantsLayer=true;for bar in bars{bar.cornerRadius=1.5;layer?.addSublayer(bar)};setAccessibilityElement(false)
        displayObservation=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.synchronize()}}
    }
    isolated deinit{if let displayObservation{NSWorkspace.shared.notificationCenter.removeObserver(displayObservation)}}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func layout(){super.layout();CATransaction.begin();CATransaction.setDisableActions(true)
        for (i,bar) in bars.enumerated(){bar.frame=CGRect(x:CGFloat(i)*5.5,y:(bounds.height-Self.low[i])/2,width:3,height:Self.low[i]);bar.backgroundColor=NativeAppearance.current.accentColor.cgColor}
        CATransaction.commit()
    }
    func synchronize(){
        let enabled = active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if enabled { if !animationVisibility.isObserving { animationVisibility.rebind() } } else { animationVisibility.stop() }
        let next = enabled && window != nil && OrbAnimationVisibility.state(layer: layer, view: self).isVisible
        if !enabled { heldAnimations.removeAll() }
        guard next != running else{return};running=next
        let now = CACurrentMediaTime()
        for (i,bar) in bars.enumerated(){
            if !next { bar.removeAnimation(forKey:"composer.voice"); continue }
            if heldAnimations.count == bars.count {
                bar.add(heldAnimations[i], forKey:"composer.voice")
            } else {
                let a=CABasicAnimation(keyPath:"bounds.size.height");a.fromValue=Self.low[i];a.toValue=Self.high[i]
                a.duration=0.45+Double(i)*0.04;a.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut);a.autoreverses=true;a.repeatCount = .greatestFiniteMagnitude
                a.beginTime = bar.convertTime(now, from:nil)
                bar.add(a,forKey:"composer.voice")
            }
        }
        // Keep the original local epoch while hidden, so reattachment advances rather than restarts.
        if next, heldAnimations.isEmpty { heldAnimations = bars.compactMap { $0.animation(forKey:"composer.voice") } }
    }
    /// Carried by the terminal's slide: keep the live waveform (not a frozen bitmap) and stretch its SOLID bars.
    func setCarryStretch(_ delta:CGPoint){
        CATransaction.begin();CATransaction.setDisableActions(true)
        for bar in bars{let size=bar.presentation()?.bounds.size ?? bar.bounds.size
            var t=CATransform3DMakeTranslation(delta.x/2,delta.y/2,0)
            t=CATransform3DScale(t,1+abs(delta.x)/max(1,size.width),1+abs(delta.y)/max(1,size.height),1);bar.transform=t
        };CATransaction.commit()
    }
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if active { animationVisibility.rebind() };synchronize()}
    override func viewDidMoveToSuperview(){super.viewDidMoveToSuperview();if active { animationVisibility.rebind() };synchronize()}
    override func viewDidHide(){super.viewDidHide();synchronize()}
    override func viewDidUnhide(){super.viewDidUnhide();synchronize()}
    override func nativeAppearanceDidChange(){super.nativeAppearanceDidChange();needsLayout=true}
}
