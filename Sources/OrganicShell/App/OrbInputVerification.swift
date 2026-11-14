import AppKit
import QuartzCore

#if !M10_DOCK_SELFTEST && !ORGANIC_SELFTEST && !ORB_SELFTEST && !ISLAND_SELFTEST && !M9_SPLIT_SELFTEST && !M11_MODE_SELFTEST
/// Offscreen product entry tests. No AppController lifecycle, CoreService, CoreClient or network transport is started.
@MainActor enum OrbInputVerification {
    /// Hidden-window counterpart of mouse dispatch: native hitTest/menu(for:), then AppKit responder dispatch.
    /// NSWindow's server path drops mouse events for unordered windows, even when the hit view accepts first mouse.
    final class DispatchWindow: NSWindow {
        var dispatches = 0, orderAttempts = 0, leftDowns = 0
        private weak var leftTarget: NSView?
        private weak var rightTarget: NSView?
        override var isKeyWindow: Bool { true }
        var hasOnscreenSurface: Bool {
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
            return windows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == windowNumber }
        }
        override func sendEvent(_ event: NSEvent) {
            dispatches += 1
            if event.type == .leftMouseDown { leftDowns += 1 }
            let selector: Selector
            switch event.type {
            case .leftMouseDown: selector = #selector(NSResponder.mouseDown(with:))
            case .leftMouseUp: selector = #selector(NSResponder.mouseUp(with:))
            case .leftMouseDragged: selector = #selector(NSResponder.mouseDragged(with:))
            case .rightMouseDown: selector = #selector(NSResponder.rightMouseDown(with:))
            case .rightMouseUp: selector = #selector(NSResponder.rightMouseUp(with:))
            default: super.sendEvent(event); return
            }
            let hit: NSView?
            switch event.type {
            case .leftMouseDragged,.leftMouseUp: hit = leftTarget
            case .rightMouseUp: hit = rightTarget
            default: hit = contentView?.hitTest(event.locationInWindow)
            }
            guard let hit else { return }
            if event.type == .leftMouseDown,event.modifierFlags.contains(.control),hit.menu(for:event) != nil { return }
            if event.type == .leftMouseDown { leftTarget = hit }
            if event.type == .rightMouseDown { rightTarget = hit }
            _ = NSApp.sendAction(selector,to:hit,from:event)
            if event.type == .leftMouseUp { leftTarget = nil }
            if event.type == .rightMouseUp { rightTarget = nil }
        }
        override func orderFront(_ sender: Any?) { orderAttempts += 1 }
        override func makeKeyAndOrderFront(_ sender: Any?) { orderAttempts += 1 }
    }
    final class RecordingTransport: CoreTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [JSONValue] = []
        private var healthReads = 0
        private let reply: @Sendable (JSONValue) async throws -> JSONValue
        init(reply: @escaping @Sendable (JSONValue) async throws -> JSONValue = { _ in [:] }) { self.reply = reply }
        var calls: [JSONValue] { lock.withLock { requests } }
        var healthCalls: Int { lock.withLock { healthReads } }
        func request(_ method: String, path: String, body: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue {
            if method == "GET" && path == "/health" {
                lock.withLock { healthReads += 1 }
                return ["name":"Organic Codex Core","backendConnected":true,"lastEventId":10000]
            }
            precondition(method == "POST" && path == "/rpc", "Only in-memory fixture RPC is permitted")
            lock.withLock { requests.append(body ?? .null) }
            return try await reply(body ?? .null)
        }
        func events(since: Int, threadID: String?) -> AsyncThrowingStream<CoreEvent, Error> { AsyncThrowingStream { $0.finish() } }
    }
    @MainActor final class Fixture {
        let app: AppController, owner: OrganicWindow
        let testScreen: NSScreen
        private let defaultsSuite: String
        private(set) var dispatchWindow: DispatchWindow?
        var dispatchDebug: [String:Any] = [:]
        var scene: AutoScene { owner.scene }
        var time = CACurrentMediaTime()+100
        init(width: CGFloat = 1280) {
            var options = Options(); options.mock = true; options.mockPaused = true; options.live = false; options.ambient = false
            let suite = "orb-input-fixture-"+UUID().uuidString
            defaultsSuite = suite
            app = AppController(options,windowDefaults:UserDefaults(suiteName:suite)!,presentsWindows:false)
            let replay = MockReplay(store:app.store); replay.start(live:false)
            app.runtime = MockConversationRuntime(store:app.store,replay:replay,animatePlayback:false)
            let screen = NSScreen.screens.first { s in
                guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayIsBuiltin(CGDirectDisplayID(n.uint32Value)) != 0
            }!
            testScreen = screen
            owner = OrganicWindow(app:app,frame:CGRect(x:screen.frame.minX+20,y:screen.frame.minY+20,width:width,height:820),screen:screen,members:["A","B","C","D","E","F"],normie:false,o:options)
            app.windows = [owner]
            app.watchArrivals()
            scene.manualSettle = true; scene.verificationPresented = true
            scene.now = { [weak self] in self?.time ?? CACurrentMediaTime() }
            scene.dock.motionTime = { [weak self] in self?.time ?? CACurrentMediaTime() }
            scene.pressedButtons = { 1 }; scene.clock.invalidate(); scene.settle()
        }
        func settle() {
            time += 2; scene.clock.onFrame?(time); scene.settle(); scene.orbFlights.frame(time); scene.clock.invalidate()
        }
        func event(_ type: NSEvent.EventType, at p: CGPoint, flags: NSEvent.ModifierFlags = [], after: Double = 0) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:scene.dockView.convert(p,to:nil),modifierFlags:flags,timestamp:time+after,
                windowNumber:(owner.root.window ?? owner.window).windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseDown ? 1:0)!
        }
        func useAppKitDispatch() -> DispatchWindow {
            if let dispatchWindow { return dispatchWindow }
            let window = DispatchWindow(contentRect:owner.window.frame,styleMask:.borderless,backing:.buffered,defer:false,screen:testScreen)
            let host = NSView(frame:CGRect(origin:.zero,size:scene.size))
            window.isReleasedWhenClosed = false; window.contentView = host
            owner.root.frame = host.bounds; host.addSubview(owner.root)
            owner.root.layoutSubtreeIfNeeded()
            window.makeFirstResponder(owner.root)
            dispatchWindow = window
            return window
        }
        func dispatch(_ event: NSEvent) {
            NSApp.postEvent(event,atStart:true)
            let mask = NSEvent.EventTypeMask(rawValue:1 << event.type.rawValue)
            if let next = NSApp.nextEvent(matching:mask,until:.distantPast,inMode:.default,dequeue:true) { NSApp.sendEvent(next) }
        }
        func key(_ code: UInt16) {
            let window = useAppKitDispatch()
            dispatch(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:time,
                windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!)
        }
        func dispatchedClick(at point: CGPoint, end: CGPoint? = nil, flags: NSEvent.ModifierFlags = [], right: Bool = false, duration: Double = 0.02, upFlags: NSEvent.ModifierFlags? = nil) -> Bool {
            let window = useAppKitDispatch()
            let down = event(right ? .rightMouseDown:.leftMouseDown,at:point,flags:flags)
            let hit = window.contentView?.hitTest(down.locationInWindow)
            // AppKit asks for a Control-click menu before mouseDown. Never enter the old modal menu in a gate.
            if flags.contains(.control), hit?.menu(for:down) != nil { return false }
            let up = event(right ? .rightMouseUp:.leftMouseUp,at:end ?? point,flags:upFlags ?? flags,after:duration)
            window.postEvent(up,atStart:false)
            dispatch(down)
            dispatchDebug = ["downWindowMatches":down.window === window,"pressedAfterDown":scene.orbInput.isPressed,
                "menuAfterDown":scene.orbMenu.state.isOpen,"windowNumber":window.windowNumber,
                "nativeMenuAssigned":(hit as? IslandButton)?.menu != nil,"nativeMenuForEvent":hit?.menu(for:down) != nil]
            let mask: NSEvent.EventTypeMask = right ? .rightMouseUp:.leftMouseUp
            while let next = NSApp.nextEvent(matching:mask,until:.distantPast,inMode:.default,dequeue:true) { dispatch(next) }
            return true
        }
        func point(_ id: String) -> CGPoint { let r = scene.orbPose(id)!; return CGPoint(x:r.midX,y:r.midY) }
        func click(_ id: String, flags: NSEvent.ModifierFlags, header: Bool = false, distance: CGFloat = 0, duration: Double = 0.02, upFlags: NSEvent.ModifierFlags? = nil) {
            _ = useAppKitDispatch()
            let p = point(id), end = CGPoint(x:p.x+distance,y:p.y)
            owner.hover(p)
            _ = dispatchedClick(at:p,end:end,flags:flags,duration:duration,upFlags:upFlags)
        }
        func dispose() {
            scene.orbInput.dispose(); scene.orbMenu.dispose(); scene.orbFlights.cancel(); scene.orbHint.cancel(); scene.orbToast.dismiss()
            scene.dock.headerOrbDragging?.dispose(); scene.disposeTranscriptPresentation(); owner.disposeWorkbenchForClose()
            dispatchWindow?.contentView = nil; dispatchWindow?.close(); dispatchWindow = nil
            owner.transcriptSessions.dispose(); owner.window.delegate = nil; owner.window.close(); app.windows = []
            UserDefaults.standard.removePersistentDomain(forName:defaultsSuite)
        }
    }
    static func run(to path: String) -> Int32 {
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ name: String) { checks += 1; if !value { failures.append(name) } }
        var dispatchRows: [[String:Any]] = []
        verifyAppKitDispatch(check:check,rows:&dispatchRows)
        for source in ["dock","full","brief"] {
            let header = source != "dock"
            for flags: NSEvent.ModifierFlags in [[],.option,.control,[.control,.option],[.option,.command],[.option,.shift],.command,.shift] {
                let f = Fixture(); defer { f.dispose() }
                let id = header ? (source == "full" ? f.scene.current:f.scene.columns.last!.conversation.id) : f.scene.order.last!
                let before = f.scene.current, order = f.scene.order
                var customizations = 0
                if header { f.scene.nodes[id]?.island?.actions.customize = { customizations += 1 } }
                f.click(id,flags:flags,header:header)
                let action = OrbGesturePolicy.action(flags:flags)
                let label = "\(source) \(header ? "HeaderIsland":"RootView") flags=\(flags.rawValue)"
                if action == .menu { check(f.scene.orbMenu.state.isOpen,label+" opens menu"); check(f.scene.current == before,label+" keeps layout") }
                else if action == .swap {
                    check(f.scene.current == id,label+" swaps into full")
                    if !header { check(f.scene.order.last == before,label+" keeps exact Dock source slot") }
                    else { check(f.scene.order == order,label+" exchanges widths without moving columns") }
                    if source == "full" { check(f.scene.orbFlights.flights[id]?.vy == -110,label+" full orb acknowledges with -110 bounce") }
                    check(customizations == 0,label+" does not customize")
                } else if action == .reserved { check(f.scene.current == before && customizations == 0 && f.scene.orbFlights.flights.isEmpty,label+" reserved is silent") }
                else if header { check(customizations == 1,label+" keeps ordinary Customize") }
                else { check(f.scene.current == before && f.scene.columns.contains { $0.conversation.id == id },label+" keeps ordinary land to brief") }
                check(!f.app.o.usesLiveCore && f.app.core == nil && f.app.live == nil && f.app.runtime is MockConversationRuntime,label+" cannot connect to real Core")
                check(f.owner.window.screen === f.testScreen,label+" fixture stays on built-in screen")
            }
        }
        do {
            let f = Fixture(); defer { f.dispose() }
            let id = f.scene.order.last!, r = f.scene.orbPose(id)!, columns = f.scene.columns.map { $0.conversation.id }
            let p = CGPoint(x:r.maxX-1,y:r.midY)
            _ = f.dispatchedClick(at:p,end:CGPoint(x:p.x+7.9,y:p.y))
            check(f.scene.columns.map({$0.conversation.id}) == columns,"ordinary Dock click uses release location after moving outside the orb below 8pt")
        }
        for header in [false,true] {
            for (distance,duration,drag) in [(CGFloat(7.9),0.249,false),(8,0.249,true),(0,0.250,true)] {
                let f = Fixture(); defer { f.dispose() }
                let id = header ? f.scene.columns.last!.conversation.id : f.scene.order.last!
                f.click(id,flags:.option,header:header,distance:distance,duration:duration)
                check(f.scene.switches.contains { ($0["reason"] as? String) == "orb-swap" } != drag,"pickup threshold \(distance)pt \(duration)s header=\(header)")
                check(!f.scene.orbInput.isPressed,"threshold releases input owner")
            }
            let f = Fixture(); defer { f.dispose() }
            let id = header ? f.scene.columns.last!.conversation.id : f.scene.order.last!, before = f.scene.current
            f.click(id,flags:[],header:header,upFlags:.option)
            check(f.scene.current == before,"late Option does not become swap header=\(header)")
        }
        for source in ["dock","full","brief","peek"] {
            for flags: NSEvent.ModifierFlags in [[],.option] {
                let f = Fixture(); defer { f.dispose() }
                let id = source == "full" ? f.scene.current : (source == "brief" ? f.scene.columns.last!.conversation.id:f.scene.order.last!)
                var p = f.point(id)
                if source == "peek" {
                    f.scene.setPeeking(id); f.scene.peekNode.setHeaderVisible(true,duration:0)
                    let r = f.scene.peekNode.view.convert(f.scene.peekNode.header.draggableOrbRect,from:f.scene.peekNode.header)
                    p = CGPoint(x:r.midX,y:r.midY)
                }
                let before = f.scene.current
                _ = f.dispatchedClick(at:p,flags:flags,right:true)
                check(f.scene.orbMenu.state.isOpen && f.scene.current == before,"\(source) right click flags=\(flags.rawValue) opens menu without changing columns")
                NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:f.dispatchWindow)
                check(!f.scene.orbMenu.state.isOpen,"\(source) resign closes right-click menu")
            }
            if source == "dock" || source == "brief" { continue }
            for (distance,duration,drag) in [(CGFloat(7.9),0.249,false),(8,0.249,true),(0,0.250,true)] {
                let f = Fixture(); defer { f.dispose() }
                let id = source == "full" ? f.scene.current:f.scene.order.last!
                if source == "full" { f.click(id,flags:.option,header:true,distance:distance,duration:duration) }
                else {
                    f.scene.setPeeking(id); f.scene.peekNode.setHeaderVisible(true,duration:0)
                    let r = f.scene.peekNode.view.convert(f.scene.peekNode.header.draggableOrbRect,from:f.scene.peekNode.header)
                    let p = CGPoint(x:r.midX,y:r.midY)
                    _ = f.dispatchedClick(at:p,end:CGPoint(x:p.x+distance,y:p.y),flags:.option,duration:duration)
                }
                let acknowledged = source == "full" ? f.scene.orbFlights.flights[id]?.vy == -110 : f.scene.current == id
                check(acknowledged != drag,"\(source) pickup threshold \(distance)pt \(duration)s")
                check(!f.scene.orbInput.isPressed,"\(source) threshold releases input owner")
            }
        }
        for flags: NSEvent.ModifierFlags in [[],.option,.control,[.control,.option],[.option,.command],[.option,.shift]] {
            let f = Fixture(); defer { f.dispose() }
            let id = f.scene.order.last!, before = f.scene.current
            f.scene.setPeeking(id); f.scene.peekNode.setHeaderVisible(true,duration:0)
            let rect = f.scene.peekNode.view.convert(f.scene.peekNode.header.draggableOrbRect,from:f.scene.peekNode.header)
            let p = CGPoint(x:rect.midX,y:rect.midY)
            _ = f.dispatchedClick(at:p,flags:flags)
            let action = OrbGesturePolicy.action(flags:flags)
            check(action == .swap ? f.scene.current == id : f.scene.current == before,"Peek top flags=\(flags.rawValue) acts on peeked conversation")
            if action == .menu { check(f.scene.orbMenu.state.isOpen,"Peek top opens same menu") }
            if action == .ordinary { check(f.scene.shownPeek == id,"ordinary Peek click keeps M11.25 behavior") }
        }
        do {
            let f = Fixture(); defer { f.dispose() }
            let id = f.scene.order.last!
            f.scene.setPeeking(id); f.scene.peekNode.setHeaderVisible(true,duration:0)
            let r = f.scene.peekNode.view.convert(f.scene.peekNode.header.draggableOrbRect,from:f.scene.peekNode.header)
            let point = CGPoint(x:r.midX,y:r.midY), moved = CGPoint(x:r.midX+8,y:r.midY)
            _ = f.useAppKitDispatch()
            f.dispatch(f.event(.leftMouseDown,at:point,flags:.option))
            f.dispatch(f.event(.leftMouseDragged,at:moved,flags:.option,after:0.02))
            check(f.scene.isDragging && f.scene.shownPeek == nil,"Option Peek top picks up through the same 8pt drag owner")
            let carried = f.scene.dock.items[id]!.glass.frame
            check(hypot(carried.midX-moved.x,carried.midY-moved.y)<60,"Peek top pickup starts from painted orb instead of bottom Dock capsule")
            f.scene.orbInput.cancel(); f.settle()
            check(!f.scene.isHolding && f.scene.current != id,"cancelled Peek drag does not become Option swap")
        }
        OrbSwitchVerification.run(check:check)
        verifyMockRPC(check:check)
        verifyWholeFork(check:check)
        var tideMenuRows: [[String:Any]] = []
        verifyTideMenus(check:check,rows:&tideMenuRows)
        var tidePickupRows: [[String:Any]] = []
        verifyTidePickup(check:check,rows:&tidePickupRows)
        let screen = NSScreen.screens.first { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            return CGDisplayIsBuiltin(id) != 0
        }!
        check(NSApp.windows.allSatisfy { !$0.isVisible },"all feature fixtures remain offscreen")
        let report: [String:Any] = ["checks":checks,"failures":failures,"realCoreConnections":0,"entryPoints":["NSApplication.sendEvent","DispatchWindow.sendEvent","NSView.hitTest","NSView.menu(for:)","NSApplication.sendAction"],"windowOrdered":false,
            "screen":screen.localizedName,"maximumFPS":screen.maximumFramesPerSecond,"screenScale":screen.backingScaleFactor,
            "frameInterval":DisplayProfile.of(screen).frameInterval,"motionSamplingScales":[1,2],"appKitDispatch":dispatchRows,"tideMenus":tideMenuRows,"tidePickup":tidePickupRows]
        let output = URL(fileURLWithPath:path,isDirectory:true)
        try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("orb-input.json"))
        print("M11.36 Orb input: \(checks) checks, \(failures.count) failures")
        failures.forEach { print("  FAIL "+$0) }
        return failures.isEmpty ? 0:1
    }
    static func verifyAppKitDispatch(check: (Bool,String) -> Void, rows: inout [[String:Any]]) {
        NSApp.finishLaunching()
        for source in ["dock", "full", "brief", "peek", "tide-orb", "tide-capsule", "tide-card"] {
            for gesture in ["option", "control", "right"] {
                let f = Fixture(); defer { f.dispose() }
                let window = f.useAppKitDispatch(), scene = f.scene
                for conversation in f.app.store.conversations where conversation.running { f.app.runtime.stop(conversation) }
                scene.dock.retireTide(); f.settle()
                let id = source == "full" ? scene.current : source == "brief" ? scene.columns.first{$0.conversation.id != scene.current}!.conversation.id : "D"
                if source == "brief" { startDispatchTide(f,id:"D") }
                if source == "tide-card" { scene.enterFocused(scene.current,reason:"dispatch-fixture"); f.settle() }
                if source.hasPrefix("tide-") { startDispatchTide(f, id:id) }
                if source == "peek" {
                    scene.setPeeking(id); scene.peekNode.setHeaderVisible(true,duration:0)
                }
                var point = f.point(id)
                if source == "tide-capsule" || source == "tide-card", let body = dispatchTideBody(scene.dock,id:id,side:source == "tide-card") {
                    point = CGPoint(x:body.midX,y:body.minY+6)
                }
                f.owner.hover(point)
                let flags: NSEvent.ModifierFlags = gesture == "option" ? .option : gesture == "control" ? .control:[]
                let down = f.event(gesture == "right" ? .rightMouseDown:.leftMouseDown,at:point,flags:flags)
                let hit = window.contentView?.hitTest(down.locationInWindow)
                let beforeCurrent = scene.current, beforeColumns = scene.columns.map { $0.conversation.id }
                let island = scene.nodes[id]?.island
                if gesture == "control",let island,["full","brief"].contains(source) {
                    check(island.titleButton.menu(for:down) != nil,"AppKit \(source) title retains its native context menu")
                }
                let beforeInput: [String:Any] = ["hitPlanet":hit === island?.planetButton,"hitTitle":hit === island?.titleButton,
                    "configuredID":island?.configuration?.id ?? "nil","dockItemExists":scene.dock.items[id] != nil,
                    "dragExists":scene.drag != nil,"tearing":scene.tearing != nil,
                    "headerPhase":scene.dock.headerOrbDragging?.phase.rawValue ?? "none",
                    "hitShieldPermits":hit.map{NativePointerShield.permits($0,localPoint:$0.convert(down.locationInWindow,from:nil))} ?? false]
                let beforeDispatches = window.dispatches
                let routed = f.dispatchedClick(at:point,flags:flags,right:gesture == "right")
                let passed = gesture == "option"
                    ? routed && scene.current == id && (source != "full" || scene.orbFlights.flights[id]?.vy == -110)
                    : routed && scene.orbMenu.state.isOpen && scene.current == beforeCurrent
                let category = source.hasPrefix("tide-") ? "tide-special" : source == "brief" && gesture == "option" ? "brief-option-hover" : gesture == "control" && ["full","brief"].contains(source) ? "header-control-native-menu" : "unexpected"
                check(passed,"AppKit \(source) \(gesture) [\(category)]")
                check(!window.hasOnscreenSurface && window.orderAttempts == 0,"AppKit dispatch remains offscreen: \(source) \(gesture)")
                check(!f.app.o.usesLiveCore && f.app.core == nil && f.app.live == nil,"AppKit dispatch cannot connect to real Core: \(source) \(gesture)")
                rows.append(["source":source,"gesture":gesture,"passed":passed,"category":category,"menuPreflightAllowed":routed,
                    "windowDispatches":window.dispatches-beforeDispatches,"hit":hit.map{String(describing:type(of:$0))} ?? "nil",
                    "target":scene.orbInputTarget(at:point) ?? "nil","id":id,"currentBefore":beforeCurrent,"currentAfter":scene.current,
                    "columnsBefore":beforeColumns,"pressedNode":scene.pressedNode ?? "nil","orbPressed":scene.orbInput.isPressed,
                    "rootFrame":NSStringFromRect(f.owner.root.frame),"rootHidden":f.owner.root.isHidden,
                    "planeFrame":NSStringFromRect(scene.nativePlane.frame),"windowPoint":NSStringFromPoint(down.locationInWindow),"dispatchDebug":f.dispatchDebug,"beforeInput":beforeInput,
                    "canDragOrb":island?.canDragOrb ?? false,"buttonEnabled":island?.planetButton.isEnabled ?? false,
                    "buttonParticipates":island?.planetButton.participates ?? false,"islandIdentity":island.map{scene.nodes[id]?.island === $0} ?? false])
            }
        }
        for side in [false,true] {
            let f = Fixture(); defer { f.dispose() }
            let window = f.useAppKitDispatch()
            for c in f.app.store.conversations where c.running { f.app.runtime.stop(c) }
            f.scene.dock.retireTide(); f.settle()
            if side { f.scene.enterFocused(f.scene.current,reason:"dispatch-fixture"); f.settle() }
            startDispatchTide(f,id:"D")
            guard let body = dispatchTideBody(f.scene.dock,id:"D",side:side) else { check(false,"Tide ordinary click has a live surface side=\(side)"); continue }
            let point = CGPoint(x:body.midX,y:body.minY+6)
            let before = dispatchTideRemaining(f.scene.dock,side:side), current = f.scene.current
            let hit = window.contentView?.hitTest(f.event(.leftMouseDown,at:point).locationInWindow)
            let sent = f.dispatchedClick(at:point)
            // The ink probe is a rendered sample. Check pin's visible effect on the live deadline instead.
            f.scene.pointer(nil); advanceDispatchTide(f,seconds:4)
            let held = dispatchTideRemaining(f.scene.dock,side:side)
            let next = dispatchTideBody(f.scene.dock,id:"D",side:side) ?? body
            let sentAgain = f.dispatchedClick(at:CGPoint(x:next.midX,y:next.minY+6))
            f.scene.pointer(nil); advanceDispatchTide(f,seconds:4)
            let released = dispatchTideRemaining(f.scene.dock,side:side)
            let passed = sent && sentAgain && before > 0 && abs(held-before) < 0.05 && released <= 0.05 && current == f.scene.current
            check(passed,"AppKit ordinary Tide click toggles pin side=\(side)")
            check(!window.hasOnscreenSurface && window.orderAttempts == 0,"ordinary Tide click remains offscreen side=\(side)")
            rows.append(["source":side ? "tide-card":"tide-capsule","gesture":"ordinary","passed":passed,
                "category":"ordinary-pin","remainingBefore":before,"remainingPinnedAfter4s":held,"remainingUnpinnedAfter4s":released,
                "hit":hit.map{String(describing:type(of:$0))} ?? "nil","dispatchDebug":f.dispatchDebug])
        }
    }
    private static func dispatchTideBody(_ dock: DockNode, id: String, side: Bool) -> CGRect? {
        if !side { return dock.items[id]?.glass.frame }
        guard let rect = dock.tideSideProbe.first(where:{$0["owner"] as? String == id})?["card"] as? [CGFloat],rect.count == 4 else { return nil }
        return CGRect(x:rect[0],y:rect[1],width:rect[2],height:rect[3])
    }
    private static func dispatchTideRemaining(_ dock: DockNode, side: Bool) -> Double {
        if side { return dock.tideSideProbe.first(where:{$0["owner"] as? String == "D"})?["eventRemaining"] as? Double ?? 0 }
        return dock.tideProbe["eventRemaining"] as? Double ?? 0
    }
    private static func advanceDispatchTide(_ f: Fixture, seconds: Double) {
        for _ in 0..<Int(seconds*60) {
            f.time += 1.0/60
            if let due = f.scene.dock.tideLightProbe["nextWakeAt"] as? Double,due <= f.time { f.scene.dock.serviceTideDeadline() }
            f.scene.dock.frame(at:f.time,elapsed:.infinity)
        }
        f.scene.clock.invalidate()
    }
    private static func startDispatchTide(_ f: Fixture, id: String) {
        f.scene.dock.prepareTideMaterialNow()
        f.app.store.apply(.init(id:10001,time:f.time,method:"turn/started",params:["threadId":.string(id),"turn":["id":"dispatch-turn"]]))
        f.app.store.apply(.init(id:10002,time:f.time,method:"item/started",params:["threadId":.string(id),"turnId":"dispatch-turn","item":["id":"dispatch-command","type":"commandExecution","command":"fixture command"]]))
        for _ in 0..<120 {
            f.time += 1.0/60
            if let due = f.scene.dock.tideLightProbe["nextWakeAt"] as? Double,due <= f.time { f.scene.dock.serviceTideDeadline() }
            f.scene.dock.frame(at:f.time,elapsed:.infinity)
        }
        f.scene.clock.invalidate()
    }
    /// A Tide planet is displaced over a borrowed brief. Picking up that source must not submit a queue preview.
    static func verifyTidePickup(check: (Bool,String) -> Void, rows: inout [[String:Any]]) {
        for outcome in ["row-return", "free-return", "remove-undo"] {
            let f = Fixture(); defer { f.dispose() }
            let scene = f.scene, id = "D", suite = "tide-pickup-" + UUID().uuidString
            scene.orbTrash.preferences = .init(defaults:UserDefaults(suiteName:suite)!)
            defer { UserDefaults.standard.removePersistentDomain(forName:suite) }
            var tears = 0; scene.onTear = { _ in tears += 1 }
            _ = f.useAppKitDispatch()
            for c in f.app.store.conversations where c.running { f.app.runtime.stop(c) }
            scene.dock.retireTide(); f.settle(); startDispatchTide(f,id:id)
            func advance(_ seconds: Double) {
                for _ in 0..<max(1,Int(seconds*60)) {
                    f.time += 1.0/60
                    if let due=scene.dock.tideLightProbe["nextWakeAt"] as? Double,due<=f.time { scene.dock.serviceTideDeadline() }
                    scene.frame(f.time); scene.clock.invalidate()
                }
            }
            let columns = scene.columns.map { $0.conversation.id }, order = scene.order, current = scene.current
            let members = Set(scene.members.map(\.id))
            let visible = scene.dock.trashCarrier(id).map { $0.rect.width > 80 } ?? false
            check(visible && scene.dock.trashLeaseFacts().tide != nil,"tide-pickup-fixture: \(outcome) has a wide notice and a borrowed brief")
            let point = f.point(id), dx: CGFloat = point.x < scene.size.width/2 ? 1 : -1
            f.dispatch(f.event(.leftMouseDown,at:point))
            check(scene.orbInput.isPressed,"tide-pickup-owner: \(outcome) goes through Passage and the unified controller")
            guard scene.orbInput.isPressed else { continue }
            var samples: [[String:Any]] = []
            func unchanged(_ sample: String) {
                let ids = scene.columns.map { $0.conversation.id }
                check(ids == columns && scene.order == order && scene.current == current,
                      "tide-pickup-layout: \(outcome) \(sample) preserves columns, order and current")
                samples.append(["sample":sample,"columns":ids,"order":scene.order,"current":scene.current,
                                "dragging":scene.isDragging,"freeCarry":scene.drag?.freeCarry ?? false])
            }
            unchanged("down")
            for distance in ([3.9,7.9,8,8.1] as [CGFloat]) {
                f.time += 1.0/60
                f.dispatch(f.event(.leftMouseDragged,at:CGPoint(x:point.x+dx*distance,y:point.y)))
                advance(0.02); unchanged("row-\(distance)")
            }
            check(scene.isDragging,"tide-pickup-threshold: \(outcome) still picks up at eight points")
            if outcome != "row-return" {
                for distance in ([10,30,43.9,44,44.1,45] as [CGFloat]) {
                    let p = CGPoint(x:point.x+dx*8.1,y:point.y-distance)
                    f.dispatch(f.event(.leftMouseDragged,at:p)); advance(0.02); unchanged("off-row-\(distance)")
                }
                check(scene.drag?.freeCarry == true,"tide-pickup-free: \(outcome) crosses the unchanged 44pt boundary")
            }
            check(!scene.switches.contains { $0["reason"] as? String == "drag-preview" },
                  "tide-pickup-preview: \(outcome) never submits a row preview")
            if outcome == "remove-undo" {
                let last = scene.layout.orbs.max(by: { $0.maxX < $1.maxX })?.midX ?? scene.size.width-46
                let geometry = OrbTrashGeometry(bounds:scene.dockView.bounds,lastSlotX:last,dockBaseline:scene.layout.me.midY)
                let grab = scene.drag?.grab ?? .zero
                let p = CGPoint(x:geometry.target.x+grab.x,y:geometry.target.y+grab.y)
                f.dispatch(f.event(.leftMouseDragged,at:p)); advance(1.2)
                check(scene.orbTrash.state.phase == .armed,"tide-pickup-trash: the displaced source arms the real trash")
                f.dispatch(f.event(.leftMouseUp,at:p)); advance(1.1)
                check(!scene.members.contains { $0.id == id } && scene.orbTrash.successfulRemovals == 1,
                      "tide-pickup-remove: exactly the bank owner is removed")
                check(scene.columns.map { $0.conversation.id } == columns,
                      "tide-pickup-remove: the borrowed brief keeps its original column")
                let presentation = scene.orbTrash.presentation
                let button = presentation.undo.isHidden ? presentation.toastUndo : presentation.undo
                let rect = scene.dockView.convert(button.bounds,from:button)
                _ = f.dispatchedClick(at:CGPoint(x:rect.midX,y:rect.midY)); advance(1.4)
                check(scene.orbTrash.successfulUndos == 1 && Set(scene.members.map(\.id)) == members,
                      "tide-pickup-undo: the original member set returns exactly once")
            } else {
                f.dispatch(f.event(.leftMouseDragged,at:point)); advance(0.1)
                f.dispatch(f.event(.leftMouseUp,at:point)); advance(1.4)
                check(scene.orbTrash.successfulRemovals == 0 && scene.orbTrash.successfulUndos == 0,
                      "tide-pickup-return: \(outcome) removes nothing")
            }
            unchanged("finished")
            check(!scene.orbInput.isPressed && scene.drag == nil && !scene.dock.isHolding
                  && scene.orbTrash.state.phase == .hidden && scene.orbTrash.presentation.proxy.isHidden,
                  "tide-pickup-cleanup: \(outcome) releases every carrier")
            check(tears == 0 && !f.app.o.usesLiveCore && f.app.core == nil && f.app.live == nil,
                  "tide-pickup-isolation: \(outcome) neither tears nor opens Core")
            rows.append(["outcome":outcome,"beforeColumns":columns,"beforeOrder":order,"samples":samples,
                         "reduceMotion":Motion.reduce,"reduceTransparency":NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                         "dispatches":f.dispatchWindow?.dispatches ?? 0])
        }
    }
    /// Exercise the real competing local monitors while both timeline and side Tide surfaces are visible.
    static func verifyTideMenus(check: (Bool,String) -> Void, rows: inout [[String:Any]]) {
        let models = ModelCatalog.models; defer { ModelCatalog.models = models }
        for side in [false,true] {
            for target in ["D","F"] {
                for input in ["escape","outside","fork","peek","keyboard","held-right","control","wheel","blink-escape","blink-outside"] {
                    let f = Fixture(); defer { f.dispose() }
                    let window = f.useAppKitDispatch(), scene = f.scene, clock = OverlayManualClock()
                    for c in f.app.store.conversations where c.running { f.app.runtime.stop(c) }
                    scene.dock.retireTide(); f.settle()
                    if side { scene.enterFocused(scene.current,reason:"tide-menu-fixture"); f.settle() }
                    scene.orbMenu = OrbContextMenu(scene:scene,clock:clock)
                    let c = f.app.store.conversation(target)!
                    c.items = [TranscriptItem(id:"menu-history-user",turnID:"menu-history",kind:.user,text:"Completed question"),
                               TranscriptItem(id:"menu-history-answer",turnID:"menu-history",kind:.assistant,text:"Completed answer")]
                    c.historyLoaded = true; f.app.store.changed(c)
                    startDispatchTide(f,id:"D")
                    func tideVisible() -> Bool {
                        if side {
                            let p = scene.dock.tideSideProbe.first { $0["owner"] as? String == "D" }
                            return p?["visible"] as? Bool == true && p?["returning"] as? Bool == false
                        }
                        return scene.dock.tideLightProbe["phase"] as? String == "holding"
                    }
                    let label = "Tide menu side=\(side) owner=\(target == "D") \(input)"
                    check(tideVisible() && dispatchTideBody(scene.dock,id:"D",side:side).map{$0.width>100} == true,label+": Tide really displays before opening")
                    let point = f.point(target), before = scene.order, full = scene.current, columns = scene.columns.map{$0.conversation.id}
                    if input == "held-right" { f.dispatch(f.event(.rightMouseDown,at:point)) }
                    else { _ = f.dispatchedClick(at:point,right:true) }
                    clock.advance(by:0.2)
                    check(scene.orbMenu.state.isOpen && tideVisible(),label+": menu opens over live Tide")
                    check(scene.tideHasForegroundSurface && scene.dock.tideCanDismiss?() == false,label+": menu owns foreground input")
                    let menu = scene.orbMenu
                    func row(_ action: OrbMenuAction) -> CGPoint {
                        let n = action.rawValue, separators = [3,5,7].filter{n >= $0}.count
                        return CGPoint(x:menu.main.frame.minX+30,y:menu.main.frame.minY+50+CGFloat(n*24+separators*9))
                    }
                    let outside = f.point(full)
                    check(!menu.main.frame.contains(outside),label+": outside fixture misses the menu")
                    switch input {
                    case "escape":
                        f.key(53)
                        check(!menu.state.isOpen && tideVisible(),label+": Esc closes only the menu")
                    case "outside":
                        let downs = window.leftDowns
                        var customizations = 0
                        scene.nodes[full]?.island?.actions.customize = { customizations += 1 }
                        _ = f.dispatchedClick(at:outside)
                        check(!menu.state.isOpen && tideVisible(),label+": outside closes only the menu")
                        check(window.leftDowns == downs && customizations == 0 && scene.current == full,label+": outside press cannot fall through")
                    case "fork","held-right":
                        if input == "held-right" {
                            f.dispatch(f.event(.rightMouseDragged,at:row(.fork),after:0.2))
                            f.dispatch(f.event(.rightMouseUp,at:row(.fork),after:0.22))
                        } else { _ = f.dispatchedClick(at:row(.fork)) }
                        check(menu.state.blinking && menu.state.isOpen && scene.dock.tideCanDismiss?() == false,label+": selection retains ownership through blinking")
                        clock.advance(by:0.1)
                        spin { scene.members.count == before.count+1 }
                        let fork = scene.members.first{!before.contains($0.id)}
                        check(fork?.items == c.completedForkItems && fork.map{scene.dock.items[$0.id]?.role == .orb} == true,label+": Fork executes with completed history into Dock")
                        check(!menu.state.isOpen && scene.current == full && scene.columns.map{$0.conversation.id} == columns,label+": Fork preserves columns and full")
                        check(!scene.dock.tideHasNotice("D"),label+": Fork retires Tide through the existing Dock layout commit")
                    case "peek","keyboard":
                        if input == "keyboard" {
                            for _ in 0..<3 { f.key(125) }
                            check(menu.state.selected == OrbMenuAction.peek.rawValue,label+": arrows reach Peek")
                            f.key(36)
                        } else { _ = f.dispatchedClick(at:row(.peek)) }
                        clock.advance(by:0.1)
                        check(!menu.state.isOpen && scene.shownPeek == target,label+": Peek executes on the requested orb")
                        check(target == "D" ? !scene.dock.tideHasNotice("D"):tideVisible(),label+": Peek preserves the existing owner retirement rule")
                    case "control":
                        let other = target == "D" ? "F":"D", next = f.point(other)
                        _ = f.dispatchedClick(at:next,flags:.control)
                        clock.advance(by:0.2)
                        check(menu.state.isOpen && menu.anchor == next && tideVisible(),label+": Control-click retargets the menu without dismissing Tide")
                        f.key(53)
                        check(!menu.state.isOpen && tideVisible(),label+": retargeted menu owns Esc")
                    case "wheel":
                        let cg = CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:3,wheel2:0,wheel3:0)!
                        cg.setIntegerValueField(CGEventField(rawValue:51)!,value:Int64(window.windowNumber))
                        let event = NSEvent(cgEvent:cg)!, dispatches = window.dispatches
                        check(event.window === window,label+": wheel targets the hidden dispatch window")
                        f.dispatch(event)
                        check(window.dispatches == dispatches && menu.state.isOpen && tideVisible(),label+": menu consumes wheel without scrolling below")
                        f.key(53)
                    default:
                        _ = f.dispatchedClick(at:row(.fork))
                        check(menu.state.blinking && menu.state.isOpen && scene.dock.tideCanDismiss?() == false,label+": blink still owns input")
                        let downs = window.leftDowns
                        if input == "blink-escape" { f.key(53) }
                        else { _ = f.dispatchedClick(at:outside) }
                        clock.advance(by:0.2)
                        check(!menu.state.isOpen && scene.order == before && tideVisible(),label+": blink cancellation keeps Tide and cancels Fork")
                        if input == "blink-outside" { check(window.leftDowns == downs,label+": blinking outside press cannot fall through") }
                    }
                    if input == "escape" || input == "outside" {
                        check(scene.dock.tideCanDismiss?() == true,label+": closed menu restores Tide dismissal")
                        if input == "escape" { f.key(53) }
                        else { _ = f.dispatchedClick(at:CGPoint(x:20,y:200)) }
                        advanceDispatchTide(f,seconds:1.5)
                        check(!scene.dock.tideHasNotice("D"),label+": the next input dismisses Tide normally")
                    }
                    check(window.orderAttempts == 0 && !window.hasOnscreenSurface && f.app.core == nil && f.app.live == nil && f.app.runtime is MockConversationRuntime,label+": mock and offscreen only")
                    rows.append(["side":side,"owner":target == "D","input":input,"menuOpen":menu.state.isOpen,"tideVisibleAfter":tideVisible(),"windowOrdered":false,"realCoreConnections":0])
                }
            }
        }
    }
    static func runTideMenus(to path: String) -> Int32 {
        var checks = 0, failures: [String] = [], rows: [[String:Any]] = []
        NSApp.finishLaunching()
        verifyTideMenus(check:{ value,name in checks += 1; if !value { failures.append(name) } },rows:&rows)
        let output = URL(fileURLWithPath:path,isDirectory:true)
        try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try? JSONSerialization.data(withJSONObject:["checks":checks,"failures":failures,"rows":rows,"mockOnly":true],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-menus.json"))
        print("M11.36b Tide menus: \(checks) checks, \(failures.count) failures")
        failures.forEach { print("  FAIL "+$0) }
        return failures.isEmpty ? 0:1
    }
    static func runAppKitDispatch(to path: String) -> Int32 {
        var checks = 0, failures: [String] = [], rows: [[String:Any]] = []
        verifyAppKitDispatch(check:{ value,name in checks += 1; if !value { failures.append(name) } },rows:&rows)
        let report: [String:Any] = ["checks":checks,"failures":failures,"rows":rows,"mockOnly":true,"entry":"NSWindow.sendEvent -> native hitTest/menu(for:) -> NSApplication.sendAction (unordered-window adapter)"]
        let output = URL(fileURLWithPath:path,isDirectory:true)
        try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("appkit-dispatch.json"))
        print("AppKit dispatch: \(checks) checks, \(failures.count) failures")
        failures.forEach { print("  FAIL "+$0) }
        return failures.isEmpty ? 0:1
    }
    private actor ForkReply {
        private var continuation: CheckedContinuation<JSONValue, Error>?
        private var result: Result<JSONValue, Error>?
        func wait() async throws -> JSONValue {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func finish(_ result: Result<JSONValue, Error>) {
            self.result = result; continuation?.resume(with:result); continuation = nil
        }
    }
    private static func spin(until done: () -> Bool) {
        let deadline = CACurrentMediaTime()+3
        while !done() && CACurrentMediaTime()<deadline { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005)) }
    }
    private static func selectFork(_ f: Fixture, source: Conversation, input: String, clock: OverlayManualClock, check: (Bool,String) -> Void) {
        let point = f.point(source.id)
        _ = f.useAppKitDispatch()
        if input == "held-right" { f.dispatch(f.event(.rightMouseDown,at:point)) }
        else { _ = f.dispatchedClick(at:point,right:true) }
        clock.advance(by:0.2)
        let menu = f.scene.orbMenu
        check(menu.state.isOpen && f.scene.onForkWhole != nil,"\(input): production RootView opens a connected Fork menu")
        let row = CGPoint(x:menu.main.frame.minX+30,y:menu.main.frame.minY+212)
        switch input {
        case "keyboard":
            for _ in 0..<6 { f.key(125) }
            check(menu.state.selected == OrbMenuAction.fork.rawValue,"keyboard reaches Fork through window dispatch")
            f.key(36)
        case "held-right":
            f.dispatch(f.event(.rightMouseDragged,at:row,after:0.2))
            f.dispatch(f.event(.rightMouseUp,at:row,after:0.22))
        case "AX":
            let items = menu.main.accessibilityChildren() as? [NSAccessibilityElement] ?? []
            check(items.count == 9 && items[6].isAccessibilityEnabled() && items[6].accessibilityPerformPress(),"AX accepts the enabled Fork row")
        default: _ = f.dispatchedClick(at:row)
        }
        clock.advance(by:0.1)
    }
    private static func memoryRuntime(_ f: Fixture, transport: RecordingTransport) -> LiveConversationRuntime {
        let state = LocalPresentationState(store:f.app.store,scope:"whole-fork-memory-only",storage:CoreMemoryStorage())
        let runtime = LiveConversationRuntime(store:f.app.store,client:transport,presentation:state)
        f.app.runtime = runtime
        return runtime
    }
    private static var forkResponse: JSONValue {
        ["thread":["id":"whole-fork-child","name":"Codex supplied name","turns":[
            ["id":"finished-1","status":"completed","items":[
                ["id":"user-1","type":"userMessage","content":[["type":"text","text":"First question"]]],
                ["id":"answer-1","type":"agentMessage","text":"First answer"]]],
            ["id":"finished-2","status":"completed","items":[
                ["id":"user-2","type":"userMessage","content":[["type":"text","text":"Second question"]]],
                ["id":"answer-2","type":"agentMessage","text":"Second answer"]]]]]]
    }
    private static var forkSourceResponse: JSONValue {
        var thread = forkResponse["thread"]!.objectValue!
        thread["id"] = "source-thread"
        return ["thread":.object(thread)]
    }
    static func verifyWholeFork(check: (Bool,String) -> Void) {
        let models = ModelCatalog.models; defer { ModelCatalog.models = models }
        check(OrbMenuAction.fork.enabled,"M11.36b: Fork is available in the production menu")
        check(OrbMenuAction.allCases.filter { !$0.enabled } == [.sidechat],"M11.36b: only Sidechat remains disabled; eligible Remove is enabled")
        for running in [false,true] {
            for input in ["mouse","keyboard","held-right","AX"] {
                let f = Fixture(); defer { f.dispose() }
                let scene = f.scene, c = f.app.store.conversation("F")!, clock = OverlayManualClock()
                scene.orbMenu = OrbContextMenu(scene:scene,clock:clock)
                let expected = c.items
                if running {
                    c.running = true; c.activeTurnID = "unfinished"
                    c.items += [TranscriptItem(id:"unfinished-user",turnID:"unfinished",kind:.user,text:"Unfinished question",status:"completed"),
                        TranscriptItem(id:"unfinished-tool",turnID:"unfinished",kind:.tool(.command),text:"Completed tool in active turn",status:"completed"),
                        TranscriptItem(id:"unfinished-answer",turnID:"unfinished",kind:.assistant,text:"Partial answer",status:"running")]
                    f.app.store.changed(c)
                }
                scene.dock.retireTide(); f.settle()
                let before = scene.order, full = scene.current, columns = scene.columns.map { $0.conversation.id }, source = c.items
                let origin = scene.orbPose(c.id)!, identities = Set(f.app.store.conversations.map { $0.identityIndex })
                let count = f.app.store.conversations.count
                selectFork(f,source:c,input:input,clock:clock,check:check)
                spin { scene.members.count == before.count+1 }
                let fork = scene.members.first { !before.contains($0.id) }
                let label = "\(input), running=\(running)"
                check(scene.members.count == before.count+1 && fork != nil,"\(label): Fork adds exactly one Dock member")
                check(scene.current == full && scene.columns.map({$0.conversation.id}) == columns,"\(label): Fork preserves columns and full")
                check(!scene.orbMenu.state.isOpen,"\(label): Fork closes its menu")
                check(fork.map { scene.dock.items[$0.id]?.role == .orb } == true,"\(label): new conversation is a Dock orb")
                check(fork?.items == expected,"\(label): fork contains every row of every completed turn")
                check(fork?.running == false && fork?.activeTurnID == nil && fork?.draft.isEmpty == true,"\(label): fork has no active turn or message draft")
                check(fork?.title == c.title && fork?.backendThreadID == nil,"\(label): mock inherits the Codex name without a backend ID")
                check(fork.map { !identities.contains($0.identityIndex) && $0.id != c.id } == true,"\(label): fork receives a fresh planet and ID")
                check(c.items == source && f.app.store.conversations.count == count+1,"\(label): source history is unchanged")
                check(fork.flatMap { scene.orbFlights.flights[$0.id] }.map { $0.start == origin } == true,"\(label): flight starts at the source orb")
                let window = f.dispatchWindow!
                check(window.dispatches > 0 && window.orderAttempts == 0 && !window.hasOnscreenSurface && f.app.core == nil && f.app.live == nil,"\(label): hidden AppKit dispatch and mock only")
            }
        }
        for input in ["mouse","keyboard","held-right","AX"] {
            let f = Fixture(); defer { f.dispose() }
            let c = f.app.store.conversation("F")!, before = f.scene.order, count = f.app.store.conversations.count, clock = OverlayManualClock()
            c.items = []; c.historyLoaded = true; f.app.store.changed(c)
            f.scene.orbMenu = OrbContextMenu(scene:f.scene,clock:clock)
            selectFork(f,source:c,input:input,clock:clock,check:check)
            spin { f.scene.orbToast.superview != nil }
            check(f.scene.order == before && f.app.store.conversations.count == count,"\(input): empty history creates no conversation or orb")
            check(f.scene.orbToast.label.stringValue == "No completed history to fork yet" && f.scene.orbToast.superview != nil,"\(input): empty history shows the same light toast")
            check(!f.scene.orbMenu.state.isOpen,"\(input): empty-history selection closes the menu")
        }
        do {
            let f = Fixture(); defer { f.dispose() }
            let response = forkResponse, source = forkSourceResponse
            let transport = RecordingTransport { body in body["method"] == "thread/read" ? source:response }, runtime = memoryRuntime(f,transport:transport)
            let c = f.app.store.conversation("F")!, clock = OverlayManualClock()
            c.backendThreadID = "source-thread"
            f.scene.orbMenu = OrbContextMenu(scene:f.scene,clock:clock)
            let before = f.scene.order, full = f.scene.current, columns = f.scene.columns.map { $0.conversation.id }
            selectFork(f,source:c,input:"mouse",clock:clock,check:check)
            spin { f.scene.members.count > before.count || f.scene.orbToast.superview != nil }
            let calls = transport.calls, forkCalls = calls.filter { $0["method"] == "thread/fork" }, fork = f.scene.members.first { !before.contains($0.id) }
            check(calls.map { $0["method"]?.stringValue ?? "" } == ["thread/read","thread/fork"],"Live snapshots completed history and emits exactly one thread/fork RPC")
            check(forkCalls.first?["params"] == .object(["threadId":"source-thread","deferGoalContinuation":true]),"Live whole Fork parameters are exactly threadId and deferGoalContinuation, without beforeTurnId")
            check(fork?.title == "Codex supplied name" && fork?.backendThreadID == "whole-fork-child","Live trusts the returned Core thread identity and name")
            check(fork?.items.map(\.text) == ["First question","First answer","Second question","Second answer"],"Live hydrates all returned completed turns")
            check(f.scene.current == full && f.scene.columns.map({$0.conversation.id}) == columns && fork.map { f.scene.dock.items[$0.id]?.role == .orb } == true,"Live response joins Dock and preserves full and columns")
            check(runtime.service == nil && f.app.core == nil && f.app.live == nil && !runtime.isStreaming,"Live contract uses only RecordingTransport and never starts Core")
            check(transport.healthCalls == 1,"Live accepts an event watermark before publishing the fork")
            runtime.shutdown()
        }
        for revertFails in [false,true] {
            let f = Fixture(); defer { f.dispose() }
            let source = forkSourceResponse, trimmed = forkResponse
            var child = trimmed["thread"]!.objectValue!
            child["turns"] = .array(child["turns"]!.arrayValue! + [["id":"active-tail","status":"interrupted","items":[["id":"partial","type":"agentMessage","text":"Unfinished tail"]]]])
            let partial: JSONValue = ["thread":.object(child)]
            let transport = RecordingTransport { body in
                if body["method"] == "thread/read" { return body["params"]?["threadId"] == "source-thread" ? source:trimmed }
                if body["method"] == "thread/fork" { return partial }
                if revertFails { throw CoreWire.failure("Fixture revert denied") }
                return ["thread":["id":"whole-fork-child","turns":[]]]
            }, runtime = memoryRuntime(f,transport:transport)
            let c = f.app.store.conversation("F")!, before = f.scene.order, clock = OverlayManualClock()
            c.backendThreadID = "source-thread"; c.running = true; c.activeTurnID = "active-tail"
            f.scene.orbMenu = OrbContextMenu(scene:f.scene,clock:clock)
            selectFork(f,source:c,input:"mouse",clock:clock,check:check)
            spin { f.scene.members.count > before.count || f.scene.orbToast.superview != nil }
            let calls = transport.calls, fork = f.scene.members.first { !before.contains($0.id) }
            let expectedMethods = revertFails ? ["thread/read","thread/fork","thread/revert"]:["thread/read","thread/fork","thread/revert","thread/read"]
            check(calls.map { $0["method"]?.stringValue ?? "" } == expectedMethods,"active Core snapshot is trimmed on the new child only")
            check(calls.first(where:{$0["method"] == "thread/revert"})?["params"] == .object(["threadId":"whole-fork-child","beforeTurnId":"active-tail"]),"revert targets exactly the child's unfinished tail")
            check(revertFails ? fork == nil && f.scene.orbToast.label.stringValue == "Fixture revert denied" : fork?.items.map(\.text) == ["First question","First answer","Second question","Second answer"],"revert \(revertFails ? "failure leaves no orb":"success removes the entire unfinished turn")")
            check(c.running && c.activeTurnID == "active-tail","whole Fork never interrupts or reverts the source")
            runtime.shutdown()
        }
        let invalid: [(String,JSONValue?)] = [("Core denied the fixture fork",nil), ("missing thread",[:]),
            ("source ID",["thread":["id":"source-thread","turns":[]]]),
            ("empty history",["thread":["id":"invalid-child","turns":[]]]),
            ("missing completed rows",["thread":["id":"invalid-child","turns":[
                ["id":"finished-1","status":"completed","items":[]],
                ["id":"finished-2","status":"completed","items":[]]]]]),
            ("incomplete turn",["thread":["id":"invalid-child","turns":[["id":"unfinished","status":"inProgress","items":[]]]]])]
        for (label,response) in invalid {
            let f = Fixture(); defer { f.dispose() }
            let source = forkSourceResponse
            let transport = RecordingTransport { body in
                if body["method"] == "thread/read" { return source }
                guard let response else { throw CoreWire.failure(label) }; return response
            }, runtime = memoryRuntime(f,transport:transport)
            let c = f.app.store.conversation("F")!, before = f.scene.order, count = f.app.store.conversations.count, clock = OverlayManualClock()
            c.backendThreadID = "source-thread"
            f.scene.orbMenu = OrbContextMenu(scene:f.scene,clock:clock)
            selectFork(f,source:c,input:"mouse",clock:clock,check:check)
            spin { f.scene.orbToast.superview != nil }
            check(transport.calls.count == 2 && f.scene.order == before && f.app.store.conversations.count == count,"\(label): failed Fork leaves no placeholder or Dock orb")
            check(f.scene.orbToast.superview != nil && !f.scene.orbToast.label.stringValue.isEmpty,"\(label): failure shows a source-orb toast")
            if response == nil { check(f.scene.orbToast.label.stringValue == label,"Core error text is preserved in the toast") }
            runtime.shutdown()
        }
        for succeed in [true,false] {
            let f = Fixture(); defer { f.dispose() }
            let source = forkSourceResponse, reply = ForkReply(), response = forkResponse
            let transport = RecordingTransport { body in
                if body["method"] == "thread/read" { return source }; return try await reply.wait()
            }
            let runtime = memoryRuntime(f,transport:transport), c = f.app.store.conversation("F")!, clock = OverlayManualClock()
            c.backendThreadID = "source-thread"
            f.scene.orbMenu = OrbContextMenu(scene:f.scene,clock:clock)
            let before = f.scene.order
            selectFork(f,source:c,input:"mouse",clock:clock,check:check)
            spin { transport.calls.count == 2 }; clock.advance(by:0.08)
            f.click(c.id,flags:.option); f.settle()
            let pose = f.scene.orbPose(c.id)!, full = f.scene.current, columns = f.scene.columns.map { $0.conversation.id }
            check(full == c.id,"pending Fork lets the source move through real Option input")
            Task { await reply.finish(succeed ? .success(response):.failure(CoreWire.failure("Moved fixture failure"))) }
            spin { f.scene.members.count > before.count || f.scene.orbToast.superview != nil }
            let fork = f.scene.members.first { !before.contains($0.id) }
            check(f.scene.current == full && f.scene.columns.map({$0.conversation.id}) == columns,"late Fork preserves the user's newer full and columns")
            if succeed {
                check(fork.flatMap { f.scene.orbFlights.flights[$0.id] }.map { $0.start == pose } == true,"late Fork takes off from the source's current pose")
            } else {
                let toast = f.scene.orbToast.frame
                check(fork == nil && f.scene.orbToast.label.stringValue == "Moved fixture failure" && hypot(toast.midX-pose.midX,toast.midY-pose.midY)<80,"late failure stays beside the moved source and leaves no orb")
            }
            runtime.shutdown()
        }
        for succeed in [true,false] {
            let f = Fixture(); defer { f.dispose() }
            let source = forkSourceResponse, reply = ForkReply(), response = forkResponse
            let transport = RecordingTransport { body in
                if body["method"] == "thread/read" { return source }; return try await reply.wait()
            }
            let runtime = memoryRuntime(f,transport:transport), c = f.app.store.conversation("F")!, clock = OverlayManualClock()
            c.backendThreadID = "source-thread"
            f.scene.orbMenu = OrbContextMenu(scene:f.scene,clock:clock)
            let before = f.scene.order
            selectFork(f,source:c,input:"mouse",clock:clock,check:check)
            spin { transport.calls.count == 2 }
            check(transport.calls.count == 2 && f.scene.order == before,"pending Fork has no placeholder and no flight")
            f.owner.window.close()
            check(f.owner.isClosed,"close-before-reply uses the real window lifecycle")
            var replied = false
            Task { await reply.finish(succeed ? .success(response):.failure(CoreWire.failure("Late fixture error"))); replied = true }
            spin { replied && (succeed ? f.app.store.backendConversation("whole-fork-child") != nil:true) }
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.03))
            check(f.scene.order == before && f.scene.orbFlights.flights.isEmpty && f.scene.orbToast.superview == nil,"closed window ignores a late \(succeed ? "success":"error") without adding an orb or toast")
            runtime.shutdown()
        }
    }
    static func runWholeFork(to path: String) -> Int32 {
        var checks = 0, failures: [String] = []
        NSApp.finishLaunching()
        verifyWholeFork { value,label in checks += 1; if !value { failures.append(label) } }
        let out = URL(fileURLWithPath:path,isDirectory:true)
        try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let report: [String:Any] = ["checks":checks,"failures":failures,"realCoreConnections":0,"mockOnly":true]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("whole-fork.json"))
        print("M11.36b whole Fork: \(checks) checks, \(failures.count) failures")
        failures.forEach { print("  FAIL "+$0) }
        return failures.isEmpty ? 0:1
    }
    static func verifyMockRPC(check: (Bool,String) -> Void) {
        let f = Fixture(); defer { f.dispose() }
        let transport = RecordingTransport(), storage = CoreMemoryStorage()
        let presentation = LocalPresentationState(store:f.app.store,scope:"orb-switch-memory-only",storage:storage)
        let oldModels = ModelCatalog.models; defer { ModelCatalog.models = oldModels }
        let runtime = LiveConversationRuntime(store:f.app.store,client:transport,presentation:presentation)
        f.scene.onRename = { c,title in runtime.rename(c,title:title) }
        f.owner.actions.archive = { c,archived in runtime.setArchived(c,archived:archived) }
        let c = f.scene.members.last!; c.backendThreadID = "fixture-thread"; c.isLiveConversation = true
        check(runtime.client is RecordingTransport && runtime.service == nil && f.app.core == nil && f.app.live == nil,"mutation fixture cannot connect to real Core")
        f.scene.performOrbAction(.rename,conversation:c,column:nil,anchor:CGPoint(x:200,y:200))
        check(f.scene.customizeSheet.isShowing,"Rename opens existing Customize Chat")
        check(f.owner.window.firstResponder === f.scene.customizeSheet.nameField || f.scene.customizeSheet.nameField.currentEditor() != nil,"Rename focuses name field")
        f.scene.customizeSheet.setName("Fixture renamed"); f.scene.customizeSheet.commit()
        let before = f.scene.order, beforeCurrent = f.scene.current
        f.scene.archiveOrb(c,at:CGPoint(x:200,y:200))
        check(c.archived && !f.scene.members.contains { $0 === c },"Archive removes only its mock target")
        f.scene.undoOrbArchive(c.id)
        check(!c.archived && f.scene.order == before && f.scene.current == beforeCurrent,"Archive Undo restores original position")
        f.scene.archiveOrb(c,at:CGPoint(x:200,y:200))
        let replacement = f.scene.order.last!
        f.scene.swapOrb(replacement); let keptColumns = f.scene.columns.map { $0.conversation.id }, keptCurrent = f.scene.current
        f.scene.undoOrbArchive(c.id)
        check(f.scene.current == keptCurrent && f.scene.columns.map { $0.conversation.id } == keptColumns,"Undo after layout change does not displace current columns")
        check(f.scene.dock.items[c.id]?.role == .orb,"Undo fallback returns as Dock orb")
        let deadline = CACurrentMediaTime()+2
        while transport.calls.count < 5 && CACurrentMediaTime()<deadline { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01)) }
        let calls = transport.calls
        check(calls.count == 5 && calls.allSatisfy { ["thread/name/set","thread/archive","thread/unarchive"].contains($0["method"]?.stringValue ?? "") },"mutation fixture emits only the five expected RPCs and never sends a turn")
        check(calls.contains { $0["method"]?.stringValue == "thread/name/set" && $0["params"]?["threadId"]?.stringValue == "fixture-thread" && $0["params"]?["name"]?.stringValue == "Fixture renamed" },"Rename emits thread/name/set with exact threadId and name")
        check(calls.filter { $0["method"]?.stringValue == "thread/archive" }.count == 2,"Archive emits thread/archive once per selection")
        check(calls.filter { $0["method"]?.stringValue == "thread/unarchive" }.count == 2,"Undo emits thread/unarchive once per selection")
        check(calls.filter { ["thread/archive","thread/unarchive"].contains($0["method"]?.stringValue ?? "") }.allSatisfy { $0["params"] == .object(["threadId":.string("fixture-thread")]) },"Archive and Undo have exact RPC parameters")
        runtime.shutdown()
    }
}
#endif
