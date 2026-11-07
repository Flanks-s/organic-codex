import AppKit
import QuartzCore

/// Real mount routes and native hit testing, without a window or backend. PNGs use the existing glass proxy.
@MainActor enum IslandLayerVerification {
    static func run(to output:URL)->(checks:Int,findings:[String]) {
        try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,findings=[String](),records=[[String:Any]]()
        @MainActor func check(_ value:Bool,_ message:String) {
            checks+=1
            if !value {findings.append(message);print("FINDING ISLAND-LAYER",message)}
        }
        for shared in [false,true] {for scale:CGFloat in [1,2] {autoreleasepool {
            let conversations=(0..<6).map { index in
                let c=Conversation(id:"layer-\(index)",title:"Offline conversation \(index)")
                c.items=(0..<48).map { i in
                    TranscriptItem(id:"layer-\(index)-\(i)",kind:i.isMultiple(of:4) ? .user:.assistant,
                        text:"Ran /bin/zsh -lc \"python3 fixture.py\" — line \(i). " + String(repeating:"Selectable offline transcript. ",count:5),running:false)
                }
                return c
            }
            let store=ConversationStore(conversations:conversations,projects:MockSeed.projects,devices:MockSeed.devices)
            let owner=shared ? NativeTranscriptSessions(store:store):nil
            let size=CGSize(width:1600,height:900)
            let scene=AutoScene(size:size,store:store,profile:.init(name:"island-layer-offscreen",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0),scale:scale,transcriptSessions:owner)
            // hitTest takes parent coordinates. A flipped, windowless root matches the real scene host.
            let root=IslandPlane(frame:CGRect(origin:.zero,size:size));root.addSubview(scene.nativePlane)
            scene.verificationPresented=true;scene.manualSettle=true;scene.ambient=false
            var time=CACurrentMediaTime()+3600;scene.now={time}
            if shared {scene.setTranscriptPresentationActive(true)}
            scene.install(members:conversations.map(\.id));scene.clock.invalidate()
            defer {scene.disposeTranscriptPresentation();owner?.dispose();withExtendedLifetime(root) {}}
            let tag="\(Int(scale))x-\(shared ? "shared":"owned")"
            @MainActor func settle() {
                time=max(time+3,scene.transitionEnd+3);scene.frame(time);scene.settle();scene.clock.invalidate()
            }
            @MainActor func checkpoint(_ name:String) {
                let plane=scene.nativePlane
                let roots=plane.subviews.filter { !($0 is NativeTranscript) }
                let headers=scene.columns.compactMap(\.island)
                let full=scene.columns.filter(\.isFull)
                // Test-only fault injection: reconstruct the old order after an actual mode return.
                // This deliberately bypasses the insertion policy, then restores it after probing.
                let oldOrder=ProcessInfo.processInfo.environment["SELFTEST_ISLAND_LAYER_OLD_ORDER"] == "1" && name == "mode-return"
                if oldOrder {plane.sortSubviews({ a,b,_ in
                    let x=a is NativeTranscript,y=b is NativeTranscript
                    return x == y ? .orderedSame:(x ? .orderedDescending:.orderedAscending)
                },context:nil)}
                defer {if oldOrder {for view in plane.subviews where view is NativeTranscript {plane.addSubview(view)}}}
                check(!full.isEmpty || scene.composingNew,"\(name) has a full column or the draft-only arrangement \(tag)")
                var inversions=0,inside=0,leaks=0,misses=0,outside=0,outsideMisses=0,overlap=0
                for native in plane.subviews where native is NativeTranscript {
                    let index=plane.subviews.firstIndex(where:{$0 === native})!
                    inversions+=roots.filter { root in plane.subviews.firstIndex(where:{$0 === root})!<index }.count
                }
                for column in full {
                    guard column.native.superview === plane,let island=column.island else {
                        check(false,"\(name) full native and island mounted \(tag)");continue
                    }
                    check(column.ownsNative && !column.native.isHidden && island.superview === plane,"\(name) full native visible and owned; island keeps its direct parent \(tag)")
                    for header in headers {header.now={time};header.setExpanded(false);header.sampleMotion(at:time+2)}
                    island.setExpanded(true,pinned:true);island.sampleMotion(at:time+2)
                    let capsule=island.geometry.capsule
                    let shape=NSBezierPath(roundedRect:capsule,xRadius:island.geometry.radius,yRadius:island.geometry.radius)
                    // Sample a one-point grid, including blank plate areas between the native controls.
                    for y in stride(from:capsule.minY+0.5,through:capsule.maxY-0.5,by:1) {
                        for x in stride(from:capsule.minX+0.5,through:capsule.maxX-0.5,by:1) {
                            let local=CGPoint(x:x,y:y)
                            guard shape.contains(local) else {continue}
                            let point=island.convert(local,to:plane),hit=plane.hitTest(point)
                            inside+=1
                            if column.native.frame.contains(point) {overlap+=1}
                            if let hit,hit === column.native || hit.isDescendant(of:column.native) {leaks+=1}
                            if hit == nil || !(hit === island || hit!.isDescendant(of:island)) {misses+=1}
                        }
                    }
                    let viewport=column.native.scrollView.contentView,body=viewport.bounds
                    for x in [body.minX+30,body.midX,body.maxX-30] {
                        for y in [body.midY,body.minY+body.height*0.75] {
                            let p=viewport.convert(CGPoint(x:x,y:y),to:plane)
                            guard plane.bounds.contains(p),!headers.contains(where:{$0.hitTest(p) != nil}) else {continue}
                            let hit=plane.hitTest(p);outside+=1
                            if hit == nil || !(hit === column.native || hit!.isDescendant(of:column.native)) {
                                outsideMisses+=1
                                print("ISLAND-LAYER outside miss",name,tag,p,"hit",hit.map{String(describing:type(of:$0))} ?? "nil")
                            }
                        }
                    }
                    // Snapshot while expanded, in actual sibling order; the proxy cannot prove live backdrop blur.
                    if name == "new-node" || name == "mode-return" || name == "collapse-return" {
                        writeFrame(scene,scale:scale,to:output.appendingPathComponent("\(name)-\(tag).png"))
                    }
                    island.setExpanded(false);island.sampleMotion(at:time+2)
                }
                check(inversions==0,"\(name) transcripts below every island/draft/spare: \(inversions) inversions \(tag)")
                check(full.isEmpty || overlap>0,"\(name) expanded capsule overlaps a selectable native viewport \(tag)")
                check((full.isEmpty || inside>0) && misses==0 && leaks==0,"\(name) capsule hit grid: \(misses) misses, \(leaks) transcript leaks / \(inside) \(tag)")
                check((full.isEmpty || outside>0) && outsideMisses==0,"\(name) outside transcript hits: \(outsideMisses) misses / \(outside) \(tag)")
                records.append(["path":name,"tag":tag,"fullColumns":full.count,"upperRoots":roots.count,"inversions":inversions,
                    "capsuleSamples":inside,"overlapSamples":overlap,"transcriptLeaks":leaks,"capsuleMisses":misses,
                    "outsideSamples":outside,"outsideMisses":outsideMisses])
            }
            settle();checkpoint("new-node")
            for column in scene.columns {scene.nativePlane.addSubview(column.native,positioned:.above,relativeTo:nil)}
            checkpoint("positioned-admission")
            // An ordinary column change must not reorder the native siblings during motion frames.
            scene.switchTo(1,reason:"island-layer-switch")
            let siblings=scene.nativePlane.subviews.map(ObjectIdentifier.init)
            for _ in 0..<24 {time+=1/120;scene.frame(time)}
            check(scene.nativePlane.subviews.map(ObjectIdentifier.init)==siblings,"motion frames keep native sibling order \(tag)")
            settle();checkpoint("column-switch")
            if let owner {
                scene.suspendModePresentation()
                let bench=NormieWorkbench(store:store,sessions:NativeComposerSessions(),current:scene.current,transcriptSessions:owner)
                bench.detail.view.frame=CGRect(origin:.zero,size:size);bench.refresh();bench.detail.view.layoutSubtreeIfNeeded()
                let native=owner.existingTranscript(for:scene.current)!
                check(native.superview === bench.detail.view && !(bench.detail.view is AutoScene.NativePlane),"Normie keeps its ordinary host \(tag)")
                let ordinary=NormieView(frame:CGRect(origin:.zero,size:size)),marker=NSView()
                ordinary.addSubview(marker)
                let ordinaryLease=owner.mount(conversations.last!,in:ordinary)
                check(ordinary.subviews.last === ordinaryLease?.transcript,"Normie host keeps its existing append policy \(tag)")
                bench.setTranscriptPresentationActive(false)
                if let plan=scene.beginModeTarget(selected:scene.current) {
                    while !plan.ready {_=scene.prepareModeTargetStep(plan)}
                    check(scene.commitModeTarget(plan),"mode target commits \(tag)")
                    checkpoint("mode-commit")
                    scene.admitUnmountedTranscripts(scene.columns)
                    checkpoint("mode-return")
                } else {check(false,"mode target prepared \(tag)")}
                // Force the d1dbf88 admission path for the next full column, retaining its existing island.
                let target=scene.columns.first { !$0.isFull }!
                target.unmountNative();scene.admitUnmountedTranscripts([target])
                scene.activate(target.conversation.id,reason:"island-layer-admit-unmounted");settle()
                checkpoint("admit-unmounted")
                let collapsedNative=owner.existingTranscript(for:scene.current)
                scene.setTranscriptPresentationActive(false)
                let strip=CollapseStrip(store:store,sessions:scene.composers,members:scene.members,shown:scene.current,scale:scale,transcriptSessions:owner)
                strip.frame=CGRect(x:0,y:0,width:900,height:540);strip.layoutSubtreeIfNeeded()
                check(owner.existingTranscript(for:scene.current) === collapsedNative,"Collapse retains the same session for restore \(tag)")
                strip.dispose();scene.setTranscriptPresentationActive(true);settle();checkpoint("collapse-return")
                bench.detail.disposeTranscripts()
            }
            let dockID=scene.order.last!
            scene.activate(dockID,reason:"island-layer-dock-in");settle();checkpoint("dock-in")
            scene.activate(conversations[0].id,reason:"island-layer-dock-out");settle()
            scene.activate(dockID,reason:"island-layer-dock-return");settle();checkpoint("dock-return")
            scene.newChat();settle();scene.warmNewChatIsland()
            check(scene.draftColumn?.superview === scene.nativePlane && scene.spareNewChatIsland?.superview === scene.nativePlane,"draft and spare share the native host \(tag)")
            if shared {scene.setTranscriptPresentationActive(false);scene.setTranscriptPresentationActive(true)}
            checkpoint("new-chat-draft")
            scene.cancelNewChat();settle();checkpoint("new-chat-cancel")
            scene.onCreate={text,_ in Conversation(id:"layer-sent",title:text)}
            scene.onSubmit={_,_,done in done(.accepted);return true}
            store.onAdd={ [weak scene] c in scene?.admit(c,reason:"island-layer-first-send") }
            scene.newChat();settle();scene.warmNewChatIsland()
            let composer=scene.composers.draft().composer;composer.setText("Offline first send");_=composer.submit()
            // First send retains the old seed for 50 ms on the main queue. A virtual scene clock cannot retire it.
            let seedDeadline=Date().addingTimeInterval(0.08)
            while Date()<seedDeadline {_=RunLoop.main.run(mode:.default,before:seedDeadline)}
            settle();checkpoint("new-chat-send")
            scene.resize(to:CGSize(width:1500,height:860),live:true);settle();checkpoint("resize")
            scene.enterFocused(scene.current,reason:"island-layer-focus");settle()
            scene.graft(conversations.first{$0.id != scene.current}!.id,at:1,reason:"island-layer-split");settle();checkpoint("split")
        }}}
        let report:[String:Any]=["checks":checks,"findings":findings,"paths":records,"glass":"Offscreen proxy; live blur requires a real window."]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:output.appendingPathComponent("verification.json"))}
        let text="Island layers: \(checks) checks, \(findings.count) findings\n"+findings.joined(separator:"\n")+"\n"
        try? text.write(to:output.appendingPathComponent("verification.txt"),atomically:true,encoding:.utf8);print(text)
        return (checks,findings)
    }

    private static func writeFrame(_ scene:AutoScene,scale:CGFloat,to url:URL) {
        let size=scene.nativePlane.bounds.size
        guard let context=CGContext(data:nil,width:Int(size.width*scale),height:Int(size.height*scale),bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return}
        context.setFillColor(Look.canvas.cgColor);context.fill(CGRect(x:0,y:0,width:context.width,height:context.height))
        for view in scene.nativePlane.subviews where !view.isHidden {
            let image:CGImage
            if let transcript=view as? NativeTranscript {image=transcript.snapshot(scale:scale)}
            else if let island=view as? HeaderIsland {image=island.snapshot(scale:scale)}
            else {continue}
            let r=view.frame
            context.draw(image,in:CGRect(x:r.minX*scale,y:(size.height-r.maxY)*scale,width:r.width*scale,height:r.height*scale))
        }
        if let image=context.makeImage() {Offscreen.write(image,url)}
    }
}
