import AppKit
import QuartzCore

/// M9: SubAgentsSheet scales the WHOLE sheet about its opening edge (0.86 -> 1, .38/.78).
/// Glass follows that pose by a real frame, never by a transform or a replicated snapshot.
struct SheetBudMotion {
    let rect:CGRect, upward:Bool, spring:Spring
    init(rect:CGRect,upward:Bool) {
        self.rect=rect;self.upward=upward
        spring=Spring(from:0,to:1,response:0.38,damping:0.78,
                      epsilon:Spring.restEpsilon/max(1,Double(max(rect.width,rect.height))))
    }
    var duration:Double { spring.duration }
    func pose(_ time:Double)->(rect:CGRect,scale:CGFloat,opacity:Float) {
        let p=spring.sample(time).value,s=CGFloat(0.86+0.14*p)
        let w=rect.width*s,h=rect.height*s
        return (CGRect(x:rect.midX-w/2,y:upward ? rect.maxY-h:rect.minY,width:w,height:h),s,Float(min(1,max(0,p))))
    }
}

/// Only the glass's geometry needs driver A; Gaussian ink is one detached content layer (driver B).
/// No timer/offscreen clock. The display link exists only while this visible finite bud is moving.
@MainActor final class SheetBudDriver:NSObject {
    private weak var card:SheetCard?
    private var link:CADisplayLink?
    private var began=0.0
    var beginTime:Double {began}
    private(set) var plan:SheetBudMotion?
    /// M10_DRAFT_EXPOSURE=0: off, for live on/off comparisons.
    var exposureEnabled=ProcessInfo.processInfo.environment["M10_DRAFT_EXPOSURE"] != "0" {
        didSet {if !exposureEnabled {contentTransition?.finish();contentTransition=nil;lastSample = .still}}
    }
    var profileOverride:DisplayProfile?
    var backingScaleOverride:CGFloat?
    var zoom=SheetZoom.selected
    var sceneClock=SceneClock()
    private(set) var contentTransition:SheetContentTransition?
    private(set) var lastSample=ExposureSample.still
    func updateTarget(_ rect:CGRect,upward:Bool) {
        guard let plan,plan.rect != rect || plan.upward != upward else { return }
        // List/status updates can change the target height during the bud. Keep the same spring clock/progress;
        // never leave the native ink at a different size from the material.
        self.plan=SheetBudMotion(rect:rect,upward:upward)
    }
    func start(card:SheetCard,upward:Bool,reduceMotion:Bool,at time:Double?=nil,windowless:Bool=false,rows:[(CGRect,CALayer)]=[]) {
        stop(reset:true);self.card=card
        plan=SheetBudMotion(rect:card.frame,upward:upward)
        // Model-only snapshots keep their endpoint, just like the original CA animation's model layer.
        began=time ?? sceneClock.mediaTime()
        guard !reduceMotion,card.window != nil || windowless else { return }
        if exposureEnabled {
            let content=SheetContentTransition(clock:sceneClock);contentTransition=content
            content.begin(in:card.content,mode:zoom,configuration:.spotlight,visible:true,at:time,scale:max(1,backingScaleOverride ?? card.window?.backingScaleFactor ?? 1),pivot:CGPoint(x:card.bounds.midX,y:upward ? card.bounds.height:0),rows:rows)
            began=content.commitTime
        }
        sample(elapsed:0,profile:profileOverride ?? M10FExposure.profile(for:card))
        guard !windowless else {return}
        let l=card.displayLink(target:self,selector:#selector(tick(_:)));l.add(to:.main,forMode:.common);link=l
    }
    func sample(elapsed:Double,profile:DisplayProfile) {
        guard let card,let plan else { return }
        let a=plan.pose(elapsed),b=plan.pose(max(0,elapsed-profile.frameInterval))
        CATransaction.begin();CATransaction.setDisableActions(true)
        let local=a.rect.offsetBy(dx:-plan.rect.minX,dy:-plan.rect.minY)
        card.placeMotionGlass(SheetStyle.snap(local,scale:max(1,backingScaleOverride ?? card.window?.backingScaleFactor ?? 1)),scale:a.scale)
        let h=plan.rect.height,w=plan.rect.width,pivot:CGFloat=plan.upward ? h:0
        let anchor=card.content.layer?.anchorPoint ?? .zero
        var transform=CATransform3DMakeScale(a.scale,a.scale,1)
        transform.m41=(w/2-anchor.x*w)*(1-a.scale)
        transform.m42=(pivot-anchor.y*h)*(1-a.scale)
        card.content.layer?.transform=transform
        contentTransition?.accumulate(now:a.rect,earlier:b.rect,profile:profile)
        lastSample=contentTransition?.lastExposure ?? .still
        contentTransition?.settle(at:began+elapsed)
        if zoom == .gauss,let content=contentTransition,content.effect?.plan == nil,content.effect?.resting == .visible {
            // The 100ms appearance is done; let native dots/hover keep drawing while the glass spring settles.
            content.finish();contentTransition=nil
        }
        CATransaction.commit()
    }
    @objc private func tick(_ display:CADisplayLink) {
        guard let card,let plan,card.window?.isVisible == true else { stop(reset:true);return }
        var p=profileOverride ?? M10FExposure.profile(for:card)
        if profileOverride == nil { p.frameInterval=max(1/1000,display.targetTimestamp-display.timestamp) }
        let elapsed=max(0,display.targetTimestamp-began)
        sample(elapsed:elapsed,profile:p)
        if elapsed>=plan.duration { stop(reset:true) }
    }
    func stop(reset:Bool) {
        link?.invalidate();link=nil
        if reset,let card {
            CATransaction.begin();CATransaction.setDisableActions(true)
            card.placeMotionGlass(nil);card.content.layer?.transform=CATransform3DIdentity
            card.content.resetExposure();lastSample = .still;CATransaction.commit()
            contentTransition?.finish();contentTransition=nil
        }
    }
    func openingOpacity(at time:Double)->Float {plan?.pose(max(0,time-began)).opacity ?? 1}
    func hideContent(at time:Double?=nil) {
        guard exposureEnabled,zoom == .gauss,let card else {return}
        if let contentTransition {contentTransition.setVisible(false,at:time ?? sceneClock.mediaTime())}
        else {
            let content=SheetContentTransition(clock:sceneClock);contentTransition=content
            content.begin(in:card.content,mode:.gauss,configuration:.spotlight,visible:false,at:time,scale:max(1,backingScaleOverride ?? card.window?.backingScaleFactor ?? 1),pivot:CGPoint(x:card.bounds.midX,y:plan?.upward == true ? card.bounds.height:0))
        }
    }
    isolated deinit { link?.invalidate() }
}

/// The same commit timestamp for the existing geometry channels and the prepared Gaussian.
@MainActor enum SheetMotionAnimation {
    static func animate(_ layer:CALayer,_ key:String,from:Any,to:Any,curve:OverlayCurve,at time:Double,delay:Double=0,enabled:Bool=true) {
        OverlayMotion.animate(layer,key,from:from,to:to,curve:curve,delay:delay,enabled:enabled)
        if let a=layer.animation(forKey:"overlay."+key)?.copy() as? CAAnimation {a.beginTime=layer.convertTime(time,from:nil)+delay;layer.add(a,forKey:"overlay."+key)}
    }
}
