#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Production owners and canonical photo coordinates; no window or application run loop is started.
@MainActor enum ModeFlightRoundTenVerification {
    final class ColorView:NSView {
        let color:NSColor
        init(_ color:NSColor,frame:CGRect) {self.color=color;super.init(frame:frame);wantsLayer=true}
        required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
        override var isFlipped:Bool {true}
        override func draw(_ dirtyRect:NSRect){color.setFill();bounds.fill()}
    }
    static func run(to output:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[String:Any]=[:]
        func check(_ value:Bool,_ name:String){checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        let size=CGSize(width:320,height:384),host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size)),front=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size))
        host.wantsLayer=true;host.addSubview(front)
        // Use the same public AppKit split-item construction as WindowShell, not a guessed material.
        let split=NSSplitViewController(),sidebar=NSViewController(),body=NSViewController()
        sidebar.view=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:240,height:384));body.view=NSView()
        split.addSplitViewItem(NSSplitViewItem(sidebarWithViewController:sidebar));split.addSplitViewItem(NSSplitViewItem(viewController:body))
        split.view.frame=CGRect(x:0,y:0,width:800,height:384);split.view.layoutSubtreeIfNeeded()
        var ancestor=sidebar.view.superview,actual:NSGlassEffectView?
        var chain:[String]=[]
        while let view=ancestor {chain.append(String(describing:type(of:view)));if actual == nil {actual=view as? NSGlassEffectView};ancestor=view.superview}
        facts["nativeSidebarAncestors"]=chain
        let bitmap=NativeViewBitmap.capture(sidebar.view,scale:1),texture=ModeTurnSidebar()
        let parent=actual?.superview,content=actual?.contentView
        texture.begin(bitmap,source:sidebar.view,in:host,below:front,rect:CGRect(x:-240,y:0,width:240,height:384),alpha:0,incoming:true,scale:1)
        check(actual != nil,"S1 native NSSplitViewItem actually owns NSGlassEffectView")
        check(actual?.superview === parent && !actual!.isDescendant(of:texture.view),"S1 system glass stays in its original native hierarchy")
        check(sidebar.view.isDescendant(of:split.view),"S1 controller content remains in the native split hierarchy")
        if let clock=texture.verificationMaterial.animation(forKey:"mode.turn.material") as? CAAnimationGroup {
            let opacity=clock.animations?.compactMap {$0 as? CABasicAnimation}.first {$0.keyPath == "opacity"}
            check((opacity?.fromValue as? NSNumber)?.doubleValue == 0 && (opacity?.toValue as? NSNumber)?.doubleValue == 1,"S1 material and foreground have the same fade, with no bright first-frame block")
        } else {check(false,"S1 material clock exists")}
        facts["nativeGlassStyle"]=actual.map {String(describing:$0.style)} ?? "missing"
        texture.finish();split.view.layoutSubtreeIfNeeded()
        check(actual.map {abs($0.bounds.height-384)<0.01} ?? false,"S1 returning Native glass restores its split-item constraints and full height")
        check(content?.superview?.layer?.isHidden != true,"S1 restored non-nil content clears the glass holder's retired backing-layer hide")
        check(actual?.superview === parent && actual?.contentView === content,"S1 the same background and its exact content return to the native wrapper")
        // An abandoned root opacity animation must not keep admitting approval/composer descendants.
        let native=ModeFlight.Plane(frame:host.bounds),card=ModeFlight.Plane(frame:host.bounds)
        native.wantsLayer=true;card.wantsLayer=true;native.addSubview(card)
        let fade=CABasicAnimation(keyPath:"opacity");fade.fromValue=0;fade.toValue=1;fade.duration=0.22
        native.layer?.add(fade,forKey:"mode.normie");card.layer?.add(fade,forKey:"animator.opacity")
        ModePhotoSnapshot.freezeNativeFades(native)
        check(native.layer?.animation(forKey:"mode.normie") == nil && card.layer?.animation(forKey:"animator.opacity") == nil,"S2 Native descendants cannot continue the abandoned fade under the curtain")
        let fadeBegin=CACurrentMediaTime()
        ModePhotoSnapshot.fadeNativeSource(native,begin:fadeBegin,duration:0.14)
        let nativeOut=native.layer?.animation(forKey:"mode.turn.native-out") as? CABasicAnimation
        check((nativeOut?.toValue as? NSNumber)?.doubleValue == 0 && nativeOut?.duration == 0.14 && native.layer?.opacity == 0,"S2 the entire outgoing Native chain fades down during the one incoming-photo crossfade")
        // Input ink stays in the photo; only its background is supplied by a matching live glass.
        let source=ModeFlight.Plane(frame:host.bounds);source.wantsLayer=true
        let input=NSGlassEffectView(frame:CGRect(x:80,y:280,width:220,height:60));input.cornerRadius=20
        source.addSubview(input)
        let marked=ColorView(.red,frame:host.bounds),ink=NativeViewBitmap.capture(marked,scale:1)
        let organic=ModeSurfacePicture(tiles:[.init(rect:host.bounds,image:ink)],glasses:[.init(view:input,rect:input.frame)],size:size,scale:1)
        let plate=ModeHandoffPlate(frame:host.bounds);plate.openRect=CGRect(x:0,y:0,width:240,height:384)
        plate.hold(organic,in:host,below:front,holes:[])
        check(plate.verificationHoles?.contains(CGPoint(x:250,y:310)) != false,"S3 Organic input ink is not erased by a full-footprint hole")
        check(plate.verificationHoles?.contains(CGPoint(x:120,y:310)) != false,"S3 a global sidebar hole cannot cut Organic input at x=240")
        func glasses(_ view:NSView)->[NSGlassEffectView]{view.subviews.flatMap {($0 as? NSGlassEffectView).map {[$0]} ?? glasses($0)}}
        check(glasses(plate).contains {$0.frame == input.frame && $0.style == input.style && $0.cornerRadius == input.cornerRadius},"S3 one complete native-style input material exists below the photographed ink")
        plate.revealDestination(duration:0.14) {}
        let materialFade=plate.verificationMaterialLayer.animation(forKey:"mode.photo.material") as? CABasicAnimation
        check(materialFade?.duration == 0.14 && plate.verificationMaterialLayer.opacity == 0,"S3 complete input material fades with its photo rather than disappearing at clear")
        let normie=ModeSurfacePicture(tiles:[.init(rect:host.bounds,image:ink)],glasses:[],size:size,scale:1)
        normie.sidebarRect=CGRect(x:0,y:0,width:240,height:384)
        plate.restoreSource(normie,in:host,below:front,holes:[])
        check(plate.verificationHasPhotoSidebarCutout,"S3 only the Normie photo excludes its own sidebar")
        check(plate.verificationHoles?.contains(CGPoint(x:120,y:310)) != false,"S3 source-specific sidebar exclusion never becomes a global Organic cutout")
        for _ in 0..<4 {plate.restoreSource(normie,in:host,below:front,holes:[])}
        let deadline=Date(timeIntervalSinceNow:3)
        while plate.verificationFlattenPending,Date()<deadline {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.001))}
        check(plate.verificationHasPhotoSidebarCutout,"S3 retained Normie photo keeps its sidebar mask through worker composition")
        plate.clear()
        // A sliced capture may span native layout changes. Positions must be frozen at construction.
        let colors:[NSColor]=[.red,.green,.blue,.yellow]
        let stripes=ModeFlight.Plane(frame:host.bounds);stripes.wantsLayer=true
        let bands=colors.enumerated().map {i,color in ColorView(color,frame:CGRect(x:0,y:i*96,width:320,height:96))}
        bands.forEach {stripes.addSubview($0)}
        let builder=ModeSurfaceBuilder(stripes,scale:1,includeWindowFrame:false,presentation:true)
        builder.step()
        for (i,band) in bands.enumerated(){band.frame.origin.y=CGFloat(3-i)*96}
        while !builder.ready {builder.step()}
        let photo=builder.finish()!,flat=photo.flattened();Offscreen.write(flat,output.appendingPathComponent("frozen-bands.png"))
        for i in 0..<4 {
            let sample=ModeFlightRoundEightVerification.rgb(flat,x:160,y:i*96+48),expected=colors[i].usingColorSpace(.sRGB)!
            check(abs(sample.0-Int(expected.redComponent*255))<3 && abs(sample.1-Int(expected.greenComponent*255))<3 && abs(sample.2-Int(expected.blueComponent*255))<3,"S4 tile band \(i) keeps the geometry frozen before native relayout")
        }
        // Raw layer geometry can differ from its flipped NSView host. Normalize every parent boundary.
        let layerHost=ModeFlight.Plane(frame:host.bounds);layerHost.wantsLayer=true
        let bottomOrigin=CALayer();bottomOrigin.frame=host.bounds;bottomOrigin.isGeometryFlipped=false
        for (i,color) in colors.enumerated(){let band=CALayer();band.frame=CGRect(x:0,y:i*96,width:320,height:96);band.backgroundColor=color.cgColor;bottomOrigin.addSublayer(band)}
        layerHost.layer?.addSublayer(bottomOrigin)
        let normalized=ModePhotoSnapshot.capture(layerHost,size:size,scale:1).render()!
        for i in 0..<4 {
            let sample=ModeFlightRoundEightVerification.rgb(normalized,x:160,y:i*96+48),expected=colors[3-i].usingColorSpace(.sRGB)!
            check(abs(sample.0-Int(expected.redComponent*255))<3 && abs(sample.1-Int(expected.greenComponent*255))<3 && abs(sample.2-Int(expected.blueComponent*255))<3,"S4 retained worker band \(i) normalizes an unflipped raw-layer parent")
        }
        Offscreen.write(normalized,output.appendingPathComponent("worker-bands.png"))
        // Row-stage glass and ink share the independent sidebar's presentation offset.
        let seed=MockSeed.make(),flight=ModeFlight();flight.resize(to:CGSize(width:1280,height:820));flight.manualTime={1000};flight.verificationServerMotion=true
        flight.rowSidebarOffset={_ in -80};flight.destinationOwnerVisible={_ in false}
        let row=ModeOrreryFlightVerification.rows[0],real=ModeOrreryFlightVerification.real[0]
        flight.start(toOrganic:false,avatar:(ModeOrreryFlightVerification.dockAvatar,ModeOrreryFlightVerification.sidebarAvatar),initials:"LL",tokens:[.init(id:seed[0].id,conversation:seed[0],from:real,to:row,start:0,absorbed:true)],composer:nil,reduceMotion:false)
        flight.advance(at:1.8)
        check(abs((flight.verificationRowLayers[seed[0].id]?.position.x ?? 0)-(row.midX-3-80))<0.01,"S5 held row ink follows the sliding sidebar instead of covering final-position row text")
        flight.shutdown()
        let result:[String:Any]=["checks":checks,"findings":failures.count,"failures":failures,"facts":facts]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("round10-verification.json"))
        print("M11.31 round 10: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
}
#endif
