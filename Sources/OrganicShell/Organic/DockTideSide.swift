import AppKit
import QuartzCore

@MainActor private final class TideSideShadowView:NSView {override var isFlipped:Bool {true};override func hitTest(_ point:NSPoint)->NSView? {nil}}

/// Retained badge ink bridges the original orb and its badge-free Tide face. It never changes glass.
@MainActor private final class TideSideBadgeView:NSView {
    override var isFlipped:Bool {true}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    private let plate=CAShapeLayer(),text=CATextLayer()
    private struct Sample:Equatable {let value:OrbBadge,orb:CGRect,opacity:Double,scale:CGFloat}
    private var sample:Sample?
    init() {
        super.init(frame:.zero);wantsLayer=true;isHidden=true
        layer?.addSublayer(plate);plate.addSublayer(text);plate.lineWidth=1;text.alignmentMode = .center
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
    func render(_ value:OrbBadge?,orb:CGRect,opacity:Double,scale:CGFloat) {
        guard let value,opacity>0 else{if !isHidden {isHidden=true};return}
        let next=Sample(value:value,orb:orb,opacity:opacity,scale:scale);guard sample != next || isHidden else{return};sample=next;isHidden=false
        let d=min(orb.width*0.4,18),string=value.symbol.text
        let base=NSFont.systemFont(ofSize:d*(string.count>2 ? 0.48:0.62),weight:.bold)
        let font=base.fontDescriptor.withDesign(.rounded).flatMap{NSFont(descriptor:$0,size:base.pointSize)} ?? base
        let width=max(d,(string as NSString).size(withAttributes:[.font:font]).width+(string.count>1 ? d*0.44:0))
        frame=CGRect(x:orb.minX+orb.width*0.86-width/2,y:orb.minY+orb.height*0.14-d/2,width:width,height:d)
        plate.frame=bounds;plate.path=CGPath(roundedRect:bounds,cornerWidth:d/2,cornerHeight:d/2,transform:nil)
        plate.fillColor=(value.tone == .red ? NSColor.systemRed:value.tone == .yellow ? .systemYellow:.systemGreen).cgColor
        plate.strokeColor=NSColor(srgbRed:42/255,green:43/255,blue:42/255,alpha:1).cgColor
        text.font=font;text.fontSize=font.pointSize;text.string=string;text.contentsScale=max(1,scale)*2
        text.foregroundColor=(value.tone == .red ? NSColor.white:NSColor.black.withAlphaComponent(0.85)).cgColor
        text.frame=CGRect(x:0,y:(d-font.ascender+font.descender)/2,width:width,height:font.ascender-font.descender)
        layer?.opacity=Float(opacity)
    }
}

/// One retained side surface. Native glass shares the existing Dock container; ink is above its backdrop.
@MainActor final class DockTideSide {
    let id:String,glass=NSGlassEffectView(),orbGlass=NSGlassEffectView(),words:DockTidePresentation
    let restingAnchor:CGRect
    private var dockRise=0.0
    let face:DockTideFace
    let orbHit=DockTideHitView()
    var motion:TideMotion,pose:TideSideMotion
    private let shadowHost=TideSideShadowView(),shadow=CALayer()
    private let badgeView=TideSideBadgeView()
    private var badge:OrbBadge?,backingScale:CGFloat
    private var badgeInk=TideInkPhase(k:1,target:1,inDuration:0.11,outDuration:0.07)
    private var stem:[NSGlassEffectView]=[]
    private var parts:[CGRect]=[]
    private var lastTime:Double?
    private var lastCard:CGRect?,lastOrb:CGRect?
    private var parked=true
    private(set) var arrivalAt=Double.infinity
    private(set) var contourBlocked=false
    private var admitted=false
    private var visibility=TideInkPhase(k:1,target:1,inDuration:0.12,outDuration:0.07)
    private var formInk=TideInkPhase(k:1,target:1,inDuration:0.12,outDuration:0.07)
    private var displayedRows=false,pendingRows:Bool?
    private var waiting:Bool {!admitted && !motion.returning && motion.active && (motion.action != nil || (motion.event?.halo ?? .none) != .none)}
    var nextWake:Double? {waiting ? nil:motion.nextWake}
    private weak var parent:NSView?
    private(set) var writes=0,callbacks=0
    var onWake:(()->Void)?
    var ready:Bool {stem.count==TideTailBudget.pieces}
    var active:Bool {motion.active || pose.shown}
    var busy:Bool {active && (pose.busy || visibility.busy || formInk.busy || pendingRows != nil || (pose.shown && badgeInk.busy) || (!waiting && motion.busy) || (waiting && motion.haloInk.busy))}
    init(id:String,anchor:CGRect,composerTop:Double,parent:NSView,inkParent:NSView,container:NSView,style:NSGlassEffectView.Style,configuration:OrbConfiguration) {
        self.id=id;self.parent=parent;restingAnchor=anchor
        badge=configuration.badge;backingScale=configuration.backingScale
        motion=TideMotion(briefs:[],orbs:[],liquidStart:0);motion.contentInAt=0.20;motion.haloInAt=0.06;pose=TideSideMotion(anchor:anchor,composerTop:composerTop)
        glass.identifier = .init("tide.side."+id);glass.style=style;glass.isHidden=true;parent.addSubview(glass)
        orbGlass.style=style;orbGlass.identifier = .init("tide.side.orb."+id);orbGlass.isHidden=true;parent.addSubview(orbGlass)
        face=DockTideFace(id:"side."+id,glass:orbGlass,configuration:configuration)
        inkParent.addSubview(face.orb.backView,positioned:.below,relativeTo:container)
        inkParent.addSubview(face.orb.frontView,positioned:.above,relativeTo:container)
        face.orb.setCanvasSize(inkParent.bounds.size)
        inkParent.addSubview(badgeView,positioned:.above,relativeTo:face.orb.frontView)
        shadowHost.wantsLayer=true;shadowHost.frame=inkParent.bounds;shadowHost.isHidden=true
        shadow.shadowColor=NSColor.black.cgColor;shadow.shadowRadius=12;shadow.shadowOffset=CGSize(width:0,height:6);shadow.shadowOpacity=0.25
        shadowHost.layer?.addSublayer(shadow);inkParent.addSubview(shadowHost,positioned:.below,relativeTo:container)
        words=DockTidePresentation(parent:inkParent,below:container);words.sideCard=true
        orbHit.isHidden=true;inkParent.addSubview(orbHit)
        orbHit.onPress={ [weak words] in words?.onPin?() }
        orbHit.onPointer={ [weak words] event in words?.onPointer?(event) }
    }
    func prepareOne() {
        guard !ready,let parent else{return}
        let v=NSGlassEffectView();v.identifier = .init("tide.side.stem.\(id).\(stem.count)")
        v.style=glass.style;v.tintColor=glass.tintColor;v.isHidden=true;parent.addSubview(v,positioned:.below,relativeTo:glass);stem.append(v)
    }
    func followDock(centerX:Double,rise:Double) {pose.translate(anchorX:centerX-pose.anchor.midX,y:dockRise-rise);dockRise=rise}
    func advance(to time:Double) {
        guard let previous=lastTime else{lastTime=time;return}
        let dt=max(0,time-previous);lastTime=time
        motion.reduced=Motion.reduce
        motion.visibilityHeld=waiting;motion.step(dt,settleFromRest:true)
        visibility.step(dt)
        badgeInk.step(dt)
        formInk.step(dt)
        if let next=pendingRows,(formInk.opacity==0 || Motion.reduce) {displayedRows=next;pendingRows=nil;formInk.show(1)}
        if Motion.reduce {visibility.k=visibility.target;visibility.delay=0;badgeInk.k=badgeInk.target;badgeInk.delay=0}
        if Motion.reduce {formInk.k=formInk.target;formInk.delay=0}
        pose.step(dt,reduced:Motion.reduce)
    }
    func receive(_ snapshot:ConversationNoticeSnapshot,incoming:[ConversationNotice],at time:Double) {
        advance(to:time)
        if !incoming.isEmpty {contourBlocked=false}
        if !motion.active,!incoming.isEmpty {arrivalAt=time}
        var summary=snapshot
        summary.pending=summary.pending.map(Self.summary)
        summary.journal=summary.journal.map(Self.summary)
        motion.syncPending(summary,owner:id)
        for notice in incoming {
            if notice.kind == .reply,notice.text == "Request expired",!motion.active || motion.returning {continue}
            motion.receive(Self.summary(notice),owner:id,at:time,protection:[:])
        }
        if let notice=summary.journal.first(where:{$0.id==motion.event?.id}) {motion.updateText(notice.text)}
    }
    /// A command is available in the full decision view; the margin card keeps the request's title.
    private static func summary(_ raw:ConversationNotice)->ConversationNotice {
        var notice=raw
        if notice.kind == .approval,let command=notice.request["params"]?["command"]?.stringValue,
           !command.isEmpty,notice.text.hasSuffix(command) {
            notice.text=String(notice.text.dropLast(command.count)).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        return notice
    }
    func pin(at time:Double) {contourBlocked=false;advance(to:time);motion.togglePin(at:time,protection:[:]);onWake?()}
    func hover(_ inside:Bool,at time:Double) {advance(to:time);motion.hover(inside);onWake?()}
    func dismiss(at time:Double) {advance(to:time);motion.dismiss();pose.aim(nil);onWake?()}
    func target(_ rect:CGRect?,staged:Bool=false) {
        let was=admitted;admitted=rect != nil
        if let rect {
            let rows=rect.height>=70
            if !pose.shown || motion.ink.opacity==0 {displayedRows=rows;pendingRows=nil;formInk.k=1;formInk.target=1;formInk.delay=0}
            else if rows != (pendingRows ?? displayedRows) {pendingRows=rows;formInk.show(0)}
        }
        if !was,admitted {
            if !pose.shown {badgeInk=TideInkPhase(k:1,target:1,inDuration:0.11,outDuration:0.07)}
            badgeInk.show(0)
        }
        if was,!admitted {badgeInk.show(1,after:0.16)}
        if was != admitted {
            if admitted,motion.ink.k<1 {visibility=TideInkPhase(k:1,target:1,inDuration:0.12,outDuration:0.07)}
            else {
                if admitted,!pose.shown {visibility.k=0;visibility.target=0}
                visibility.show(admitted ? 1:0,after:admitted ? 0.2:0)
            }
        }
        pose.aim(rect,staged:staged)
    }
    func configure(_ configuration:OrbConfiguration) {badge=configuration.badge;backingScale=configuration.backingScale;face.configure(configuration)}
    var candidate:TideSidePacking.Candidate? {
        guard motion.active,!motion.returning,!contourBlocked else{return nil}
        let action=motion.action
        let width=min(300,max(150,(motion.lyric as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.semibold)]).width+51))
        return .init(id:id,anchor:pose.anchor,preferred:width,action:action != nil,one:action?.buttons.count==1,rank:(action != nil ? 4:0)+(motion.lastKind == .stoppedError || motion.lastKind == .retryingError ? 2:0)+((motion.event?.halo ?? .none) != .none ? 1:0))
    }
    /// The stem follows the same rendered-tail taper, stopping inside the orb before its thin SVG end.
    private func stemParts(card:CGRect,orb:CGRect)->[CGRect] {
        guard ready,!stem.isEmpty else{return []}
        let k=max(0,min(1,(pose.anchor.midY+6-card.maxY)/(pose.anchor.midY+6-(pose.composerTop-14))))
        guard k>0.02 else{return []}
        let side=card.midX>=orb.midX ? 1.0:-1.0
        let rx=card.width>36 ? max(card.minX+16,min(card.maxX-16,orb.midX+side*8)):card.midX
        let root=CGPoint(x:rx,y:card.maxY-3),tip=CGPoint(x:orb.midX,y:orb.midY)
        let len=hypot(tip.x-root.x,tip.y-root.y),control=CGPoint(x:rx,y:root.y+len*0.62)
        // The orb covers the last thin section. Every retained disc overlaps its next disc by at least 1 pt.
        var result:[CGRect]=[]
        for index in 0..<stem.count {
            let u=Double(index)/Double(max(1,stem.count-1))*0.76,m=1-u
            let p:CGPoint
            if abs(root.x-tip.x)>26,card.maxY<pose.composerTop-30 {
                // The alternate parked lane bends back before entering the neighbouring composer's row.
                // Its full native discs are admitted below; the stem is never scaled thinner to fit.
                let first=CGPoint(x:root.x,y:root.y+len*0.25),second=CGPoint(x:tip.x+(root.x>tip.x ? -40:40),y:tip.y-8)
                p=CGPoint(x:m*m*m*root.x+3*m*m*u*first.x+3*m*u*u*second.x+u*u*u*tip.x,
                          y:m*m*m*root.y+3*m*m*u*first.y+3*m*u*u*second.y+u*u*u*tip.y)
            } else {p=CGPoint(x:m*m*root.x+2*m*u*control.x+u*u*tip.x,y:m*m*root.y+2*m*u*control.y+u*u*tip.y)}
            let rootBlend=max(0,1-u/0.35),narrow=min(1,max(0,(u-0.40)/0.25))
            var r=max(0.6,0.6+(5.5*min(1,0.5+0.5*k)-0.6)*pow(m,1.6)+0.55*rootBlend*rootBlend-0.95*narrow)
            if let previous=result.last {r=max(r,hypot(p.x-previous.midX,p.y-previous.midY)-previous.width/2+1)}
            result.append(CGRect(x:p.x-r,y:p.y-r,width:2*r,height:2*r))
        }
        return result
    }
    func projectedPhysical(_ card:CGRect)->[CGRect] {
        let orb=CGRect(x:pose.anchor.midX-18,y:pose.anchor.midY-18,width:36,height:36)
        return [card,orb]+stemParts(card:card,orb:orb)
    }
    private func admit(_ proposed:CGRect,orb:CGRect,obstacles:[CGRect])->CGRect? {
        func fits(_ r:CGRect)->Bool {([r,orb]+stemParts(card:r,orb:orb)).allSatisfy{a in obstacles.allSatisfy{TideContour.gap(a,$0)>=11.99999}}}
        if fits(proposed) {return proposed}
        guard var current=lastCard,current.width>=13.99,current.height>=13.99,fits(current) else{return nil}
        // Each admitted axis starts at the preceding axis's result. An old rectangle must never undo it.
        for axis in 0..<7 {
            var attempt=current
            switch axis {
            case 0:attempt.size.width=min(current.width,proposed.width)
            case 1:attempt.size.height=min(current.height,proposed.height)
            case 2:attempt.origin.x=proposed.midX-current.width/2
            case 3:attempt.origin.y=proposed.maxY-current.height
            case 4:attempt.size.width=proposed.width
            case 5:attempt.size.height=proposed.height;attempt.origin.y=current.maxY-proposed.height
            default:
                if let goal=pose.goal {
                    let step=max(1,abs(proposed.midX-current.midX),abs(proposed.width-current.width)/2)
                    attempt.origin.x+=max(-step,min(step,goal.minX-current.minX))
                }
            }
            if fits(attempt) {current=attempt;continue}
            var lo=0.0,hi=1.0
            let from=current
            func mix(_ k:Double)->CGRect {CGRect(x:from.minX+(attempt.minX-from.minX)*k,y:from.minY+(attempt.minY-from.minY)*k,width:from.width+(attempt.width-from.width)*k,height:from.height+(attempt.height-from.height)*k)}
            for _ in 0..<24 {let m=(lo+hi)/2;if fits(mix(m)) {lo=m}else{hi=m}}
            current=mix(lo)
        }
        return current
    }
    /// Returns the enlarged native orb pose; the host remains its only body writer.
    func render(title:String,color:NSColor,obstacles:[CGRect],write:(NSGlassEffectView,CGRect,Bool)->Void)->CGRect {
        callbacks+=1
        guard active,pose.shown else{park();return pose.anchor}
        parked=false
        let orb=pose.orb;var card=pose.card
        guard let legal=admit(card,orb:orb,obstacles:obstacles) else {
            contourBlocked=true;admitted=false
            pose=TideSideMotion(anchor:pose.anchor,composerTop:pose.composerTop)
            visibility.k=0;visibility.target=0;visibility.delay=0
            park();return pose.anchor
        }
        if legal != card {pose.accept(legal);card=legal}
        let tails=stemParts(card:card,orb:orb)
        if lastCard != card || lastOrb != orb || parts != tails {
            let path=CGMutablePath();path.addRoundedRect(in:card,cornerWidth:min(pose.radius.x,card.height/2),cornerHeight:min(pose.radius.x,card.height/2))
            path.addEllipse(in:orb)
            for r in tails {path.addEllipse(in:r)}
            shadow.shadowPath=path;shadowHost.isHidden=false
        }
        if lastCard != card || glass.isHidden {
            write(glass,card,false);glass.cornerRadius=min(pose.radius.x,min(card.width,card.height)/2);lastCard=card;writes+=1
        }
        if parts != tails {
            for (i,v) in stem.enumerated() {
                if tails.indices.contains(i) {write(v,tails[i],false);v.cornerRadius=tails[i].width/2}
                else if !v.isHidden {write(v,.zero,true)}
            }
            writes+=1;parts=tails
        }
        let tint=color.usingColorSpace(.sRGB) ?? color
        let tone=NSColor(srgbRed:(58*0.84+tint.redComponent*255*0.16)/255,green:(59*0.84+tint.greenComponent*255*0.16)/255,blue:(58*0.84+tint.blueComponent*255*0.16)/255,alpha:0.92)
        for v in [glass,orbGlass]+stem where v.tintColor != tone {v.tintColor=tone;writes+=1}
        if lastOrb != orb || orbGlass.isHidden {write(orbGlass,orb,false);orbGlass.cornerRadius=orb.width/2;writes+=1}
        // The planet stays visible while the bud/card's independent content arrives and retreats.
        face.render(rect:orb,opacity:1)
        badgeView.render(badge,orb:orb,opacity:badgeInk.opacity,scale:backingScale)
        orbHit.frame=orb;orbHit.isHidden=false;orbHit.interactive=true
        let bounds=tails.reduce(orb.union(card)){$0.union($1)}
        var content=motion
        let actionForm=motion.actionInk.k==motion.actionInk.target ? formInk.k:1
        content.ink.k*=visibility.k*formInk.k;content.actionInk.k*=visibility.k*actionForm;content.detailInk.k*=visibility.k*formInk.k
        words.sideTwoRows=displayedRows
        words.render(content,rect:card,tailBounds:bounds,title:title,color:color)
        lastOrb=orb
        return orb
    }
    /// The first glass frame is committed after render(). Size its dedicated ink viewport in that same batch.
    func finishMaterialFrame() {
        guard pose.shown,!orbGlass.isHidden,let content=orbGlass.contentView else{return}
        let bounds=CGRect(origin:.zero,size:orbGlass.bounds.size)
        if content.frame != bounds {content.frame=bounds}
    }
    var physical:[CGRect] {guard let card=lastCard,let orb=lastOrb else{return []};return [card,orb]+parts}
    var probe:[String:Any] {
        ["owner":id,"active":active,"visible":!parked,"motionBusy":busy,"event":motion.event?.kind.rawValue ?? "","returning":pose.returning,"waiting":waiting,"admitted":admitted,"contourBlocked":contourBlocked,
         "goal":pose.goal.map(DockTideShape.rect) ?? [],"widthState":[pose.width.x,pose.width.v,pose.width.value.target,pose.width.queued?.0 ?? -1],"centerState":[pose.center.x,pose.center.v,pose.center.value.target],"heightState":[pose.height.x,pose.height.v,pose.height.value.target],"rawCard":DockTideShape.rect(pose.card),"poseBusy":pose.busy,"card":DockTideShape.rect(lastCard ?? .zero),"orb":DockTideShape.rect(lastOrb ?? pose.anchor),"stem":parts.map(DockTideShape.rect),
         "nativeParts":2+stem.count,"faceViewport":DockTideShape.rect(orbGlass.contentView?.frame ?? .zero),"faceCanvas":DockTideShape.rect(face.orb.frontView.frame),"writes":writes,"callbacks":callbacks,"face":face.probe,"badgeAlpha":badge == nil ? 0:badgeInk.opacity,"contentRows":displayedRows ? 2:1,"formAlpha":formInk.opacity,"presentation":words.probe,"eventRemaining":motion.eventRemaining,"occupancyRemaining":motion.occupancyRemaining]
    }
    /// A sleeping surface keeps its last pose. Diagnostics still report the live semantic deadlines.
    func probe(at time:Double)->[String:Any] {
        var result=probe
        let age=motion.paused || !motion.active ? 0:max(0,time-(lastTime ?? time))
        result["eventRemaining"]=max(0,motion.eventRemaining-age)
        result["occupancyRemaining"]=max(0,motion.occupancyRemaining-age)
        result["sampleAt"]=lastTime ?? time;result["probeAt"]=time
        return result
    }
    var physicalProbe:[String:Any] {
        var p=probe
        p["card"]=DockTideShape.rect(glass.frame);p["orb"]=DockTideShape.rect(orbGlass.frame)
        p["stem"]=stem.filter{!$0.isHidden}.map{DockTideShape.rect($0.frame)}
        p["visible"] = !glass.isHidden;p["radius"]=glass.cornerRadius
        return p
    }
    @discardableResult func park(keepHalo:Bool=false)->Bool {guard !parked else{if !keepHalo,words.probe["haloOnly"] as? Bool==true {words.park()};return false};parked=true;shadowHost.isHidden=true;badgeView.isHidden=true;orbHit.isHidden=true;face.park();orbGlass.isHidden=true;glass.isHidden=true;stem.forEach{$0.isHidden=true};words.park();lastCard=nil;parts=[];lastOrb=nil;return true}
    func renderWaitingHalo(title:String,color:NSColor) {words.renderHaloOnly(motion,rect:pose.anchor)}
    func retire() {motion=TideMotion(briefs:[],orbs:[],liquidStart:0);motion.contentInAt=0.20;motion.haloInAt=0.06;pose=TideSideMotion(anchor:pose.anchor,composerTop:pose.composerTop);lastTime=nil;admitted=false;contourBlocked=false;displayedRows=false;pendingRows=nil;formInk=TideInkPhase(k:1,target:1,inDuration:0.12,outDuration:0.07);visibility=TideInkPhase(k:1,target:1,inDuration:0.12,outDuration:0.07);park()}
    func fadeModeExit(_ fade:TideModeExit) {
        fade.include([glass,orbGlass,face.orb.backView,face.orb.frontView,badgeView]+stem)
        fade.include([shadowHost],plane:.behindMaterial)
        words.fadeModeExit(fade)
    }
    func dispose() {park();shadowHost.removeFromSuperview();badgeView.removeFromSuperview();orbHit.removeFromSuperview();face.dispose();orbGlass.removeFromSuperview();glass.removeFromSuperview();stem.forEach{$0.removeFromSuperview()};words.dispose()}
}
