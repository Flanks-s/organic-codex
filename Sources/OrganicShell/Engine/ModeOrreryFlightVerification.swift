#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Independent expected frames are exported by the actual running planet3 board with shot.mjs.
/// Invoke from a private windowless harness; this file never changes App/SelfTest.swift.
@MainActor enum ModeOrreryFlightVerification {
    struct XY: Decodable { let x: Double, y: Double }
    struct Expected: Decodable {
        let x: Double, y: Double, s: Double, gl: Double, rw: Double
        let vis: Bool, landed: Bool, z: Double
        var rect: CGRect { CGRect(x:x,y:y,width:s,height:s) }
    }
    struct Frame: Decodable { let fwd: Bool, t: Double, avatar: XY, tokens: [String:Expected] }
    static let rows: [CGRect] = [CGRect(x:39,y:156,width:16,height:16), CGRect(x:39,y:188,width:16,height:16),
        CGRect(x:28,y:316,width:16,height:16), CGRect(x:39,y:444,width:16,height:16),
        CGRect(x:39,y:508,width:16,height:16), CGRect(x:39,y:220,width:16,height:16)]
    static let real: [CGRect] = [CGRect(x:283.5,y:52,width:56,height:56), CGRect(x:735.5,y:56,width:44,height:44),
        CGRect(x:1064,y:56,width:44,height:44), CGRect(x:1106,y:748,width:32,height:32),
        CGRect(x:1162,y:748,width:32,height:32), CGRect(x:1218,y:748,width:32,height:32)]
    static let sidebarAvatar = CGRect(x:17,y:777,width:26,height:26), dockAvatar = CGRect(x:30,y:746,width:36,height:36)
    static let ids = ["A","B","C","D","E","F"]
    static let profile = DisplayProfile(name:"board-240Hz",frameInterval:1/240,mmPerPoint:0.27,persistenceFrames:0)

    static func run(to output: URL, reference: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let frames = try JSONDecoder().decode([Frame].self,from:Data(contentsOf:reference))
        let conversations = MockSeed.make(), byID = Dictionary(uniqueKeysWithValues:MockSeed.make().map { ($0.id,$0) })
        var checks=0, failures:[String]=[], maxGeometry=0.0, maxAvatar=0.0, maxReversal=0.0
        var negativeFailures=0, evidence:[[String:Any]]=[]
        func check(_ value: Bool, _ name: String) { checks += 1; if !value && failures.count < 100 { failures.append(name) } }
        func tokens(_ forward: Bool) -> [ModeFlight.Token] {
            ids.enumerated().map { i,id in .init(id:i<3 ? "header."+id:id,conversation:byID[id] ?? conversations[i],
                from:forward ? rows[i]:real[i],to:forward ? real[i]:rows[i],start:0.08+0.04*Double(min(i,4)),absorbed:!forward) }
        }
        for forward in [true,false] {
            var now=1000.0
            let flight=ModeFlight();flight.manualTime={now};flight.verificationServerMotion=true;flight.resize(to:CGSize(width:1280,height:820))
            let plan=tokens(forward), avatar=forward ? (sidebarAvatar,dockAvatar):(dockAvatar,sidebarAvatar)
            // The endpoint's different drawing size catches nominal-32pt reconstruction at handoff.
            let endpoints = Dictionary(uniqueKeysWithValues:plan.enumerated().map { i,t in
                let orb=OrbComponent(id:"endpoint."+t.id)
                orb.configure(makeOrbConfiguration(t.conversation,drawingSize:i<3 ? 56:48,backingScale:2,reduceMotion:true,ambient:false,isKeyWindow:true))
                orb.glassView.frame=real[i];return (t.id,orb)
            })
            let nativeHost=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:1280,height:820));nativeHost.wantsLayer=true
            let nativeRows=plan.enumerated().map { i,t -> NSView in
                let row=NormieSidebarIdentity(frame:rows[i].offsetBy(dx:-3,dy:-1));row.identity=NormieDrawing.identity(t.conversation)
                nativeHost.addSubview(row);row.isHidden=true;return row
            }
            for (i,t) in plan.enumerated() {
                let endpoint=endpoints[t.id]!
                endpoint.setCanvasSize(nativeHost.bounds.size);endpoint.setFrame(real[i])
                for v in [endpoint.glassView,endpoint.backView,endpoint.frontView] {nativeHost.addSubview(v);v.isHidden=true}
            }
            func nativeVisible(_ id: String) -> Bool {
                guard let i=plan.firstIndex(where:{$0.id == id}) else {return true}
                if !forward { return !nativeRows[i].isHidden && nativeRows[i].superview === nativeHost }
                let endpoint=endpoints[id]!
                return !endpoint.glassView.isHidden && !endpoint.frontView.isHidden && endpoint.glassView.superview === nativeHost
            }
            flight.destinationOwnerVisible=nativeVisible
            flight.onFrame={ t in
                for (i,token) in plan.enumerated() {
                    let hidden = !flight.arrived(token.id,at:t)
                    if forward {
                        let endpoint=endpoints[token.id]!
                        for v in [endpoint.glassView,endpoint.backView,endpoint.frontView] {v.isHidden=hidden}
                    } else {nativeRows[i].isHidden=hidden}
                }
            }
            flight.endpointOrb={endpoints[$0]}
            flight.prewarm(tokens:plan)
            flight.start(toOrganic:forward,avatar:avatar,initials:"LL",tokens:plan,composer:nil,reduceMotion:false)
            let paths=flight.verificationServerLayers.mapValues { layer -> ([Double],[Double]) in
                let group=layer.animation(forKey:"mode.server.translation") as? CAAnimationGroup
                let channels=group?.animations?.compactMap { $0 as? CAKeyframeAnimation } ?? []
                let x=channels.first { $0.keyPath == "position.x" }?.values?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                let y=channels.first { $0.keyPath == "position.y" }?.values?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                return (x.map {$0+(0.5-layer.anchorPoint.x)*layer.bounds.width},y.map {$0+(0.5-layer.anchorPoint.y)*layer.bounds.height})
            }
            func channel(_ layer: CALayer?, group: String, key: String) -> [Double] {
                let animation=layer?.animation(forKey:group) as? CAAnimationGroup
                let keyframe=animation?.animations?.compactMap { $0 as? CAKeyframeAnimation }.first { $0.keyPath == key }
                return keyframe?.values?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            }
            let rowOpacity=flight.verificationRowLayers.mapValues { channel($0,group:"mode.orrery.appearance",key:"opacity") }
            let rowScale=flight.verificationRowLayers.mapValues { channel($0,group:"mode.orrery.appearance",key:"transform.scale") }
            let rowRadius=flight.verificationRowLayers.mapValues { channel($0,group:"mode.orrery.appearance",key:"filters.m1131RowGaussian.inputRadius") }
            let glassOpacity=flight.verificationMaterialViews.mapValues { channel($0.layer,group:"mode.orrery.appearance",key:"opacity") }
            let depths=flight.verificationServerLayers.mapValues { channel($0,group:"mode.server.translation",key:"zPosition") }
            check(rowOpacity.count==6 && rowOpacity.values.allSatisfy { $0.count==481 },"row appearance runs on the same render-server clock")
            check(paths.count==7 && paths.values.allSatisfy { $0.0.count==481 && $0.1.count==481 },"all seven production render-server paths exist")
            var actual:[String:M10ModeFrameSample]=[:]
            flight.onExposureSample={actual[$0.id]=$0}
            for frame in frames where frame.fwd == forward {
                actual=[:];flight.sample(at:frame.t,profile:profile)
                if let me=actual["me"] {
                    let error=hypot(me.now.midX-frame.avatar.x,me.now.midY-frame.avatar.y)
                    maxAvatar=max(maxAvatar,error);check(error<1e-8,"avatar \(forward) \(frame.t): \(error)")
                    let index=Int((frame.t*240).rounded())
                    if abs(Double(index)/240-frame.t)<1e-9,let path=paths["me"],index<path.0.count {
                        check(hypot(path.0[index]-frame.avatar.x,path.1[index]-frame.avatar.y)<1e-8,"LL server keyframe follows independent board")
                    }
                }
                let states=Dictionary(uniqueKeysWithValues:flight.verificationOrreryState(at:frame.t).map { ($0["id"] as! String,$0) })
                for (i,id) in ids.enumerated() {
                    let expected=frame.tokens[id]!, tokenID=i<3 ? "header."+id:id
                    let state=states[tokenID]!
                    if expected.vis && !expected.landed {
                        let measured=actual["planet."+tokenID]?.now
                        let error=measured.map { MotionStep.edge($0,expected.rect) } ?? .infinity
                        maxGeometry=max(maxGeometry,error);check(error<1e-8,"geometry \(forward) \(id) \(frame.t): \(error)")
                        let index=Int((frame.t*240).rounded())
                        if abs(Double(index)/240-frame.t)<1e-9,let path=paths[tokenID],index<path.0.count {
                            check(hypot(path.0[index]-expected.rect.midX,path.1[index]-expected.rect.midY)<1e-8,"planet server keyframe follows independent board")
                            check(rowOpacity[tokenID].map { index<$0.count && abs($0[index]-expected.rw)<1e-8 } ?? false,"row server opacity follows board")
                            check(rowScale[tokenID].map { index<$0.count && abs($0[index]-(1+0.15*(1-expected.rw)))<1e-8 } ?? false,"row server scale follows board")
                            check(rowRadius[tokenID].map { index<$0.count && abs($0[index]-6*(1-expected.rw))<1e-8 } ?? false,"row server Gaussian follows board")
                            check(glassOpacity[tokenID].map { index<$0.count && abs($0[index]-expected.gl)<1e-8 } ?? false,"sharp glass server opacity follows board")
                            check(depths[tokenID].map { index<$0.count && abs($0[index]-expected.z)<1e-8 } ?? false,"server depth follows board around LL")
                        }
                        check(abs((state["glassOpacity"] as! CGFloat)-expected.gl)<1e-6,"glass strength follows board")
                        check(abs(((state["rowOpacity"] as? NSNumber)?.doubleValue ?? -1)-expected.rw)<1e-6,"row strength follows board")
                        check(abs((state["depth"] as! CGFloat)-expected.z)<1e-8,"planet depth follows board")
                    }
                    check(!(state["glassFiltered"] as! Bool),"glass has no Gaussian filter")
                    check((state["rowFilterCount"] as! Int) == 1 && (state["copies"] as! Int) == 1,"one Gaussian content layer, no exposure replicas")
                    check(state["endpointConfigurationMatches"] as! Bool,"flight copies real endpoint configuration")
                    if expected.landed {
                        check(nativeVisible(tokenID) && flight.arrived(tokenID,at:frame.t),"actual native destination is visible at handoff")
                        if state["hidden"] as! Bool { check(nativeVisible(tokenID),"retired flying owner has a mounted visible native owner") }
                    }
                    // Deliberately shift the board by one 120Hz frame. This must fail the same geometry tolerance.
                    let bad=ModeOrreryFlight.Plan(forward:forward,row:rows[i],real:real[i],rank:i,lastRank:5,avatarFrom:avatar.0,avatarTo:avatar.1).pose(at:frame.t+1/120)
                    if expected.vis && !expected.landed && MotionStep.edge(bad.rect,expected.rect)>0.1 { negativeFailures += 1 }
                }
            }
            for t in [0.08,0.54,0.95,1.22,1.50] {
                flight.verificationRearmAvatar();flight.sample(at:t,profile:profile)
                let root=CALayer();root.backgroundColor=NSColor(white:0.09,alpha:1).cgColor
                let renderer=OffscreenRenderer(size:CGSize(width:1280,height:820),host:root,scale:2)
                let restore=flight.verificationPaint(into:root,scale:2,elapsed:t)
                let pixels=renderer.render(at:CACurrentMediaTime()+3600+t)
                Offscreen.write(renderer.image(pixels),output.appendingPathComponent("flight-\(forward ? "forward":"reverse")-\(Int(t*1000)).png"))
                restore()
            }
            flight.shutdown();endpoints.values.forEach { $0.dispose() }

            // Reverse during glyph staging, entry, orbit, exit and staggered handoffs. Toggle back again.
            for cut in [0.08,0.28,0.54,0.95,1.30] {
                now=2000
                let f=ModeFlight();f.manualTime={now};f.verificationServerMotion=true;f.resize(to:CGSize(width:1280,height:820))
                f.start(toOrganic:forward,avatar:avatar,initials:"LL",tokens:plan,composer:nil,reduceMotion:false)
                var before:[String:CGRect]=[:],after:[String:CGRect]=[:]
                f.onExposureSample={before[$0.id]=$0.now};f.sample(at:cut,profile:profile)
                now+=cut
                f.onExposureSample={after[$0.id]=$0.now}
                f.start(toOrganic:!forward,avatar:(avatar.1,avatar.0),initials:"LL",tokens:tokens(!forward),composer:nil,reduceMotion:false)
                for (id,r) in before {
                    let error=after[id].map { MotionStep.edge(r,$0) } ?? .infinity
                    maxReversal=max(maxReversal,error);check(error<1e-7,"reverse pose \(forward) \(cut) \(id): \(error)")
                }
                let reverseDuration=f.duration
                let interval=min(0.04,cut/2);now+=interval;after=[:];f.sample(at:interval,profile:profile)
                before=after;after=[:]
                f.start(toOrganic:forward,avatar:avatar,initials:"LL",tokens:plan,composer:nil,reduceMotion:false)
                for (id,r) in before {
                    let owner = after[id] ?? plan.first(where: { "planet."+$0.id == id && f.arrived($0.id,at:0) })?.to
                    let error=owner.map { MotionStep.edge(r,$0) } ?? .infinity
                    maxReversal=max(maxReversal,error);check(error<1e-7,"second reversal \(forward) \(cut) \(id): \(error)")
                }
                evidence.append(["forward":forward,"cut":cut,"reverseDuration":reverseDuration,"resumeDuration":f.duration])
                let duration=f.duration
                f.advance(at:duration+profile.frameInterval)
                check(!f.running && f.view.isHidden,"continuous toggles pass production advance and finish")
                f.shutdown()
            }
        }
        check(negativeFailures>100,"one-frame phase error is detected by independent board comparison")
        let report:[String:Any]=["checks":checks,"failures":failures,"boardFrames":frames.count,"maxGeometryError":maxGeometry.isFinite ? maxGeometry : -1,
            "maxAvatarError":maxAvatar.isFinite ? maxAvatar : -1,"maxReversalError":maxReversal.isFinite ? maxReversal : -1,"negativePhaseMismatches":negativeFailures,"reversals":evidence,
            "scope":"Actual ModeFlight model-layer geometry and ownership; sharp glass material still requires real-window review"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("orrery-verification.json"))
        print("M11.31: \(checks) checks, \(failures.count) findings, geometry \(maxGeometry), avatar \(maxAvatar), reversal \(maxReversal), negative \(negativeFailures)")
        failures.forEach { print("FAIL: "+$0) }
        return failures.isEmpty ? 0:1
    }
}
#endif
