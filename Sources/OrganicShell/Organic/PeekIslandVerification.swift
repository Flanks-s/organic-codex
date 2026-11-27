#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore
/// A CLI owns its final receipt and exit; record any AppKit termination request.
@MainActor final class PeekProbeApplication:NSApplication {
    override func terminate(_ sender:Any?) {
        FileHandle.standardError.write(Data(("PEEK_TERMINATE_REQUEST\n"+Thread.callStackSymbols.joined(separator:"\n")+"\n").utf8))
    }
}
extension M10DockVerification {
    static func peekIsland(output:URL) async throws {
        if CommandLine.arguments.contains("--peek-perf") {try await peekOpenCost(output:output);return}
        atexit {FileHandle.standardError.write(Data(("PEEK_EXIT_STACK\n"+Thread.callStackSymbols.joined(separator:"\n")+"\n").utf8))}
        let selected=ProcessInfo.processInfo.environment["M1125_CATEGORY"]
        #if PEEK_ISLAND_IMPLEMENTATION
        if selected=="browser" {
            for scale:CGFloat in [1,2] {try await peekBrowserCombination(scale:scale,output:output) {check($0,"[browser] "+$1+" @\(Int(scale))x")}}
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"));return
        }
        #endif
        func observe(_ category:String,_ value:Bool,_ label:String) {
            if selected == nil || selected==category {check(value,"["+category+"] "+label)}
        }
        for scale:CGFloat in [1,2] {
            let f=HeaderFixture(scale:scale);f.scene.verificationIdlePrewarm=true
            defer {f.dispose();f.scene.disposeTranscriptPresentation()}
            guard let id=f.scene.order.dropFirst(f.scene.layout.columns.count).first,
                  let c=f.scene.store.conversation(id),let item=f.scene.dock.items[id] else {
                check(false,"[fixture] overflow conversation is required");continue
            }
            let h=f.scene.peekNode.header,tag=" @\(Int(scale))x"
            h.now={ [weak f] in f?.time ?? 0 }
            c.running=false;c.loading=false;c.sending=false;c.approvals=[];c.userInput=nil;c.question=nil
            c.satellites=[.init(id:"peek-moon",face:"S")];c.notices=ConversationNoticeFeed()
            f.scene.dock.refreshOrbs()
            func step(_ seconds:Double) {
                for _ in 0..<max(1,Int((seconds*120).rounded())) {f.tick(1/120);h.sampleMotion(at:f.time)}
                f.scene.clock.invalidate()
            }
            func point(_ rect:CGRect)->CGPoint {
                f.root.convert(CGPoint(x:rect.midX,y:rect.midY),from:h)
            }
            func mouse(_ type:NSEvent.EventType,_ p:CGPoint)->NSEvent {
                NSEvent.mouseEvent(with:type,location:f.root.convert(p,to:nil),modifierFlags:[],timestamp:f.time,
                    windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            }
            func hit(_ p:CGPoint)->NSView? {f.root.hitTest(f.root.convert(p,to:nil))}
            func capture(_ name:String) {
                Offscreen.write(h.snapshot(scale:scale),output.appendingPathComponent("brief-\(Int(scale))x-"+name+".png"))
                Offscreen.write(NativeViewBitmap.capture(f.root,scale:scale),output.appendingPathComponent("scene-\(Int(scale))x-"+name+".png"))
            }
            func open() async throws {
                f.scene.setPeeking(id);f.scene.clock.invalidate()
                try await Task.sleep(for:.milliseconds(160));step(0.2)
            }
            f.scene.setPeeking(id);f.scene.clock.invalidate()
            let planet=point(h.draggableOrbRect)
            observe("active",!h.planetButton.acceptsFirstResponder && hit(planet) !== h.planetButton,"unrevealed endpoint has no input"+tag)
            try await Task.sleep(for:.milliseconds(160));step(0.2)
            observe("active",h.configuration?.active==true && h.planetButton.acceptsFirstResponder,"ordinary active header"+tag)
            observe("route",hit(point(h.draggableOrbRect)) === h.planetButton,"root reaches native planet"+tag)
            observe("moons",h.configuration?.signals.satellites.map(\.id)==["peek-moon"],"moons on ordinary top endpoint"+tag)
            observe("moons",item.decoration.verificationConfiguration?.satellites.isEmpty==true && f.scene.peekRow.isEmpty,"no bottom decoration or row moons"+tag)
            capture("rest")
            let title=point(h.geometry.capsule)
            f.scene.pointer(title)
            let entered=NSEvent.enterExitEvent(with:.mouseEntered,location:f.root.convert(title,to:nil),modifierFlags:[],
                timestamp:f.time,windowNumber:0,context:nil,eventNumber:0,trackingNumber:0,userData:nil)!
            h.mouseEntered(with:entered);f.time+=0.3;h.advance(to:f.time);step(0.6)
            observe("hold",h.state.expanded && !h.state.pinned,"ordinary hover deadline expands"+tag)
            capture("hover")
            h.titleButton.mouseDown(with:mouse(.leftMouseDown,title));step(0.5)
            observe("hold",h.state.pinned,"native title pins"+tag)
            capture("pinned")
            let detail=point(CGRect(x:h.geometry.capsule.midX,y:h.geometry.capsule.maxY-10,width:1,height:1))
            observe("shield",f.scene.peekNode.coversPointer(detail),"expanded controls occlude the lower column"+tag)
            observe("shield",hit(detail)?.isDescendant(of:f.scene.peekNode.view)==true,"expanded input never reaches underlying native"+tag)
            var heldRetarget:(String,CGRect)?
            if let other=f.scene.order.dropFirst(f.scene.layout.columns.count).first(where:{$0 != id}),let r=f.scene.dock.frame(of:other) {
                heldRetarget=(other,r);f.scene.pointer(CGPoint(x:r.midX,y:r.midY));try await Task.sleep(for:.milliseconds(300))
                observe("hold",f.scene.shownPeek==id,"pinned Peek blocks another orb dwell"+tag)
            } else {Self.check(false,"[fixture] second overflow orb is required"+tag)}
            f.scene.pointer(nil);try await Task.sleep(for:.milliseconds(460))
            observe("hold",f.scene.peekOpen,"pinned Peek survives pointer exit"+tag)
            var routes=0
            let original=h.actions.route
            h.actions.route={ route in if case .panel(.context)=route {routes+=1};original?(route) }
            h.openPanel(.context)
            observe("actions",routes==1 && h.makePanelContent(.context).view != nil,"ordinary context panel route"+tag)
            observe("actions",h.actions.rename != nil && h.actions.compact != nil && h.actions.openSatellite != nil && h.actions.customize != nil,"ordinary action bindings"+tag)
            var satelliteRoutes=0
            h.actions.route={route in if case .satellite("peek-moon")=route {satelliteRoutes+=1}}
            h.actions.openSatellite={sub,point in if sub=="peek-moon",point==nil {satelliteRoutes+=1}}
            var satellite:IslandButton?
            if let row=h.geometry.satelliteRow {
                for x in stride(from:row.minX,through:row.maxX,by:2) {
                    if let button=hit(point(CGRect(x:x,y:row.midY,width:1,height:1))) as? IslandButton,
                       button.text.hasPrefix("Sub-agent S") {satellite=button;break}
                }
            }
            observe("actions",satellite?.beginPointerGesture != nil,"top moon retains the ordinary opener"+tag)
            if let satellite {
                let p=f.root.convert(CGPoint(x:satellite.bounds.midX,y:satellite.bounds.midY),from:satellite)
                satellite.mouseDown(with:mouse(.leftMouseDown,p));satellite.mouseUp(with:mouse(.leftMouseUp,p))
            }
            observe("actions",satelliteRoutes==1,"native satellite click routes the same identity without opening a test window"+tag)
            h.beginRename();let editingHeld=h.state.editing && f.scene.peekOpen;h.renameField.stringValue="Peek renamed";h.commitRename()
            observe("actions",editingHeld && c.title=="Peek renamed","ordinary rename holds Peek and writes the shared conversation"+tag)
            if let (_,r)=heldRetarget {f.scene.pointer(CGPoint(x:r.midX,y:r.midY))}
            h.escape();step(0.6);capture("unpinned")
            try await Task.sleep(for:.milliseconds(300))
            let resumedDwell=heldRetarget.map{f.scene.shownPeek==$0.0} ?? false
            f.scene.pointer(nil)
            try await Task.sleep(for:.milliseconds(760));step(0.8)
            observe("hold",resumedDwell && !f.scene.peekOpen && f.scene.shownPeek==nil,"unpin resumes orb dwell and compact Peek still closes"+tag)
            try await open()
            var serial=10000
            func emit(_ method:String,_ params:JSONValue) {
                serial+=1;c.notices.consume(.init(id:serial,time:f.time,method:method,params:params),in:c)
                f.scene.store.changed(c);f.scene.clock.invalidate()
            }
            c.running=true
            emit("turn/started",["turn":["id":"peek-turn"]]);step(0.7)
            f.scene.pointer(point(h.geometry.capsule));f.scene.pointer(nil);try await Task.sleep(for:.milliseconds(760))
            observe("automatic",f.scene.peekOpen,"Pulse bloom holds Peek without legacy activity"+tag)
            observe("automatic",h.configuration?.notices==c.notices.snapshot(in:c),"ordinary notice snapshot stays current"+tag)
            capture("bloom")
            #if PEEK_ISLAND_IMPLEMENTATION
            if selected == nil || selected=="browser" {
                try await peekBrowserCombination(scale:scale,output:output) {value,label in observe("browser",value,label+tag)}
            }
            observe("automatic",h.hostPresentation.holdsPeek && f.scene.peekInteractionHolds && h.state.activity==nil,"Pulse activity exported through scene holding and typed host summary"+tag)
            if selected == nil || selected=="hold" {
                var pulsePinned=false
                let expansion=h.actions.expansion
                h.actions.expansion={open,pin in pulsePinned=pin;expansion?(open,pin)}
                h.hover(true);step(0.4);capture("pulse-hover")
                let live=h.hostPresentation.interactiveRegions.dropFirst().first
                let pulseSurface=live.flatMap {hit(point(CGRect(x:$0.midX,y:$0.minY+8,width:1,height:1))) as? IslandButton}
                observe("hold",pulseSurface != nil && (live?.height ?? 0)>h.geometry.capsule.height,"Pulse hover reaches its actual expanded surface"+tag)
                pulseSurface?.performClick(nil);h.hover(false);step(0.3);capture("pulse-pinned")
                observe("hold",pulsePinned && h.hostPresentation.holdsPeek,"native Pulse surface pins after pointer exit"+tag)
                pulseSurface?.performClick(nil);step(0.3);capture("pulse-unpinned")
                observe("hold",!pulsePinned,"native Pulse surface unpins"+tag)
            }
            var publications=[HeaderIslandHostPresentation]()
            let publish=h.actions.presentation
            h.actions.presentation={value in publications.append(value);publish?(value)}
            #endif
            let approval=Approval(id:"peek-approval",title:"Mock approval",command:"mock",note:"",acceptLabel:"Allow",toolItemID:"mock",method:"item/commandExecution/requestApproval",
                request:["method":"item/commandExecution/requestApproval","params":["command":"mock","availableDecisions":["accept","decline"]]])
            c.approvals=[approval]
            emit("core/approvalRequested",["approvalId":"peek-approval","request":approval.request]);step(0.7)
            observe("automatic",f.scene.peekOpen && h.configuration?.notices?.pending.count==1,"Pulse action remains in Peek"+tag)
            capture("action")
            var approvals=0
            let actions=NormieActions();actions.approvalValue={conversation,request,_ in
                if conversation === c,request.id==approval.id {approvals+=1}
            };f.scene.islandActions=actions
            var accept:IslandButton?
            for y in stride(from:h.geometry.planet.minY,through:h.frame.height,by:4) {
                for x in stride(from:CGFloat(0),through:h.frame.width,by:4) {
                    if let button=hit(point(CGRect(x:x,y:y,width:1,height:1))) as? IslandButton,button.text=="Allow" {accept=button;break}
                }
                if accept != nil {break}
            }
            if let accept {let p=f.root.convert(CGPoint(x:accept.bounds.midX,y:accept.bounds.midY),from:accept)
                accept.mouseDown(with:mouse(.leftMouseDown,p));accept.mouseUp(with:mouse(.leftMouseUp,p))}
            observe("actions",accept != nil && approvals==1,"native approval uses the ordinary mock action path"+tag)
            #if PEEK_ISLAND_IMPLEMENTATION
            let summary=h.hostPresentation
            observe("shield",summary.interactiveRegions.allSatisfy {r in
                let p=point(r);return f.scene.peekNode.coversPointer(p)
            },"all painted ordinary hit regions covered"+tag)
            observe("automatic",publications.contains(where:{$0.holdsPeek}),"Pulse pose publishes automatic holding"+tag)
            h.escape();h.setKeyboardFocus(true);let focusHeld=h.hostPresentation.holdsPeek && f.scene.peekInteractionHolds
            h.beginRename();let editExported=h.state.editing && h.hostPresentation.holdsPeek && f.scene.peekInteractionHolds;h.cancelRename();h.escape();h.setKeyboardFocus(false)
            observe("automatic",focusHeld && editExported && !h.hostPresentation.holdsPeek,"event-free Pulse focus and legacy edit hold; Escape releases original state"+tag)
            #else
            h.escape()
            #endif
            c.approvals=[];c.running=false;emit("core/approvalResponded",["approvalId":"peek-approval"])
            h.escape();step(0.6)
            let glass=item.glass,orb=point(h.draggableOrbRect)
            f.scene.pressedButtons={1}
            h.planetButton.mouseDown(with:mouse(.leftMouseDown,orb))
            observe("carrier",f.scene.pressedNode==id && f.scene.orbInput.isPressed,"one shared scene press owns top orb"+tag)
            let moved=CGPoint(x:orb.x+24,y:orb.y)
            h.planetButton.mouseDragged(with:mouse(.leftMouseDragged,moved));f.tick()
            observe("carrier",f.scene.isDragging && item.glass === glass,"same Dock glass is carried"+tag)
            let escape=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:f.time,
                windowNumber:0,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
            NSApp.sendEvent(escape);f.settle();f.scene.pressedButtons={0}
            observe("carrier",!f.scene.isDragging && !f.scene.dock.isHolding,"Esc returns existing carrier"+tag)
            try await open()
            var customized=0;h.actions.customize={customized+=1}
            let top=point(h.draggableOrbRect)
            h.planetButton.mouseDown(with:mouse(.leftMouseDown,top));h.planetButton.mouseUp(with:mouse(.leftMouseUp,top));f.settle()
            observe("click",f.scene.current==id && !f.scene.peekOpen && customized==0,"short click enters conversation with no substitute menu"+tag)
            #if PEEK_ISLAND_IMPLEMENTATION
            if let column=f.scene.nodes[id] {
                let attachment=BrowserColumnAttachment(column:column);column.browserAttachment=attachment;attachment.cover()
                observe("browser",column.island?.hostPresentation.acceptsInput==false,"browser pause withdraws input"+tag)
                let facts=c.notices.snapshot(in:c)
                if let originalHeader=column.island {
                    originalHeader.isHidden=true;originalHeader.retireHiddenInteraction()
                    observe("browser",!originalHeader.hostPresentation.acceptsInput,"Peek retirement does not release browser pause"+tag)
                }
                attachment.restore();column.browserAttachment=nil;f.scene.restIslands()
                f.scene.orbMenuPeekColumn=id;f.scene.setPeeking(id);f.scene.clock.invalidate();step(0.3)
                observe("browser",f.scene.peekNode.header.configuration?.id==id && f.scene.peekOpen,"column menu Peek admits ordinary header after lease return"+tag)
                observe("browser",c.notices.snapshot(in:c)==facts,"presentation operations preserve notice facts"+tag)
                f.scene.dismissPeek()
            } else {observe("browser",false,"landed column exists"+tag)}
            #endif
            // An old asynchronous retirement must not clear a freshly reopened endpoint.
            f.scene.dismissPeek();try await Task.sleep(for:.milliseconds(10))
            if let other=f.scene.order.dropFirst(f.scene.layout.columns.count).first {
                f.scene.setPeeking(other);f.scene.clock.invalidate();try await Task.sleep(for:.milliseconds(160));step(0.2)
                observe("lifecycle",h.configuration?.id==other && h.configuration?.active==true,"retired generation cannot clear next identity"+tag)
                f.scene.setPeeking(nil);f.scene.clock.invalidate()
                try await Task.sleep(for:.milliseconds(90))
                Offscreen.write(NativeViewBitmap.capture(f.root,scale:scale),output.appendingPathComponent("scene-\(Int(scale))x-closing.png"))
                try await Task.sleep(for:.milliseconds(300));step(0.5)
                observe("lifecycle",f.scene.peekNode.headerFrame==nil && !h.pulseClockRunning && !h.motionIsRunning,"close detaches and stops presentation work"+tag)
            } else {observe("lifecycle",false,"overflow fixture remains after landing"+tag)}
        }
        if selected == nil || selected=="carrier" {
            for scale:CGFloat in [1,2] {
                let f=HeaderFixture(scale:scale);f.scene.verificationIdlePrewarm=true;defer {f.dispose();f.scene.disposeTranscriptPresentation()}
                guard let id=f.scene.order.last else {continue}
                f.scene.pressedButtons={1} // Synthetic NSEvents do not change the hardware button mask.
                f.scene.setPeeking(id);f.scene.peekNode.setHeaderVisible(true,duration:0)
                let h=f.scene.peekNode.header,r=f.root.convert(h.draggableOrbRect,from:h),start=CGPoint(x:r.midX,y:r.midY)
                func event(_ type:NSEvent.EventType,_ p:CGPoint)->NSEvent {
                    NSEvent.mouseEvent(with:type,location:f.root.convert(p,to:nil),modifierFlags:[],timestamp:f.time,
                        windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
                }
                h.planetButton.mouseDown(with:event(.leftMouseDown,start))
                f.scene.orbInput.dragged(event(.leftMouseDragged,CGPoint(x:start.x,y:start.y-45)));f.settle()
                let can=CGPoint(x:f.scene.dock.restingTargets.max(by:{$0.rect.maxX<$1.rect.maxX})!.rect.midX-52,
                    y:f.scene.layout.me.midY-68)
                f.scene.orbInput.dragged(event(.leftMouseDragged,can));f.settle()
                observe("carrier",f.scene.orbTrash.output?.pose.phase == .armed,"top orb reaches ordinary trash @\(Int(scale))x")
                f.scene.orbInput.released(event(.leftMouseUp,can));f.scene.pressedButtons={0};f.settle()
                observe("carrier",f.scene.orbTrash.successfulRemovals==1 && !f.scene.members.contains(where:{$0.id==id}),"top orb releases through ordinary Remove @\(Int(scale))x")
            }
        }
        if selected == nil || selected=="click" {
            for inside in [false,true] {
                let f=HeaderFixture(scale:1);f.scene.verificationIdlePrewarm=true;defer {f.dispose();f.scene.disposeTranscriptPresentation()}
                f.scene.enterFocused(f.scene.current,reason:"peek-fixture");f.settle()
                let id=inside ? f.scene.current:f.scene.order.last!
                f.scene.orbMenuPeekColumn=id;f.scene.setPeeking(id);f.scene.peekNode.setHeaderVisible(true,duration:0)
                let h=f.scene.peekNode.header,r=f.root.convert(h.draggableOrbRect,from:h),p=CGPoint(x:r.midX,y:r.midY)
                func event(_ type:NSEvent.EventType)->NSEvent {NSEvent.mouseEvent(with:type,location:f.root.convert(p,to:nil),
                    modifierFlags:[],timestamp:f.time,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
                h.planetButton.mouseDown(with:event(.leftMouseDown));h.planetButton.mouseUp(with:event(.leftMouseUp));f.settle()
                observe("click",!f.scene.peekOpen && f.scene.current==id && f.scene.scheme.split.contains(id),"Focused Peek enters selected conversation inside=\(inside)")
            }
        }
        check(NSApp.windows.allSatisfy{!$0.isVisible},"[fixture] no visible windows")
        try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
    }
    #if PEEK_ISLAND_IMPLEMENTATION
    static func peekBrowserCombination(scale:CGFloat,output:URL,check:(Bool,String)->Void) async throws {
        guard let screen=NSScreen.main else {Self.check(false,"[fixture] screen exists for hidden browser host");return}
        var options=Options();options.mock=true;options.live=false;options.ambient=false
        let suite="OrganicShell.M1125.BrowserCombination",defaults=UserDefaults(suiteName:"OrganicShell.M1125.BrowserCombination")!
        defaults.removePersistentDomain(forName:suite)
        let app=AppController(options,windowDefaults:defaults,presentsWindows:false)
        let replay=MockReplay(store:app.store);replay.start(live:false);app.mock=replay
        let w=OrganicWindow(app:app,frame:CGRect(x:100,y:100,width:1280,height:820),screen:screen,
            members:["A","B","C","D","E","F"],normie:false,o:options)
        app.windows=[w]
        var time=VerificationClock.renderOrigin,serial=30000
        w.scene.now={time};w.scene.manualSettle=true;w.scene.verificationIdlePrewarm=true;w.scene.backingChanged(scale);w.scene.clock.invalidate()
        w.scene.setAmbientRunning(true) // Unshown fixture; never claims real key status.
        defer {FileHandle.standardError.write(Data("BROWSER_DEFER_CLOSE\n".utf8));w.window.close();app.windows=[];defaults.removePersistentDomain(forName:suite);FileHandle.standardError.write(Data("BROWSER_CLOSED\n".utf8))}
        _=replay.setBrowserMockEnabled(true);w.reconcileBrowserOrb()
        guard let owner=w.browserOwner,let source=replay.browserReplay else {Self.check(false,"[fixture] explicit mock owner exists");return}
        owner.reduceOverride=true;owner.visibilityOverride=true;owner.visibilityChanged()
        for _ in 0..<2000 where !owner.ready {try await Task.sleep(for:.milliseconds(5))}
        guard owner.ready,let column=w.scene.nodes[w.scene.current] else {Self.check(false,"[fixture] ready browser and current column exist");return}
        check(owner.ready,"actual browser host becomes ready")
        w.scene.settle();w.scene.clock.invalidate()
        let c=column.conversation,id=c.id,h=w.scene.peekNode.header
        func event(_ type:NSEvent.EventType,_ at:CGPoint)->NSEvent {NSEvent.mouseEvent(with:type,location:w.root.convert(at,to:nil),
            modifierFlags:[],timestamp:time,windowNumber:w.window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
        func key(_ code:UInt16)->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:time,
            windowNumber:w.window.windowNumber,context:nil,characters:code==53 ? "\u{1b}":"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!}
        func step() {for _ in 0..<90 {time+=1/60;source.advance(by:1/60);w.scene.clock.onFrame?(time);h.sampleMotion(at:time)};w.scene.clock.invalidate()}
        func hit(_ p:CGPoint)->NSView? {w.root.hitTest(w.root.convert(p,to:w.root.superview))}
        func capture(_ name:String) {
            let r=w.root.bounds,rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(r.width*scale),pixelsHigh:Int(r.height*scale),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!;rep.size=r.size;memset(rep.bitmapData!,0,rep.bytesPerRow*rep.pixelsHigh)
            w.root.cacheDisplay(in:r,to:rep);Offscreen.write(rep.cgImage!,output.appendingPathComponent("browser-\(Int(scale))x-"+name+".png"))
        }
        func open() async throws {
            w.scene.setAmbientRunning(true) // Re-admit the hidden fixture after genuine window activity/occlusion callbacks.
            guard let original=column.island else {Self.check(false,"[fixture] original endpoint exists");return}
            let r=w.root.convert(original.draggableOrbRect,from:original)
            original.planetButton.rightMouseDown(with:event(.rightMouseDown,CGPoint(x:r.midX,y:r.midY)))
            try await Task.sleep(for:.milliseconds(70))
            for _ in 0..<3 {w.scene.orbMenu.keyDown(with:key(125))};w.scene.orbMenu.keyDown(with:key(36))
            try await Task.sleep(for:.milliseconds(240));w.scene.setAmbientRunning(true);step()
            check(w.scene.peekOpen && h.configuration?.id==id,"native column menu opens Peek")
        }
        func emit(_ method:String,_ params:JSONValue) {serial+=1;c.notices.consume(.init(id:serial,time:time,method:method,params:params),in:c);w.scene.store.changed(c);step()}
        func controls(_ v:NSView)->[IslandButton] {((v as? IslandButton).map{[$0]} ?? [])+v.subviews.flatMap{controls($0)}}
        func axPaths()->Set<ObjectIdentifier> {
            var seen=Set<ObjectIdentifier>()
            func visit(_ v:Any) {guard let n=v as? NSObject,let ax=v as? any NSAccessibilityProtocol,seen.insert(ObjectIdentifier(n)).inserted else {return};for child in ax.accessibilityChildren() ?? [] {visit(child)}}
            visit(w.window);return seen
        }
        func hiddenAX(_ v:NSView,_ tree:Set<ObjectIdentifier>)->Bool {
            var n:Any?=v
            while let ax=n as? any NSAccessibilityProtocol {if ax.isAccessibilityHidden() {return true};n=ax.accessibilityParent()}
            return !v.isAccessibilityElement() || !tree.contains(ObjectIdentifier(v))
        }
        func record(_ stage:String) throws {
            let r=w.root.convert(h.draggableOrbRect,from:h),target=hit(CGPoint(x:r.midX,y:r.midY))
            let row:[String:Any]=["stage":stage,"rootParentFlipped":w.root.superview?.isFlipped ?? false,"windowBaseHit":w.root.hitTest(w.root.convert(CGPoint(x:r.midX,y:r.midY),to:nil)).map{String(describing:type(of:$0))} ?? "none","peek":w.scene.peekState,"pinned":h.state.pinned,"focused":h.state.focused,"activity":h.state.activity?.text ?? "none","deadline":h.state.nextDeadline ?? -1,"holds":h.hostPresentation.holdsPeek,"accepts":h.hostPresentation.acceptsInput,"hidden":h.isHiddenOrHasHiddenAncestor,"carried":h.orbIsCarried,"headerFrame":NSStringFromRect(h.frame),"parentFrame":NSStringFromRect(h.superview?.frame ?? .zero),"parentAdmits":(h.superview as? PeekNode.HeaderPlane)?.admitsControls ?? false,"parentOpacity":h.superview?.alphaValue ?? -1,"hitIsPeek":target === w.scene.peekNode.view,"ambient":w.scene.ambientRunning,"regions":h.hostPresentation.interactiveRegions.map{NSStringFromRect($0)},"pulse":h.pulseProbe ?? [:],"planet":NSStringFromRect(r),"hit":target.map{String(describing:type(of:$0))} ?? "none","hitFrame":target.map{NSStringFromRect(w.root.convert($0.bounds,from:$0))} ?? "none"]
            try JSONSerialization.data(withJSONObject:row,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("browser-\(Int(scale))x-"+stage+".json"))
        }
        for mode in ["ordinary","bloom","action"] {
            c.running=false;c.approvals=[];c.notices=ConversationNoticeFeed();c.satellites=[.init(id:"covered-moon",face:"S")];w.scene.store.changed(c)
            try await open();var pulsePinned=false
            let expansion=h.actions.expansion;h.actions.expansion={open,pin in pulsePinned=pin;expansion?(open,pin)}
            if mode=="ordinary" {check(h.titleButton.accessibilityPerformPress(),"ordinary title accepts pin")}
            else {
                c.running=true;emit("turn/started",["turn":["id":.string("covered-turn-"+mode)]])
                if mode=="action" {
                    let request:JSONValue=["method":"item/commandExecution/requestApproval","params":["command":"mock","availableDecisions":["accept","decline"]]]
                    c.approvals=[Approval(id:"covered-approval",title:"Mock approval",command:"mock",note:"",acceptLabel:"Allow",toolItemID:"mock",method:"item/commandExecution/requestApproval",request:request)]
                    emit("core/approvalRequested",["approvalId":"covered-approval","request":request])
                }
                check(h.pulseProbe?["mode"] as? String == mode && h.pulseClockRunning,"real notice presents live Pulse "+mode)
                h.hover(true);step()
                let r=h.hostPresentation.interactiveRegions.dropFirst().first ?? .zero,p=w.root.convert(CGPoint(x:r.midX,y:r.minY+8),from:h)
                let surface=hit(p) as? IslandButton
                check(surface != nil,"actual Pulse surface is reachable "+mode);surface?.performClick(nil);h.hover(false)
            }
            step();try record(mode+"-pin");check(h.hostPresentation.holdsPeek && (mode=="ordinary" ? h.state.pinned:pulsePinned),"real control pins "+mode)
            capture(mode+"-pinned")
            let buttons=controls(h).filter{!$0.isHiddenOrHasHiddenAncestor && $0.isEnabled},facts=c.notices.snapshot(in:c)
            let before=axPaths()
            check(before.contains(ObjectIdentifier(h.planetButton)) && (mode != "ordinary" || before.contains(ObjectIdentifier(h.titleButton))),"live AX fixture reaches original controls "+mode)
            check(mode != "action" || buttons.contains{$0.text=="Allow"},"real pending action exposes its native button")
            owner.toggleFull();step();try await Task.sleep(for:.milliseconds(30));step()
            check(owner.full && column.browserAttachment?.covers==true,"browser really covers original column")
            check(!w.scene.peekOpen && w.scene.shownPeek==nil && w.scene.peeking==nil && w.scene.peekStage.isEmpty && w.scene.peekTimer==nil,"coverage dismisses complete Peek lifecycle")
            let tree=axPaths()
            for button in buttons {check(hiddenAX(button,tree),"retired control leaves AX: "+button.text)}
            check(hiddenAX(w.scene.peekNode.view,tree) && (w.scene.peekNode.view.accessibilityChildren() ?? []).isEmpty,"fog and lyrics have no Peek AX children")
            check(h.configuration?.active==false && !h.hostPresentation.holdsPeek && h.state.nextDeadline==nil && !h.state.pinned && !h.state.focused && !h.pulseClockRunning && !h.motionIsRunning && h.pulseProbe==nil,"retirement clears interaction and live presentation work")
            check(c.notices.snapshot(in:c)==facts,"dismiss preserves conversation notice facts");capture(mode+"-closed")
            _=w.key(key(53));step()
            check(!owner.full && column.browserAttachment==nil && w.browserOwner === owner && !owner.disposed,"real Esc returns browser to Dock")
            try await open()
            try record(mode+"-new")
            check(!h.state.pinned && !h.hostPresentation.holdsPeek && !h.state.focused && h.state.activity==nil && (h.pulseProbe?["event"] as? String ?? "none")=="none","reopened endpoint has no retired pin event or focus")
            let r=w.root.convert(h.draggableOrbRect,from:h),p=CGPoint(x:r.midX,y:r.midY)
            check(hit(p) === h.planetButton,"reopened root reaches exact planet");capture(mode+"-new")
            guard let glass=w.scene.dock.items[id]?.glass else {Self.check(false,"[fixture] original Dock carrier exists");return}
            w.scene.pressedButtons={1};h.planetButton.mouseDown(with:event(.leftMouseDown,p))
            NSApp.sendEvent(event(.leftMouseDragged,CGPoint(x:p.x+24,y:p.y-45)));step()
            check(h.orbDragProvider()==nil && w.scene.orbInput.isPressed,"detached source yields further events to the retained press owner")
            check(w.scene.orbInput.isPressed && w.scene.isDragging && w.scene.dock.items[id]?.glass === glass && !glass.isHidden && !owner.hidesGlass(glass),"reopened drag carries same visible glass");capture(mode+"-drag")
            if mode=="action" {
                let last=w.scene.layout.orbs.max(by:{$0.maxX<$1.maxX})?.midX ?? w.scene.sizeForOrb.width-46
                let can=OrbTrashGeometry(bounds:w.scene.dockView.bounds,lastSlotX:last,dockBaseline:w.scene.layout.me.midY).target
                NSApp.sendEvent(event(.leftMouseDragged,CGPoint(x:can.x-52,y:can.y)));step()
                let legacy=w.scene.dock.restingTargets.max(by:{$0.rect.maxX<$1.rect.maxX})!.rect.midX-52
                try JSONSerialization.data(withJSONObject:["target":NSStringFromPoint(can),"oldPointerX":legacy,"phase":w.scene.orbTrash.output?.pose.phase.rawValue ?? "none","free":w.scene.drag?.freeCarry==true],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("browser-\(Int(scale))x-trash.json"))
                check(w.scene.orbTrash.output?.pose.phase == .armed,"returned browser drag reaches ordinary trash")
                NSApp.sendEvent(event(.leftMouseUp,CGPoint(x:can.x-52,y:can.y)));w.scene.settle()
                check(w.scene.orbTrash.successfulRemovals==1 && !w.scene.members.contains(where:{$0.id==id}),"returned browser drag removes exactly once")
            } else {NSApp.sendEvent(key(53));w.scene.settle()}
            w.scene.pressedButtons={0};w.scene.clock.invalidate()
            check(!w.scene.orbInput.isPressed && w.scene.pressedNode==nil && !w.scene.isDragging && !w.scene.dock.isHolding,"release clears shared press owner and monitor lifecycle")
        }
        check(!w.window.isVisible && !app.store.usesLiveCore,"combo stays mock and offscreen")
        FileHandle.standardError.write(Data("BROWSER_BODY_DONE\n".utf8));w.scene.dismissPeek();owner.retire();await owner.drain()
    }
    #endif
    /// Retain sample order: first is the actual first observation, never the minimum.
    static func peekOpenCost(output:URL) async throws {
        var records=[[String:Any]]()
        for scale:CGFloat in [1,2] {
            for kind in ["cold","idle","closed","reverse","other"] {
                var samples=[Double](),closeSamples=[Double](),readyCPU=[Double](),parts=[[String:Double]]()
                for _ in 0..<12 {
                    M10ColumnWorkTrace.reset()
                    let construction=CACurrentMediaTime(),f=HeaderFixture(scale:scale);f.scene.verificationIdlePrewarm=true
                    let fixtureMS=(CACurrentMediaTime()-construction)*1000
                    let headerConstruction=M10ColumnWorkTrace.events.filter{$0.name=="peek.header.construct"}.reduce(0){$0+($1.end-$1.start)*1000}
                    guard let id=f.scene.order.dropFirst(f.scene.layout.columns.count).first else {throw CocoaError(.fileReadCorruptFile)}
                    defer {f.dispose();f.scene.disposeTranscriptPresentation()}
                    f.scene.peekNode.header.now={ [weak f] in f?.time ?? 0 }
                    if kind=="idle" {
                        let idle=M11IdlePreparation(interval:0.001,valid:{true})
                        try await f.scene.warmPeekImagesInIdle(idle);idle.finish()
                    }
                    if kind=="closed" || kind=="reverse" || kind=="other" {
                        f.scene.setPeeking(id);f.scene.clock.invalidate()
                        if kind != "reverse" {try await Task.sleep(for:.milliseconds(160));f.tick(0.3)}
                        if kind != "other" {
                            f.scene.setPeeking(nil);f.scene.clock.invalidate()
                            if kind=="closed" {try await Task.sleep(for:.milliseconds(340));f.tick(0.5)}
                        }
                    }
                    let target=kind=="other" ? f.scene.order.dropFirst(f.scene.layout.columns.count).first(where:{$0 != id}) ?? id:id
                    M10ColumnWorkTrace.reset()
                    let began=CACurrentMediaTime();f.scene.setPeeking(target);f.scene.clock.invalidate()
                    let synchronousEnd=CACurrentMediaTime()
                    samples.append((synchronousEnd-began)*1000)
                    try await Task.sleep(for:.milliseconds(210));f.tick(0.3);f.scene.clock.invalidate()
                    let deferred=M10ColumnWorkTrace.events.filter{$0.parent<0 && $0.name.hasPrefix("peek.") && $0.start>=synchronousEnd}
                        .reduce(0){$0+max(0,$1.end-$1.start)*1000}
                    readyCPU.append(samples.last!+deferred)
                    var row=["fixtureConstruction":fixtureMS,"peek.header.construct":headerConstruction]
                    for name in ["peek.header","peek.header.configure","peek.header.wire","peek.header.pulse","peek.header.reveal","peek.images","peek.lyrics"] {
                        row[name]=M10ColumnWorkTrace.events.filter{$0.name==name}.reduce(0){$0+($1.end-$1.start)*1000}
                        row[name+".calls"]=Double(M10ColumnWorkTrace.events.filter{$0.name==name}.count)
                    }
                    M10ColumnWorkTrace.reset()
                    parts.append(row)
                    let closing=CACurrentMediaTime();f.scene.setPeeking(nil);f.scene.clock.invalidate()
                    let closeEnd=CACurrentMediaTime()
                    try await Task.sleep(for:.milliseconds(340));f.tick(0.5);f.scene.clock.invalidate()
                    let retired=M10ColumnWorkTrace.events.filter{$0.parent<0 && $0.name.hasPrefix("peek.") && $0.start>=closeEnd}
                        .reduce(0){$0+max(0,$1.end-$1.start)*1000}
                    closeSamples.append((closeEnd-closing)*1000+retired)
                    f.scene.dismissPeek();f.scene.clock.invalidate()
                    try await Task.sleep(for:.milliseconds(5))
                }
                let sorted=samples.sorted()
                records.append(["scale":scale,"kind":kind,"samplesMs":samples,"partsMs":parts,"first":samples[0],
                    "mean":samples.reduce(0,+)/Double(samples.count),"p50":sorted[sorted.count/2],"p90":sorted[Int(Double(sorted.count)*0.9)],"max":sorted.last!,
                    "readyCPUSamplesMs":readyCPU,"readyCPUFirst":readyCPU[0],"readyCPUMean":readyCPU.reduce(0,+)/Double(readyCPU.count),
                    "readyCPUP50":readyCPU.sorted()[readyCPU.count/2],"readyCPUP90":readyCPU.sorted()[Int(Double(readyCPU.count)*0.9)],"readyCPUMax":readyCPU.max()!,
                    "closeSamplesMs":closeSamples,"closeFirst":closeSamples[0],"closeMean":closeSamples.reduce(0,+)/Double(closeSamples.count),
                    "closeP50":closeSamples.sorted()[closeSamples.count/2],"closeP90":closeSamples.sorted()[Int(Double(closeSamples.count)*0.9)],"closeMax":closeSamples.max()!])
            }
        }
        try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("peek-cost.json"))
        check(!records.isEmpty,"Peek open cost records all configurations")
    }
}
#endif
