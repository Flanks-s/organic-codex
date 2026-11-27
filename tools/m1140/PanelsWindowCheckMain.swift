import AppKit
import QuartzCore
import ImageIO
import CryptoKit

@MainActor final class FunctionPanelWindowFixture {
    let data: FunctionPanelCRecordedData
    let root: FunctionPanelPlane
    let window: NSWindow
    let transcript: NativeTranscript
    let composer: NativeComposer
    let header = HeaderIsland()
    let resources = BodyResources()
    var current: Conversation?
    var callback: (() -> Void)?
    var retiredCallbacks: [() -> Void] = []
    var reads = 0
    var subscriptions = 0
    var scale: Int
    var reduced: Bool
    var visible = true
    var paused = false
    var owner: FunctionPanelWindowOwner!
    init(scale: Int, reduced: Bool) {
        let data = FunctionPanelCRecordedData()
        let root = FunctionPanelPlane(frame: CGRect(x: 0, y: 0, width: 960, height: 852))
        self.data = data
        self.root = root
        self.scale = scale
        self.reduced = reduced
        current = data.conversation
        data.conversation.identitySymbol = "earth"
        transcript = NativeTranscript(conversation: data.conversation, store: data.store)
        composer = NativeComposer(conversation: data.conversation, store: data.store)
        window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.addSubview(transcript)
        root.addSubview(composer)
        root.addSubview(header)
        transcript.frame = CGRect(x: 360, y: 80, width: 300, height: 540)
        composer.frame = CGRect(x: 360, y: 650, width: 300, height: 170)
        header.configure(.init(id: "neighbour", title: "Neighbour", columnWidth: 300, band: 44,
                               reduceMotion: true, ambient: false, scale: CGFloat(scale)))
        header.frame.origin = CGPoint(x: 360, y: 32)
        for surface in [transcript as NativeInteractionSurface, composer] {
            surface.verificationWindowVisible = true
        }
        root.layoutSubtreeIfNeeded()
        let access = FunctionPanelColumnAccess(views: { [unowned self] in [transcript, composer, header] },
            isPaused: { [unowned self] in paused }, suspend: { [unowned self] in suspend() },
            admitsFocus: { [unowned self] view in !paused && NativeInteractionSurface.permits(view) })
        owner = FunctionPanelWindowOwner(window: window, store: data.store, resources: resources,
            current: { [unowned self] in current }, connected: { true }, commands: { _ in .init() },
            read: { [unowned self] _, _ in
                reads += 1
                return data.sources
            }, observe: { [unowned self] _, _, receive in
                subscriptions += 1
                callback = receive
                retiredCallbacks.append(receive)
                return { [weak self] in
                    self?.subscriptions -= 1
                    self?.callback = nil
                }
            }, environment: { [unowned self] in
                .init(viewport: CGRect(x: 0, y: 32, width: 960, height: 820),
                      column: CGRect(x: 0, y: 32, width: 360, height: 820),
                      visible: visible, scale: self.scale, reduced: self.reduced)
            }, columns: access, actions: { _ in })
    }
    func suspend() -> () -> Void {
        let surfaces: [NativeInteractionSurface] = [transcript, composer]
        let clips = surfaces.map(\.presentationClip)
        let active = surfaces.map(\.presentationActive)
        paused = true
        for surface in surfaces {
            surface.presentationClip = .zero
            surface.presentationActive = false
            surface.invalidateAccessibilityLease()
        }
        header.setPresentationActive(false)
        return { [unowned self] in
            for (index, surface) in surfaces.enumerated() {
                surface.presentationClip = clips[index]
                surface.presentationActive = active[index]
            }
            header.setPresentationActive(true)
            paused = false
        }
    }
    func dispose() {
        owner.retire()
        header.dispose()
        transcript.dispose()
        window.close()
    }
}

@main @MainActor enum FunctionPanelWindowCheck {
    static var checks = 0
    static var failures: [String] = []
    static var frames: [String] = []
    static func check(_ value: Bool, _ category: String, line: Int = #line) {
        checks += 1
        if !value { failures.append(category) }
        if !value {
            print("FAIL \(category) at line \(line)")
        }
    }
    static func wait(_ predicate: () -> Bool) async {
        let deadline = CACurrentMediaTime() + 12
        while !predicate() && CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    static func event(_ type: NSEvent.EventType, _ fixture: FunctionPanelWindowFixture,
                      at point: CGPoint = .zero) -> NSEvent {
        if type == .scrollWheel {
            return NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                           wheelCount: 1, wheel1: 8, wheel2: 0, wheel3: 0)!)!
        }
        if type == .keyDown {
            return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: fixture.window.windowNumber, context: nil, characters: "\t",
                charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        }
        let location = fixture.owner!.host.convert(point, to: nil)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 1,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
    }
    static func capture(_ f: FunctionPanelWindowFixture, scale: Int, reduced: Bool, named: String? = nil) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960 * scale, pixelsHigh: 852 * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = f.root.bounds.size
        f.root.cacheDisplay(in: f.root.bounds, to: rep)
        let out = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("frames")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let name = named ?? "popup-\(scale)x-\(reduced ? "reduced" : "standard").png"
        let data = rep.representation(using: .png, properties: [:])
        do {
            try data?.write(to: out.appendingPathComponent(name))
            check(data != nil, "window.frames")
            frames.append(name)
        } catch { check(false, "window.frames") }
    }
    static func run(scale: Int, reduced: Bool) async {
        let f = FunctionPanelWindowFixture(scale: scale, reduced: reduced)
        defer { f.dispose() }
        let owner = f.owner!
        check(owner.stage == nil && owner.body == nil && f.reads == 0, "window.dormant")
        check(f.subscriptions == 0 && f.resources.hdReservedBytes == 0, "window.dormant")
        f.window.makeFirstResponder(f.composer.textView)
        let original = f.window.firstResponder
        let cached = f.composer.proxy(f.composer.textView, parent: f.composer)
        check(cached != nil && !f.transcript.screenClip.isEmpty, "window.fixture")
        check(f.header.titleButton.acceptsFirstResponder, "window.fixture")
        let originalClip = CGRect(x: 0, y: 0, width: 299, height: 170)
        f.composer.presentationClip = originalClip
        owner.present()
        let stage = owner.stage!
        for point in [CGPoint(x: 390, y: 100), CGPoint(x: 640, y: 100)] {
            let target = owner.host.hitTest(owner.host.convert(point, to: owner.host.superview))
            check(target === owner.host || target?.isDescendant(of: stage) == true, "window.pause")
        }
        let coveredPoint = CGPoint(x: 390, y: 100)
        let click = event(.leftMouseDown, f, at: coveredPoint)
        if owner.host.route(click, at: coveredPoint) != nil {
            let hitPoint = owner.host.convert(coveredPoint, to: owner.host.superview)
            owner.host.hitTest(hitPoint)?.mouseDown(with: click)
        }
        check(owner.body?.resources === f.resources, "window.resources")
        check(abs(stage.motion.began - CACurrentMediaTime()) < 1, "window.clock")
        check(!reduced || !stage.hasTimer, "window.tick")
        check(f.subscriptions == 1 && f.paused, "window.pause")
        for surface in [f.transcript as NativeInteractionSurface, f.composer] {
            check(surface.effectiveInteractionClip.isEmpty, "window.pause")
            check(surface.accessibilityChildren()?.isEmpty == true, "window.pause")
            let point = f.window.convertPoint(toScreen: surface.convert(CGPoint(x: 1, y: 1), to: nil))
            check(surface.accessibilityHitTest(point) == nil, "window.pause")
        }
        check(cached == nil || cached!.accessibilityFrame().isEmpty, "window.pause")
        check(!f.header.titleButton.acceptsFirstResponder, "window.pause")
        check(!f.header.titleButton.accessibilityPerformPress(), "window.pause")
        check(f.header.isAccessibilityHidden(), "window.pause")
        let draft = f.composer.textView.string
        cached?.setAccessibilityValue("blocked")
        for point in [CGPoint(x: 390, y: 100), CGPoint(x: 640, y: 100), CGPoint(x: 400, y: 800)] {
            for kind: NSEvent.EventType in [.mouseMoved, .scrollWheel, .leftMouseDragged] {
                check(owner.host.route(event(kind, f), at: point) == nil, "window.pause")
                let hit = owner.host.hitTest(owner.host.convert(point, to: owner.host.superview))
                check(hit === owner.host || hit?.isDescendant(of: stage) == true, "window.pause")
            }
            let screen = f.window.convertPoint(toScreen: owner.host.convert(point, to: nil))
            let hit = owner.host.accessibilityHitTest(screen) as? NSView
            check(hit === stage, "window.pause")
        }
        for _ in 0..<40 {
            _ = owner.host.route(event(.keyDown, f))
            let focused = f.window.firstResponder as? NSView
            check(focused?.isDescendant(of: stage) == true, "window.pause")
        }
        check(f.composer.textView.string == draft, "window.pause")
        stage.selectPage(.files)
        let selected = stage.state.fileID
        let reads = f.reads
        f.data.sources.revision += 1
        f.callback?()
        check(stage.state.page == .files && stage.state.fileID == selected, "window.incremental")
        check(f.reads == reads + 1, "window.incremental")
        await wait { !stage.hasTimer && owner.body?.currentPicture?.quality == .panelHD }
        check(!stage.hasTimer && !stage.needsFrames, "window.tick")
        let builds = owner.source.projection.builds
        try? await Task.sleep(for: .milliseconds(50))
        check(owner.source.projection.builds == builds, "window.incremental")
        guard let body = owner.body else {
            check(false, "window.hd")
            return
        }
        check(body.currentPicture?.quality == .panelHD, "window.hd")
        check(body.currentPicture?.image.width == 150 * scale, "window.hd")
        check(body.currentPicture?.event == owner.snapshot?.phase.value?.event, "window.hd")
        if !CommandLine.arguments.contains("--no-frames") { capture(f, scale: scale, reduced: reduced) }
        let staleImage = stage.bodySnapshot
        let staleCallback = body.receive
        owner.dismiss(animated: false)
        let closeBegan = CACurrentMediaTime()
        await wait { !body.hasPendingWork && f.resources.hdReservedBytes == 0 }
        let closeMS = (CACurrentMediaTime() - closeBegan) * 1000
        print("CLOSE_WAIT scale=\(scale) reduced=\(reduced) ms=\(closeMS)")
        if body.hasPendingWork || f.resources.hdReservedBytes != 0 {
            print("FAIL window.close timeout after \(closeMS) ms")
        }
        check(body.pendingImages == 0 && body.phaseWork["pending", default: 0] == 0, "window.close")
        check(!body.hasPendingWork && !stage.hasTimer && f.resources.hdReservedBytes == 0, "window.close")
        check(!f.paused && f.composer.presentationClip == originalClip, "window.restore")
        check(f.window.firstResponder === original, "window.restore")
        check(f.subscriptions == 0 && owner.stage == nil, "window.close")
        body.close()
        let replacement = FunctionPanelCRecordedData()
        replacement.conversation.identitySymbol = "mars"
        f.current = replacement.conversation
        owner.present()
        let next = owner.stage!
        let before = next.bodySnapshot
        staleCallback(staleImage)
        check(next.bodySnapshot.planet?.bodyID == before.planet?.bodyID, "window.stale")
        let oldReads = f.reads
        for callback in f.retiredCallbacks.dropLast() { callback() }
        check(f.reads == oldReads, "window.stale")
        let outside = CGPoint(x: 640, y: 100)
        _ = owner.host.route(event(.leftMouseDown, f), at: outside)
        check(!owner.isOpen, "window.outside-dismiss")
        await wait { owner.stage == nil }
        check(!f.paused, "window.restore")
        if scale == 2 && reduced {
            await wait { f.resources.hdReservedBytes == 0 }
            guard let held = f.resources.reserveHD(bytes: 16 * 1024 * 1024) else {
                check(false, "window.resources")
                return
            }
            owner.present()
            await wait { owner.body?.currentPicture != nil }
            check(owner.stage?.bodySnapshot.phaseLoading == .budgetRefused, "window.resources")
            check(owner.body?.currentPicture?.quality == .preview, "window.resources")
            owner.dismiss(animated: false)
            f.resources.releaseHD(held)
        }
        for change in 0..<3 {
            owner.present()
            let retiring = owner.body!
            if change == 0 { f.scale = scale == 1 ? 2 : 1 }
            if change == 1 { f.visible = false }
            if change == 2 { f.current = Conversation(id: "replaced", title: "Replaced") }
            owner.synchronize()
            await wait { !retiring.hasPendingWork && f.resources.hdReservedBytes == 0 }
            check(!owner.isOpen && owner.stage == nil && f.subscriptions == 0, "window.close")
            check(f.resources.hdReservedBytes == 0, "window.close")
            f.visible = true
        }
        f.current = f.data.conversation
        f.window.makeFirstResponder(f.composer.textView)
        owner.present()
        f.composer.textView.removeFromSuperview()
        owner.dismiss(animated: false)
        check(f.window.firstResponder !== f.composer.textView, "window.restore")
    }
    static func artifacts() async {
        let f = FunctionPanelWindowFixture(scale: 2, reduced: true), wire = CoreControllerFixture()
        let runtime = MockConversationRuntime(store: f.data.store, animatePlayback: false)
        let tools = CoreArtifactsController(storage: CoreMemoryStorage())
        defer { f.dispose() }
        tools.configure(client: wire.transport, runtime: runtime, endpoint: "test")
        let content = wire.content["text"]!
        let sha = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let note: JSONValue = ["id": "text", "threadId": "t1", "sha256": .string(sha), "mimeType": "text/plain",
                               "path": "/fixture/Notes.md", "sourcePath": "fixture.swift"]
        wire.artifacts = [note, wire.artifacts[1], ["id": "mapped"], ["id": "unassigned"]]
        var endpoint = "test", connected = true
        let failure = CoreError(code: 409, message: "Recorded conflict", data: ["source": "fixture"], httpStatus: 409)
        wire.before = { request in
            if request.path == "/preview/artifacts?threadId=empty" { return [] }
            if request.path == "/preview/artifacts?threadId=failed" { throw failure }
            guard request.path == "/preview/content?id=text" else { return nil }
            try? await Task.sleep(for: .milliseconds(250))
            let payload = ["dataBase64": JSONValue.string(content.base64EncodedString())]
            return .object(note.objectValue!.merging(payload) { _, value in value })
        }
        wire.annotations = [["artifactId": "text", "id": "kept-note", "text": "Kept annotation"]]
        tools.reconcileArtifactList(wire.artifacts)
        tools.select("text")
        await wait { tools.selectedData != nil }
        tools.comment = "keep draft"
        tools.quote = "keep quote"
        tools.page = 7
        tools.region = ["x": 1]
        tools.error = "keep error"
        let scope = CoreArtifactsController.ArtifactScope(thread: "t1", endpoint: "test", mapped: [])
        let empty = await tools.readArtifacts(.init(thread: "empty", endpoint: scope.endpoint, mapped: []))
        let isEmpty = if case .empty = empty { true } else { false }
        check(isEmpty, "artifact.empty")
        let refused = await tools.readArtifacts(.init(thread: "failed", endpoint: scope.endpoint, mapped: []))
        check(refused.failure as? CoreError == failure, "artifact.error")
        for (key, value) in [("sha256", JSONValue.string("stale")), ("bytes", .number(33 * 1_048_576))] {
            let raw = JSONValue.object(note.objectValue!.merging([key: value]) { _, new in new })
            let before = wire.requests.count
            let result = await tools.readArtifact(.init(scope: scope, artifact: .init(raw: raw)))
            let message = key == "bytes" ? "32 MiB" : "version changed"
            check(result.failure?.localizedDescription.contains(message) == true, "artifact.read")
            check(wire.requests.count - before == (key == "bytes" ? 0 : 1), "artifact.request")
        }
        let cancelStart = wire.requests.count
        let cancelled = Task { await tools.readArtifact(.init(scope: scope, artifact: .init(raw: note))) }
        await wait { wire.requests.count > cancelStart }
        cancelled.cancel()
        let cancellation = await cancelled.value
        check(cancellation.failure is CancellationError && wire.requests.count == cancelStart + 1, "artifact.cancel")
        for mime in ["text/plain", "image/png"] {
            check((try? FunctionPanelArtifactPreview.decode(Data([255]), mime: mime)) == nil, "artifact.decode")
        }
        let requestStart = wire.requests.count
        let previews = FunctionPanelArtifactPreviewOwner(controller: tools, endpoint: { endpoint },
            current: { [weak f] in f?.current }, connected: { connected })
        f.data.sources.artifactThreads = ["mapped": "t1", "image": "t1", "unassigned": "other"]
        f.data.sources.outputArtifactIDs = ["text"]
        f.owner.source.artifacts = previews
        f.owner.present(page: .library)
        let stage = f.owner.stage!
        stage.onAction = { [unowned stage] action in _ = previews.submit(action, input: stage.input) }
        stage.onPresentation = { [weak stage, onPresentation = stage.onPresentation] progress in
            onPresentation?(progress)
            if let stage { previews.show(stage.visibleArtifactIDs) }
        }
        await wait { previews.previews["text"]?.value != nil }
        check(previews.listing.value?.map(\.id) == ["text", "mapped"], "artifact.thread")
        check(stage.input.covers.value?.first?.metadata == .unavailable, "artifact.bytes")
        check(previews.previews["text"]?.value == .text(String(decoding: content, as: UTF8.self)), "artifact.read")
        check(wire.requests.dropFirst(requestStart).map(\.path) == ["/preview/artifacts",
              "/preview/content?id=text"], "artifact.request")
        tools.setLocalPathsAvailable(true)
        var opens: [String] = [], copies: [Bool] = []
        previews.open = { [weak stage] url in
            opens.append(url.path)
            if stage?.state.page == .library { throw CoreWire.failure("Open sink rejected") }
        }
        previews.copy = { [weak stage] data, mime in
            copies.append(data == content && mime == "text/plain")
            if stage?.state.page == .library { throw CoreWire.failure("Copy sink rejected") }
        }
        f.callback?()
        let entries: [(FunctionPanelPage, [String])] = [(.library, ["cover.open", "cover.copy"]),
            (.files, ["file.open"]), (.outputs, ["output.open", "output.copy"])]
        for (page, ids) in entries {
            stage.selectPage(page)
            let reject = page == .library
            if reject { stage.interact { $0.coverID = "text" } }
            for id in ids {
                await wait { stage.buttonFrame(id) != nil }
                check(stage.buttons[id]?.accessibilityPerformPress() == true, "artifact.entry")
                let receipt = id.hasSuffix(".open") ? (reject ? "Open sink rejected" : "Opened artifact") :
                    (reject ? "Copy sink rejected" : "Copied artifact")
                await wait { stage.renderedTexts.contains(receipt) }
                check(stage.renderedTexts.contains(receipt), "artifact.feedback")
            }
            if !CommandLine.arguments.contains("--no-frames") {
                capture(f, scale: 2, reduced: true, named: page.rawValue + ".png")
            }
        }
        let requests = wire.requests.count
        connected = false
        _ = previews.submit(.openCover("text"), input: stage.input)
        check(stage.renderedTexts.contains { $0.hasPrefix("Disconnected") }, "artifact.feedback")
        connected = true
        previews.copy = nil
        _ = previews.submit(.copyCover("text"), input: stage.input)
        check(stage.renderedTexts.contains("Copy is no longer available."), "artifact.feedback")
        check(opens == Array(repeating: "/fixture/Notes.md", count: 3) && copies == [true, true] &&
              wire.requests.count == requests && stage.buttonFrame("output.copy") == nil, "artifact.withdrawn")
        check(tools.selectedID == "text" && tools.selectedData == content &&
              tools.annotations == wire.annotations && tools.region == ["x": 1] && tools.page == 7 &&
              tools.comment == "keep draft" && tools.quote == "keep quote" && !tools.busy &&
              tools.error == "keep error", "artifact.selection")
        previews.show([])
        previews.show(["text"])
        await wait { wire.requests.count == requests + 1 }
        endpoint = "replacement"
        try? await Task.sleep(for: .milliseconds(300))
        check(previews.previews["text"] == .loading && wire.requests.count == requests + 1, "artifact.late")
        _ = previews.submit(.openCover("text"), input: stage.input)
        check(stage.renderedTexts.contains("The conversation or artifact source changed."), "artifact.feedback")
        endpoint = "test"
        let bitmap = CGContext(data: nil, width: 8192, height: 8192, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.drawLinearGradient(CGGradient(colorsSpace: bitmap.colorSpace!,
            colors: [NSColor.black.cgColor, NSColor.white.cgColor] as CFArray, locations: nil)!,
            start: .zero, end: CGPoint(x: 8192, y: 8192), options: [])
        let png = NSBitmapImageRep(cgImage: bitmap.makeImage()!).representation(using: .png, properties: [:])!
        let imageSHA = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let image: JSONValue = ["id": "text", "threadId": "t1", "sha256": .string(imageSHA), "mimeType": "image/png"]
        wire.artifacts = [image]
        wire.before = { r in r.path == "/preview/content?id=text" ?
           .object(image.objectValue!.merging(["dataBase64": .string(png.base64EncodedString())]) { _, v in v }) : nil }
        previews.load(f.data.conversation, page: .library, mapped: [:])
        await wait { previews.listing.value != nil }
        let start = CACurrentMediaTime()
        _ = try? FunctionPanelArtifactPreview.decode(png, mime: "image/png")
        let elapsed = CACurrentMediaTime() - start
        var last = CACurrentMediaTime(), gap = 0.0
        previews.show(["text"])
        await wait {
            let now = CACurrentMediaTime()
            gap = max(gap, now - last)
            last = now
            return previews.previews["text"]?.value != nil
        }
        print("E1A T=\(elapsed) G=\(gap) state=\(String(describing: previews.previews["text"]))")
        check(previews.previews["text"]?.value != nil && gap < 0.5 * elapsed, "e1a.decode-off-main")
        previews.show([])
        previews.show(["text"])
        connected = false
        func jobs() -> Int { (Mirror(reflecting: previews).descendant("jobs") as? [String: Any])?.count ?? -1 }
        await wait { jobs() == 0 }
        check(jobs() == 0, "e1a.rejected-job")
        connected = true
    }
    static func modelSelection() {
        let f = FunctionPanelWindowFixture(scale: 2, reduced: true), target = f.data.conversation
        defer { f.dispose() }
        let composer = NativeComposer(conversation: target, store: f.data.store)
        composer.verificationWindowVisible = true
        composer.frame = CGRect(x: 0, y: 756, width: 760, height: 48)
        composer.targetWidth = 760
        f.root.addSubview(composer, positioned: .below, relativeTo: f.owner.host)
        composer.layoutSubtreeIfNeeded()
        let binding = OverlayComposerBinding(composer: composer, host: f.root, clock: OverlayManualClock())
        let picker = binding.modelPicker, before = target.next, current = target.settings
        let otherSettings = f.data.store.conversations.filter { $0 !== target }.map(\.next)
        var eligible = true, result: CoreSubmissionResult?
        f.owner.present()
        let opened = binding.presentModelPicker(for: target, qualify: { eligible }) { result = $0 }
        check(f.owner.isOpen && opened && picker.isShowing && target.next == before, "model.next")
        let choices = ModelCatalog.models.filter { picker.available($0) && $0.id != before.modelID }
        guard let selected = choices.first, let rejected = choices.dropFirst().first else {
            return check(false, "model.next")
        }
        check(picker.selectModel(selected.id) && target.next == picker.settings && result == .accepted, "model.next")
        check(target.next.modelID == selected.id && target.settings == current, "model.next")
        eligible = false
        check(picker.selectModel(rejected.id) && target.next.modelID == selected.id, "model.next")
        check(f.data.store.conversations.filter { $0 !== target }.map(\.next) == otherSettings, "model.next")
        picker.dismiss()
        (picker.clock as! OverlayManualClock).advance(by: 1)
        for reason: OverlayDismissReason in [.escape, .outside, .programmatic] {
            var token: NSObject? = NSObject()
            weak var sentinel = token
            result = nil
            let opened = binding.presentModelPicker(for: target, qualify: { true }) { [held = token!] value in
                result = held === held ? value : nil
            }
            token = nil
            if reason == .programmatic { binding.disconnect() } else { picker.dismiss(reason: reason) }
            let released = sentinel == nil, settings = composer.settings
            let selected = picker.selectModel(rejected.id)
            check(opened && released && selected && composer.settings == settings && result == nil, "e1a.picker-revoke")
            (picker.clock as! OverlayManualClock).advance(by: 1)
        }
    }
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        if CommandLine.arguments.contains("--artifacts") { await artifacts() }
        if CommandLine.arguments.contains("--model") { modelSelection() }
        for scale in [1, 2] where !CommandLine.arguments.contains("--artifacts") {
            for reduced in [false, true] { await run(scale: scale, reduced: reduced) }
        }
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        check(!NSApp.windows.contains(where: \.isVisible), "window.offscreen")
        let report: [String: Any] = ["checks": checks, "failures": failures,
                                    "frames": frames,
                                    "visibleWindows": NSApp.windows.filter(\.isVisible).count]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: out.appendingPathComponent("report.json"))
        print(String(data: bytes, encoding: .utf8)!)
        exit(failures.isEmpty ? 0 : 1)
    }
}
