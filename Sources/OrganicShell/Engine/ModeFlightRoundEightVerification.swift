#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Asymmetric photo and production-layer regressions; all surfaces remain windowless.
@MainActor enum ModeFlightRoundEightVerification {
    final class Marker:NSView {
        let markerFlipped:Bool
        init(_ flipped:Bool,frame:CGRect) {self.markerFlipped=flipped;super.init(frame:frame)}
        required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
        override var isFlipped:Bool {markerFlipped}
        override func draw(_ dirtyRect:NSRect) {
            NSColor.red.setFill();CGRect(x:0,y:markerFlipped ? 0:bounds.height-20,width:bounds.width,height:20).fill()
            NSColor.green.setFill();CGRect(x:0,y:markerFlipped ? bounds.height-20:0,width:bounds.width,height:20).fill()
        }
    }
    static func run(to output:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[String:Any]=[:]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        let size=CGSize(width:192,height:288),host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size)),front=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size))
        host.wantsLayer=true;host.addSubview(front)
        var records:[[String:Any]]=[]
        for rootFlipped in [true,false] {
        for presentation in [false,true] {
            let root=Marker(rootFlipped,frame:host.bounds);root.wantsLayer=true
            for (i,flipped) in [true,false].enumerated() {
                let marker=Marker(flipped,frame:CGRect(x:CGFloat(i)*64,y:0,width:64,height:288));marker.wantsLayer=true;root.addSubview(marker)
            }
            let ca=ModeFlight.Plane(frame:CGRect(x:128,y:0,width:64,height:288));ca.wantsLayer=true
            let sample=Marker(true,frame:ca.bounds)
            let ink=CALayer();ink.frame=ca.bounds;ink.contents=NativeViewBitmap.capture(sample,scale:1);ca.layer?.addSublayer(ink);root.addSubview(ca)
            let native=NativeViewBitmap.capture(root,scale:1)
            Offscreen.write(native,output.appendingPathComponent("native.png"))
            let builder=ModeSurfaceBuilder(root,scale:1,includeWindowFrame:false,presentation:presentation)
            while !builder.ready {builder.step()};let picture=builder.finish()!
            let flattened=picture.flattened();Offscreen.write(flattened,output.appendingPathComponent("capture-\(presentation).png"))
            let plate=ModeHandoffPlate(frame:host.bounds);plate.hold(picture,in:host,below:front,holes:[])
            let first=render(plate,at:VerificationClock.renderOrigin);Offscreen.write(first,output.appendingPathComponent("held-\(presentation).png"))
            for (name,bitmap) in [("capture",flattened),("held",first)] {
                for x in [32,96,160] {
                    let top=rgb(bitmap,x:x,y:10),bottom=rgb(bitmap,x:x,y:278)
                    check(top.0>top.1+100 && bottom.1>bottom.0+100,"P1 \(name) \(presentation) keeps top red and bottom green x=\(x)")
                    records.append(["phase":name,"presentation":presentation,"x":x,"top":[top.0,top.1,top.2],"bottom":[bottom.0,bottom.1,bottom.2]])
                }
            }
            for _ in 0..<5 {
                plate.restoreSource(picture,in:host,below:front,holes:[])
                plate.verificationImageLayer?.removeAllAnimations();plate.verificationImageLayer?.opacity=1
            }
            let deadline=Date(timeIntervalSinceNow:3)
            while plate.verificationFlattenPending,Date()<deadline {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.001))}
            let compacted=render(plate,at:VerificationClock.renderOrigin);Offscreen.write(compacted,output.appendingPathComponent("compacted-\(presentation).png"))
            for x in [32,96,160] {let top=rgb(compacted,x:x,y:10),bottom=rgb(compacted,x:x,y:278);check(top.0>top.1+100 && bottom.1>bottom.0+100,"P1 compacted photo keeps asymmetric markers \(presentation) x=\(x)")}
            plate.pinNativeBackdrop(picture,in:host,below:front,holes:[])
            let pinned=render(plate.verificationNativeBackdropView,at:VerificationClock.renderOrigin)
            for x in [32,96,160] {let top=rgb(pinned,x:x,y:10),bottom=rgb(pinned,x:x,y:278);check(top.0>top.1+100 && bottom.1>bottom.0+100,"P1 native backing retains the same top-left photo convention \(presentation) x=\(x)")}
            plate.clear()
        }
        }
        facts["photoMarkers"]=records
        try lifecycleChecks(check:check,facts:&facts)
        try ownershipChecks(check:check,facts:&facts)
        try headerChecks(check:check)
        let result:[String:Any]=["checks":checks,"findings":failures.count,"failures":failures,"facts":facts]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("round8-verification.json"))
        print("M11.31 round 8: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
    private static func lifecycleChecks(check:(Bool,String)->Void,facts:inout [String:Any]) throws {
        let host=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:248,height:300)),source=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:248,height:300)),front=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:248,height:300))
        host.wantsLayer=true;source.wantsLayer=true;host.addSubview(source);host.addSubview(front)
        let bitmap=NativeViewBitmap.capture(Marker(true,frame:source.bounds),scale:1),texture=ModeTurnSidebar()
        source.layer?.opacity=0
        texture.begin(bitmap,source:source,in:host,below:front,rect:source.frame,alpha:0,incoming:true,scale:1)
        let color=texture.verificationMaterial.backgroundColor
        check(color?.alpha == 1,"S4 detached sidebar footprint uses Native's opaque background policy")
        check(texture.verificationNativeMaterial.material == .sidebar && texture.verificationNativeMaterial.blendingMode == .behindWindow,"S4 a live sidebar uses Native sidebar material rather than the board color")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.28))
        check(!texture.isActive,"S3 a settled sidebar retires even without an admission completion callback")
        check(source.layer?.opacity == 1 && source.alphaValue == 1,"S2 overlapping proxies cannot restore a native sidebar to opacity zero")
        let glass=NSGlassEffectView(frame:CGRect(x:12,y:220,width:220,height:60)),orb=NSGlassEffectView(frame:CGRect(x:40,y:20,width:40,height:40))
        source.addSubview(glass);source.addSubview(orb)
        let picture=ModeSurfacePicture(tiles:[.init(rect:source.bounds,image:bitmap)],glasses:[.init(view:glass,rect:glass.frame),.init(view:orb,rect:orb.frame)],size:source.bounds.size,scale:1)
        let plate=ModeHandoffPlate(frame:host.bounds);plate.hold(picture,in:host,below:front,holes:[])
        check(plate.verificationHoles?.contains(CGPoint(x:120,y:250)) == true,"P2 input ink remains photographed above its complete live material")
        check(plate.verificationHoles?.contains(CGPoint(x:60,y:40)) == false,"S5/S6 photos never paint a second orb under a flying owner")
        plate.restoreSource(ModeSurfacePicture(image:bitmap),in:host,below:front,holes:[])
        check(plate.verificationHoles?.contains(CGPoint(x:120,y:250)) == true,"P2 a new photo does not inherit an old input-footprint hole")
        plate.clear();texture.finish()
        facts["nativeSidebarColor"]=color?.components ?? []
    }
    private static func headerChecks(check:(Bool,String)->Void) throws {
        let size=CGSize(width:1280,height:820),store=ConversationStore(),seed=MockReplay(store:store)
        seed.start(live:false);let sessions=NativeTranscriptSessions(store:store)
        let scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:1,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=true
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {root.addSubview(plane);plane.frame=root.bounds}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic);_=shell.view
        defer {shell.disposeModePreparation();shell.flight.shutdown();workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback()}
        shell.verificationFlightSettle(asOrganic:false)
        guard let column=scene.columns.first(where:{$0.island != nil}),let orb=column.island?.orb else {check(false,"S6 fixture has a native header orb");return}
        let id="header."+column.conversation.id
        var now=1000.0
        shell.verificationHoldHeader(id);shell.flight.manualTime={now}
        shell.flight.start(toOrganic:false,avatar:(ModeOrreryFlightVerification.dockAvatar,ModeOrreryFlightVerification.sidebarAvatar),initials:"LL",tokens:[.init(id:id,conversation:column.conversation,from:CGRect(x:300,y:70,width:40,height:40),to:CGRect(x:40,y:160,width:16,height:16),start:0,absorbed:true)],composer:nil,reduceMotion:false)
        root.isHidden=true;shell.verificationPublishFlightOwners(at:0.04)
        check(orb.glassView.isHidden && orb.frontView.isHidden,"S6 hiding the source root never releases an airborne header into a second native owner")
        shell.verificationScheduleFlightEndpoints()
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
        let refreshes=shell.verificationEndpointRefreshCount
        for _ in 0..<12 {shell.verificationScheduleFlightEndpoints()}
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
        check(shell.verificationEndpointRefreshCount == refreshes,"B7 repeated visibility notifications with unchanged endpoints do not redirect or reclaim rows")
        shell.flight.cancel();shell.verificationFlightSettle(asOrganic:true)
        shell.prepareModeSwitch(reason:"round8.sidebar-photo")
        shell.verificationFlightToggle(toOrganic:false);shell.verificationFlightAdmit()
        now+=0.54;shell.flight.advance(at:0.54);shell.verificationFlightToggle(toOrganic:true)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
        check(shell.verificationTurnSidebarCutout,"S4 retained photos cannot paint a stationary sidebar beneath a moving outgoing sidebar")
    }
    private static func ownershipChecks(check:(Bool,String)->Void,facts:inout [String:Any]) throws {
        let rows=ModeOrreryFlightVerification.rows,real=ModeOrreryFlightVerification.real,seed=MockSeed.make()
        let f=ModeFlight();f.manualTime={1000};f.resize(to:CGSize(width:1280,height:820));f.verificationServerMotion=true
        var reads=0
        f.destinationOwnerVisible={_ in reads+=1;return false}
        f.start(toOrganic:false,avatar:(ModeOrreryFlightVerification.dockAvatar,ModeOrreryFlightVerification.sidebarAvatar),initials:"LL",tokens:(0..<6).map {i in .init(id:seed[i].id,conversation:seed[i],from:real[i],to:rows[i],start:0,absorbed:true)},composer:nil,reduceMotion:false)
        reads=0;f.advance(at:0.4)
        check(reads<=7,"B7 each native owner is sampled at most once per production frame")
        facts["ownerReadsPerFrame"]=reads;f.shutdown()
    }
    static func rgb(_ image:CGImage,x:Int,y:Int)->(Int,Int,Int) {
        let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));let bytes=c.data!.assumingMemoryBound(to:UInt8.self),index=(y*image.width+x)*4
        return (Int(bytes[index]),Int(bytes[index+1]),Int(bytes[index+2]))
    }
    static func render(_ view:NSView,at time:Double)->CGImage {
        func copyLayer(_ source:CALayer)->CALayer {
            let target=CALayer();target.frame=source.frame;target.opacity=source.opacity;target.contents=source.contents;target.contentsScale=source.contentsScale;target.backgroundColor=source.backgroundColor;target.isHidden=source.isHidden;target.isGeometryFlipped=source.isGeometryFlipped
            for key in source.animationKeys() ?? [] {target.add(source.animation(forKey:key)!,forKey:key)}
            for child in source.sublayers ?? [] {target.addSublayer(copyLayer(child))};return target
        }
        func copyView(_ source:NSView)->CALayer {
            let target=CALayer();target.frame=source.frame;target.opacity=source.layer?.opacity ?? Float(source.alphaValue);target.isHidden=source.isHidden;target.isGeometryFlipped=source.isFlipped;target.backgroundColor=source.layer?.backgroundColor
            if let layer=source.layer {
                for key in layer.animationKeys() ?? [] {target.add(layer.animation(forKey:key)!,forKey:key)}
                let children=Set(source.subviews.compactMap(\.layer).map(ObjectIdentifier.init))
                for child in layer.sublayers ?? [] where !children.contains(ObjectIdentifier(child)) {target.addSublayer(copyLayer(child))}
            }
            for child in source.subviews {target.addSublayer(copyView(child))};return target
        }
        let root=copyView(view);root.frame=CGRect(origin:.zero,size:view.bounds.size)
        let renderer=OffscreenRenderer(size:view.bounds.size,host:root)
        return renderer.image(renderer.render(at:time))
    }
}
#endif
