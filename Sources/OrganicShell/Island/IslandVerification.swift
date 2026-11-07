#if ISLAND_SELFTEST
import AppKit
import ObjectiveC

/// swiftc Core/*.swift Native/*.swift Orb/*.swift Normie/*.swift Island/*.swift -D ISLAND_SELFTEST.
/// No NSWindow, no app run loop, no .app launch. Time is injected into all state-machine checks.
@main @MainActor enum IslandVerification {
    static func main() throws {
        _ = NSApplication.shared; NSApp.appearance=NSAppearance(named:.darkAqua)
        OrbDisplayEnvironment.shared.setOverride(.init()); defer { OrbDisplayEnvironment.shared.setOverride(nil) }
        let directory=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "/tmp/sol-island-results")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],notes:[String]=[]
        func check(_ value:@autoclosure ()->Bool,_ message:String) { checks+=1; if !value() { failures.append(message) } }
        SatelliteOpenerVerification.run {check($0,$1)}
        // M10.4: the island remains independent of Organic; a shared-canvas provider owns the gesture.
        let dragCanvas=IslandPlane(frame:CGRect(x:0,y:0,width:600,height:400))
        let dragProvider=IslandDragVerificationProvider(frame:dragCanvas.bounds)
        let dragHeader=HeaderIsland();dragHeader.configure(.init(id:"drag",title:"Drag source",columnWidth:600,ambient:false))
        dragCanvas.addSubview(dragHeader)
        check(dragHeader.orbDragProvider() == nil,"unbound header keeps its original Customize path")
        dragCanvas.addSubview(dragProvider)
        check(dragHeader.orbDragProvider() === dragProvider,"header discovers only its shared-canvas provider")
        for variant:HeaderIslandVariant in [.full,.brief,.split(focused:true),.split(focused:false),.collapse,.newChat] {
            dragHeader.configure(.init(id:"drag",title:"Drag source",variant:variant,columnWidth:600,ambient:false))
            let supported:Bool
            switch variant {case .full,.brief,.split:supported=true;case .collapse,.newChat:supported=false}
            check(dragHeader.canDragOrb == supported,"full / brief / Split top orbs share the Dock gesture")
        }
        dragHeader.configure(.init(id:"drag",title:"Drag source",columnWidth:600,ambient:false))
        for scale:CGFloat in [1,2] {
            let before=dragHeader.snapshot(scale:scale),glassParent=dragHeader.orb.glassView.superview,rect=dragHeader.draggableOrbRect
            dragHeader.setOrbCarried(true)
            check(dragHeader.orb.glassView.isHidden && dragHeader.orb.backView.isHidden && dragHeader.orb.frontView.isHidden,"carry hides all source paint planes")
            check(dragHeader.draggableOrbRect == rect && dragHeader.orb.glassView.superview === glassParent,"carry does not change geometry or glass parent")
            check(!dragHeader.canDragOrb && dragHeader.hitTest(CGPoint(x:rect.midX,y:rect.midY)) !== dragHeader.planetButton,"carried source has no invisible planet hit target")
            _=dragHeader.snapshot(scale:scale)
            check(dragHeader.orb.backView.isHidden && dragHeader.orb.frontView.isHidden,"offscreen snapshot cannot accidentally restore carried source")
            dragHeader.setOrbCarried(false)
            check(before.dataProvider?.data == dragHeader.snapshot(scale:scale).dataProvider?.data,"carry handback restores native pixels exactly at \(scale)x")
        }
        let dragEvent=NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        dragHeader.planetButton.mouseDown(with:dragEvent)
        dragHeader.planetButton.mouseDragged(with:dragEvent)
        dragHeader.planetButton.mouseUp(with:dragEvent)
        check(dragProvider.gesture.moves==1 && dragProvider.gesture.ups==1,"planet forwards drag/up without blocking AppKit's event loop")
        dragHeader.planetButton.cancelOperation(nil)
        check(dragProvider.gesture.cancels==1,"planet Esc forwards cancellation")
        dragHeader.dispose()
        let variants:[(String,HeaderIslandVariant,CGFloat,CGFloat,CGFloat,CGFloat)]=[
            ("full",.full,56,8,60,112),("brief",.brief,44,12,52,100),
            ("split-focused",.split(focused:true),48,10,54,104),("split",.split(focused:false),48,10,54,104),
            ("collapse",.collapse,48,8,52,104),("new-chat",.newChat,88,0,84,146)]
        for (name,variant,diameter,top,capsule,content) in variants {
            for scale:CGFloat in [1,2] {
                for width:CGFloat in [180,320,563.25,960] {
                    let g=HeaderIslandGeometry.make(variant:variant,columnWidth:width,state:.init(titleWidth:86,hasMark:true,band:44,scale:scale))
                    check(g.planet.size == CGSize(width:diameter,height:diameter) && g.planet.minY == 44+top,"\(name) authored planet at \(width) / \(scale)x")
                    check(g.capsule.minY == 44+capsule && g.contentTop == 44+content,"\(name) title band/content fade remain fixed")
                    check(abs(g.planet.midX-width/2)<=0.5/scale && g.planet.maxY>g.capsule.minY,"\(name) centered planet overlaps the nameplate")
                    check(g.capsule.minX>=0 && g.capsule.maxX<=width+1/scale && g.title.minX>=g.capsule.minX && g.title.maxX<=g.capsule.maxX,"\(name) narrow/large widths keep caption inside column")
                    let rects=[g.planet,g.capsule,g.title,g.titleRow]
                    check(rects.allSatisfy { r in [r.minX,r.minY,r.width,r.height].allSatisfy { abs($0*scale-($0*scale).rounded())<0.0001 } },"\(name) all endpoint rectangles lie on \(scale)x grid")
                }
            }
        }
        for shape:HeaderIslandShape in [.compact,.activity,.expanded,.editing] {
            let g=HeaderIslandGeometry.make(variant:.full,columnWidth:400,state:.init(shape:shape,titleWidth:80,hasSatellites:true))
            check(g.planet == CGRect(x:172,y:8,width:56,height:56),"\(shape) never moves the planet")
            check(g.contentTop == 112,"\(shape) floats over, never pushes transcript")
            switch shape {
            case .activity:check(g.capsule.height == 58 && g.event?.minY == 91,"activity two-line endpoint")
            case .expanded:check(g.capsule.size == CGSize(width:336,height:148) && g.actions.count == 4 && g.satelliteRow?.height == 24,"expanded four cells and one satellite row")
            case .editing:check(g.capsule.height == 36 && g.rename?.height == 36,"single-line 36pt rename endpoint")
            case .compact:check(g.capsule.height == 32,"compact full height")
            }
        }
        let collapse=HeaderIslandGeometry.make(variant:.collapse,columnWidth:400,state:.init(shape:.expanded,hasSatellites:true))
        check(collapse.satelliteRow == nil && collapse.capsule.height == 116,"Collapse has no duplicate header row")
        let seed=HeaderIslandGeometry.make(variant:.newChat,columnWidth:400,state:.init(shape:.expanded,hasMark:true,hasSatellites:true))
        check(seed.planet.width == 88 && seed.capsule.height == 42 && seed.actions.isEmpty && seed.satelliteRow == nil,"New Chat always stays seed 88 / caption 42")
        check(HeaderIslandVariant.band(bleedTop:52) == 44 && HeaderIslandVariant.band(bleedTop:0) == 0,"title band derives from authored bleed")

        var signals=HeaderIslandSignals(error:.stopped,approvals:12,completions:1,question:true,running:true)
        check(signals.mark == .stoppedError,"stopped error outranks all")
        signals.error = .running; check(signals.mark == .runningError,"running error outranks approvals")
        signals.error=nil; check(signals.mark == .approvals(9),"approval count caps at 9")
        signals.approvals=0; check(signals.mark == .question,"question outranks completion")
        signals.question=false; check(signals.mark == .completion,"completion outranks working")
        signals.completions=0; check(signals.mark == .working,"working is last mark")
        signals.running=false; check(signals.mark == nil,"idle has no mark")

        for error in [nil,HeaderIslandSignals.Error.running,.stopped] {
            for approvals in [0,1,12] { for question in [false,true] { for completions in [0,2] { for running in [false,true] {
                let x=HeaderIslandSignals(error:error,approvals:approvals,completions:completions,question:question,running:running)
                let expected:HeaderIslandSignals.Mark? = error != nil ? (error == .stopped ? .stoppedError:.runningError):approvals>0 ? .approvals(min(9,approvals)):question ? .question:completions>0 ? .completion:running ? .working:nil
                check(x.mark == expected,"all compact mark priority combinations")
            } } } }
        }
        for n in 0..<52 {
            let key=ConversationIdentity.assigned(n),draw=OrbIdentity.assigned(n)
            check(key.symbol == ConversationIdentity.symbols[draw.symbol.rawValue] && key.tint == ConversationIdentity.tints[draw.tint.rawValue],"Core and Orb identity key \(n)")
        }

        let holds:[Double]=[1.5,2.4,2,2.2,2.4,2.4,3,4,4,5]
        for (i,kind) in HeaderIslandEvent.Kind.allCases.enumerated() {
            let e=HeaderIslandEvent(kind:kind,text:kind == .finish ? "Finished":"Event",satellite:"last",at:10)
            check(e.hold == holds[i],"\(kind) product hold")
            var state=HeaderIslandState(); state.show(e,now:10)
            state.tick(now:10+holds[i]-0.001); check(state.activity != nil,"\(kind) remains for full hold")
            state.tick(now:10+holds[i]); check(state.activity == nil,"\(kind) expires exactly at hold")
        }
        func event(_ kind:HeaderIslandEvent.Kind,_ time:Double,_ text:String="event") -> HeaderIslandEvent { .init(kind:kind,text:text,at:time) }
        var queue=HeaderIslandState(); queue.show(event(.approval,0),now:0)
        queue.show(event(.changes,1),now:1); queue.show(event(.spawn,2),now:2)
        check(queue.activity?.kind == .approval && queue.waiting?.kind == .spawn,"urgent event retains only latest informational event")
        queue.tick(now:4); check(queue.activity?.kind == .spawn && queue.waiting == nil,"fresh waiting event follows urgent hold")
        var stale=HeaderIslandState(); stale.show(event(.error,0),now:0); stale.show(event(.changes,0.5),now:0.5)
        stale.focus(true,now:1); stale.tick(now:5); stale.focus(false,now:8); stale.tick(now:8.8)
        check(stale.activity == nil && stale.waiting == nil,"waiting event older than six seconds is discarded after keyboard hold")
        var clear=HeaderIslandState(); clear.show(event(.approval,0),now:0); clear.show(event(.changes,1),now:1); clear.show(event(.error,2),now:2)
        check(clear.activity?.kind == .error && clear.waiting == nil,"new urgent event clears old informational queue")
        var merge=HeaderIslandState(); merge.show(event(.changes,0,"first"),now:0)
        let revision=merge.lobeRevision; merge.show(event(.changes,0.2,"merged"),now:0.2)
        check(merge.lobeRevision == revision && merge.activity?.text == "merged" && merge.activity?.at == 0,"same kind within 250ms updates text without another lobe")
        merge.tick(now:2.41); check(merge.activity != nil,"merged event renews hold")
        merge.tick(now:2.6); check(merge.activity == nil,"merged event eventually expires")
        let routes:[HeaderIslandEvent.Kind:HeaderIslandRoute]=[.changes:.panel(.changes),.context:.panel(.context),.compacted:.panel(.context),.spawn:.panel(.subAgents),.finish:.satellite("last"),.done:.transcript,.error:.transcript,.approval:.transcript,.question:.transcript,.working:.transcript]
        for (kind,route) in routes { check(HeaderIslandEvent(kind:kind,text:"",satellite:"last",at:0).route == route,"\(kind) click route") }
        var a=HeaderIslandSignals(),b=a; b.running=true
        check(HeaderIslandEvent.between(a,b,contextArmed:true,now:0)?.kind == .working,"working edge")
        a=b; b.running=false; b.stops=1
        check(HeaderIslandEvent.between(a,b,contextArmed:true,now:0) == nil,"user stop is not Done")
        b.stops=0; check(HeaderIslandEvent.between(a,b,contextArmed:true,now:0)?.kind == .done,"successful turn completion")
        a.context=0.79; b=a; b.context=0.8
        check(HeaderIslandEvent.between(a,b,contextArmed:true,now:0)?.kind == .context,"80% crossing event")
        check(HeaderIslandEvent.between(a,b,contextArmed:false,now:0) == nil,"context crossing obeys hysteresis arm")
        b.compactions=1; b.error = .stopped; b.approvals=1
        check(HeaderIslandEvent.between(a,b,contextArmed:true,now:0)?.kind == .error,"event priority resolves simultaneous changes")
        a=HeaderIslandSignals(); a.satellites=[.init(id:"a",face:"a"),.init(id:"b",face:"b")]
        b=a; b.satellites[0].done=true; b.satellites[0].finishedOrder=7; b.satellites[1].done=true; b.satellites[1].finishedOrder=3
        check(HeaderIslandEvent.between(a,b,contextArmed:true,now:0)?.satellite == "a","latest completion uses finishing order rather than array order")
        var hysteresis=HeaderIslandState(); a.context=0.79; b=a; b.context=0.81; hysteresis.update(a,b,now:0)
        check(!hysteresis.contextArmed,"context warning disarms")
        a=b; b.context=0.74; hysteresis.update(a,b,now:1); check(hysteresis.contextArmed,"below75% rearms context warning")

        var interaction=HeaderIslandState(); interaction.hover(true,now:0); interaction.tick(now:0.279)
        check(!interaction.expanded,"hover waits 280ms")
        interaction.tick(now:0.280); check(interaction.expanded && !interaction.pinned,"hover opens unpinned")
        interaction.focus(true,now:0.3); interaction.hover(false,now:0.4); interaction.tick(now:10)
        check(interaction.expanded,"keyboard title/event focus prevents timeout close")
        interaction.focus(false,now:10); interaction.tick(now:10.299); check(interaction.expanded,"focus departure retains authored close delay")
        interaction.tick(now:10.3); check(!interaction.expanded,"unfocused hover island closes after300ms")
        interaction.togglePin(); interaction.hover(false,now:11); interaction.tick(now:30)
        check(interaction.expanded && interaction.pinned,"pinned island survives hover departure")
        interaction.togglePin(); check(!interaction.expanded && !interaction.pinned,"second title click closes pinned island")
        interaction.togglePin(); interaction.outside(); check(!interaction.expanded,"outside closes")
        interaction.togglePin(); interaction.escape(); check(!interaction.expanded,"Esc closes")
        interaction.beginRename("Original"); interaction.editRename("Changed"); interaction.cancelRename()
        check(!interaction.editing && interaction.renameText == "Original","rename Esc preserves original")
        interaction.beginRename("Original"); interaction.editRename("  \n ")
        check(interaction.commitRename() == nil && !interaction.editing,"empty rename preserves original")
        interaction.beginRename("Original"); interaction.editRename("  新名字  ")
        check(interaction.commitRename() == "新名字" && interaction.commitRename() == nil,"rename trims and commits only once")
        interaction.beginRename("Original"); interaction.show(event(.error,50),now:50)
        check(interaction.activity == nil,"editing suppresses activity events")
        interaction.escape(); interaction.togglePin(); interaction.show(event(.changes,60),now:60)
        check(interaction.activity == nil,"expanded island suppresses transient events")

        var retirement=HeaderIslandState()
        retirement.updateSatelliteRetirement(was:false,retired:true,now:2)
        retirement.tick(now:3.999); check(retirement.satellitesHoldingUntil == 4,"satellites remain for the complete two-second hold")
        retirement.tick(now:4); check(retirement.satellitesHoldingUntil == nil,"satellite hold expires after two seconds")
        retirement.updateSatelliteRetirement(was:false,retired:true,now:5)
        retirement.updateSatelliteRetirement(was:true,retired:false,now:6)
        check(retirement.satellitesHoldingUntil == nil,"a new turn cancels satellite retirement")

        let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
        let custom=HeaderIslandConfiguration.conversation(store.conversation("A")!,variant:.full,columnWidth:400,identitySymbol:"mars",identityTint:"ocean")
        check(custom.identity.symbol == .mars && custom.identity.tint == .ocean,"Customize symbol and tint override the assigned pair independently")
        let fallback=HeaderIslandConfiguration.conversation(store.conversation("A")!,variant:.full,columnWidth:400,identitySymbol:"unknown",identityTint:"unknown")
        check(fallback.identity == .assigned(store.conversation("A")!.identityIndex),"invalid persisted identity names preserve assigned defaults")
        let persisted=Conversation(id:"persisted",title:"Persisted"); persisted.identitySymbol="mars"; persisted.identityTint="ocean"
        check(HeaderIslandConfiguration.conversation(persisted,variant:.full,columnWidth:400).identity == custom.identity,"header reads persisted identity without explicit overrides")
        let root=HeaderIsland(); var clock:Double=100; root.now={ clock }
        var config=HeaderIslandConfiguration.conversation(store.conversation("A")!,variant:.full,columnWidth:400)
        config.ambient=false; root.configure(config)
        let bridge=HeaderIslandInspectorBridge(conversation:store.conversation("A")!,store:store,actions:NormieActions())
        root.panelContent={ bridge.content(for:$0) }
        check(root.accessibilityRole() == .group && root.titleButton.accessibilityRole() == .button && root.planetButton.accessibilityRole() == .button,"root/title/planet AX roles")
        check(root.titleButton.accessibilityLabel() == config.title && root.planetButton.accessibilityLabel()?.contains("Customize") == true,"title and planet have independent semantics")
        check(root.renameField.superview == nil && !root.renameField.acceptsFirstResponder && !root.renameField.isAccessibilityElement() && root.renameField.hitTest(.zero) == nil,"idle rename is absent from hit/key/AX")
        let overlap=CGPoint(x:root.geometry.planet.midX,y:root.geometry.capsule.minY+1)
        check(root.hitTest(overlap) === root.planetButton,"overlap click belongs to planet")
        check(root.hitTest(CGPoint(x:0,y:0)) == nil,"empty header area passes clicks through")
        var renamed:[String]=[],customized=0,routed:[HeaderIslandRoute]=[]
        root.actions.rename={ renamed.append($0) }; root.actions.customize={ customized+=1 }; root.actions.route={ routed.append($0) }
        root.planetButton.performClick(nil); check(customized == 1,"planet callback")
        let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        root.titleButton.keyDown(with:key); check(root.state.expanded && root.state.pinned,"native Return key activates title pin")
        root.titleButton.keyDown(with:key); check(!root.state.expanded,"native Return key closes title")
        check(root.titleButton.becomeFirstResponder() && root.state.focused,"native title first responder enters focus hold")
        _ = root.titleButton.resignFirstResponder(); check(!root.state.focused,"native first responder departure releases hold")
        root.receive(.init(kind:.finish,text:"Finished",satellite:"latest",at:clock),at:clock)
        check(!root.eventButton.participates,"invisible incoming completion cannot receive a click")
        clock+=0.6;root.sampleMotion(at:clock)
        root.eventButton.performClick(nil)
        check(routed.last == .satellite("latest") && root.state.activity == nil,"native event action routes latest completion and closes")
        root.openPanel(.changes)
        check(routed.last == .panel(.changes) && root.state.expanded && root.state.pinned,"native panel action routes and pins without opening an offscreen window")
        root.escape()
        let hooked=HeaderIsland();hooked.now={clock}; var hookInput=config
        hookInput.signals.satellites=(0..<24).map { .init(id:"agent-\($0)",face:"\($0)",done:$0>=12,finishedOrder:$0>=12 ? $0-12:nil) }
        hooked.configure(hookInput); hooked.setFrameOrigin(CGPoint(x:37,y:21))
        var openings:[(CGRect,String?)]=[],fallbackRoutes:[HeaderIslandRoute]=[]
        hooked.actions.subAgents={ openings.append(($0,$1)) }; hooked.actions.route={ fallbackRoutes.append($0) }
        let anchor=hooked.frame; hooked.openPanel(.subAgents)
        check(openings.count == 1 && openings[0].0 == anchor && openings[0].1 == nil,"sub-agents hook receives island frame in superview coordinates")
        check(!hooked.state.expanded && !hooked.verificationHasPopover && fallbackRoutes.isEmpty,"hook bypasses local popover and fallback route")
        hooked.receive(.init(kind:.spawn,text:"Spawned",at:clock),at:clock)
        check(!hooked.eventButton.participates,"invisible incoming spawn cannot receive a click")
        clock+=0.6;hooked.sampleMotion(at:clock);hooked.eventButton.performClick(nil)
        check(openings.count == 2 && openings.last?.1 == nil && hooked.state.activity == nil,"spawn event goes to host sheet and closes activity")
        hooked.togglePin(); let hidden=hooked.verificationFirstHidden
        hooked.verificationOverflowButton.performClick(nil)
        check(hidden != nil && openings.last?.1 == hidden && !hooked.state.expanded,"satellite overflow opens host sheet selecting first omitted agent")
        let running=[OrbSatellite(id:"r0",face:""),.init(id:"r1",face:"")],done=[OrbSatellite(id:"d0",face:"",done:true),.init(id:"d1",face:"",done:true)]
        check(HeaderIslandSatellitePlan.firstHidden(shown:["r0"],running:running,done:done) == "r1","overflow prioritizes omitted running agents")
        check(HeaderIslandSatellitePlan.firstHidden(shown:["r0","r1"],running:running,done:done) == "d1","overflow then chooses newest omitted finished agent")
        hooked.actions.subAgents=nil; hooked.openPanel(.subAgents)
        check(fallbackRoutes.last == .panel(.subAgents) && hooked.state.expanded,"unset host hook preserves existing sub-agent panel behavior")
        hookInput.active=false; hooked.configure(hookInput); let opened=openings.count
        hooked.actions.subAgents={ openings.append(($0,$1)) }; hooked.openPanel(.subAgents)
        check(openings.count == opened,"inactive island cannot invoke a stale sheet action"); hooked.dispose()
        let lease=HeaderIsland(); lease.configure(config); var staleCustomize=0; lease.actions.customize={ staleCustomize+=1 }
        let staleAX=lease.planetButton.accessibilityCustomActions()!.first!,staleMenu=lease.planetButton.menu!.items.compactMap { $0 as? IslandMenuItem }.first { $0.title == "Customize…" }!
        lease.beginRename(); let focusLease=lease.renameField.focusGeneration
        let ime=MarkedIslandEditor(); lease.renameField.stringValue="Composition"
        check(!lease.control(lease.renameField,textView:ime,doCommandBy:#selector(NSResponder.insertNewline(_:))) && lease.state.editing,"IME Return does not commit marked text")
        lease.cancelRename()
        check(!lease.renameField.focusSession(generation:focusLease) && !lease.renameField.canBecomeKeyView,"cancelled rename rejects queued focus and key view entry")
        check(!lease.renameField.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilityValue:")),"idle rename AX rejects value writes")
        let original=lease.renameField.stringValue; lease.renameField.setAccessibilityValue("late AX write")
        check(lease.renameField.stringValue == original,"idle stale AX cannot change rename draft")
        check(staleAX.handler?() == false,"old AX action cannot cross a rename session")
        staleMenu.invoke?(); check(staleCustomize == 0,"old context menu cannot cross a rename session")
        check(lease.planetButton.accessibilityCustomActions()!.first!.handler?() == true && lease.state.editing && staleCustomize == 0,"fresh AX forwards current native action once")
        lease.cancelRename(); let hiddenAX=lease.titleButton.accessibilityCustomActions()!.first!
        lease.isHidden=true; lease.planetButton.performClick(nil)
        check(hiddenAX.handler?() == false && staleCustomize == 0,"hidden header rejects retained AX and native button actions")
        lease.isHidden=false
        check(hiddenAX.handler?() == false && lease.titleButton.accessibilityCustomActions()!.first!.handler?() == true,"revealing a retained header installs fresh actions without reviving old AX leases")
        lease.dispose()

        let layerIDs=root.orb.verificationLayers.flatMap { allLayers($0) }.filter { $0 is CATextLayer }.map(ObjectIdentifier.init)
        root.togglePin()
        let rowIDs=root.orb.verificationLayers.flatMap { allLayers($0) }.filter { $0 is CATextLayer }.map(ObjectIdentifier.init)
        check(Set(layerIDs) == Set(rowIDs),"orbit and row retain exact same satellite text layer objects")
        check(root.orb.verificationSatellites.count == config.signals.satellites.count,"one satellite pair per ID after expansion")
        let rowPositions=root.orb.verificationSatellites.values.map { $0.front.y }
        check(Set(rowPositions).count<=1,"all expanded satellite faces use one row")
        root.beginRename(); check(root.state.editing && root.renameField.participates && root.renameField.frame.height == 36,"native rename field participates only while editing")
        root.renameField.stringValue="  Renamed 行星  "; root.outsideClick()
        check(renamed == ["Renamed 行星"] && root.configuration?.title == "Renamed 行星","outside commits rename through callback")
        check(!root.renameField.participates && root.renameField.superview == nil,"commit immediately withdraws editor semantics")
        root.beginRename(); root.renameField.stringValue="Snapshot draft 编辑中"
        let editingState=root.state
        let draftImage=root.snapshot(variant:.brief,scale:1)
        try write(draftImage,directory.appendingPathComponent("rename-edit-brief@1x.png"))
        let draftGeometry=HeaderIslandGeometry.make(variant:.brief,columnWidth:400,state:.init(shape:.editing,titleWidth:130,scale:1))
        let input=draftImage.cropping(to:draftGeometry.rename!.insetBy(dx:12,dy:7))!
        let data=input.dataProvider!.data!
        let bytes=Array(UnsafeBufferPointer(start:CFDataGetBytePtr(data)!,count:CFDataGetLength(data)))
        var inputColors=Set<UInt32>()
        for y in 0..<input.height { for x in 0..<input.width { let i=y*input.bytesPerRow+x*4; inputColors.insert(UInt32(bytes[i])<<16 | UInt32(bytes[i+1])<<8 | UInt32(bytes[i+2])) } }
        check(inputColors.count>8,"other-variant snapshot retains the in-progress rename text")
        check(root.state == editingState && root.renameField.stringValue == "Snapshot draft 编辑中","preparing another endpoint does not change the live rename draft")
        root.renameField.stringValue="Cancelled"; root.cancelRename()
        check(renamed.count == 1 && root.configuration?.title == "Renamed 行星","native cancel has no rename callback")
        root.beginRename(); root.renameField.stringValue=" "
        let editor=NSTextView()
        check(root.control(root.renameField,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:))) && renamed.count == 1,"Return confirms blank without destroying name")
        let status=root.makePanelContent(.status),changes=root.makePanelContent(.changes)
        check(status === bridge.inspector && changes === bridge.inspector,"Status and Changes reuse the actual Normie inspector")
        for panel in HeaderIslandPanel.allCases {
            let content=root.makePanelContent(panel); content.view.layoutSubtreeIfNeeded()
            check(plainControls(content.view).isEmpty,"\(panel) popover has no plain text controls")
        }
        check(root.makePanelContent(.context).view.accessibilityRole() == .group,"local context panel AX group")
        config.active=false; root.configure(config)
        let old=customized; root.planetButton.performClick(nil)
        check(customized == old && root.hitTest(overlap) == nil && root.isAccessibilityHidden(),"inactive header cannot hit/act/expose AX")
        config.active=true; config.reduceMotion=true; root.configure(config); root.beginRename(); root.renameField.stringValue="Reduced"; root.commitRename()
        check(root.orb.verificationLayers.flatMap(allLayers).allSatisfy { $0.animation(forKey:"headerRename") == nil },"Reduce Motion has no planet tilt")
        check(controlsWithoutDraw(root).isEmpty,"all instantiated header text controls override draw")
        check(plainControls(root).isEmpty,"header has zero ordinary NSTextField/NSButton/NSPopUpButton")
        check(allViews(root).allSatisfy { if let b=$0 as? NSButton { return !b.isBordered }; if let f=$0 as? NSTextField { return !f.isBordered && !f.isBezeled }; return true },"all header fields/buttons have no system bezel")

        let orbit=root.orb
        orbit.verificationPause(true,at:1000)
        let paused=orbit.verificationPhases(at:1001)
        let later=orbit.verificationPhases(at:1011)
        check(zip(paused,later).allSatisfy { abs($0.0-$1.0)<0.00001 && abs($0.1-$1.1)<0.00001 },"satellite pause retains each front/back phase")
        orbit.verificationPause(false,at:1011)
        let resumed=orbit.verificationPhases(at:1011)
        check(zip(paused,resumed).allSatisfy { abs($0.0-$1.0)<0.00001 && abs($0.1-$1.1)<0.00001 },"satellite resume starts at held phase")
        for (r,d,w,expected) in [(2,2,200,0),(20,10,200,24),(2,2,50,4)] {
            let p=HeaderIslandSatellitePlan.make(running:r,done:d,width:CGFloat(w))
            check(p.hidden == expected && p.running+p.done+p.hidden == r+d,"satellite overflow plan \(r)/\(d) at \(w)")
        }
        let packed=HeaderIslandSatellitePlan.make(running:3,done:12,width:280),packedPlaces=HeaderIslandSatellitePlan.make(running:3,done:12,width:280).places(width:280)
        check(packedPlaces.running == [12,36,60] && packedPlaces.more == 264,"overflow row packs running, separator, done then ellipsis")
        check(packedPlaces.done == (0..<packed.done).map { 84+CGFloat(packed.done-1-$0)*24+12 },"overflow finished order is product right-to-left")
        let finished=HeaderIslandSatellitePlan.make(running:0,done:20,width:200).places(width:200)
        check(finished.more == 188 && finished.done == [20,44,68,92,116,140,164],"finished-only overflow retains product left-to-right ordering at right edge")
        let divided=HeaderIslandSatellitePlan.make(running:2,done:2,width:110).places(width:110)
        check(divided.divider == 55 && divided.done == [98,74],"non-overflow separator centers in the gap between groups")
        for scale:CGFloat in [1,2] {
            for (name,variant,_,_,_,_) in variants {
                config.variant=variant; config.scale=scale; config.active=true; root.configure(config); root.escape()
                clock+=1;root.sampleMotion(at:clock)
                let before=root.geometry,model=root.state
                let image=root.snapshot(variant:variant,scale:scale)
                let savedExposure=root.motionExposure.enabled
                root.motionExposure.enabled=false;let withoutExposure=root.snapshot(scale:scale)
                root.motionExposure.enabled=true;let withExposure=root.snapshot(scale:scale)
                root.motionExposure.enabled=savedExposure
                check(withoutExposure.dataProvider?.data == withExposure.dataProvider?.data,"M10 \(name) resting native pixels unchanged at \(scale)x")
                try write(image,directory.appendingPathComponent("\(name)@\(Int(scale))x.png"))
                check(image.width == Int(config.columnWidth*scale),"\(name) capture pixel width at \(scale)x")
                check(root.geometry == before && root.state == model,"\(name) snapshot preserves live geometry/state")
                if variant == .full {
                    let r=root.geometry.planet.insetBy(dx:12,dy:12)
                    let crop=image.cropping(to:CGRect(x:r.minX*scale,y:r.minY*scale,width:r.width*scale,height:r.height*scale))!
                    let data=crop.dataProvider!.data!
                    let bytes=Array(UnsafeBufferPointer(start:CFDataGetBytePtr(data)!,count:CFDataGetLength(data)))
                    var colors=Set<UInt32>()
                    for y in 0..<crop.height { for x in 0..<crop.width {
                        let i=y*crop.bytesPerRow+x*4
                        colors.insert(UInt32(bytes[i])<<16 | UInt32(bytes[i+1])<<8 | UInt32(bytes[i+2]))
                    } }
                    check(colors.count>8,"actual liquid/glyph ornaments survive the offscreen render, rather than an empty glass proxy")
                }
            }
            config.variant = .full; root.configure(config); root.togglePin()
            clock+=1;root.sampleMotion(at:clock)
            try write(root.snapshot(scale:scale),directory.appendingPathComponent("expanded@\(Int(scale))x.png"))
            root.beginRename();clock+=1;root.sampleMotion(at:clock)
            try write(root.snapshot(scale:scale),directory.appendingPathComponent("rename@\(Int(scale))x.png")); root.cancelRename()
            for c in store.conversations {
                let v=HeaderIsland(); var input=HeaderIslandConfiguration.conversation(c,variant:.full,columnWidth:400,ambient:false,scale:scale)
                input.reduceMotion=true; v.configure(input)
                try write(v.snapshot(scale:scale),directory.appendingPathComponent("state-\(c.id)@\(Int(scale))x.png")); v.dispose()
            }
        }
        // f078 promotion uses the same live component and leaves the title edit/scene driver with the host.
        config.variant = .newChat; root.configure(config)
        check(root.orb.verificationSatellites.isEmpty && root.geometry.planet.width == 88,"seed has no satellite/context decoration")
        config.variant = .full; root.configure(config)
        check(root.geometry.planet.width == 56 && root.geometry.capsule.height == 32,"first-send promotion produces normal full endpoint")
        for scale:CGFloat in [1,2] {
            config.scale=scale; config.variant = .newChat; config.reduceMotion=false; root.configure(config)
            check(root.geometry.capsule.size == CGSize(width:192,height:42) && root.geometry.titleFont == 17,"product seed caption192x42/17pt")
            check(root.orb.verificationContent == .seed && root.orb.verificationLiquidLevel == 0.12,"seed uses fixed liquid rather than placeholder identity")
            let colors=root.orb.verificationLiquidColors
            check(colors.count == 2 && abs((colors[0].components?.last ?? 0)-0.32)<0.0001 && abs((colors[1].components?.last ?? 0)-0.5)<0.0001,"seed jade alpha0.32/0.5")
            check(root.orb.verificationSeedLayer.contents != nil && !root.orb.verificationSeedLayer.isHidden,"medium sparkle has cached backing pixels")
            config.variant = .full; config.title="First message title"; root.configure(config)
            let promotionBegan=clock
            let plan=root.beginPromotion(seedCenterY:280)!
            check(plan.seed.planet.midY == 280 && plan.seed.capsule.size == CGSize(width:192,height:42),"seed endpoint aligns to supplied center")
            check(plan.initial.planet.width == 88 && abs(plan.initial.planet.midY-280)<=0.5/scale,"product88/56 launch scale aligns planet center")
            check(!plan.sample(elapsed:0.119).revealTitle && plan.sample(elapsed:0.12).revealTitle,"title handoff exactly120ms")
            check(HeaderIslandPromotion.riseResponse == 0.38 && HeaderIslandPromotion.riseDamping == 0.86 && HeaderIslandPromotion.nameResponse == 0.24 && HeaderIslandPromotion.nameDamping == 0.72,"promotion springs match product")
            check(plan.motionSample(elapsed:0).geometry == plan.sample(elapsed:0).geometry && plan.motionSample(elapsed:1.2).geometry == plan.full,"M10 continuous promotion preserves exact pixel endpoints")
            let tailSteps=(490...510).map { k in MotionStep.edge(plan.motionSample(elapsed:Double(k)/1000).geometry.title,plan.motionSample(elapsed:Double(k-1)/1000).geometry.title) }
            check(tailSteps.max()!<0.1,"M10 promotion tail has no integer-pixel quantization jump (1ms substeps)")
            check(HeaderIslandPromotion.titleInDelay == 0.05 && HeaderIslandPromotion.titleInDuration == 0.10 && HeaderIslandPromotion.titleOutDuration == 0.05,"name fade contracts match product")
            check(root.verificationName == "New Chat","promotion holds seed name before explicit reveal")
            let before=root.orb.metrics
            for frame in 0...144 {
                let time=Double(frame)/120,pose=plan.sample(elapsed:time)
                clock=promotionBegan+time
                if pose.revealTitle { root.revealPromotionTitle() }
                root.frame.size.height=max(plan.full.height,pose.geometry.height)
                root.placeMotion(pose.geometry,fontScale:pose.fontScale)
                check([pose.geometry.planet,pose.geometry.capsule,pose.geometry.title].allSatisfy { r in [r.minX,r.minY,r.width,r.height].allSatisfy { abs($0*scale-($0*scale).rounded())<0.00001 } },"promotion sampled pixel grid\(frame)/\(scale)")
                if [0,14,24,72,144].contains(frame) { try write(root.snapshot(scale:scale),directory.appendingPathComponent("promotion-\(frame)@\(Int(scale))x.png")) }
            }
            check(root.verificationName == config.title,"true title replaces seed exactly once")
            check(root.orb.metrics.glyphPaths == before.glyphPaths && root.orb.metrics.liquidPaths == before.liquidPaths,"per-frame promotion never rebuilds orb drawing")
            check(plan.sample(elapsed:2).geometry == plan.full,"promotion lands on exact full geometry")
            root.endPromotion(); check(root.geometry == plan.full,"endPromotion restores resting native endpoint")
            let rest=root.snapshot(scale:scale)
            root.motionExposure.enabled.toggle();let toggled=root.snapshot(scale:scale);root.motionExposure.enabled.toggle()
            check(rest.dataProvider?.data == toggled.dataProvider?.data,"M10 promoted resting native pixels unchanged at \(scale)x")
            config.reduceMotion=true; root.configure(config)
            let reduced=root.beginPromotion(seedCenterY:280)!
            check(reduced.sample(elapsed:0).geometry == reduced.full && reduced.sample(elapsed:0).revealTitle,"Reduce Motion skips rise and name delay")
            root.revealPromotionTitle(); root.endPromotion()
        }
        let dots=IslandWorkingDots(); dots.configure(paused:false,reduced:false,scale:2,now:100)
        check(dots.layer.animationKeys()?.isEmpty != false && dots.layer.sublayers?.allSatisfy { $0.animationKeys()?.isEmpty != false } == true,"M11.47 working dots are static while ambient is enabled")
        OrbMotion.setAnimationsPaused(true,on:dots.layer,at:101)
        let dotPhase=dots.layer.convertTime(105,from:nil)
        OrbMotion.setAnimationsPaused(false,on:dots.layer,at:105)
        check(abs(dotPhase-dots.layer.convertTime(105,from:nil))<0.000001,"working dots retain phase across ambient pause")
        dots.configure(paused:true,reduced:true,scale:2,now:106)
        check(dots.layer.animationKeys()?.isEmpty != false,"Reduce Motion removes working dot loop")
        try PlainControlSourceAuditVerification.run(component:"Island",evidenceDirectory:directory) { check($0,$1) }
        let displayState=root.state,displayGeometry=root.geometry
        for options in [OrbDisplayEnvironment.Options(increaseContrast:true),.init(reduceTransparency:true),.init(increaseContrast:true,reduceTransparency:true)] {
            OrbDisplayEnvironment.shared.setOverride(options)
            check(root.verificationGlassTints.allSatisfy { $0 == nil } && root.verificationShadow == 0,"display options defer glass fallback to system and remove decorative shadows")
            check(root.state == displayState && root.geometry == displayGeometry,"Workspace display options preserve header interaction and geometry")
            for scale:CGFloat in [1,2] {
                let image=root.snapshot(scale:scale)
                check(image.width == Int(root.bounds.width*scale),"accessible header snapshot backing grid")
                try write(image,directory.appendingPathComponent("a11y-\(options.increaseContrast ? "contrast":"transparency")-\(options.reduceTransparency)@\(Int(scale))x.png"))
            }
        }
        OrbDisplayEnvironment.shared.setOverride(.init())
        check(root.verificationGlassTints.allSatisfy { $0 != nil },"display option reset restores authored glass tints")
        check(root.orb.verificationLayers.allSatisfy { $0.superlayer != nil },"offscreen capture restores every original decoration plane")
        root.setPresentationActive(false)
        let beforeFrozen=customized; root.planetButton.performClick(nil)
        check(customized == beforeFrozen && root.isAccessibilityHidden(),"snapshot flight withdraws hit/AX/action participation")
        root.configure(config); root.planetButton.performClick(nil)
        check(customized == beforeFrozen,"semantic configure cannot reactivate a frozen flight")
        root.setPresentationActive(true); root.planetButton.performClick(nil)
        check(customized == beforeFrozen+1,"restoring native endpoint reactivates actions")
        clock+=1; root.dispose()
        root.planetButton.performClick(nil); check(customized == beforeFrozen+1,"disposed stale planet cannot invoke callbacks")
        check(!root.control(root.renameField,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:))),"idle stale rename delegate does not consume keys")
        notes.append("Offscreen captures use native cacheDisplay for all text; render-server glass is represented by an explicit proxy. Live snapshot uses the window's own bitmapImageRepForCachingDisplay. No real-window swap/VoiceOver claim.")
        notes.append("PNG: full/brief/split-focused/split/collapse/new-chat, expanded/rename and A–F, at 1x and 2x. No window or app instance launched.")
        let report="Island verification: \(checks) checks, \(failures.count) findings\n"+(notes+failures.map { "FAIL: "+$0 }).joined(separator:"\n")+"\n"
        try report.write(to:directory.appendingPathComponent("verification.txt"),atomically:true,encoding:.utf8)
        print(report); if !failures.isEmpty { exit(1) }
    }
    static func allViews(_ v:NSView) -> [NSView] { [v]+v.subviews.flatMap(allViews) }
    static func allLayers(_ v:CALayer) -> [CALayer] { [v]+(v.sublayers ?? []).flatMap(allLayers) }
    static func plainControls(_ v:NSView) -> [String] { allViews(v).filter { type(of:$0) == NSTextField.self || type(of:$0) == NSButton.self || type(of:$0) == NSPopUpButton.self }.map { String(describing:type(of:$0)) } }
    static func controlsWithoutDraw(_ v:NSView) -> [String] {
        allViews(v).compactMap { child in
            let base:AnyClass
            if child is NSTextField { base=NSTextField.self }
            else if child is NSButton { base=NSButton.self }
            else if child is IslandButton { base=NSControl.self }
            else { return nil }
            let selector=#selector(NSView.draw(_:))
            guard let cls=object_getClass(child),let own=class_getInstanceMethod(cls,selector),let original=class_getInstanceMethod(base,selector) else { return "missing draw" }
            return method_getImplementation(own) == method_getImplementation(original) ? String(describing:type(of:child)):nil
        }
    }
    static func write(_ image:CGImage,_ url:URL) throws { try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:url) }
}
@MainActor private final class MarkedIslandEditor:NSTextView { override func hasMarkedText()->Bool { true } }
@MainActor private final class IslandDragVerificationGesture:IslandOrbDragGesture {
    var moves=0,ups=0,cancels=0
    func dragged(with event:NSEvent) {moves+=1}
    func released(with event:NSEvent) {ups+=1}
    func cancel() {cancels+=1}
}
@MainActor private final class IslandDragVerificationProvider:IslandPlane,IslandOrbDragProvider {
    let gesture=IslandDragVerificationGesture()
    func beginOrbDrag(from island:HeaderIsland,event:NSEvent)->(any IslandOrbDragGesture)? {gesture}
}
#endif
