import AppKit
import QuartzCore

/// A per-column queue survives an interrupted transition without changing the wheel's units or phases.
/// Weak object-identity keys keep two hosts borrowing the same retained transcript from sharing motion state.
@MainActor final class ColumnTranscriptHandoff {
    private static let states=NSMapTable<ColumnNode,ColumnTranscriptHandoff>(keyOptions:[.weakMemory,.objectPointerPersonality],valueOptions:.strongMemory)
    static func state(for column:ColumnNode)->ColumnTranscriptHandoff {
        if let state=states.object(forKey:column) {return state}
        let state=ColumnTranscriptHandoff();states.setObject(state,forKey:column);return state
    }
    static var replayDepth=0
    static var verificationThreshold:CGFloat?
    static var verificationFlightThreshold:CGFloat?
    static let configuredThreshold:CGFloat = {
        guard let text=ProcessInfo.processInfo.environment["M11_TRANSCRIPT_HANDOFF_PT"],let n=Double(text),n.isFinite,n>=0 else {return 8}
        return CGFloat(n)
    }()
    static let configuredFlightThreshold:CGFloat = {
        guard let text=ProcessInfo.processInfo.environment["M11_TRANSCRIPT_HANDOFF_FLIGHT_PT"],let n=Double(text),n.isFinite,n>=0 else {return 1.5}
        return CGFloat(n)
    }()
    static var verificationEarlyWheel:Bool?
    static var verificationWheelThreshold:CGFloat?
    static let configuredEarlyWheel=ProcessInfo.processInfo.environment["M11_TRANSCRIPT_EARLY_WHEEL"] != "0"
    static let configuredWheelThreshold:CGFloat = {
        guard let text=ProcessInfo.processInfo.environment["M11_TRANSCRIPT_WHEEL_PT"],let n=Double(text),n.isFinite,n>=0 else {return 24}
        return CGFloat(n)
    }()
    static let configuredWheelFlightThreshold:CGFloat = {
        guard let text=ProcessInfo.processInfo.environment["M11_TRANSCRIPT_WHEEL_FLIGHT_PT"],let n=Double(text),n.isFinite,n>=0 else {return 0.05}
        return CGFloat(n)
    }()
    static let wheelVelocityWeight:Double = {
        guard let text=ProcessInfo.processInfo.environment["M11_TRANSCRIPT_WHEEL_VELOCITY"],let n=Double(text),n.isFinite,n>=0 else {return 0}
        return n
    }()
    static let wheelFormEnvelope=ProcessInfo.processInfo.environment["M11_TRANSCRIPT_WHEEL_FORM"] == "1"
    static let wheelRelativeFlight=ProcessInfo.processInfo.environment["M11_TRANSCRIPT_WHEEL_RELATIVE_FLIGHT"] != "0"
    static let keepWheelFlights=ProcessInfo.processInfo.environment["M11_TRANSCRIPT_WHEEL_KEEP_FLIGHTS"] != "0"
    static let rangedGoals=ProcessInfo.processInfo.environment["M11_TRANSCRIPT_WHEEL_GOAL_RANGES"] != "0"
    static let edgeClip=ProcessInfo.processInfo.environment["M11_TRANSCRIPT_WHEEL_EDGE_CLIP"] != "0"
    static let clipSeconds:Double = {
        guard let text=ProcessInfo.processInfo.environment["M11_TRANSCRIPT_WHEEL_CLIP_SECONDS"],let n=Double(text),n.isFinite,n>0 else {return 0.08}
        return n
    }()
    var flightClipStart:Double=0,flightClipDuration:Double=0.08
    var flightClipPadding=CGSize.zero
    var flightClipLeft:CGFloat=0
    var preparedFlightVisibility:NativeTranscript.FlightVisibility?
    var previousFlightVisibility:NativeTranscript.FlightVisibility?
    var continuedFlights:[FlightNode]=[]
    var flightRoot:CALayer?,flightScroll:CALayer?
    var scrollObservation:NSObjectProtocol?
    weak var flightNative:NativeTranscript?
    var flightScrollStart:CGFloat=0,flightScrollForm:Double=1
    isolated deinit {
        if let scrollObservation {NotificationCenter.default.removeObserver(scrollObservation)}
        if let previousFlightVisibility {flightNative?.restoreFlightVisibility(previousFlightVisibility)}
        flightRoot?.removeFromSuperlayer()
    }
    static var earlyWheel:Bool {verificationEarlyWheel ?? configuredEarlyWheel}
    static var wheelThreshold:CGFloat {verificationWheelThreshold ?? configuredWheelThreshold}
    static var threshold:CGFloat {verificationThreshold ?? configuredThreshold}
    static var flightThreshold:CGFloat {verificationFlightThreshold ?? configuredFlightThreshold}
    var events:[NSEvent]=[]
    var replaying=false,handedOff=false,active=false
    var handoffTime:Double?
}

extension ColumnNode {
    var transcriptHandoff:ColumnTranscriptHandoff {ColumnTranscriptHandoff.state(for:self)}

    func beginTranscriptMotion() {
        let state=transcriptHandoff
        if !state.continuedFlights.isEmpty,ownsNative {
            // A reversal's departure is the scrolled native base; the retained plans still supply its missing glyphs.
            let mask=native.layer?.mask;native.layer?.mask=nil
            motionBase=native.snapshot(scale:scale);restWithGoal=motionBase;native.layer?.mask=mask
            finishContinuedTranscriptFlights()
        }
        state.handedOff=false;state.handoffTime=nil;state.active=ownsNative
        if ownsNative {
            native.layer?.removeAnimation(forKey:"column.motion.tail")
            native.layer?.mask?.removeAnimation(forKey:"column.motion.crop")
        }
        transcriptClip.isHidden=false;inkMaterial.isHidden=false;zoomSurface.layer.isHidden=false
        for tile in bakedPresence {tile.trail.isHidden=false}
    }

    func replayTranscriptWheel() {
        let state=transcriptHandoff
        guard ownsNative,!state.replaying,!state.events.isEmpty else {return}
        let events=state.events;state.events=[];state.replaying=true
        ColumnTranscriptHandoff.replayDepth+=1
        defer {state.replaying=false;ColumnTranscriptHandoff.replayDepth-=1}
        for event in events {native.scrollView.scrollWheel(with:event)}
    }

    func endTranscriptMotion() {
        let state=transcriptHandoff;state.active=false
        finishContinuedTranscriptFlights()
        guard ownsNative else {state.events=[];return}
        replayTranscriptWheel()
        native.layer?.removeAnimation(forKey:"column.motion.tail")
        native.layer?.mask?.removeAnimation(forKey:"column.motion.crop")
    }

    /// The idle path retains its displacement/speed envelope. Input may use the exact animated tail instead.
    /// Reflow must already have one layout; neither path cuts an unfinished wrap crossfade.
    func transcriptReady(at t:Double,threshold:CGFloat,flightThreshold:CGFloat,flights:[FlightNode],velocityWeight:Double=1,relativeFlight:Bool=false,includeForm:Bool=true)->Bool {
        guard threshold>0,isFull,ownsNative,!restOnSnapshot,!transcriptHandoff.handedOff else {return false}
        func remaining(_ spring:Spring)->Double {
            let s=spring.sample(t)
            return abs(s.value-spring.to)+velocityWeight*abs(s.velocity)*spring.response/(2 * .pi)
        }
        let reach=Double(max(rect.target.width,rect.target.height))
        let error=max(remaining(rect.x)+remaining(rect.w),remaining(rect.y)+remaining(rect.h),includeForm ? remaining(form)*reach:0,remaining(presence)*reach)
        guard error<=Double(threshold),fullReflow.map({$0.progress(at:t)>=1-0.00001}) ?? true else {return false}
        // Removed flights cannot retain their local stagger/scale. Input compares that local error to the native
        // tail at this instant; the idle path retains its conservative absolute endpoint comparison.
        let tail=relativeFlight ? transcriptTailTransform(at:t):CATransform3DIdentity
        let nativeOrigin=CGPoint(x:rect.target.minX+nativeArea.minX,y:rect.target.minY+nativeArea.minY)
        for flight in flights {
            let pose=flight.screenPose(rect:rect.sample(t).rect,form:form.sample(t).value)
            let endpoint=flight.screenPose(rect:rect.target,form:1)
            let local=CGPoint(x:endpoint.origin.x-nativeOrigin.x,y:endpoint.origin.y-nativeOrigin.y)
            let projected=local.applying(CATransform3DGetAffineTransform(tail))
            let end=relativeFlight ? (origin:CGPoint(x:projected.x+nativeOrigin.x,y:projected.y+nativeOrigin.y),scale:endpoint.scale*tail.m11):(origin:endpoint.origin,scale:endpoint.scale)
            let extent=max(flight.line.source.width,flight.line.source.height,flight.line.destination.width,flight.line.destination.height)
            if max(abs(pose.origin.x-end.origin.x),abs(pose.origin.y-end.origin.y))+abs(pose.scale-end.scale)*extent>flightThreshold {return false}
        }
        return true
    }

    /// This transform is shared by admission and the render-server tail, including the presence pivot.
    func transcriptTailTransform(at t:Double)->CATransform3D {
        let r=rect.sample(t).rect,p=CGFloat(presence.sample(t).value)
        let k=presenceScaleMap.base+presenceScaleMap.slope*p
        let pivot=CGPoint(x:rect.target.width/2-nativeArea.minX,y:logicalBottom-nativeArea.minY)
        var transform=CATransform3DMakeTranslation(r.minX-rect.target.minX,r.minY-rect.target.minY,0)
        transform=CATransform3DTranslate(transform,pivot.x,pivot.y,0)
        transform=CATransform3DScale(transform,k,k,1)
        return CATransform3DTranslate(transform,-pivot.x,-pivot.y,0)
    }

    func transcriptWheelReady(at t:Double,flights:[FlightNode])->Bool {
        guard ColumnTranscriptHandoff.threshold>0,ColumnTranscriptHandoff.earlyWheel else {return false}
        // Presence also carries opacity, which the transform tail does not replace. Keep its original envelope.
        let p=presence.sample(t),reach=Double(max(rect.target.width,rect.target.height))
        let presenceError=(abs(p.value-presence.to)+abs(p.velocity)*presence.response/(2 * .pi))*reach
        guard presenceError<=Double(ColumnTranscriptHandoff.threshold),MorphFlightMath.transcriptOpacity(form:form.sample(t).value,on:true)==1 else {return false}
        let carry=canContinueTranscriptFlights(at:t,flights:flights)
        return transcriptReady(at:t,threshold:ColumnTranscriptHandoff.wheelThreshold,
            flightThreshold:min(ColumnTranscriptHandoff.flightThreshold,ColumnTranscriptHandoff.configuredWheelFlightThreshold),flights:carry ? []:flights,
            velocityWeight:ColumnTranscriptHandoff.wheelVelocityWeight,relativeFlight:ColumnTranscriptHandoff.wheelRelativeFlight,includeForm:ColumnTranscriptHandoff.wheelFormEnvelope)
    }

    var hasContinuedTranscriptFlights:Bool {!transcriptHandoff.continuedFlights.isEmpty}

    func transcriptViewportFrame(at t:Double)->CGRect {
        let origin=CGPoint(x:rect.target.minX+nativeArea.minX,y:rect.target.minY+nativeArea.minY)
        let local=CGRect(x:0,y:0,width:nativeArea.width+rect.w.sample(t).value-rect.w.to,height:nativeArea.height)
        return local.applying(CATransform3DGetAffineTransform(transcriptTailTransform(at:t))).offsetBy(dx:origin.x,dy:origin.y)
    }

    func canContinueTranscriptFlights(at t:Double,flights:[FlightNode])->Bool {
        guard ColumnTranscriptHandoff.keepWheelFlights,!flights.isEmpty,transcriptHandoff.preparedFlightVisibility != nil,
              presence.sample(t).value==1 else {return false}
        let viewport=transcriptViewportFrame(at:t),opaque=viewport.insetBy(dx:0,dy:0)
        let band=CGRect(x:opaque.minX,y:opaque.minY+16,width:opaque.width,height:max(0,opaque.height-44))
        // The header boundary is immediate. Side/bottom boundaries start outside all current exposures,
        // then close continuously; a narration landing below the viewport must not delay native input.
        return flights.allSatisfy {flight in
            [t,t-motionProfile.frameInterval].allSatisfy {sample in
                let box=flight.continuationBounds(rect:rect.sample(sample).rect,form:form.sample(sample).value,lyricSize:lyricSize)
                return ColumnTranscriptHandoff.edgeClip ? box.minY>=band.minY:band.contains(box)
            }
        }
    }

    func continuedTranscriptClip(at t:Double)->CGRect {
        let state=transcriptHandoff,viewport=transcriptViewportFrame(at:t)
        let k=CGFloat(1-smoothstep(0,state.flightClipDuration,t-state.flightClipStart))
        return CGRect(x:viewport.minX-state.flightClipLeft*k,y:viewport.minY,
                      width:viewport.width+state.flightClipPadding.width*k,height:viewport.height+state.flightClipPadding.height*k)
    }

    static func flightClipLocations(_ box:CGRect)->[NSNumber] {
        [0,NSNumber(value:Double(16/max(44,box.height))),NSNumber(value:Double(1-28/max(44,box.height))),1]
    }

    private func installContinuedTranscriptFlights(at time:Double,began:Double,ends:Double,frameInterval:Double) {
        let state=transcriptHandoff
        guard let originalParent=state.continuedFlights.first?.replicator.superlayer else {return}
        // Keep glyphs above opaque native bubble/row backing, in the same screen-coordinate plane.
        let parent=native.superview?.layer ?? originalParent
        state.flightNative=native
        let root=CALayer(),scroll=CALayer(),mask=Self.fade()
        root.anchorPoint = .zero;root.frame=parent.bounds;scroll.anchorPoint = .zero;scroll.frame=root.bounds
        root.name="column.continued-flights";root.addSublayer(scroll);parent.addSublayer(root)
        state.flightRoot=root;state.flightScroll=scroll;state.flightScrollStart=native.scrollOffset.y
        state.flightScrollForm=form.sample(time-began).value
        state.flightClipStart=time-began
        state.flightClipDuration=max(0.000001,min(ColumnTranscriptHandoff.clipSeconds,form.duration-state.flightClipStart))
        state.flightClipLeft=0;state.flightClipPadding = .zero
        if ColumnTranscriptHandoff.edgeClip {
            let viewport=transcriptViewportFrame(at:time-began)
            let ink=state.continuedFlights.reduce(CGRect.null) {box,flight in
                [time-began,time-began-frameInterval].reduce(box) {partial,t in
                    partial.union(flight.continuationBounds(rect:rect.sample(t).rect,form:form.sample(t).value,lyricSize:lyricSize))
                }
            }
            let left=max(0,viewport.minX-ink.minX+1/scale),right=max(0,ink.maxX-viewport.maxX+1/scale)
            state.flightClipLeft=left
            state.flightClipPadding=CGSize(width:left+right,height:max(0,ink.maxY+28+1/scale-viewport.maxY))
        }
        let count=max(2,Int(ceil((ends-time)*Timeline.rate(frameInterval:frameInterval))))
        let times=(0...count).map{Double($0)/Double(count)}
        let boxes=times.map{continuedTranscriptClip(at:time+(ends-time)*$0-began)}
        // Keep the exchange model pose open too: a newly attached mask must never expose the final crop before its first CA sample.
        mask.anchorPoint = .zero;shapeFade(mask,boxes.first!.size);mask.frame=boxes.first!;root.mask=mask
        for (key,values) in [("position",boxes.map{NSValue(point:$0.origin)}),("bounds",boxes.map{NSValue(rect:CGRect(origin:.zero,size:$0.size))})] {
            let animation=CAKeyframeAnimation(keyPath:key);animation.values=values;animation.keyTimes=times.map{NSNumber(value:$0)}
            animation.duration=ends-time;animation.beginTime=mask.convertTime(time,from:nil);animation.fillMode = .both;animation.isRemovedOnCompletion=false
            ModeSignposts.frameRange(animation);mask.add(animation,forKey:"column.flight.clip."+key)
        }
        let locations=CAKeyframeAnimation(keyPath:"locations")
        locations.values=boxes.map{Self.flightClipLocations($0)};locations.keyTimes=times.map{NSNumber(value:$0)}
        locations.duration=ends-time;locations.beginTime=mask.convertTime(time,from:nil);locations.fillMode = .both;locations.isRemovedOnCompletion=false
        ModeSignposts.frameRange(locations);mask.add(locations,forKey:"column.flight.clip.locations")
        for flight in state.continuedFlights {scroll.addSublayer(flight.replicator)}
        state.scrollObservation=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:native.scrollView.contentView,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {self?.transportContinuedTranscriptFlights()}
        }
    }

    func transportContinuedTranscriptFlights() {
        let state=transcriptHandoff
        guard !state.continuedFlights.isEmpty,ownsNative else {return}
        let delta=state.flightScrollStart-native.scrollOffset.y
        CATransaction.begin();CATransaction.setDisableActions(true)
        state.flightScroll?.position.y=delta
        for flight in state.continuedFlights {
            flight.line.nativeScrollY=delta
            flight.line.nativeScrollForm=state.flightScrollForm
        }
        CATransaction.commit()
    }

    @discardableResult func finishContinuedTranscriptFlightsIfReady(at t:Double)->Bool {
        let state=transcriptHandoff
        guard !state.continuedFlights.isEmpty,t>=form.duration else {return false}
        finishContinuedTranscriptFlights();return true
    }

    func finishContinuedTranscriptFlights(restoringRetiredLease:Bool=false) {
        let state=transcriptHandoff
        guard !state.continuedFlights.isEmpty || state.previousFlightVisibility != nil else {return}
        CATransaction.begin();CATransaction.setDisableActions(true)
        if ownsNative || restoringRetiredLease,let visibility=state.previousFlightVisibility {native.restoreFlightVisibility(visibility)}
        for flight in state.continuedFlights {flight.replicator.removeFromSuperlayer()}
        state.flightRoot?.removeFromSuperlayer();state.flightRoot=nil;state.flightScroll=nil
        state.continuedFlights=[];state.previousFlightVisibility=nil
        if let observer=state.scrollObservation {NotificationCenter.default.removeObserver(observer);state.scrollObservation=nil}
        invalidateCaptures()
        if ownsNative {native.layoutSubtreeIfNeeded();native.displayIfNeeded()}
        CATransaction.commit()
    }

    /// Only the transcript changes owner here. Header, separator, Dock and every other column keep their original clocks.
    func handoffTranscript(at time:Double,began:Double,ends:Double,frameInterval:Double,flights:[FlightNode],continueFlights:Bool=false) {
        let state=transcriptHandoff
        guard !state.handedOff else {return}
        let work=M10ColumnWorkTrace.scope("column.handoffTranscript",["id":conversation.id,"queued":state.events.count,"elapsed":time-began])
        defer {work.end()}
        state.handedOff=true;state.handoffTime=time
        if continueFlights,let visibility=state.preparedFlightVisibility {
            state.previousFlightVisibility=native.flightVisibility()
            native.restoreFlightVisibility(visibility)
            state.continuedFlights=flights
            invalidateCaptures()
        }
        CATransaction.begin();CATransaction.setDisableActions(true)
        // The target layout is already the capture's layout. Never turn an exchange into the old 0.22 s scroll correction.
        motionOffset=nil
        let show=M10ColumnWorkTrace.scope("column.handoff.showRest")
        showRest(full:true);show.end()
        finishGaussian()
        transcriptClip.isHidden=true;inkMaterial.isHidden=true;zoomSurface.layer.isHidden=true
        for tile in bakedPresence {tile.trail.isHidden=true}
        if continueFlights {installContinuedTranscriptFlights(at:time,began:began,ends:ends,frameInterval:frameInterval)}
        else {for flight in flights {flight.replicator.removeFromSuperlayer()}}
        if let layer=native.layer,time<ends {
            let count=max(2,Int(ceil((ends-time)*Timeline.rate(frameInterval:frameInterval))))
            let times=(0...count).map { Double($0)/Double(count) }
            let samples=times.map { time+(ends-time)*$0-began }
            let tail=CAKeyframeAnimation(keyPath:"transform")
            tail.isAdditive=true
            tail.values=samples.map { NSValue(caTransform3D:transcriptTailTransform(at:$0)) }
            tail.keyTimes=times.map{NSNumber(value:$0)};tail.duration=ends-time
            tail.beginTime=layer.convertTime(time,from:nil);tail.fillMode = .backwards
            tail.calculationMode = .linear;ModeSignposts.frameRange(tail)
            layer.add(tail,forKey:"column.motion.tail")
            if let mask=layer.mask {
                let crop=CAKeyframeAnimation(keyPath:"bounds.size.width")
                crop.values=samples.map{NSNumber(value:Double(nativeArea.width)+rect.w.sample($0).value-rect.w.to)}
                crop.keyTimes=tail.keyTimes;crop.duration=tail.duration;crop.beginTime=mask.convertTime(time,from:nil)
                crop.fillMode = .backwards;crop.calculationMode = .linear;ModeSignposts.frameRange(crop)
                mask.add(crop,forKey:"column.motion.crop")
            }
        }
        replayTranscriptWheel()
        // Showing a retained lease may refresh deferred content; replay can also mount a different viewport.
        // Flush that layout and its restored glyph backing before this transaction removes the frozen owners.
        let layout=M10ColumnWorkTrace.scope("column.handoff.layoutSubtreeIfNeeded")
        native.layoutSubtreeIfNeeded();layout.end()
        let display=M10ColumnWorkTrace.scope("column.handoff.displayIfNeeded")
        native.displayIfNeeded();display.end()
        CATransaction.commit()
    }
}

extension AutoScene {
    /// RootView has already offered Peek and queueSwipe the event. A hidden full viewport keeps the original events in order.
    @discardableResult func transcriptWheel(_ event:NSEvent,at point:CGPoint)->Bool {
        guard ColumnTranscriptHandoff.replayDepth == 0,!inModeHandoff,began>=0,isMoving || columns.contains(where:{$0.transcriptHandoff.active}) else {return false}
        let t=now()-began
        guard let column=columns.first(where:{ column in
            guard column.isFull,column.ownsNative else {return false}
            let r=column.rect.sample(t).rect,area=column.nativeArea
            return CGRect(x:r.minX+area.minX,y:r.minY+area.minY,width:r.width,height:area.height).contains(point)
        }) else {return false}
        let state=column.transcriptHandoff
        guard !state.replaying else {return false}
        state.events.append(event)
        if state.handedOff {column.replayTranscriptWheel()}
        else {handoffTranscripts(at:now())}
        return true
    }

    func handoffTranscripts(at time:Double) {
        guard began>=0,!inModeHandoff else {return}
        for column in columns {
            let state=column.transcriptHandoff
            if state.handedOff {
                if column.finishContinuedTranscriptFlightsIfReady(at:time-began) {flights[column.conversation.id]=nil}
                continue
            }
            guard time<=ends else {continue}
            let nodes=flights[column.conversation.id] ?? []
            let wheelReady = !state.events.isEmpty && column.transcriptWheelReady(at:time-began,flights:nodes)
            if wheelReady || column.transcriptReady(at:time-began,threshold:ColumnTranscriptHandoff.threshold,flightThreshold:ColumnTranscriptHandoff.flightThreshold,flights:nodes) {
                column.handoffTranscript(at:time,began:began,ends:ends,frameInterval:profile.frameInterval,flights:nodes,
                    continueFlights:wheelReady && column.canContinueTranscriptFlights(at:time-began,flights:nodes))
                if !column.hasContinuedTranscriptFlights {flights[column.conversation.id]=nil}
            }
        }
    }
}
