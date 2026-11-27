import Foundation
import CoreGraphics

/// The board's delayed, velocity-preserving spring. Only new Tide channels use these recipes.
struct TideSpring {
    var value: PulseSpring
    var queued: (Double, Double, Double, Double)?
    init(_ x: Double) { value = PulseSpring(x) }
    var x: Double { value.x }
    var v: Double { value.v }
    var busy: Bool { queued != nil || value.busy }
    mutating func aim(_ x: Double, _ recipe: (Double, Double), after: Double = 0) {
        guard (queued?.0 ?? value.target) != x else { return }
        if after > 0 { queued = (x, recipe.0, recipe.1, after) }
        else { queued = nil; value.aim(x, recipe) }
    }
    mutating func snap() {
        if let q=queued {value.aim(q.0,(q.1,q.2));queued=nil}
        value.x=value.target;value.v=0
    }
    mutating func step(_ dt: Double) {
        if let q = queued {
            if q.3 <= dt { queued = nil; value.aim(q.0, (q.1,q.2)) }
            else { queued = (q.0,q.1,q.2,q.3-dt) }
        }
        value.step(dt)
    }
}

struct TideInkPhase {
    var k = 0.0, target = 0.0, delay = 0.0
    var inDuration = 0.11, outDuration = 0.07
    mutating func show(_ x: Double, after: Double = 0) { target=x;delay=x>0 ? after:0 }
    mutating func step(_ dt: Double) {
        if delay>0 {delay=max(0,delay-dt)}
        else if target>k {k=min(target,k+dt/inDuration)}
        else {k=max(target,k-dt/outDuration)}
    }
    var opacity: Double {let x=min(1,max(0,k));return x*x*(3-2*x)}
    var busy: Bool { k != target || delay>0 }
}

struct TideBorrowMotion {
    let id: String
    var original: CGRect
    var left: TideSpring, width: TideSpring, height: TideSpring, tail=TideSpring(0), lean=TideSpring(26)
    var content=TideInkPhase(k:1,target:1), face=TideInkPhase(inDuration:0.11,outDuration:0.06)
    init(id:String,rect:CGRect) {
        self.id=id;original=rect;left=TideSpring(rect.minX);width=TideSpring(rect.width);height=TideSpring(rect.height)
    }
    var rect:CGRect {CGRect(x:left.x,y:original.midY-height.x/2,width:max(36,width.x),height:height.x)}
    mutating func take(after:Double) {
        width.aim(36,(0.40,0.88),after:after);height.aim(36,(0.46,0.86),after:after+0.05)
        content.show(0);content.delay=after;face.show(1,after:after+0.13);tail.aim(1,(0.30,0.62),after:after+0.30)
    }
    mutating func restore(after:Double,fast:Bool=false) {
        tail.aim(0,(0.09,1));face.show(0)
        let recipe=fast ? (0.26,0.94):(0.44,0.84)
        width.aim(original.width,recipe,after:after);height.aim(original.height,recipe,after:after)
        content.show(1,after:after+(fast ? 0.05:0.16))
    }
    mutating func step(_ dt:Double) {left.step(dt);width.step(dt);height.step(dt);tail.step(dt);lean.step(dt);content.step(dt);face.step(dt)}
    var busy:Bool {left.busy || width.busy || height.busy || tail.busy || lean.busy || content.busy || face.busy}
}

struct TideDockMotion {
    var original:CGRect
    var right:TideSpring,width:TideSpring,height:TideSpring,lift=TideSpring(0)
    var widthDemand:Double
    init(_ r:CGRect) {original=r;right=TideSpring(r.maxX);width=TideSpring(r.width);height=TideSpring(r.height);widthDemand=r.width}
    var rect:CGRect {CGRect(x:right.x-width.x,y:original.midY-height.x/2-lift.x,width:width.x,height:height.x)}
    mutating func step(_ dt:Double) {right.step(dt);width.step(dt);height.step(dt);lift.step(dt)}
    var busy:Bool {right.busy || width.busy || height.busy || lift.busy}
}

/// Notice identity is consumed by the host; event and occupancy clocks are independent.
struct TideMotion {
    var bubbles:[String:TideBorrowMotion]=[:],nodes:[String:TideDockMotion]=[:]
    private(set) var briefOrder:[String],orbOrder:[String]
    var capacityDemand:Double?
    var contentInAt=0.19,haloInAt=0.19,visibilityHeld=false
    private(set) var lastKind=ConversationNotice.Kind.command
    private(set) var owner:String?,event:ConversationNotice?,eventRemaining=0.0,occupancyRemaining=0.0
    struct Pending {var owner:String;var notice:ConversationNotice;let order:Int}
    private(set) var pending:[Pending]=[]
    private var pendingSerial=0
    var liquidWidth:TideSpring,liquidOpacity=TideSpring(0)
    private let liquidOrbOpacity:Double
    var percentageInk=TideInkPhase(inDuration:0.12,outDuration:0.07)
    private(set) var displayedProgress:Double?
    private(set) var progress:Double?
    var workInProgress:Bool {progress.map{$0<1} ?? false}
    private(set) var displayedAction:ConversationNotice?
    private(set) var displayedHalo:ConversationNotice?
    private var queuedHalo:ConversationNotice?
    var actionInk=TideInkPhase(inDuration:0.12,outDuration:0.07)
    var haloInk=TideInkPhase(inDuration:0.12,outDuration:0.07)
    var detailInk=TideInkPhase(inDuration:0.12,outDuration:0.07)
    private(set) var inside=false,hovering=false,pinned=false,hoverAge=0.0
    var reduced=false
    private var protectionFacts:[String:Set<DockSlotLeases.Reason>]=[:]
    private var clockOrigin=0.0
    private var refused=false
    private(set) var level=0,returning=false,elapsed=0.0
    var paused:Bool {inside || hovering || pinned || visibilityHeld}
    var action:ConversationNotice? {event?.buttons.isEmpty == false ? event:nil}
    static func hold(_ notice:ConversationNotice)->Double {
        if !notice.buttons.isEmpty {return 7}
        return notice.kind == .command ? 5:notice.hold
    }
    mutating func syncPending(_ snapshot:ConversationNoticeSnapshot,owner id:String) {
        if owner==id {
            let wasWorking=workInProgress;progress=snapshot.progress;aimLiquid()
            if wasWorking,!workInProgress,occupancyRemaining==0,!returning {startReturn()}
        }
        let ids=Set(snapshot.pending.compactMap(\.requestID))
        pending.removeAll{$0.owner==id && !ids.contains($0.notice.requestID ?? "")}
        for notice in snapshot.pending {
            if let i=pending.firstIndex(where:{$0.owner==id && $0.notice.requestID==notice.requestID}) {pending[i].notice=notice}
            else {pendingSerial+=1;pending.append(.init(owner:id,notice:notice,order:pendingSerial))}
        }
        if owner==id,let request=event?.requestID {
            if let current=snapshot.pending.first(where:{$0.requestID==request}) {event=current;if displayedAction?.requestID==request {displayedAction=current}}
            else {
                // HTTP acknowledgement can remove pending without a second streamed response event.
                event = .init(kind:.reply,text:"Request resolved");lastKind = .reply;eventRemaining=1.8
                occupancyRemaining=1.8*1.7
                pinned=false;putLyric("Request resolved");retargetContent();retarget(level:level,opening:false)
            }
        }
    }
    mutating func resumeClock(at time:Double) {clockOrigin=time-elapsed}
    mutating func hover(_ value:Bool) {guard inside != value else{return};inside=value;hoverAge=0}
    mutating func togglePin(at time:Double,protection:[String:Set<DockSlotLeases.Reason>]) {
        pinned.toggle()
        if pinned,event == nil,let next=pending.min(by:{$0.order<$1.order}) {
            receive(next.notice,owner:next.owner,at:time,protection:protection)
        }
        retarget(level:level,opening:false)
    }
    mutating func dismiss() {
        guard active else{return}
        event=nil;eventRemaining=0;occupancyRemaining=0;inside=false;hovering=false;pinned=false
        startReturn()
    }
    private mutating func retargetContent() {
        if let event,!event.buttons.isEmpty {displayedAction=event;actionInk.show(1,after:contentInAt)}
        else {actionInk.show(0)}
        if let event,event.halo != .none {
            if !reduced,let old=displayedHalo,haloInk.k>0,(old.halo != event.halo || old.kind != event.kind) {
                queuedHalo=event;haloInk.show(0)
            } else {queuedHalo=nil;displayedHalo=event;haloInk.show(1,after:haloInAt)}
        } else {queuedHalo=nil;haloInk.show(0)}
    }
    private mutating func startReturn() {
        returning=true;queuedHalo=nil;aimLiquid();ink.show(0);actionInk.show(0);haloInk.show(0);detailInk.show(0);ownerInk.show(1,after:0.16)
        retarget(level:0,opening:false);leases.retire()
    }
    private mutating func aimLiquid() {
        // syncPending can deliver the ratio before its journal notice reaches receive().
        if progress != nil,!returning,liquidOpacity.value.target==0 {liquidOpacity=TideSpring(liquidOrbOpacity)}
        percentageInk.show(progress != nil && !returning ? 1:0)
        if let progress {displayedProgress=progress}
        // The board integrates percentage points; normalizing before integration changes its rest thresholds.
        if let progress {liquidWidth.aim(min(1,max(0,progress))*100,(0.6,0.9))}
        liquidOpacity.aim(progress != nil && !returning ? 0.24:0,(0.6,0.9))
    }
    var ink=TideInkPhase(inDuration:0.12,outDuration:0.07)
    var leases=DockSlotLeases()
    private var candidateText:String?,queuedLyric:String?,liveAge=0.0,residual=0.0
    private(set) var lyric="",previousLyric="",lyricAge=10.0,lyricSerial=0
    var lyricCurrentY=TideSpring(0),lyricOldY=TideSpring(-18),lyricNewY=TideSpring(18)
    var lyricCurrentAlpha=TideSpring(1),lyricOldAlpha=TideSpring(0),lyricNewAlpha=TideSpring(0)
    init(briefs:[(String,CGRect)],orbs:[(String,CGRect)],liquidStart:Double=100) {
        liquidWidth=TideSpring(liquidStart);liquidOrbOpacity=liquidStart>0 ? 0.42:0
        briefOrder=briefs.map(\.0);orbOrder=orbs.map(\.0)
        for (id,r) in briefs {bubbles[id] = .init(id:id,rect:r)}
        for (id,r) in orbs {nodes[id] = .init(r)}
    }
    /// Membership changes preserve unrelated event clocks and leases while updating geometric anchors.
    mutating func reflow(briefs:[(String,CGRect)],orbs:[(String,CGRect)]) {
        let live=Set(orbs.map(\.0))
        pending.removeAll { !live.contains($0.owner) }
        if let owner,!live.contains(owner) {
            if let token=leases.tide?.token { _=leases.release(token) }
            self.owner=nil;event=nil;eventRemaining=0;occupancyRemaining=0
        }
        briefOrder=briefs.map(\.0);orbOrder=orbs.map(\.0)
        bubbles=bubbles.filter { briefOrder.contains($0.key) };nodes=nodes.filter { live.contains($0.key) }
        for (id,r) in briefs {
            if var b=bubbles[id] {
                b.original=r
                if !briefOrder.prefix(level).contains(id) { b.left.aim(r.minX,(0.44,0.84));b.restore(after:0) }
                bubbles[id]=b
            } else { bubbles[id] = .init(id:id,rect:r) }
        }
        for (id,r) in orbs {
            if var n=nodes[id] { n.original=r;n.right.aim(r.maxX,(0.44,0.84));nodes[id]=n } else { nodes[id] = .init(r) }
        }
        if active { retarget(level:level,opening:false) }
    }
    var active:Bool {owner != nil}
    var busy:Bool {active && (bubbles.values.contains(where:\.busy) || nodes.values.contains(where:\.busy) || ink.busy || ownerInk.busy || actionInk.busy || haloInk.busy || queuedHalo != nil || detailInk.busy || lyricBusy || liquidWidth.busy || liquidOpacity.busy || percentageInk.busy)}
    var ownerInk=TideInkPhase(k:1,target:1,inDuration:0.11,outDuration:0.07)
    var lyricBusy:Bool {lyricCurrentY.busy || lyricOldY.busy || lyricNewY.busy || lyricCurrentAlpha.busy || lyricOldAlpha.busy || lyricNewAlpha.busy}
    var nextWake:Double? {
        guard active else{return nil}
        var deadlines=[Double]()
        if !paused {
            if occupancyRemaining>0 {deadlines.append(occupancyRemaining)}
            if eventRemaining>0 {deadlines.append(eventRemaining)}
        }
        if inside && !hovering {deadlines.append(max(0,0.28-hoverAge))}
        if !inside && hovering {deadlines.append(max(0,0.14-hoverAge))}
        if candidateText != nil {deadlines.append(max(0,0.9-liveAge))}
        if queuedLyric != nil {deadlines.append(max(0,0.42-lyricAge))}
        return deadlines.min()
    }
    var desiredLevel:Int {
        guard let c=briefOrder.first.flatMap({bubbles[$0]}),let right=orbOrder.last.flatMap({nodes[$0]?.original.maxX}) else{return 0}
        let want=(capacityDemand ?? ((action?.buttons.count ?? 0)>1 ? 300:192))+Double(max(0,orbOrder.count-1))*44
        if right-c.original.maxX-12>=want {return 0}
        if right-c.original.minX-48>=want {return 1}
        return 2
    }
    mutating func receive(_ raw:ConversationNotice,owner:String,at time:Double,protection:[String:Set<DockSlotLeases.Reason>]) {
        var notice=raw
        if notice.kind == .stoppedError {notice.buttons=[.init(title:"Review error",action:.review)]}
        let hold=Self.hold(notice)
        // A reply owns its hold before the oldest unanswered request can resume.
        if event?.kind == .reply,eventRemaining>0,!pending.isEmpty,!notice.urgent,notice.kind != .reply {
            occupancyRemaining=max(occupancyRemaining,hold*1.7);return
        }
        // Urgent actions retain the display while ordinary updates can only extend occupancy.
        if event?.urgent == true,event?.buttons.isEmpty == false,!notice.urgent,notice.kind != .reply {
            occupancyRemaining=max(occupancyRemaining,hold*1.7);return
        }
        let fresh=self.owner == nil,reopening=returning
        let incomingWater=notice.progress != nil && (progress == nil || self.owner != owner || reopening)
        if let previous=self.owner,previous != owner {leases.retire();inside=false;hovering=false;pinned=false}
        if self.owner != owner {progress=notice.progress}
        else if let value=notice.progress {progress=value}
        if notice.kind == .done || notice.kind == .stoppedError {progress=nil}
        self.owner=owner;event=notice;lastKind=notice.kind;returning=false
        eventRemaining=hold;occupancyRemaining=notice.kind == .reply ? hold*1.7:max(occupancyRemaining,hold*1.7);liveAge=0;candidateText=nil
        if incomingWater {liquidOpacity=TideSpring(liquidOrbOpacity)}
        retargetContent();aimLiquid()
        putLyric(notice.text,immediate:fresh || elapsed<0.03)
        if fresh {elapsed=0;residual=0;clockOrigin=time}
        if fresh || reopening {ink.show(1,after:contentInAt);ownerInk.show(briefOrder.isEmpty ? 1:0)}
        protect(protection,at:time)
        retarget(level:level,opening:fresh)
    }
    mutating func updateText(_ text:String) {if text != lyric {candidateText=text}}
    /// Admission consumes blocked velocity; the next frame starts at the glass that was actually shown.
    mutating func acceptRaisedPose(_ rect:CGRect,for id:String) {
        guard var node=nodes[id],!reduced else{return}
        if abs(node.width.x-rect.width)>0.000_001 {
            node.width.value.x=rect.width;node.width.value.v=0
        }
        let lift=node.original.midY-rect.midY
        if abs(node.lift.x-lift)>0.000_001 {
            node.lift.value.x=abs(lift-node.lift.value.target)<0.000_001 ? node.lift.value.target:lift
            node.lift.value.v=0
        }
        nodes[id]=node
    }
    /// Geometry admission is the displayed spring origin. Unseen progress cannot accumulate behind a neighbour.
    mutating func acceptRowPose(_ rect:CGRect,capacity:Double,for id:String) {
        guard var node=nodes[id],!reduced else{return}
        func accept(_ spring:inout TideSpring,_ value:Double) {
            if abs(spring.x-value)>0.000_001 {spring.value.x=value;spring.value.v=0}
        }
        accept(&node.width,rect.width);accept(&node.right,rect.maxX);accept(&node.height,rect.height)
        let target=min(node.widthDemand,max(32,capacity))
        // Binary contour admission can differ by one floating-point unit after a settled frame.
        // Keep the existing exact spring endpoint when that difference is below geometry precision.
        if let q=node.width.queued {
            if abs(q.0-target)>0.000_001 {node.width.queued=(target,q.1,q.2,q.3)}
        } else if abs(node.width.value.target-target)>0.000_001 {node.width.value.target=target}
        nodes[id]=node
    }
    mutating func protect(_ protection:[String:Set<DockSlotLeases.Reason>],at time:Double) {
        protectionFacts=protection
        for id in Set(briefOrder).union(protection.keys) {leases.updateProtection(protection[id] ?? [],for:id,at:time)}
        guard active,!returning else{return}
        let candidates=briefOrder.map{DockSlotLeases.Candidate(id:$0,role:.brief,protection:protection[$0] ?? [])}
        let request=leases.request(owner:owner!,purpose:.tide,count:desiredLevel,candidates:candidates,at:time)
        let next=request.lease?.briefs.count ?? 0
        if next != level {
            let previous=level
            let protected:Set<DockSlotLeases.Reason>=[.fullColumn,.draft,.attachment,.focus,.hover,.markedText,.choosingAttachment,.submitting,.reclaimed,.grace]
            retarget(level:next,opening:next>level,fast:next<previous && !request.reasons.intersection(protected).isEmpty)
        }
        let denied=desiredLevel>next
        if denied,!refused,let id=briefOrder.first,var b=bubbles[id],
           request.allowsRefusalKnock {
            // The board's -36 is a velocity impulse, not a 36 pt change of the text width.
            b.width.value.v-=36;bubbles[id]=b
            if let owner {nodes[owner]?.width.value.v+=90}
        }
        refused=denied
    }
    private mutating func retarget(level next:Int,opening:Bool,fast:Bool=false) {
        let old=level;level=next
        for (index,id) in briefOrder.enumerated() where index<2 {
            guard var b=bubbles[id] else{continue}
            if index<next,index>=old {b.take(after:index == 0 ? 0:(old==0 || elapsed<0.09 ? max(0,0.09-elapsed):0))}
            if index>=next,index<old {b.restore(after:fast ? 0:0.07+(old == 2 && index == 0 ? 0.09:0),fast:fast)}
            if index==0 {
                let x=next==2 ? (bubbles[briefOrder[1]]!.original.minX+48):b.original.minX
                b.left.aim(x,fast ? (0.26,0.94):(0.44,0.84),after:fast ? 0:next==2 ? (old==0 || elapsed<0.09 ? max(0,0.09-elapsed):0):(old==2 ? 0.16:0))
                b.lean.aim(next==2 ? 54:26,(0.34,0.72),after:next==2 ? (old==0 || elapsed<0.09 ? max(0,0.09-elapsed):0):(old==2 ? 0.07:0))
            }
            bubbles[id]=b
        }
        guard let owner,let c=briefOrder.first.flatMap({bubbles[$0]}),let last=orbOrder.last.flatMap({nodes[$0]}) else{return}
        let left:Double
        if next==2 {left=bubbles[briefOrder[1]]!.original.minX+96}
        else if next==1 {left=c.original.minX+48}
        else {left=c.original.maxX+12}
        let available=last.original.maxX-left-Double(max(0,orbOrder.count-1))*44
        var edge=last.original.maxX
        for id in orbOrder.reversed() {
            guard var n=nodes[id] else{continue}
            let expanded=occupancyRemaining>0 && id==owner
            let raised=expanded && action != nil && pinned && next==0
            let w=raised ? 300:expanded ? (next>0 ? min((action?.buttons.count ?? 0)==1 ? 192:Double.infinity,max(32,available)):(available>=68 ? 68:32)):32
            let h=expanded && w>68 ? (action?.buttons.count ?? 0 > 1 ? 48.0:40.0):32.0
            n.lift.aim(raised ? 60:0,(0.42,0.80))
            let targetRight=occupancyRemaining>0 ? edge:n.original.maxX
            let index=orbOrder.firstIndex(of:id) ?? 0
            let delay=opening ? 0.07+Double(abs(index-(orbOrder.firstIndex(of:owner) ?? 0)))*0.035:0
            n.right.aim(targetRight,targetRight<n.right.value.target ? (0.46,0.78):(0.56,0.68),after:delay)
            n.widthDemand=w
            n.width.aim(w,w>n.width.value.target ? (0.42,0.80):(0.50,0.86),after:delay)
            n.height.aim(h,h>n.height.value.target ? (0.42,0.80):(0.50,0.86),after:delay)
            nodes[id]=n;edge-=w+12
        }
    }
    mutating func putLyric(_ text:String,immediate:Bool=false) {
        guard text != lyric else{return}
        if immediate || lyric.isEmpty {lyric=text;previousLyric="";lyricAge=10;lyricSerial+=1;return}
        if lyricAge<0.42 {queuedLyric=text;return}
        previousLyric=lyric;lyric=text;lyricSerial+=1;lyricAge=0
        lyricOldY=TideSpring(-18);lyricOldY.aim(-36,(0.48,0.84));lyricOldAlpha=TideSpring(0)
        lyricCurrentY=TideSpring(0);lyricCurrentY.aim(-18,(0.48,0.84),after:0.03)
        lyricCurrentAlpha=TideSpring(1);lyricCurrentAlpha.aim(0,(0.30,1),after:0.03)
        lyricNewY=TideSpring(18);lyricNewY.aim(0,(0.48,0.84),after:0.08)
        lyricNewAlpha=TideSpring(0);lyricNewAlpha.aim(1,(0.30,1),after:0.08)
    }
    mutating func step(_ dt:Double,settleFromRest:Bool=false) {
        guard active,dt>0 else{return}
        // Idle semantic time still advances in full. A late wake starts the new pose at the
        // last displayed glass, rather than presenting several missed animation frames at once.
        let idleWake=settleFromRest && !busy && !reduced && dt>(nextWake ?? dt)+1.0/60+1e-8
        var deferPose=false
        // Fixed board ticks avoid a different Euler stencil at 60/120 Hz or large media timestamps.
        let h=1.0/240
        residual+=dt
        let count=max(0,Int(floor((residual+1e-8)/h)))
        residual-=Double(count)*h
        for _ in 0..<count {
            elapsed+=h;lyricAge+=h;liveAge+=h;hoverAge+=h
            if inside && !hovering && hoverAge+1e-9>=0.28 {hovering=true}
            if !inside && hovering && hoverAge+1e-9>=0.14 {hovering=false}
            if !paused {
                let previous=event
                eventRemaining=max(0,eventRemaining-h)
                if eventRemaining==0,event != nil {
                    event=nil;retargetContent();retarget(level:level,opening:false)
                    if previous?.kind == .reply,let next=pending.min(by:{$0.order<$1.order}) {
                        receive(next.notice,owner:next.owner,at:clockOrigin+elapsed,protection:protectionFacts)
                    }
                }
                occupancyRemaining=max(0,occupancyRemaining-h)
            }
            if lyricAge>=0.42,let next=queuedLyric {queuedLyric=nil;putLyric(next)}
            if liveAge>=0.9,let next=candidateText {candidateText=nil;liveAge=0;putLyric(next)}
            if occupancyRemaining==0,!returning,!workInProgress {startReturn()}
            detailInk.show(!returning && (hovering || pinned) && displayedAction == nil ? 1:0)
            if idleWake,busy {deferPose=true}
            if deferPose {continue}
            for id in briefOrder {bubbles[id]?.step(h)}
            for id in orbOrder {nodes[id]?.step(h)}
            liquidWidth.step(h);liquidOpacity.step(h)
            if liquidOpacity.x==0,liquidOpacity.value.target==0 {liquidWidth.snap()}
            ink.step(h);ownerInk.step(h);actionInk.step(h);haloInk.step(h);detailInk.step(h);percentageInk.step(h)
            if percentageInk.k==0,percentageInk.target==0 {displayedProgress=nil}
            if actionInk.opacity==0,action == nil {displayedAction=nil}
            if haloInk.opacity==0 {
                if let next=queuedHalo {displayedHalo=next;queuedHalo=nil;haloInk.show(1)}
                else if (event?.halo ?? NoticeHalo.none) == NoticeHalo.none {displayedHalo=nil}
            }
            lyricOldY.step(h);lyricCurrentY.step(h);lyricNewY.step(h);lyricOldAlpha.step(h);lyricCurrentAlpha.step(h);lyricNewAlpha.step(h)
        }
        if reduced {
            for id in briefOrder {
                bubbles[id]?.left.snap();bubbles[id]?.width.snap();bubbles[id]?.height.snap();bubbles[id]?.tail.snap();bubbles[id]?.lean.snap()
                if var b=bubbles[id] {b.content.k=b.content.target;b.content.delay=0;b.face.k=b.face.target;b.face.delay=0;bubbles[id]=b}
            }
            for id in orbOrder {nodes[id]?.right.snap();nodes[id]?.width.snap();nodes[id]?.height.snap();nodes[id]?.lift.snap()}
            liquidWidth.snap();liquidOpacity.snap()
            ink.k=ink.target;ink.delay=0;ownerInk.k=ownerInk.target;ownerInk.delay=0
            actionInk.k=actionInk.target;actionInk.delay=0;haloInk.k=haloInk.target;haloInk.delay=0;detailInk.k=detailInk.target;detailInk.delay=0;percentageInk.k=percentageInk.target;percentageInk.delay=0
            lyricCurrentY.snap();lyricOldY.snap();lyricNewY.snap();lyricCurrentAlpha.snap();lyricOldAlpha.snap();lyricNewAlpha.snap()
        }
        if returning,!bubbles.values.contains(where:\.busy),!nodes.values.contains(where:\.busy),!ink.busy,!ownerInk.busy {owner=nil}
    }
}
