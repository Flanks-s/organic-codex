#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Regression boundaries captured from the live findings. No NSWindow, AppController, or system input.
@MainActor enum ModeRegressionChecks {
    // M10-C §12 measured this opaque subtree-cache matte. draw owns glyphs and transparent blank only.
    final class RecordedMatte: NSView {
        override var isFlipped:Bool {true}
        override func draw(_ dirtyRect:NSRect) {
            NSColor.white.setFill();CGRect(x:10,y:10,width:18,height:18).fill()
            NSColor.black.setFill();CGRect(x:36,y:10,width:18,height:18).fill()
        }
        override func cacheDisplay(in rect:NSRect,to bitmap:NSBitmapImageRep) {
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
            NSColor(srgbRed:28/255,green:28/255,blue:28/255,alpha:1).setFill();bounds.fill();draw(bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    static func stagedReversal(check:(Bool,String)->Void) {
        let store=ConversationStore() // Separate fixture never connects a Core or opens a window.
        let mock=MockReplay(store:store);mock.start(live:false)
        let sessions=NativeTranscriptSessions(store:store),size=CGSize(width:1080,height:760)
        let scene=AutoScene(size:size,store:store,profile:.init(name:"reversal",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0),scale:2,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=true
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for v in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {v.frame=root.bounds;root.addSubview(v)}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic);_=shell.view;shell.split.view.isHidden=true
        shell.prepareModeSwitch(reason:"reversal.fixture")
        check(shell.verificationStagedReversal(),"reversing between Native staging and reveal preserves the held source and restores actual Organic composer ownership")
        shell.disposeModePreparation();shell.flight.shutdown();workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();mock.stopPlayback()
    }
    /// The user's 11-01 recording: after Normie and back, a column that was brief at the commit had nothing to show when it
    /// went full. The same for one the commit sent to the Dock, and for one parked there, suspended, all along.
    static func modeReturnTranscripts(check:(Bool,String)->Void) {
        let store=ConversationStore()
        let mock=MockReplay(store:store);mock.start(live:false)
        let sessions=NativeTranscriptSessions(store:store),size=CGSize(width:1080,height:760)
        let scene=AutoScene(size:size,store:store,profile:.init(name:"return",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0),scale:2,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=true
        var time=1000.0;scene.now={time}
        func settle() {time=max(time,scene.transitionEnd+0.1);scene.clock.onFrame?(time);scene.settle();CATransaction.flush()}
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for v in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {v.frame=root.bounds;root.addSubview(v)}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();settle()
        func transcript(_ id:String)->NativeTranscript? {sessions.existingTranscript(for:id)}
        func back(selecting id:String?)->Bool {
            scene.beginModeHandoff();scene.suspendModePresentation()
            let picked=id ?? scene.current
            guard let plan=scene.beginModeTarget(selected:picked) else{return false}
            while !plan.ready {guard scene.modeTargetIsValid(plan) else{return false};scene.prepareModeTargetStep(plan)}
            return scene.commitModeTarget(plan)
        }
        let brief=scene.columns.filter{$0.conversation.id != scene.current}
        check(!brief.isEmpty && back(selecting:nil),"a mode commit runs on this fixture")
        scene.endModeHandoff()
        check(scene.columns.allSatisfy{$0.ownsNative},"after a mode commit every column holds its transcript, brief ones too")
        check(brief.allSatisfy{$0.native.isHidden && $0.native.layer?.isHidden == true && transcript($0.conversation.id)?.presentationActive == false},"a brief column's transcript comes back hidden and inactive, as at any other rest")
        check(brief.allSatisfy{$0.native.frame.width>0},"a brief column's transcript has a frame to be laid out from")
        let next=brief[0],id=next.conversation.id
        let plan=scene.prepare(members:scene.members,current:id,at:scene.now())
        check(plan.snapshots[id]?.withGoal != nil,"going full after a mode commit has the column's real picture, not a borrowed blank")
        scene.commit(plan,reason:"return",prewarmed:false,start:CACurrentMediaTime());settle()
        check(next.ownsNative && !next.native.isHidden && next.native.contentHeight>0,"the column that went full shows its transcript, with content")
        // A conversation from the Dock is selected in Normie: a column goes to the Dock, unmounted.
        if let parked=scene.order.dropFirst(scene.columns.count).first {
            let before=scene.columns.map(\.conversation.id)
            check(back(selecting:parked),"a mode commit that takes a conversation from the Dock runs")
            scene.endModeHandoff()
            check(scene.columns.allSatisfy{$0.ownsNative},"the column that came from the Dock and the others hold their transcripts")
            if let gone=scene.order.dropFirst(scene.columns.count).first(where:before.contains),let node=scene.nodes[gone] {
                let landing=scene.prepare(members:scene.members,current:gone,at:scene.now())
                check(node.ownsNative && landing.snapshots[gone]?.withGoal != nil,"a column the commit sent to the Dock has its real picture when it comes back full")
                scene.commit(landing,reason:"return",prewarmed:false,start:CACurrentMediaTime());settle()
                check(node.ownsNative && !node.native.isHidden,"and shows its transcript")
            } else {check(false,"the commit sent a column to the Dock")}
        } else {check(false,"this fixture has a conversation in the Dock")}
        workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();mock.stopPlayback()
    }
    static func dockIdle(check:(Bool,String)->Void) {
        let animation=CABasicAnimation(keyPath:"opacity"),rangeBefore=CAFrameRateRange.default
        ModeSignposts.frameRange(animation)
        let range=animation.preferredFrameRateRange
        check(ModeSignposts.requestsHighFrameRate ? (range.minimum==80 && range.maximum==120 && range.preferred==120):(range.minimum==rangeBefore.minimum && range.maximum==rangeBefore.maximum && range.preferred==rangeBefore.preferred),"frame-rate opt-out changes only the requested range")
        let host=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:800,height:200));host.wantsLayer=true
        let c=NativeComposer(frame:CGRect(x:0,y:0,width:620,height:100));host.addSubview(c);c.targetWidth=620;c.layoutSubtreeIfNeeded()
        let motion=M10DockComposer(in:host);motion.canPrepareAtRest={false}
        var turns=0,maxTurn=0.0
        while turns<100 {
            let t=CACurrentMediaTime(),done=motion.prewarmModeStep();maxTurn=max(maxTurn,(CACurrentMediaTime()-t)*1000);turns+=1
            if done{break}
        }
        check(motion.captures==1 && turns>1 && turns<100,"Dock geometry prewarm publishes one complete resource across control-sized turns")
        let before=motion.captures
        motion.beginModeHandoff()
        let t=CACurrentMediaTime()
        for i in 0..<30 {c.frame.size.width=620+CGFloat(i);motion.prepare(c,atCommit:true)}
        let modePrepareMS=(CACurrentMediaTime()-t)*1000
        check(motion.captures==before && motion.modeCaptureSkips==30,"real Dock composer atCommit never captures/scans during a mode flight, including width changes")
        _=c.setText("a newer native draft");motion.prepare(c,atCommit:true)
        check(motion.captures==before,"dirty content stays native during a flight instead of showing a stale picture")
        motion.endModeHandoff()
        turns=0;while turns<100 {turns+=1;if motion.prewarmModeStep(){break}}
        check(motion.captures==before+1,"idle preparation rebuilds the changed draft after the flight")
        print("DOCK IDLE: maxControl=\(maxTurn) ms; 30 mode prepares=\(modePrepareMS) ms; flight captures=0")
    }
    static func avatarPaint(scale:CGFloat,check:(Bool,String)->Void) {
        final class Reference:NSView {
            let face=ModeFlight.AvatarFace()
            override var isFlipped:Bool{true}
            override func draw(_ dirtyRect:NSRect) {
                let g=face.glassness,r=bounds
                NSGraphicsContext.saveGraphicsState();NSBezierPath(ovalIn:r).addClip()
                NSGradient(colors:[NSColor(srgbRed:0x78/255,green:0xd8/255,blue:0xa6/255,alpha:1-0.7*g),NSColor(srgbRed:0x2b/255,green:0x8a/255,blue:0x7a/255,alpha:1-0.7*g)])?.draw(in:r,angle:-45)
                NSGraphicsContext.restoreGraphicsState();face.drawGlyph(in:r)
            }
        }
        for size:CGFloat in [26,36] {for g:CGFloat in [0,0.1,0.4,0.65,1] {
            let a=ModeFlight.AvatarFace(frame:CGRect(x:0,y:0,width:size,height:size));a.glassness=g
            let b=Reference(frame:a.frame);b.face.glassness=g
            let x=NativeViewBitmap.capture(a,scale:scale),y=NativeViewBitmap.capture(b,scale:scale)
            check((x.dataProvider!.data! as Data)==(y.dataProvider!.data! as Data),"cached account gradient matches original paint at \(g), \(size)pt \(scale)x")
        }}
    }
    static func idleMotion(_ detail:NormieDetailController,scale:CGFloat,check:(Bool,String)->Void) {
        var longest=0.0,totalOld=0.0,slices=0
        let composerScale=detail.composer?.verificationScale
        detail.composer?.verificationScale=scale;detail.composer?.needsLayout=true;detail.composer?.layoutSubtreeIfNeeded()
        defer{detail.composer?.verificationScale=composerScale;detail.composer?.needsLayout=true;detail.composer?.layoutSubtreeIfNeeded()}
        func rgba(_ image:CGImage)->Data {
            let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return Data(bytes:c.data!,count:image.width*image.height*4)
        }
        let before=detail.composer.map{($0.superview,$0.frame,$0.text,$0.textView.selectedRange())}
        let legacyStart=CACurrentMediaTime()
        ModeSignposts.operation("LegacyNormieMotionPrewarm",detail:"offscreen negative budget reference only") {detail.prepareMotionPictures()}
        let legacyMS=(CACurrentMediaTime()-legacyStart)*1000
        check(legacyMS>8,"old monolithic motion prewarm reproduces an over-budget main-thread block")
        for source in detail.verificationIdleMotionSources {
            if !NormieIdleMotionCapture.supports(source) {
                check(source === detail.terminalPane,"unbounded terminal is explicitly deferred to its owner, never silently published with incomplete pixels")
                continue
            }
            let start=CACurrentMediaTime()
            guard let old=detail.verificationMotionCapture(source,scale:scale) else{continue}
            totalOld+=(CACurrentMediaTime()-start)*1000
            let editor=source === detail.composer?.scrollView ? detail.composer:nil
            let allocationStart=CACurrentMediaTime()
            guard let capture=NormieIdleMotionCapture(editor?.textView ?? source,scale:scale,composer:editor) else{check(false,"idle motion capture initializes");continue}
            longest=max(longest,(CACurrentMediaTime()-allocationStart)*1000)
            let deadline=Date(timeIntervalSinceNow:10)
            while !capture.complete && Date()<deadline {
                if capture.waitingForPixels {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.002))}
                else {detail.verificationExposeMotionSource(source) {capture.step()};slices+=1}
            }
            check(capture.complete,"idle motion worker completes for \(type(of:source))")
            guard let picture=capture.result else{continue}
            longest=max(longest,capture.maxSliceMS)
            // ContextRow already has an own-draw foreground contract in Dock. cacheDisplay can downsample its
            // 2x private symbol backing in detached 1x checks; compare tiles to the established transparent adapter.
            let expected=(source is NativeComposerContextRow ? M10DockPicture.draw(source,scale:scale,plates:false):nil) ?? old.full
            var a=rgba(expected),b=rgba(picture.full)
            // NSProgressIndicator runs its own threaded animation. Its phase is not a deterministic pixel oracle.
            func excludeLiveSpinner(_ view:NSView) {
                if view is NSProgressIndicator {
                    let q=view.convert(view.bounds,to:source).insetBy(dx:-2,dy:-2)
                    let width=old.full.width,height=old.full.height
                    for row in max(0,Int(floor(q.minY*scale)))..<min(height,Int(ceil(q.maxY*scale))) {
                        for y in [row,height-1-row] {
                            for x in max(0,Int(floor(q.minX*scale)))..<min(width,Int(ceil(q.maxX*scale))) {for c in 0..<4{a[(y*width+x)*4+c]=0;b[(y*width+x)*4+c]=0}}
                        }
                    }
                }
                for child in view.subviews{excludeLiveSpinner(child)}
            }
            excludeLiveSpinner(source)
            let changed=zip(a,b).filter{$0 != $1}.count
            print("IDLE PICTURE \(scale)x \(type(of:source)): bytes=\(changed)/\(a.count), sliceMax=\(capture.maxSliceMS)")
            if a != b {
                let out=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first!)
                Offscreen.write(old.full,out.appendingPathComponent("idle-old-\(type(of:source))-\(scale).png"))
                Offscreen.write(picture.full,out.appendingPathComponent("idle-new-\(type(of:source))-\(scale).png"))
            }
            if a != b {
                let indices=a.indices.filter{a[$0] != b[$0]};let xs=indices.map{($0/4)%old.full.width},ys=indices.map{($0/4)/old.full.width}
                print("DIFF BOUNDS \(type(of:source)) x=\(xs.min()!)...\(xs.max()!) y=\(ys.min()!)...\(ys.max()!)")
            }
            let error=zip(a,b).map{abs(Int($0)-Int($1))}.max() ?? 0
            check(error <= (source is NativeComposerContextRow ? 1:0),"idle foreground matches unsliced transparent paint (context-row rounding <=1 LSB) \(type(of:source))")
            check(rgba(old.solids)==rgba(picture.solids),"tiled idle plates exactly match native plates \(type(of:source))")
            check(picture.glasses.count==old.glasses.count && picture.inkRegion != nil,"idle capture retains real glass descriptors and precomputed ink bounds")
        }
        if let c=detail.composer,let before {
            check(c.superview === before.0 && c.frame == before.1 && c.text == before.2 && c.textView.selectedRange() == before.3,"idle slices preserve native composer ownership, frame, text and selection")
        }
        check(longest<8,"idle AppKit tile stays below 8 ms offscreen")
        print("IDLE BUDGET \(scale)x: oldMonolithic=\(legacyMS) ms; oldSourcesTotal=\(totalOld) ms; maxSlice=\(longest) ms; slices=\(slices)")
    }
    static func mount(_ view:NSView) {
        // CARenderer borrows native layers. Reconcile AppKit's ACTUAL sibling order, without flattening the flight.
        for child in view.subviews {if let layer=child.layer {view.layer?.addSublayer(layer)};mount(child)}
    }
    static func streamAndSourceRegressions(_ shell:WindowShell,scale:CGFloat,check:(Bool,String)->Void) {
        let frameOld=shell.verificationGeometryUnderDeltas(legacy:true,deltas:false)
        let frameCurrent=shell.verificationGeometryUnderDeltas(legacy:false,deltas:false)
        check(!frameOld.ready && frameCurrent.ready,"restoring Organic hidden sidebar frames each turn breaks the old key and preserves current geometry completion")
        check(shell.verificationSourceUnderFrameRestores(),"real Organic geometry and source phases both finish while AppKit restores the hidden sidebar frame")
        let old=shell.verificationGeometryUnderDeltas(legacy:true)
        let current=shell.verificationGeometryUnderDeltas(legacy:false)
        print("GEOMETRY streaming \(scale)x: legacy=\(old) current=\(current)")
        check(!old.ready,"legacy hidden-frame/full-key/store-cancel rules fail geometry completion under deltas")
        check(current.ready && current.tokens>=3,"real Organic hierarchy finishes geometry with header/Dock flights under continuous store changes and hidden-frame restoration")
        // The production NativePlane really contains mounted parked transcripts behind an empty fade mask.
        // Replay the live parked state inside the real NativePlane. A windowless scene uses cached captures at rest.
        let recorded=NativeTranscript(conversation:MockSeed.make().last!)
        recorded.frame=CGRect(x:0,y:0,width:220,height:180);recorded.wantsLayer=true
        let empty=CALayer();empty.bounds = .zero;recorded.layer?.mask=empty
        shell.verificationNativePlane.addSubview(recorded);recorded.isHidden=false
        let parked=shell.verificationNativePlane.subviews.filter{$0.layer?.mask?.bounds.isEmpty == true}
        check(!parked.isEmpty,"real NativePlane hosts the recorded empty-mask parked transcript state")
        let caret=NSTextInsertionIndicator(frame:CGRect(x:4,y:4,width:3,height:30));caret.wantsLayer=true
        shell.verificationNativePlane.addSubview(caret)
        let layerHidden=NSView(frame:CGRect(x:20,y:4,width:24,height:24));layerHidden.wantsLayer=true;layerHidden.layer?.isHidden=true
        shell.verificationNativePlane.addSubview(layerHidden)
        ModeSurfaceBuilder.verificationLegacyVisibility=true
        let oldViews=shell.verificationCurrentSurface.verificationViews
        ModeSurfaceBuilder.verificationLegacyVisibility=false
        let views=shell.verificationCurrentSurface.verificationViews
        check(parked.contains{p in oldViews.contains{$0 === p}},"old source walk includes a genuinely parked NativePlane view")
        check(!parked.contains{p in views.contains{$0 === p || $0.isDescendant(of:p)}},"source display list excludes parked NativePlane transcript subtrees")
        check(oldViews.contains{$0 === caret} && !views.contains{$0 === caret},"old source includes the system caret; production source excludes it")
        check(oldViews.contains{$0 === layerHidden} && !views.contains{$0 === layerHidden},"source honors CALayer.isHidden independently of NSView.isHidden")
        recorded.dispose();recorded.removeFromSuperview();caret.removeFromSuperview();layerHidden.removeFromSuperview()
        shell.prepareModeSwitch(reason:"verification.restore.after.streaming")
        let opening=shell.verificationStreamingOpening()
        check(opening.tokens==current.tokens && opening.tokens>=3,"all real opening orbs exist on the first production frame during a body-only picture miss")
        check(opening.hits==opening.tokens,"streaming opening consumes every prepared orb resource without a body-revision miss")
        check(opening.stableSource,"a source viewport remains visually frozen while later stream deltas reach the model")
        print("STREAM OPENING \(scale)x: \(opening)")
        shell.prepareModeSwitch(reason:"verification.restore.after.opening")
    }
    static func runShell(_ shell:WindowShell,scale:CGFloat,output:URL,check:(Bool,String)->Void) {
        let ready=shell.verificationBeginLayerReplay()
        check(ready,"real WindowShell has header, Dock and me resources for the combined layer check")
        guard ready else{return}
        mount(shell.view)
        var samples:[M10ModeFrameSample]=[];shell.flight.onExposureSample={samples.append($0)}
        shell.flight.sample(at:0.16,profile:.init(name:"60Hz",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0))
        let renderer=OffscreenRenderer(size:shell.view.bounds.size,host:shell.view.layer!,scale:scale)
        let time=VerificationClock.renderOrigin
        var visible=0
        for sample in samples {
            let focus=shell.flight.verificationFocus(sample.id)
            let restore=shell.flight.verificationPaint(into:shell.flight.view.layer!,scale:scale,elapsed:0.16,onlyID:sample.id)
            CATransaction.begin();CATransaction.setDisableActions(true);shell.flight.view.layer?.opacity=1;CATransaction.commit()
            let on=renderer.render(at:time)
            CATransaction.begin();CATransaction.setDisableActions(true);shell.flight.view.layer?.opacity=0;CATransaction.commit()
            let off=renderer.render(at:time)
            let rect=sample.now.insetBy(dx:-2,dy:-2)
            var count=0
            for y in max(0,Int(rect.minY*scale))...min(renderer.h-1,Int(rect.maxY*scale)) {
                for x in max(0,Int(rect.minX*scale))...min(renderer.w-1,Int(rect.maxX*scale)) {
                    let i=(y*renderer.w+x)*4
                    if (0..<3).contains(where:{abs(Int(on[i+$0])-Int(off[i+$0]))>2}) {count+=1}
                }
            }
            if count>0 {visible+=1}
            print("SHELL orb \(sample.id) \(sample.now) changedPixels=\(count)")
            Offscreen.write(renderer.image(on),output.appendingPathComponent("window-shell-\(sample.id)-\(scale).png"))
            restore();focus()
        }
        check(visible==3,"real WindowShell split/source/flight composition retains all three moving orbs after re-admission")
        print("WindowShell layer replay \(scale)x: \(visible)/3 non-glass orb centres visible")
        shell.flight.view.layer?.opacity=1;shell.flight.onExposureSample=nil;shell.verificationEndLayerReplay()
    }
    static func stalledServerMotion(scale:CGFloat,forward:Bool,check:(Bool,String)->Void) {
        let flight=ModeFlight();var clock=1000.0;flight.manualTime={clock};flight.verificationServerMotion=true
        flight.resize(to:CGSize(width:640,height:420))
        let c=MockSeed.make()[0],a=CGRect(x:48,y:70,width:20,height:20),b=CGRect(x:510,y:250,width:52,height:52)
        let token=ModeFlight.Token(id:"stall",conversation:c,from:forward ? a:b,to:forward ? b:a,start:0.08,absorbed:!forward)
        flight.prewarm(tokens:[token]);flight.prewarmServerMotion(toOrganic:forward,avatar:(a,b),tokens:[token],composer:nil)
        flight.start(toOrganic:forward,avatar:(a,b),initials:"LL",tokens:[token],composer:nil,reduceMotion:false)
        guard let layer=flight.verificationServerLayer,let command=layer.animation(forKey:"mode.server.translation") else {check(false,"renderer translation command exists");return}
        // Borrow the exact production position/transform and CA command. A red marker replaces only glyph ink.
        // No ModeFlight.sample, timer or main-thread shape update is called between renderer frames.
        let root=CALayer();root.bounds=CGRect(x:0,y:0,width:640,height:420);root.isGeometryFlipped=true
        let marker=CALayer();marker.bounds=layer.bounds;marker.position=layer.position;marker.anchorPoint=layer.anchorPoint;marker.transform=layer.transform
        let ink=CALayer();ink.frame=CGRect(x:token.from.midX-4,y:token.from.midY-4,width:8,height:8);ink.backgroundColor=NSColor.red.cgColor;marker.addSublayer(ink)
        root.addSublayer(marker);marker.add(command,forKey:"mode.server.translation")
        let renderer=OffscreenRenderer(size:CGSize(width:640,height:420),host:root,scale:scale)
        func centre(_ bytes:[UInt8])->CGPoint? {
            var xSum=0.0,ySum=0.0,n=0.0
            for y in 0..<renderer.h {for x in 0..<renderer.w {let i=(y*renderer.w+x)*4
                if bytes[i+2]>100 && bytes[i+1]<20 {xSum+=Double(x);ySum+=Double(y);n+=1}
            }}
            return n>0 ? CGPoint(x:xSum/n/scale,y:ySum/n/scale):nil
        }
        let first=centre(renderer.render(at:1000.10)),last=centre(renderer.render(at:1000.22))
        let distance=first.flatMap{a in last.map{hypot($0.x-a.x,$0.y-a.y)}} ?? 0
        print("STALL \(forward ? "N2O":"O2N") \(scale)x first=\(String(describing:first)) last=\(String(describing:last)) movement=\(distance)")
        check(distance>20,"\(scale)x \(forward ? "N2O":"O2N") production CA translation advances during 120ms without a main-thread flight sample")
        var baked:CGRect?
        flight.onExposureSample={if $0.id == "planet.stall" {baked=$0.now}}
        clock=1000.22;flight.targetShift={.zero}
        let reference=ModeFlight();reference.manualTime={1000};reference.resize(to:CGSize(width:640,height:420))
        reference.start(toOrganic:forward,avatar:(a,b),initials:"LL",tokens:[token],composer:nil,reduceMotion:false)
        var expected:CGRect?;reference.onExposureSample={if $0.id == "planet.stall" {expected=$0.now}}
        reference.sample(at:0.22,profile:.init(name:"60Hz",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0))
        check(baked.flatMap{a in expected.map{MotionStep.edge(a,$0)<0.001}} ?? false,"driver B retirement bakes the current pose before sidebar driver A takes over")
        reference.shutdown();flight.shutdown()
    }
    static func composerBatch(check:(Bool,String)->Void) {
        let c=NativeComposer();let initial=c.presentationUpdateCount
        c.configurePresentation {c.layoutMode = .growing;c.targetWidth=nil;c.deviceName="Fixture";c.contextSummary="Fixture context";c.layoutMode = .growing}
        check(c.presentationUpdateCount-initial==1,"host composer policy installs one native menu/control presentation")
        let settled=c.presentationUpdateCount;c.layoutMode = .growing
        check(c.presentationUpdateCount==settled,"assigning an unchanged composer layout mode does not rebuild menus")
        check(c.text.isEmpty && c.layoutMode == .growing && c.targetWidth == nil,"composer batching preserves draft and final host semantics")
    }
    static func detachedCardGrid(check:(Bool,String)->Void) {
        guard let c=MockSeed.make().first(where:{!$0.approvals.isEmpty}),let approval=c.approvals.first else {check(false,"approval fixture exists");return}
        let source=NativeApprovalSource(project:"Mock",conversation:c.title,isOtherConversation:false,canShowConversation:true)
        let old=NativeTranscriptCard();old.setApprovalSource(source,reconfigure:false)
        old.configureApproval(approval,width:1040){_ in};old.verificationScale=2
        let card=NativeTranscriptCard();card.prepareForPresentation(scale:2);card.setApprovalSource(source,reconfigure:false)
        card.configureApproval(approval,width:1040){_ in};card.verificationScale=2
        check(old.approvalConfigurationCount>1,"old detached 1x fallback rebuilds at simulated 2x admission")
        check(card.approvalConfigurationCount==1,"prepared target grid avoids the duplicate rail rebuild at 2x admission")
        check(card.frame==old.frame && card.approvalPlateRect==old.approvalPlateRect,"single-pass card preserves the final 2x geometry")
        print("CARD detached grid: old=\(old.approvalConfigurationCount) prepared=\(card.approvalConfigurationCount)")
        let flight=ModeFlight();flight.manualTime={1000};flight.resize(to:CGSize(width:640,height:420))
        let token=ModeFlight.Token(id:"body.delta",conversation:c,from:CGRect(x:40,y:40,width:40,height:40),to:CGRect(x:20,y:300,width:16,height:16),start:0.08,absorbed:true)
        flight.prewarm(tokens:[token]);let prepared=flight.preparedTokenCount
        c.revision+=1
        flight.start(toOrganic:false,avatar:(token.from,token.to),initials:"LL",tokens:[token],composer:nil,reduceMotion:false)
        check(flight.consumedPreparedTokens==1 && flight.preparedTokenCount==prepared,"body-only revisions preserve prepared flight decoration")
        flight.shutdown()
    }
    static func run(_ output:URL,check:(Bool,String)->Void) {
        composerBatch(check:check)
        detachedCardGrid(check:check)
        var audit:[[String:Any]]=[]
        for scale:CGFloat in [1,2] {
            for forward in [false,true] {stalledServerMotion(scale:scale,forward:forward,check:check)}
            let card=RecordedMatte(frame:CGRect(x:0,y:0,width:100,height:64));card.wantsLayer=true
            let glass=NSGlassEffectView(frame:card.bounds);card.addSubview(glass)
            let captured=ModeSurfaceCapture.capture(card,scale:scale)
            let pixels=NSBitmapImageRep(cgImage:captured)
            let blank=pixels.colorAt(x:Int(80*scale),y:Int(40*scale))!
            let white=pixels.colorAt(x:Int(18*scale),y:Int(18*scale))!
            let black=pixels.colorAt(x:Int(42*scale),y:Int(18*scale))!
            check(blank.alphaComponent==0,"\(scale)x recorded opaque approval canvas never enters the source foreground")
            check(white.alphaComponent>0 && black.alphaComponent>0,"own-draw retains both white and legitimate black glyphs")
            audit.append(["scale":scale,"recordedCacheBlank":[28,28,28,255],"sourceBlankAlpha":blank.alphaComponent])

            let materialHost=ModeFlight.Plane(frame:card.bounds);materialHost.wantsLayer=true
            let material=NSGlassEffectView(frame:card.bounds),ink=RecordedMatte(frame:card.bounds)
            material.contentView=ink;materialHost.addSubview(material)
            let builder=ModeSurfaceBuilder(materialHost,scale:scale)
            while !builder.ready {builder.step()}
            let source=builder.finish()!,foreground=NSBitmapImageRep(cgImage:source.flattened())
            check(foreground.colorAt(x:Int(18*scale),y:Int(18*scale))!.alphaComponent>0,"real glass content has an independent source foreground")
            let top=ModeFlight.Plane(frame:card.bounds);top.wantsLayer=true;materialHost.addSubview(top)
            let carrier=ModeHandoffPlate(frame:.zero);carrier.hold(source,in:materialHost,below:top,holes:[])
            check((ModeHandoffPlate.carriesGlass ? material.superview !== materialHost:material.superview === materialHost) && material.frame == card.bounds && material.alphaValue == 1,"source handoff preserves the material geometry and the selected ancestry policy")
            check(ink.alphaValue == (ModeHandoffPlate.carriesGlass ? 0:1),"resident source glass never loses its own live content or backdrop ancestry")
            carrier.clear()
            check(material.superview === materialHost && ink.alphaValue == 1,"source retirement restores real glass content ownership and opacity")

            for forward in [false,true] {
                let size=CGSize(width:640,height:420), host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size))
                host.wantsLayer=true
                let target=ModeFlight.Plane(frame:host.bounds);target.wantsLayer=true;target.layer?.backgroundColor=NSColor.blue.cgColor;host.addSubview(target)
                let flight=ModeFlight();flight.manualTime={1000};flight.resize(to:size);host.addSubview(flight.view)
                let picture=CGContext(data:nil,width:640,height:420,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                picture.setFillColor(NSColor.blue.cgColor);picture.fill(host.bounds)
                let bitmap=picture.makeImage()!,plate=ModeHandoffPlate(frame:.zero)
                plate.stage(bitmap,in:host,below:flight.view)
                let conversation=MockSeed.make()[0]
                let row=CGRect(x:26,y:100,width:16,height:16),header=CGRect(x:400,y:24,width:56,height:56),dock=CGRect(x:540,y:365,width:40,height:40)
                let tokens=[ModeFlight.Token(id:"header."+conversation.id,conversation:conversation,from:forward ? row:header,to:forward ? header:row,start:0.08,absorbed:!forward),
                            .init(id:"dock",conversation:conversation,from:forward ? row.offsetBy(dx:0,dy:40):dock,to:forward ? dock:row.offsetBy(dx:0,dy:40),start:0.12,absorbed:!forward)]
                flight.prewarm(tokens:tokens)
                flight.start(toOrganic:forward,avatar:(CGRect(x:280,y:366,width:36,height:36),CGRect(x:24,y:365,width:26,height:26)),initials:"LL",tokens:tokens,composer:nil,reduceMotion:false)
                plate.hold(bitmap,in:host,below:flight.view,holes:[])
                // Replay a backing-view admission above the old source/flight. This is a recorded-state boundary,
                // not a claim that a windowless NSView reproduces WindowServer's undocumented layer rebuild.
                host.addSubview(target,positioned:.above,relativeTo:nil)
                host.addSubview(plate,positioned:.above,relativeTo:nil)
                plate.hold(bitmap,in:host,below:flight.view,holes:[])
                mount(host)
                var samples:[M10ModeFrameSample]=[];flight.onExposureSample={samples.append($0)}
                flight.sample(at:0.16,profile:.init(name:"60Hz",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0))
                let renderer=OffscreenRenderer(size:size,host:host.layer!,scale:scale)
                let restore=flight.verificationPaint(into:flight.view.layer!,scale:scale,elapsed:0.16)
                let bytes=renderer.render(at:VerificationClock.renderOrigin)
                var visible=0
                for sample in samples {
                    let x=min(renderer.w-1,max(0,Int(sample.now.midX*scale))),y=min(renderer.h-1,max(0,Int(sample.now.midY*scale))),i=(y*renderer.w+x)*4
                    if bytes[i+1]>20 || bytes[i+2]>20 {visible+=1}
                }
                check(visible==samples.count && visible>=3,"\(scale)x \(forward ? "N2O":"O2N") header/Dock/me survive target + source native layer re-admission")
                audit.append(["scale":scale,"direction":forward ? "N2O":"O2N","visibleOrbs":visible,"expectedOrbs":samples.count,"boundary":"target/source re-admitted above flight, then production hold reasserts order"])
                Offscreen.write(renderer.image(bytes),output.appendingPathComponent("hierarchy-\(forward ? "n2o":"o2n")-\(scale).png"))
                restore();flight.shutdown();plate.clear()
            }
        }
        try! JSONSerialization.data(withJSONObject:audit,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("regressions.json"))
    }
}
#endif
