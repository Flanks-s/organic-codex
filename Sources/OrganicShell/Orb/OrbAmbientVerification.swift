#if M10_DOCK_SELFTEST || ORB_SELFTEST
import AppKit
import QuartzCore

/// M11.47 is independently testable without Tide or its animation audit.
@MainActor enum OrbAmbientVerification {
    static func run(check:(Bool,String)->Void) {
        let c=Conversation(id:"ambient",title:"Ambient contract")
        let store=ConversationStore(conversations:[c]),orb=OrbComponent(id:"ambient-contract")
        func configuration()->OrbConfiguration {makeOrbConfiguration(c,drawingSize:40,backingScale:2,reduceMotion:false,ambient:true,isKeyWindow:true)}
        func refresh(){orb.configure(configuration())}
        func layers()->[CALayer] {
            var result:[CALayer]=[],seen=Set<ObjectIdentifier>()
            func layer(_ l:CALayer) {
                guard seen.insert(ObjectIdentifier(l)).inserted else{return};result.append(l)
                if let mask=l.mask {layer(mask)};for child in l.sublayers ?? [] {layer(child)}
            }
            func view(_ v:NSView){if let l=v.layer{layer(l)};for child in v.subviews {view(child)}}
            for v in [orb.glassView,orb.backView,orb.frontView] {view(v)};return result
        }
        func settle()->CAAnimation? {layers().compactMap{$0.animation(forKey:"eventSettle")}.first}
        func loops(_ l:CALayer)->Int {
            let own=(l.animationKeys() ?? []).filter{key in guard let a=l.animation(forKey:key) else{return false};return !a.repeatCount.isFinite || a.repeatCount>1_000_000}.count
            return own+(l.sublayers ?? []).reduce(0){$0+loops($1)}
        }
        refresh()
        var serial=101
        func emit(_ method:String,_ fields:JSONValue)->CoreEvent {
            serial+=1;let e=CoreEvent(id:serial,time:Double(serial),method:method,params:fields);store.apply(e);refresh();return e
        }
        _=emit("turn/started",["threadId":"ambient","turn":["id":"turn"]])
        _=emit("item/started",["threadId":"ambient","turnId":"turn","item":["id":"build","type":"commandExecution","command":"swift build"]])
        check(!layers().contains{l in (l.animationKeys() ?? []).contains{key in let a=l.animation(forKey:key)!;return !a.repeatCount.isFinite || a.repeatCount>1_000_000}},"running orb has no infinite liquid animation")
        check(configuration().liquidLevel == c.contextShown,"running identity liquid keeps the reported context waterline")
        check(settle()?.duration == 0.9 && settle()?.repeatCount == 0,"command starts one finite 0.9 second settle")
        let commandTime=settle()?.beginTime
        let e=emit("item/commandExecution/outputDelta",["threadId":"ambient","turnId":"turn","itemId":"build","delta":"Compiling\n"])
        check(settle()?.beginTime == commandTime,"streaming command output never restarts a settle")
        let outputTime=settle()?.beginTime,paths=orb.metrics.liquidPaths
        refresh();store.changed(c);refresh()
        check(settle()?.beginTime == outputTime && orb.metrics.liquidPaths == paths,"refresh and structural publication do not replay a settle")
        store.apply(e);refresh()
        check(settle()?.beginTime == outputTime && orb.metrics.liquidPaths == paths,"duplicate event ID cannot submit another settle")
        _=emit("item/completed",["threadId":"ambient","turnId":"turn","item":["id":"build","type":"commandExecution","command":"swift build","status":"completed"]])
        check(settle() != nil && settle()?.beginTime == outputTime,"step completion merges into the active settle")
        let stepTime=settle()?.beginTime
        EventReducer.apply(.init(id:999,time:200,method:"item/commandExecution/outputDelta",params:["threadId":"ambient","turnId":"turn","itemId":"build","delta":"history"]),to:c)
        store.changed(c);refresh()
        check(settle()?.beginTime == stepTime,"history apply and read publication cannot replay live activity")
        var reduced=configuration();reduced.reduceMotion=true;orb.configure(reduced)
        check(settle()==nil,"Reduce Motion removes the finite event settle")
        _=emit("turn/completed",["threadId":"ambient","turn":["id":"turn","status":"completed"]])
        check(configuration().liquidLevel == c.contextShown,"idle liquid restores the reported context waterline")
        let dots=DotsLayer();dots.frame=CGRect(x:0,y:0,width:12,height:12);dots.configure(.compact,color:.labelColor,scale:2)
        check(loops(dots)==0,"brief working dots have no idle loop")
        let header=IslandWorkingDots();header.configure(paused:false,reduced:false,scale:2,now:CACurrentMediaTime())
        check(loops(header.layer)==0,"header working dots have no idle loop")
        check(header.layer.sublayers?.allSatisfy{$0.opacity>0} == true,"static working ink remains visible")
        c.error = .stopped;c.redEvents=1;c.redSeen=1;store.changed(c);refresh()
        check(!layers().contains{$0.animation(forKey:"breathe") != nil},"acknowledged status cannot start an idle glow pulse")
        c.satellites=[.init(id:"retained-orbit",face:"•ᴗ•",done:false)];c.satellitesRetired=false;store.changed(c);refresh()
        let visibleOrbit = layers().contains{$0.animation(forKey:"orbit")?.repeatCount == .infinity}
        var hidden = configuration(); hidden.satellitesRetired = true; hidden.reduceMotion = true
        orb.configure(hidden)
        let hiddenOrbit = layers().contains{$0.animation(forKey:"orbit") != nil}
        refresh()
        check(visibleOrbit && !hiddenOrbit && layers().contains{$0.animation(forKey:"orbit")?.repeatCount == .infinity},
              "visible satellite orbits remain continuous; retained hidden satellites have no orbit")
        orb.dispose()
    }

    #if ORB_SELFTEST
    /// Real Dock and header adapters, synthetic events, and sampled component ink; no visible window or Core.
    static func corrections(to output:URL,check:(Bool,String)->Void) {
        _ = NSApplication.shared
        var evidence:[[String:Any]]=[],observations:[[String:Any]]=[]
        func record(_ value:Bool,_ name:String) {check(value,name);evidence.append(["check":name,"passed":value])}
        func image(_ orb:OrbComponent,_ name:String,_ scale:CGFloat) {
            let preview=OrbComponent(id:"ambient-preview")
            preview.configure(orb.verificationConfiguration!)
            preview.setCanvasSize(CGSize(width:104,height:104))
            let diameter:CGFloat=name.hasPrefix("Dock") ? 32:name.hasPrefix("LL") ? 36:56
            let rect=CGRect(x:52-diameter/2,y:52-diameter/2,width:diameter,height:diameter)
            preview.setFrame(rect)
            (preview.verificationMotionLayers[3] as! CAShapeLayer).path=(orb.verificationMotionLayers[3] as! CAShapeLayer).path
            let context=CGContext(data:nil,width:Int(104*scale),height:Int(104*scale),bitsPerComponent:8,bytesPerRow:0,
                                  space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x:0,y:104*scale);context.scaleBy(x:scale,y:-scale)
            context.setFillColor(NSColor(white:0.12,alpha:1).cgColor);context.fill(CGRect(x:0,y:0,width:104,height:104))
            preview.renderOffscreenDecorations(in:context,planet:rect)
            Offscreen.write(context.makeImage()!,output.appendingPathComponent(name+"-\(Int(scale))x.png"))
            preview.dispose()
        }
        for scale:CGFloat in [1,2] {
            let c=Conversation(id:"ambient-correction",title:"Context waterline");c.contextUsed=0.3
            let store=ConversationStore(conversations:[c])
            let host=DockNode.Passage(frame:CGRect(x:0,y:0,width:800,height:160));host.wantsLayer=true
            let dock=DockNode(view:host,scale:scale)
            dock.ambient=true;dock.still=false
            var layout=AutoLayout();layout.me=CGRect(x:20,y:90,width:36,height:36)
            layout.orbs=[CGRect(x:500,y:90,width:32,height:32)]
            dock.install(layout,metrics:.init(),order:[c],full:[],store:store)
            let header=HeaderIsland()
            func refresh() {
                // Native header preparation can flush an unattached Dock's CA transaction offscreen.
                header.configure(.conversation(c,variant:.full,columnWidth:400,band:44,ambient:true,scale:scale))
                dock.refreshOrbs()
            }
            var id=0
            func emit(_ method:String,_ fields:JSONValue) {
                id+=1;store.apply(.init(id:id,time:Double(id),method:method,params:fields));refresh()
            }
            emit("turn/started",["threadId":"ambient-correction","turn":["id":"correction-turn"]])
            emit("item/started",["threadId":"ambient-correction","turnId":"correction-turn","item":["id":"command","type":"commandExecution","command":"synthetic build"]])
            guard let dockOrb=dock.items[c.id]?.decoration else {record(false,"correction Dock fixture exists");header.dispose();continue}
            let orbs=[("Dock",dockOrb),("header",header.orb)]
            func boundary(_ orb:OrbComponent)->CGFloat {
                let surface=orb.verificationMotionLayers[3]
                return surface.position.y-surface.bounds.minY
            }
            for (name,orb) in orbs {
                let d=orb.verificationMotionLayers[3].bounds.width
                record(orb.verificationLiquidLevel == 0.3 && abs(boundary(orb)-d*0.7)<1e-6,
                       "\(name) running context 30% has a 30% liquid mask @\(Int(scale))x")
                image(orb,name+"-running-30",scale)
            }
            c.contextUsed=0.88;c.running=false;refresh()
            let idle=orbs.map {boundary($0.1)}
            c.running=true;refresh()
            for (i,pair) in orbs.enumerated() {
                let (name,orb)=pair,d=orb.verificationMotionLayers[3].bounds.width
                record(orb.verificationLiquidLevel == 0.88 && abs(boundary(orb)-d*0.12)<1e-6 && boundary(orb)==idle[i],
                       "\(name) idle and running context 88% have identical liquid masks @\(Int(scale))x")
                image(orb,name+"-running-88",scale)
            }
            c.contextUsed=0.3;refresh();CATransaction.flush()
            let available=Date().addingTimeInterval(1.0)
            while Date()<available {_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}
            emit("item/completed",["threadId":"ambient-correction","turnId":"correction-turn","item":["id":"command","type":"commandExecution","status":"completed"]])
            var settledAtContext:[Bool]=[]
            for (name,orb) in orbs {
                let surface=orb.verificationMotionLayers[3] as! CAShapeLayer
                let d=surface.bounds.width,animation=surface.animation(forKey:"eventSettle") as? CAKeyframeAnimation
                let paths=animation?.values as? [CGPath] ?? []
                let correct=abs(boundary(orb)-d*0.7)<1e-6 && paths.count==25 && animation?.duration==0.9
                    && animation?.repeatCount==0 && animation?.isRemovedOnCompletion==true
                    && paths.contains{$0.boundingBox.minY < -0.2} && paths.last?.boundingBox.minY==0
                observations.append(["host":name,"scale":scale,"drawingSize":d,"liquidLevel":orb.verificationLiquidLevel ?? -1,
                                     "waterlineY":boundary(orb),"keyframes":paths.count,"duration":animation?.duration ?? -1,
                                     "repeatCount":animation?.repeatCount ?? -1,"running":orb.verificationConfiguration?.running ?? false,
                                     "reduced":orb.verificationConfiguration?.reduceMotion ?? true,"ambient":orb.verificationConfiguration?.ambient ?? false])
                settledAtContext.append(correct)
                record(correct,"\(name) event submits one finite visible settle at context 30% @\(Int(scale))x")
                let began=animation?.beginTime,draws=orb.metrics.liquidPaths
                refresh();store.changed(c);refresh()
                record(surface.animation(forKey:"eventSettle")?.beginTime==began && orb.metrics.liquidPaths==draws,
                       "\(name) duplicate configuration does not replay event settle @\(Int(scale))x")
                let model=surface.path
                for index in [0,6,12,24] where paths.indices.contains(index) {
                    surface.path=paths[index];image(orb,name+"-settle-keyframe-\(index)",scale)
                }
                surface.path=model
            }
            CATransaction.flush()
            let end=Date().addingTimeInterval(1.05)
            while Date()<end { _=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
            CATransaction.flush()
            for (i,pair) in orbs.enumerated() {
                let (name,orb)=pair,surface=orb.verificationMotionLayers[3]
                let liquid=Mirror(reflecting:orb).children.first{$0.label=="liquid"}!.value
                let fields=Mirror(reflecting:liquid).children
                let hasDeadline=fields.contains { field in
                    let label=(field.label ?? "").lowercased(),type=String(describing:type(of:field.value))
                    return label.contains("deadline") || type.contains("DispatchWorkItem") || type.contains("Timer") || type.contains("DisplayLink")
                }
                record(settledAtContext[i] && surface.animationKeys()?.isEmpty != false && !hasDeadline,
                       "\(name) context settle ends with no CA animation or deadline @\(Int(scale))x")
            }
            let me=OrbComponent(id:"ambient-LL")
            c.error = .stopped;store.changed(c)
            var meInput=makeMeConfiguration(store:store,initials:"LL",drawingSize:36,backingScale:scale,reduceMotion:false,ambient:true,isKeyWindow:true)
            me.configure(meInput)
            let ring=me.verificationMotionLayers[4] as! CAShapeLayer
            record(ring.opacity==0.4 && !ring.isHidden && ring.path?.isEmpty==false && ring.animation(forKey:"breathe")==nil,
                   "LL keeps its static red ring without breathing @\(Int(scale))x")
            image(me,"LL-static-red-ring",scale)
            meInput.reduceMotion=true;meInput.ambient=false;me.configure(meInput)
            record(ring.opacity==0.4 && ring.animationKeys()?.isEmpty != false,"LL static red ring survives Reduce Motion and ambient hold @\(Int(scale))x")
            c.error=nil;store.changed(c)
            me.configure(makeMeConfiguration(store:store,initials:"LL",drawingSize:36,backingScale:scale,reduceMotion:false,ambient:true,isKeyWindow:true))
            record(ring.opacity==0,"LL red ring clears when the last error clears @\(Int(scale))x")
            me.dispose();header.dispose()
        }
        let c=Conversation(id:"ambient-lead",title:"Static working ink");c.running=true
        let input=HeaderIslandConfiguration.conversation(c,variant:.full,columnWidth:400,band:44,ambient:true,scale:2)
        let pulse=HeaderPulsePresentation(frame:CGRect(x:0,y:0,width:400,height:180))
        var time=1000.0,snapshot=ConversationNoticeSnapshot(running:true)
        func configure(){pulse.configure(snapshot,input:input,compact:CGRect(x:100,y:40,width:180,height:32),at:time,suspended:false,interactive:true)}
        func advance(_ dt:Double){for _ in 0..<Int((dt*240).rounded()){time+=1/240;pulse.sample(at:time)}}
        configure();snapshot.journal=[.init(id:1,kind:.command,text:"Synthetic event")];configure();advance(0.05)
        record(abs((pulse.motion?.kick.x ?? 1)-1)>0.001,"Pulse new event retains its finite notification kick")
        advance(5)
        func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap{descendants($0)}}
        let leads=descendants(pulse).filter{String(describing:type(of:$0))=="PulseLeadView"}
        func ink(_ view:NSView)->Data {
            let rep=VerificationRaster.bitmap(width: 28, height: 28)
            rep.size=CGSize(width:14,height:14)
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
            view.draw(view.bounds);NSGraphicsContext.restoreGraphicsState()
            return Data(bytes:rep.bitmapData!,count:rep.bytesPerRow*rep.pixelsHigh)
        }
        let still=leads.map{ink($0)}
        var same=true
        for _ in 0..<24 {advance(1/12);same = same && leads.map{ink($0)}==still}
        record(leads.count==3 && same && pulse.motion?.busy==false,
               "PulseLeadView working dots remain identical through two idle seconds in compact, bloom and action planes")
        snapshot.journal.append(.init(id:2,kind:.command,text:"Next synthetic event"));configure();advance(0.05)
        record(abs((pulse.motion?.kick.x ?? 1)-1)>0.001,"Pulse next event triggers one fresh finite notification kick")
        advance(5);let rested=pulse.motion?.kick.x;configure();advance(1)
        record(pulse.motion?.busy==false && pulse.motion?.kick.x==rested && leads.map{ink($0)}==still,
               "Pulse repeated snapshot cannot restart the notification or working dots")
        pulse.dispose()
        record(!NSApp.windows.contains(where:{$0.isVisible}),"ambient correction verification never orders a window")
        try? JSONSerialization.data(withJSONObject:["checks":evidence,"observations":observations,"liquidImages":"Component model ink; settle images sample the submitted CA keyframes, without a native glass backdrop."],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("ambient-corrections.json"))
    }
    /// Discrete event projection, finite CA samples and lifecycle interruption on synthetic components only.
    static func shortRound(to output:URL,check:(Bool,String)->Void) {
        _ = NSApplication.shared
        var rows:[[String:Any]]=[],timing:[[String:Any]]=[]
        func record(_ value:Bool,_ name:String){check(value,name);rows.append(["check":name,"passed":value])}
        func pump(until end:Double){while CACurrentMediaTime()<end {_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.002))}}
        func points(_ path:CGPath)->[CGFloat] {
            var values:[CGFloat]=[]
            path.applyWithBlock { element in
                let e=element.pointee
                if e.type == .addLineToPoint,values.count<25 {values.append(e.points[0].y)}
            }
            return values
        }
        let c=Conversation(id:"discrete",title:"Discrete activity"),store=ConversationStore(conversations:[c])
        c.running=true;c.contextUsed=0.3
        let orb=OrbComponent(id:"stream-contract")
        func refresh(){orb.configure(makeOrbConfiguration(c,drawingSize:40,backingScale:2,reduceMotion:false,ambient:true,isKeyWindow:true))}
        var id=1000
        @discardableResult func emit(_ method:String,_ value:JSONValue)->CoreEvent {
            id+=1;var fields=value.objectValue ?? [:];fields["threadId"] = "discrete"
            let e=CoreEvent(id:id,time:Double(id)*0.25,method:method,params:.object(fields));store.apply(e);refresh();return e
        }
        refresh()
        let increments=["item/agentMessage/delta","item/reasoning/summaryTextDelta","item/reasoning/textDelta","item/commandExecution/outputDelta","item/fileChange/outputDelta"]
        for method in increments {
            let serial=c.orbActivity.serial,draws=orb.metrics.liquidPaths
            for _ in 0..<12 {emit(method,["itemId":"stream","delta":"synthetic delta"])}
            record(c.orbActivity.serial==serial && orb.metrics.liquidPaths==draws && orb.verificationMotionLayers[3].animation(forKey:"eventSettle")==nil,
                   "0.25 second streaming increments never settle: "+method)
        }
        let discrete:[(String,JSONValue)]=[
            ("turn/started",["turn":["id":"discrete-turn"]]),
            ("item/started",["item":["id":"cmd","type":"commandExecution"]]),
            ("item/completed",["item":["id":"cmd","type":"commandExecution"]]),
            ("item/started",["item":["id":"file","type":"fileChange","changes":[["path":"fixture.swift","kind":"update"]]]]),
            ("item/completed",["item":["id":"file","type":"fileChange"]]),
            ("item/completed",["item":["id":"answer","type":"agentMessage"]]),
            ("item/completed",["item":["id":"reason","type":"reasoning"]]),
            ("item/completed",["item":["id":"search","type":"webSearch"]]),
            ("turn/plan/updated",["plan":[["step":"One","status":"completed"]]]),
            ("core/approvalRequested",["approvalId":"approve","request":["method":"item/commandExecution/requestApproval","params":["command":"synthetic"]]]),
            ("core/approvalRequested",["approvalId":"question","request":["method":"item/tool/requestUserInput","params":["questions":[["id":"q","question":"Synthetic?"]]]]]),
            ("error",["willRetry":true,"error":["message":"Synthetic retry"]]),
            ("error",["willRetry":false,"error":["message":"Synthetic failure"]]),
            ("turn/completed",["turn":["id":"discrete-turn","status":"completed"]])]
        for (method,fields) in discrete {
            let before=c.orbActivity.serial;emit(method,fields)
            record(c.orbActivity.serial==before+1,"discrete projection advances once: "+method+" #\(id)")
        }
        let before=c.orbActivity.serial
        let plan=emit("turn/plan/updated",["plan":[["step":"One","status":"completed"]]])
        store.apply(plan);refresh()
        record(c.orbActivity.serial==before,"repeated completed plan snapshots and duplicate IDs do not become new events")
        let userSerial=c.orbActivity.serial
        emit("item/completed",["item":["id":"user","type":"userMessage"]])
        record(c.orbActivity.serial==userSerial,"user-message completion is not agent activity")
        let historySerial=c.orbActivity.serial
        EventReducer.apply(.init(id:9000,time:0,method:"item/completed",params:["item":["id":"history","type":"commandExecution"]]),to:c)
        record(c.orbActivity.serial==historySerial,"history completion never replays discrete activity")
        orb.dispose()

        let metrics=OrbMetrics(),liquid=OrbLiquid(metrics:metrics)
        CATransaction.begin();CATransaction.setDisableActions(true)
        liquid.configure(size:40,level:0.3,colors:[NSColor.white.cgColor,NSColor.white.cgColor],wobble:1.2,compactions:0,animate:false)
        CATransaction.commit()
        let clock=CACurrentMediaTime();var starts:[Double]=[]
        for index in 0...8 {
            pump(until:clock+Double(index)*0.25)
            let paths=metrics.value.liquidPaths,now=CACurrentMediaTime()
            liquid.settle(activitySerial:UInt64(index+1),amplitude:1.2,animate:true)
            let started=metrics.value.liquidPaths>paths
            if started {starts.append(now)}
            timing.append(["event":index,"time":now-clock,"started":started])
        }
        record(starts.count==3,"discrete events during a settle merge without restart or a queued tail")
        let gaps=zip(starts.dropFirst(),starts).map{next,previous in next-previous}
        record(!gaps.isEmpty && gaps.allSatisfy{$0>=0.9},"successive settle starts are at least 0.9 seconds apart")
        let after=metrics.value.liquidPaths;pump(until:CACurrentMediaTime()+1.05)
        record(metrics.value.liquidPaths==after && liquid.surfaceLayer.animationKeys()?.isEmpty != false,"settle stops without deferred replay or a CA clock")

        let source=OrbComponent(id:"coalesced-carry")
        var carryInput=OrbConfiguration(content:.identity(.assigned(0)),drawingSize:40,context:0.3,running:true)
        source.configure(carryInput);carryInput.activitySerial=1;source.configure(carryInput)
        if let carrier=source.prepareDragDecoration() {
            let paths=carrier.metrics.liquidPaths;carryInput.activitySerial=2;carrier.configure(carryInput)
            record(carrier.metrics.liquidPaths==paths,"prepared drag decoration inherits the active settle merge interval")
            carrier.dispose()
        } else {record(false,"prepared drag decoration inherits the active settle merge interval")}
        source.dispose()

        for size:CGFloat in [40,56] {
            let model=OrbLiquid(metrics:OrbMetrics())
            model.configure(size:size,level:0.3,colors:[NSColor.white.cgColor],wobble:1.2*size/40,compactions:0,animate:false)
            model.settle(activitySerial:1,amplitude:1.2*size/40,animate:true)
            let animation=model.surfaceLayer.animation(forKey:"eventSettle") as? CAKeyframeAnimation
            let paths=(animation?.values as? [CGPath] ?? []).map(points)
            func frame(_ t:Double)->[CGFloat] {
                guard paths.count>1 else{return []}
                let u=min(Double(paths.count-1),max(0,t/0.9*Double(paths.count-1))),i=min(paths.count-2,Int(u)),k=CGFloat(u-Double(i))
                return zip(paths[i],paths[i+1]).map{$0*(1-k)+$1*k}
            }
            let frames=(0...54).map{frame(Double($0)/60)}
            let first=frames.first?.map{abs($0)}.max() ?? .infinity
            let later=zip(frames.dropFirst(),frames).flatMap{a,b in zip(a,b).map{abs($0-$1)}}.max() ?? 0
            record(first<=later+0.000001 && first<0.05,"settle first-frame displacement is below a normal later step at \(size)pt")
            record(paths.count==25 && paths[0]==paths[1] && paths[23]==paths[24] && first==0,"settle enters and leaves the resting pose with zero velocity at \(size)pt")
            timing.append(["drawingSize":size,"firstFrameStep":first,"maximumLaterStep":later])
            for mode in ["ambient","hidden","reduced"] {
                let component=OrbComponent(id:"hold-\(mode)-\(size)")
                var input=OrbConfiguration(content:.identity(.assigned(0)),drawingSize:size,context:0.3,running:true)
                component.configure(input);input.activitySerial=1;component.configure(input)
                let surface=component.verificationMotionLayers[3] as! CAShapeLayer
                let began=CACurrentMediaTime(),target=surface.position
                let level=CABasicAnimation(keyPath:"position");level.fromValue=NSValue(point:CGPoint(x:target.x,y:target.y+0.41));level.toValue=NSValue(point:target);level.duration=0.9
                level.timingFunction=CAMediaTimingFunction(name:.linear)
                level.beginTime=surface.convertTime(began,from:nil);surface.add(level,forKey:"level")
                // Freeze the same intermediate local time as the live eight-second ambient hold.
                component.verificationPause(true,at:began+0.22)
                if mode=="ambient" {input.ambient=false;component.configure(input)}
                else if mode=="hidden" {component.setPresentationActive(false)}
                else {input.reduceMotion=true;component.configure(input)}
                let local=surface.convertTime(CACurrentMediaTime(),from:nil)
                var wave=surface.path.map(points) ?? []
                if let animation=surface.animation(forKey:"eventSettle") as? CAKeyframeAnimation,
                   let values=animation.values as? [CGPath],values.count>1,animation.duration>0 {
                    let u=min(Double(values.count-1),max(0,(local-animation.beginTime)/animation.duration*Double(values.count-1)))
                    let index=min(values.count-2,Int(u)),fraction=CGFloat(u-Double(index))
                    wave=zip(points(values[index]),points(values[index+1])).map{$0*(1-fraction)+$1*fraction}
                }
                var position=surface.position.y
                if let animation=surface.animation(forKey:"level") as? CABasicAnimation,
                   let from=(animation.fromValue as? NSValue)?.pointValue,let to=(animation.toValue as? NSValue)?.pointValue {
                    let fraction=CGFloat(min(1,max(0,(local-animation.beginTime)/animation.duration)))
                    position=from.y*(1-fraction)+to.y*fraction
                }
                let error=Double(wave.map{abs(position-target.y+$0)}.max() ?? abs(position-target.y))
                record(error<0.05 && surface.animationKeys()?.isEmpty != false,"\(mode) interruption returns to exact waterline with error <0.05pt at \(size)pt")
                input.ambient=true;input.reduceMotion=false;component.configure(input);component.setPresentationActive(true)
                record(surface.animationKeys()?.isEmpty != false && abs(surface.position.y-target.y)<0.05,"\(mode) resume cannot revive a held liquid offset at \(size)pt")
                timing.append(["drawingSize":size,"interruption":mode,"waterlineError":error])
                component.dispose()
            }
        }
        record(!NSApp.windows.contains(where:{$0.isVisible}),"short-round checks never order a window")
        try? JSONSerialization.data(withJSONObject:["checks":rows,"samples":timing],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("ambient-short.json"))
    }
    #endif
}
#endif
