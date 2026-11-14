import AppKit
import QuartzCore
import Darwin
import CryptoKit

/// The same public-component assertions run against HEAD and the integrated app.
@MainActor enum BodyWiringVerification {
    final class Canvas: NSView { override var isFlipped: Bool { true } }
    static func layers(_ view: NSView) -> [CALayer] {
        func walk(_ layer: CALayer) -> [CALayer] { [layer]+(layer.sublayers ?? []).flatMap(walk) }
        return (view.layer.map(walk) ?? [])+view.subviews.flatMap(layers)
    }
    static func bodies(_ view: NSView) -> [CALayer] {
        var seen=Set<ObjectIdentifier>()
        return layers(view).filter { $0.name == "organic.body.texture" && seen.insert(ObjectIdentifier($0)).inserted }
    }
    static func image(_ layer: CALayer?) -> CGImage? {
        guard let layer else { return nil }
        if let contents=layer.contents,CFGetTypeID(contents as CFTypeRef) == CGImage.typeID { return (contents as! CGImage) }
        return (layer.sublayers ?? []).compactMap { image($0) }.first
    }
    static func spin(_ seconds: Double) {
        let until=Date().addingTimeInterval(seconds)
        while Date()<until { _=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005)) }
    }
    static func footprint() -> UInt64 {
        var value=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let capacity=Int(count)
        let result=withUnsafeMutablePointer(to:&value) { p in p.withMemoryRebound(to:integer_t.self,capacity:capacity) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
        return result == KERN_SUCCESS ? value.phys_footprint : 0
    }
    static func lightingMatches(_ root: NSView, faces: [CALayer]) -> Bool {
        func views(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(views) }
        let all=views(root)
        guard !faces.isEmpty,let source=all.first(where: { $0.layer?.sublayers?.contains { $0.name == "organic.body.light-anchor" } == true }),
              let anchor=source.layer?.sublayers?.first(where: { $0.name == "organic.body.light-anchor" }) else { return false }
        func down(_ point: CGPoint, from view: NSView) -> CGPoint {
            let converted=root.convert(point,from:view)
            return root.isFlipped ? converted : CGPoint(x:converted.x,y:root.bounds.maxY-converted.y)
        }
        let ll=down(anchor.position,from:source)
        return faces.allSatisfy { face in
            guard let glass=all.reversed().compactMap({$0 as? NSGlassEffectView}).first(where: { bodies($0).contains { $0 === face } }) else { return false }
            let center=down(CGPoint(x:glass.bounds.midX,y:glass.bounds.midY),from:glass)
            let angle=(atan2(center.y-ll.y,ll.x-center.x)*180/CGFloat.pi+360).truncatingRemainder(dividingBy:360)
            let expected=Int((angle/11.25).rounded())%32
            let actual=face.value(forKey:"lightBin") as? Int
            if actual != expected { print("LIGHT mismatch: actual=\(String(describing:actual)), expected=\(expected), LL=\(ll), center=\(center)") }
            return actual == expected
        }
    }
    final class Storage: CorePresentationStorage {
        var values: [String: Data] = [:]
        var fails = false
        var writes = 0
        func read(key: String) throws -> Data? { values[key] }
        func write(_ data: Data, key: String) throws {
            writes += 1
            if fails { throw CocoaError(.fileWriteNoPermission) }
            values[key] = data
        }
    }
    /// This test double never writes a preferences domain.
    final class FailingDefaults: UserDefaults, @unchecked Sendable {
        var memory: [String:Data] = [:]
        override func data(forKey defaultName: String) -> Data? { memory[defaultName] }
        override func set(_ value: Any?, forKey defaultName: String) { memory[defaultName]=value as? Data }
        override func removeObject(forKey defaultName: String) { memory[defaultName]=nil }
        override func synchronize() -> Bool { false }
    }
    static func run(to path: String) -> Int32 {
        let out = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Measure the unchanged production prewarm verifier; full Column Work correctness runs separately.
        if ProcessInfo.processInfo.environment["BODY_COLUMN_MEASURE"] == "1" {
            let result=M11PrewarmVerification.run(to:out.appendingPathComponent("prewarm"))
            let report: [String:Any] = ["checks":result.checks,"findings":result.findings,"scope":"Unmodified M11PrewarmVerification; full Column Work correctness is a separate run"]
            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("report.json"))
            print("COLUMN PREWARM \(result.checks) checks, \(result.findings.count) findings")
            return result.findings.isEmpty ? 0:1
        }
        var checks = 0, failures: [String] = [], measurements: [String:Any] = [:]
        func check(_ ok: Bool, _ name: String) {
            checks += 1
            if !ok { failures.append(name); print("FAIL: \(name)") }
        }
        let bundled=Bundle.main.resourceURL?.appendingPathComponent("Bodies")
        let resourceProfile=bundled.flatMap { try? Data(contentsOf:$0.appendingPathComponent("profile.json")) }.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
        check(resourceProfile?["version"] as? String == "org.organic.bodies.v2" && resourceProfile?["bodyMotion"] as? String == "static", "the app bundles the v2 static body profile")
        let manifest=bundled.flatMap { try? Data(contentsOf:$0.appendingPathComponent("manifest.json")) }.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
        let assets=manifest?["assets"] as? [[String:Any]] ?? []
        let approved=assets.count == 16 && assets.allSatisfy { asset in
            guard let source=asset["repositoryPath"] as? String,source.hasPrefix("design/orrery/project/tex/"),let root=bundled,
                  let data=try? Data(contentsOf:root.appendingPathComponent("Textures").appendingPathComponent(URL(fileURLWithPath:source).lastPathComponent)) else { return false }
            return data.count == asset["bytes"] as? Int && SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() == asset["sha256"] as? String
        }
        check(approved, "all bundled maps match the sixteen approved texture hashes")
        let shader=bundled.map { FileManager.default.fileExists(atPath:$0.appendingPathComponent("BodyShaders.metal").path) } ?? false
        let credits=Bundle.main.resourceURL.flatMap { try? Data(contentsOf:$0.appendingPathComponent("Credits.rtf")) }
        check(shader && credits?.starts(with:Data("{\\rtf".utf8)) == true, "shader source and About Credits.rtf ship in the app bundle")
        let mockStore=ConversationStore()
        let mockRuntime=MockConversationRuntime(store:mockStore,animatePlayback:false)
        mockRuntime.start()
        check(!mockStore.conversations.isEmpty && mockStore.conversations.allSatisfy { ConversationIdentity.resolved(index:$0.identityIndex,symbol:$0.identitySymbol,tint:$0.identityTint).symbol != "earth" } && mockStore.nextIdentity()>=1_000_000, "the product mock runtime also reserves Earth and enables new body allocation")
        mockRuntime.shutdown()
        do {
            let defaults=FailingDefaults(suiteName:"body-wiring-mock")!
            defaults.memory["state"]=Data("old".utf8)
            do { try CoreDefaultsStorage(defaults).write(Data("new-marker".utf8),key:"state") } catch {}
            check(defaults.memory["state"] == Data("old".utf8), "failed preferences synchronization rolls back the in-memory migration marker")
            let scope = "body-migration-fixture", storage = Storage()
            let earth = Conversation(id: "earth", identityIndex: 2, title: "Keep my title", projectID: nil, updated: Date(), contextUsed: 0)
            let initial = LocalPresentationState(store: ConversationStore(conversations: [earth]), scope: scope, storage: storage, attachmentInputs: CoreMemoryAttachmentInputs())
            try initial.save()
            let key = storage.values.keys.first!
            var old = try JSONSerialization.jsonObject(with: storage.values[key]!) as! [String: Any]
            old.removeValue(forKey: "bodyMigrationVersion")
            var chats = old["chats"] as! [[String: Any]]
            chats[0]["symbol"] = "earth"; chats[0]["tint"] = "ocean"
            old["chats"] = chats
            storage.values[key] = try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys])
            let original = storage.values[key]!
            storage.fails = true; storage.writes = 0
            let failedStore = ConversationStore()
            let failed = LocalPresentationState(store: failedStore, scope: scope, storage: storage, attachmentInputs: CoreMemoryAttachmentInputs())
            failed.restore()
            check(storage.writes == 1 && storage.values[key] == original && failedStore.conversation("earth")?.identitySymbol == "earth", "migration failure preserves the durable snapshot and the in-memory identity")
            let failedSnapshot=try JSONSerialization.jsonObject(with: storage.values[key]!) as! [String: Any]
            check(failed.lastError != nil && failedSnapshot["bodyMigrationVersion"] == nil, "failed migration reports the write error and never marks completion")
            let failedSidebar=NormieSidebarController(model:NormieSidebarModel(store:failedStore,current:"earth")), failedMenu=NSMenu()
            if let c=failedStore.conversation("earth") { failedSidebar.appendIdentityMenu(to:failedMenu,conversation:c) }
            let failedChoices=failedMenu.items.first { $0.title == "Symbol" }?.submenu?.items ?? []
            check(failedChoices.count == 24 && failedChoices.allSatisfy { !$0.isEnabled }, "new body choices stay disabled until the migration transaction commits")
            storage.fails = false; storage.writes = 0
            let restoredStore = ConversationStore()
            let restored = LocalPresentationState(store: restoredStore, scope: scope, storage: storage, attachmentInputs: CoreMemoryAttachmentInputs())
            restored.restore()
            let migrated = restoredStore.conversation("earth")!
            check(storage.writes == 1 && migrated.identitySymbol == "neptune" && migrated.identityTint == "ocean" && migrated.title == "Keep my title", "second restore retries migration, prefers free Neptune and preserves title and color")
            let committed = storage.values[key]!
            check((try JSONSerialization.jsonObject(with: committed) as! [String: Any])["bodyMigrationVersion"] as? Int == 1, "migration version commits with the identities")
            var normalized=try JSONSerialization.jsonObject(with:committed) as! [String:Any]
            normalized.removeValue(forKey:"bodyMigrationVersion")
            var normalizedChats=normalized["chats"] as! [[String:Any]]
            for i in normalizedChats.indices { normalizedChats[i]["symbol"]=chats[i]["symbol"]; normalizedChats[i]["tint"]=chats[i]["tint"] }
            normalized["chats"]=normalizedChats
            let committedVersion=(try JSONSerialization.jsonObject(with:committed) as! [String:Any])["bodyMigrationVersion"] as? Int
            let normalizedData=try JSONSerialization.data(withJSONObject:normalized,options:[.sortedKeys])
            let originalData=try JSONSerialization.data(withJSONObject:old,options:[.sortedKeys])
            check(committedVersion == 1 && normalizedData == originalData, "identity migration preserves every unrelated snapshot field")
            let next=restoredStore.nextIdentity()
            check(next>=1_000_000 && ConversationIdentity.resolved(index:next,symbol:nil,tint:nil).symbol != "earth", "successful migration enables the new stable body allocation")
            storage.writes = 0
            let againStore = ConversationStore()
            let again = LocalPresentationState(store: againStore, scope: scope, storage: storage, attachmentInputs: CoreMemoryAttachmentInputs())
            again.restore(); again.restore()
            check(storage.writes == 0 && storage.values[key] == committed && againStore.conversation("earth")?.identitySymbol == "neptune", "completed migration survives repeated restores without another write")
            var occupied=old
            var other=chats[0]; other["key"]="occupied-neptune"; other["title"]="Other title"; other["identityIndex"]=7; other["symbol"]="neptune"; other["tint"]="indigo"
            occupied["chats"]=[chats[0],other]
            storage.values[key]=try JSONSerialization.data(withJSONObject:occupied)
            let occupiedStore=ConversationStore()
            let occupiedState=LocalPresentationState(store:occupiedStore,scope:scope,storage:storage,attachmentInputs:CoreMemoryAttachmentInputs())
            occupiedState.restore()
            check(occupiedStore.conversation("earth")?.identitySymbol == "mercury" && occupiedStore.conversation("occupied-neptune")?.identitySymbol == "neptune", "occupied Neptune is preserved and Earth takes the first free non-reserved body")
        } catch { check(false, "migration fixture: \(error)") }
        let canvas=Canvas(frame:CGRect(x:0,y:0,width:1000,height:800)); canvas.wantsLayer=true
        func mount(_ orb: OrbComponent, rect: CGRect) {
            canvas.addSubview(orb.backView); canvas.addSubview(orb.glassView); canvas.addSubview(orb.frontView)
            orb.setCanvasSize(canvas.bounds.size); orb.glassView.frame=rect
            orb.glassView.contentView?.frame=orb.glassView.bounds; orb.setFrame(rect)
        }
        let ll=OrbComponent(id:"body-test.ll")
        mount(ll,rect:CGRect(x:80,y:700,width:32,height:32))
        ll.configure(.init(content:.me(initials:"LL",quota:.init(primaryUsed:0.1,secondaryUsed:0.2)),drawingSize:32,ambient:false))
        let orb=OrbComponent(id:"body-test.saturn")
        mount(orb,rect:CGRect(x:400,y:300,width:32,height:32))
        var configuration=OrbConfiguration(content:.identity(.assigned(5)),drawingSize:32,ambient:false)
        orb.configure(configuration)
        for scale: CGFloat in [1,2] {
            configuration.backingScale=scale; orb.configure(configuration)
            let body=bodies(orb.glassView).first, picture=image(body)
            check(body?.value(forKey:"bodyID") as? String == "saturn" && picture?.width == Int(44*scale), "Orb32 displays the Saturn texture at \(Int(scale))x with maximum-drawing headroom")
            var clipped=false
            if let picture,let data=picture.dataProvider?.data,let bytes=CFDataGetBytePtr(data) {
                let side=picture.width, row=picture.bytesPerRow
                clipped=true
                for y in 0..<side { for x in 0..<side {
                    let dx=max(0,abs(Double(x)+0.5-Double(side)/2)-0.5)
                    let dy=max(0,abs(Double(y)+0.5-Double(side)/2)-0.5)
                    if dx*dx+dy*dy>Double(side*side)/4 && bytes[y*row+x*4+3] != 0 { clipped=false }
                }}
            }
            check(body != nil && clipped, "Saturn's body and rings have zero alpha outside the orb circle at \(Int(scale))x")
        }
        let body=bodies(orb.glassView).first
        let changes=body?.value(forKey:"imageChanges") as? Int
        for _ in 0..<100 { configuration.activitySerial &+= 1; orb.configure(configuration); orb.setFrame(CGRect(x:400,y:300,width:32,height:32)) }
        check(body != nil && changes == body?.value(forKey:"imageChanges") as? Int && (body?.animationKeys() ?? []).isEmpty, "repeated events and unchanged layout submit zero body work and install no body animation")
        let expectedAngle=atan2(CGFloat(316-716),CGFloat(96-416))*180/CGFloat.pi
        let expectedBin=(Int(((expectedAngle+360).truncatingRemainder(dividingBy:360))/11.25+0.5))%32
        check(body?.value(forKey:"lightBin") as? Int == expectedBin, "LL and Orb center resolve in the same scene coordinate space")
        orb.setOpacity(0)
        configuration.content = .identity(.assigned(3)); orb.configure(configuration)
        check(body != nil && changes == body?.value(forKey:"imageChanges") as? Int, "hidden identity changes submit no body decode or rendering")
        orb.setOpacity(1)
        check(body?.value(forKey:"bodyID") as? String == "mars", "showing an updated body publishes its current texture")
        let tide=DockTideFace(id:"body-test",glass:NSGlassEffectView(),configuration:configuration)
        mount(tide.orb,rect:CGRect(x:500,y:600,width:36,height:36)); tide.render(rect:CGRect(x:500,y:600,width:36,height:36),opacity:1)
        let tideBody=bodies(tide.orb.glassView).first
        check(tideBody?.value(forKey:"logicalOuter") as? Double == 36 && image(tideBody)?.width == 112, "Tide36 uses its logical diameter and a texture covering its maximum drawing size")
        check(lightingMatches(canvas,faces:tideBody.map { [$0] } ?? []), "Tide36 resolves LL and its actual body center in one coordinate space")
        let header=HeaderIsland(); canvas.addSubview(header)
        header.setFrameOrigin(CGPoint(x:120,y:80))
        for variant: HeaderIslandVariant in [.brief,.full] {
            header.configure(.init(id:"body-test.header",title:"Body",identity:.assigned(5),variant:variant,columnWidth:500,ambient:false))
            let face=bodies(header.orb.glassView).first
            check(face?.value(forKey:"logicalOuter") as? Double == Double(header.geometry.planet.width) && image(face) != nil, "Header \(variant) uses its actual logical outer diameter and texture")
            check(lightingMatches(canvas,faces:face.map { [$0] } ?? []), "Header \(variant) resolves LL after its translated host placement")
        }
        let sheet=SheetCustomizeChat()
        check(sheet.symbolButtons.count == 24 && !sheet.symbolButtons.contains { $0.title == "Earth" }, "all 24 selectable body IDs are exposed and Earth is absent")
        sheet.selectSymbol(.earth)
        check(sheet.draft.symbol != .earth, "programmatic legacy Earth selection is rejected")
        sheet.symbolButtons.first { $0.title == "Sedna" }?.invoke?()
        check(sheet.symbolButtons.first { $0.title == "Sedna" }?.selected == true, "customization accepts a body ID outside the legacy symbol enum")
        let high=OrbComponent(id:"body-test.hd")
        mount(high,rect:CGRect(x:600,y:200,width:64,height:64))
        var highInput=OrbConfiguration(content:.identity(.assigned(5)),drawingSize:64,ambient:false)
        high.configure(highInput); spin(3)
        let highBody=bodies(high.glassView).first
        var hdMeasurement: [String:Any]=[:]
        for key in ["cpuJobs","gpuSubmissions","sharedMapCacheBytes","preparedMapBytes","metalResidentBytes","sharedHDReservedBytes"] { hdMeasurement[key]=highBody?.value(forKey:key) ?? 0 }
        let cpu=layers(high.glassView).first { $0.name == "organic.body.cpu" }
        check(highBody != nil && (highBody?.value(forKey:"cpuJobs") as? Int ?? 0)>0 && image(cpu)?.width == 128 && !cpu!.isHidden, "HD keeps its CPU picture until a GPU drawable actually presents")
        let submitted=[highBody?.value(forKey:"cpuJobs") as? Int ?? -1,highBody?.value(forKey:"gpuSubmissions") as? Int ?? -1]
        for _ in 0..<100 { highInput.activitySerial &+= 1; high.configure(highInput) }
        spin(0.2)
        check(highBody != nil && submitted == [highBody?.value(forKey:"cpuJobs") as? Int ?? -2,highBody?.value(forKey:"gpuSubmissions") as? Int ?? -2], "settled HD and repeated events submit zero CPU and GPU work")
        high.setOpacity(0); highInput.content = .identity(.assigned(3)); high.configure(highInput); spin(0.2)
        check(highBody != nil && highBody!.isHidden && submitted == [highBody?.value(forKey:"cpuJobs") as? Int ?? -2,highBody?.value(forKey:"gpuSubmissions") as? Int ?? -2], "hidden HD identity changes submit no CPU or GPU work")
        high.dispose()
        let ids=["mercury","venus","mars","jupiter","saturn","uranus","neptune","pluto","ceres","pallas","juno","vesta","astraea","hygiea","chiron","pholus","nessus","orcus","haumea","quaoar","makemake","gonggong","eris","sedna"]
        let before=footprint()
        var faces: [OrbComponent]=[]
        for (i,id) in ids.enumerated() {
            let c=Conversation(id:"face-\(id)",identityIndex:0,title:id,projectID:nil,updated:Date(),contextUsed:0); c.identitySymbol=id
            let face=OrbComponent(id:c.id)
            mount(face,rect:CGRect(x:CGFloat(i%8)*44+100,y:CGFloat(i/8)*44+80,width:32,height:32))
            face.configure(makeOrbConfiguration(c,drawingSize:32,backingScale:2,reduceMotion:false,ambient:false,isKeyWindow:true))
            faces.append(face)
        }
        let after=footprint(), pictures=faces.compactMap { bodies($0.glassView).first }.compactMap(image)
        let delta=Int64(after)-Int64(before)
        measurements=["scope":"24 detached product Orb32 faces; not whole-App steady/peak or WindowServer", "footprintBefore":before,"footprintAfter":after,"footprintDelta":delta,"displayedDecodedBytes":pictures.reduce(0) { $0+$1.bytesPerRow*$1.height },"spriteCacheBytes":faces.last.flatMap { bodies($0.glassView).first?.value(forKey:"sharedSpriteBytes") } ?? 0,"spriteCachePeakBytes":faces.last.flatMap { bodies($0.glassView).first?.value(forKey:"sharedSpritePeakBytes") } ?? 0,"hd":hdMeasurement]
        check(pictures.count == 24 && zip(faces,ids).allSatisfy { bodies($0.0.glassView).first?.value(forKey:"bodyID") as? String == $0.1 }, "all 24 body IDs display their own texture through the production adapter")
        check(pictures.count == 24 && before>0 && after>0 && delta<=96*1024*1024, "24 visible detached faces stay within the 96 MiB additional steady-memory budget")
        for face in faces { face.dispose() }; faces=[]
        let store=ConversationStore()
        let replay=MockReplay(store:store); replay.start(live:false)
        for c in store.conversations { c.identitySymbol="saturn" }
        let sidebar=NormieSidebarController(model:NormieSidebarModel(store:store,current:"A")), sidebarMenu=NSMenu()
        if let c=store.conversation("A") { sidebar.appendIdentityMenu(to:sidebarMenu,conversation:c) }
        let sidebarChoices=sidebarMenu.items.first { $0.title == "Symbol" }?.submenu?.items ?? []
        check(sidebarChoices.count == 24 && !sidebarChoices.contains { $0.title == "Earth" } && sidebarChoices.allSatisfy { $0.image != nil && !$0.image!.isTemplate }, "Normie identity menus accept all body IDs with raster faces and exclude Earth")
        let profile=DisplayProfile(name:"body-wiring",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0)
        let scene=AutoScene(size:CGSize(width:1440,height:900),store:store,profile:profile,scale:2)
        let sceneCanvas=Canvas(frame:CGRect(x:0,y:0,width:1440,height:900)); sceneCanvas.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] as [NSView] { plane.frame=sceneCanvas.bounds; sceneCanvas.addSubview(plane) }
        scene.manualSettle=true; scene.ambient=false; scene.install(members:MockSeed.windowMembers); scene.settle(); scene.clock.invalidate()
        let dockBodies=bodies(scene.dockView).filter { image($0) != nil && !$0.isHidden }
        check(dockBodies.contains { $0.value(forKey:"logicalOuter") as? Double == 32 && $0.value(forKey:"bodyID") as? String == "saturn" }, "the actual Dock32 host displays textured bodies")
        check(lightingMatches(sceneCanvas,faces:dockBodies), "Dock32 uses the actual LL anchor in the common scene coordinates")
        if let target=scene.dock.restingTargets.first(where: { !$0.bar }) {
            scene.setPeeking(target.id); scene.settle(); scene.clock.invalidate()
            let peekBodies=bodies(scene.peekNode.view)
            check(peekBodies.contains { image($0) != nil && $0.value(forKey:"bodyID") as? String == "saturn" }, "the passive Peek header keeps its textured body while interaction is inactive")
            check(lightingMatches(sceneCanvas,faces:peekBodies.filter { image($0) != nil }), "Peek resolves LL after moving its passive header host")
            let menu=scene.contextMenu(at:CGPoint(x:target.rect.midX,y:target.rect.midY))
            let symbols=menu?.items.first { $0.title == "Symbol" }?.submenu?.items ?? []
            check(symbols.count == 24 && !symbols.contains { $0.title == "Earth" } && symbols.allSatisfy { $0.image != nil && !$0.image!.isTemplate }, "Dock identity menus contain 24 raster faces and exclude Earth")
        } else { check(false,"the passive Peek header keeps its textured body while interaction is inactive"); check(false,"Peek resolves LL after moving its passive header host"); check(false,"Dock identity menus contain 24 raster faces and exclude Earth") }
        let members=MockSeed.windowMembers.compactMap(store.conversation)
        if let first=members.first {
            let collapse=CollapseStrip(store:store,sessions:scene.composers,members:members,shown:first.id,scale:2)
            collapse.frame=CGRect(x:0,y:0,width:400,height:900); collapse.layout()
            check(bodies(collapse).contains { image($0) != nil && $0.value(forKey:"logicalOuter") as? Double == 36 }, "the actual Collapse36 rail displays textured bodies")
            check(lightingMatches(collapse,faces:bodies(collapse).filter { image($0) != nil }), "Collapse rail and header share the strip's LL coordinate space")
            collapse.dispose()
        }
        scene.disposeTranscriptPresentation(); scene.clock.invalidate(); replay.stopPlayback()
        header.dispose(); tide.dispose(); orb.dispose(); ll.dispose()
        let result: [String: Any] = ["checks": checks, "failures": failures,"measurements":measurements]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("wiring.json"))
        print("Body wiring: \(checks) checks, \(failures.count) failures")
        return failures.isEmpty ? 0 : 1
    }
}
