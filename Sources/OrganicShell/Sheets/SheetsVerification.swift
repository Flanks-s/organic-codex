#if SHEETS_SELFTEST
import AppKit
import ObjectiveC

@MainActor private final class SheetTestWindow: SheetWindowHandle {
    let host: NSView
    var title: String
    var presentations: [CGPoint?] = []
    var dismissals = 0
    let onClose: @MainActor () -> Void
    init(_ configuration: SheetWindowConfiguration, _ onClose: @escaping @MainActor () -> Void) {
        host = OverlayView(frame: CGRect(origin: .zero, size: configuration.size)); title = configuration.title; self.onClose = onClose
    }
    func present(at point: CGPoint?) { presentations.append(point) }
    func presentSheet(for parent: NSWindow) { presentations.append(nil) }
    func dismiss() { dismissals += 1; onClose() }
}

@main @MainActor enum SheetsVerification {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/sol-sheets-m4-results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks = 0, findings: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ name: String) { checks += 1; if !value() { findings.append(name) } }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func pixels(_ image: CGImage) -> [UInt8] {
            let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        func render(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded()
            for scale in [CGFloat(1), 2] {
                let image = (view as? SheetSurface)?.snapshot(scale: scale) ?? VerificationRaster.capture(view, scale: scale), rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name)-\(Int(scale))x.png"))
                check(image.width == Int(view.bounds.width * scale) && image.height == Int(view.bounds.height * scale), "\(name) \(Int(scale))x backing dimensions")
                let original = pixels(image)
                check(stride(from: 3, to: original.count, by: 4).contains { original[$0] > 0 }, "\(name) \(Int(scale))x has visible native content")
                check(original == pixels(VerificationRaster.capture(view, scale: scale)), "\(name) \(Int(scale))x repeated cache is byte-identical")
            }
            let views = [view] + descendants(view), draw = #selector(NSView.draw(_:))
            let text = views.filter { $0 is NSTextField || $0 is NSButton || $0 is NSTextView }
            check(text.allSatisfy { v in
                let base: AnyClass = v is NSButton ? NSButton.self : v is NSSecureTextField ? NSSecureTextField.self : v is NSTextField ? NSTextField.self : NSTextView.self
                guard let own = class_getInstanceMethod(type(of: v), draw), let original = class_getInstanceMethod(base, draw) else { return false }
                return method_getImplementation(own) != method_getImplementation(original)
            }, "\(name) every text control overrides draw")
            check(text.allSatisfy { v in if let field = v as? NSTextField { return !field.isBordered && !field.isBezeled }; if let button = v as? NSButton { return !button.isBordered }; return true }, "\(name) no system text-control bezel")
            check((text + views.filter { $0 is SheetButton }).allSatisfy { v in [v.frame.minX, v.frame.minY, v.frame.width, v.frame.height].allSatisfy { abs($0 - $0.rounded()) < 1e-8 } }, "\(name) all text/button geometry on the 1x and 2x grid")
        }

        let host = OverlayView(frame: CGRect(x: 0, y: 0, width: 760, height: 820)), clock = OverlayManualClock()
        let anchor = CGRect(x: 360, y: 740, width: 28, height: 28)
        let parent = Conversation(id: "parent-a", title: "Fix sidebar spacing")
        parent.identityIndex = 2; parent.contextUsed = 0.34
        parent.satellites = [
            .init(id: "r0", face: "•ᴗ•", title: "Searching for rowInsets across native/"),
            .init(id: "d0", face: "-_-", done: true, finishedOrder: 0),
            .init(id: "r1", face: "•ᴗ•", title: "Running the narrow layout checks"),
            .init(id: "d1", face: "-_-", done: true, finishedOrder: 2),
            .init(id: "d2", face: "-_-", done: true, finishedOrder: 1)
        ]
        let agents = SheetSubAgents(clock: clock)
        var selected: [String] = [], opened: [String] = [], agentDismissals: [SheetDismissReason] = []
        agents.onSelect = { selected.append($0) }; agents.onOpenWindow = { id, c in if c === parent { opened.append(id) } }; agents.onDismiss = { agentDismissals.append($0) }
        agents.present(conversation: parent, anchor: anchor, upward: true, in: host, select: "r1")
        check(agents.orderedIDs == ["r0", "r1", "d1", "d2", "d0"], "Running remains in start order; done is latest-finished-first")
        check(agents.selectedID == "r1" && agents.card.frame.maxY == anchor.minY - 10, "Selected ID and upward anchor gap")
        let bud=agents.budMotion.plan
        check(bud?.spring.response == 0.38 && bud?.spring.damping == 0.78,"Actual bud keeps response .38/damping .78")
        let nativeGlass = descendants(agents.card).first { $0 is NSGlassEffectView }
        agents.budMotion.sample(elapsed:0,profile:DisplayProfile(name:"Dell",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0))
        check(abs((nativeGlass?.frame.width ?? 0)-agents.card.bounds.width*0.86)<=1,"M9 whole sheet glass actually buds from .86")
        check(nativeGlass?.layer?.animation(forKey:"sheets.bud.transform.scale") == nil && nativeGlass.map{CATransform3DIsIdentity($0.layer?.transform ?? CATransform3DIdentity)} == true,"Glass grows through real frames, never a scale transform")
        agents.budMotion.stop(reset:true)
        let workingDots = SheetActivityDots(frame:CGRect(x:0,y:0,width:12,height:12))
        check(workingDots.subviews.allSatisfy { $0.layer?.animationKeys()?.isEmpty != false } && workingDots.layer?.animationKeys()?.isEmpty != false, "M11.47 sheet working dots have no ambient clock")
        check(agents.handleKey(.down) && agents.selectedID == "d1" && selected.last == "d1", "Down follows grouped visual order")
        check(agents.handleKey(.up) && agents.selectedID == "r1", "Up follows grouped visual order")
        check(!agents.select("missing"), "Unknown subagent ID cannot select or open")
        try render(agents, "subagents")
        check(agents.handleKey(.enter) && opened == ["r1"] && agents.isDismissing, "Return opens the selected stable ID once")
        _ = agents.handleKey(.enter); check(opened.count == 1, "Closing rows cannot open a second window")
        clock.advance(by: 0.16); check(!agents.isShowing && agents.superview == nil, "Subagent modal retires after fade")
        agents.present(conversation: parent, anchor: CGRect(x: 100, y: 50, width: 80, height: 26), upward: false, in: host)
        check(agents.card.frame.minY == 86, "Column chip opens downward with the original anchor")
        parent.satellites[0].done = true; parent.satellites[0].finishedOrder = 100; agents.refresh()
        check(agents.orderedIDs.prefix(2) == ["r1", "r0"] && agents.selectedID == "r0", "Running→done reorder preserves stable selected ID")
        for i in 0..<15 { parent.satellites.append(.init(id: "extra-\(i)", face: "•ᴗ•")) }; agents.refresh()
        check(agents.card.bounds.height == 448 && agents.scrollView.documentView!.bounds.height > agents.scrollView.contentSize.height, "Long subagent groups cap at 448 and scroll")
        _ = agents.select("d0"); check(agents.scrollView.contentView.bounds.minY > 0, "Keyboard selection reveals an overflow row")
        agents.scrollView.contentView.scroll(to: CGPoint(x: 0, y: 31.37))
        check(agents.scrollView.contentView.bounds.minY == 31, "Native sheet wheel/clip origins are constrained to the backing grid")
        let opener = SheetSubAgentsEllipsis(frame: CGRect(x: 40, y: 700, width: 28, height: 24)); opener.modalHost = host; host.addSubview(opener)
        var openerAnchor: CGRect?; opener.onOpen = { openerAnchor = $0 }; opener.performClick(nil)
        check(openerAnchor == opener.frame, "Ellipsis callback supplies the real rect in modal-host coordinates")

        let customize = SheetCustomizeChat(clock: clock)
        var customResults: [SheetChatCustomization] = [], customCancels = 0
        customize.onDone = { customResults.append($0) }; customize.onCancel = { customCancels += 1 }
        customize.present(name: parent.title, identity: .assigned(2), level: parent.contextUsed, in: host)
        check(!agents.isShowing && agentDismissals.last == .replaced && host.subviews.compactMap { $0 as? SheetSurface }.count == 1, "A new M4 modal synchronously replaces the prior one; only one shield")
        check(customize.symbolButtons.count == 13 && customize.tintButtons.count == 13, "All 13 Orb symbols and 13 tints are present")
        check(customize.initialResponder === customize.nameField && customize.nameField.nextKeyView === customize.symbolButtons.first, "Customize owns native field focus and a contained Tab loop")
        customize.selectSymbol(.mars); check(customize.draft.tint == .rust && !customize.tintPicked, "Picking a symbol carries its default tint before a manual color")
        customize.selectTint(.mint); customize.selectSymbol(.jupiter); check(customize.draft.tint == .mint && customize.tintPicked, "Manual tint survives subsequent symbol changes")
        customize.useDefaults(); check(customize.draft.tint == .sand && !customize.tintPicked, "Use Defaults restores body tint and clears manual lock")
        customize.selectSymbol(.saturn); check(customize.draft.tint == .gold && !customize.defaultsButton.isEnabled, "Default following resumes and button disables at default")
        customize.selectTint(.cyan); customize.setName("  Rename sidebar  ")
        check(customize.outsideClick(at: .zero) && !customize.isDismissing, "Customize blocks outside clicks without treating them as Done or Cancel")
        try render(customize, "customize")
        customize.cancelButton.performClick(nil); clock.advance(by: 0.16)
        check(customResults.isEmpty && customCancels == 1 && parent.title == "Fix sidebar spacing", "Cancel never writes name or identity to the parent")
        customize.present(name: parent.title, identity: .assigned(2), level: 0.34, in: host); customize.setName("  Renamed  "); customize.selectTint(.lilac); _ = customize.handleKey(.enter)
        check(customResults == [.init(name: "Renamed", symbol: .earth, tint: .lilac)], "Done returns a trimmed name and exact symbol/tint once")
        clock.advance(by: 0.16); customize.present(name: "Keep original", identity: .assigned(0), level: 0, in: host); customize.setName(" \n "); customize.commit()
        check(customResults.last?.name == "Keep original", "Blank name retains original while identity can still commit")
        clock.advance(by: 0.16)

        let compare = SheetCompareConfirmation(clock: clock)
        var preferences: [Bool] = [], comparisons: [Bool] = [], compareCancels = 0
        compare.onNeverAskChange = { preferences.append($0) }; compare.onConfirm = { comparisons.append($0) }; compare.onCancel = { compareCancels += 1 }
        compare.present(anchor: anchor, in: host, neverAsk: false); compare.suppressionButton.performClick(nil)
        check(compare.neverAsk && preferences == [true], "Don't ask again forwards preference immediately like the product binding")
        try render(compare, "compare")
        check(compare.outsideClick(at: .zero) && compare.isDismissing && compareCancels == 1 && comparisons.isEmpty, "Compare outside click cancels without confirmation or click-through")
        check(compare.hitTest(CGPoint(x: 30, y: 30)) === compare, "Closing modal shield remains hit-active")
        clock.advance(by: 0.16); check(compare.hitTest(CGPoint(x: 30, y: 30)) == nil, "Retired modal has no hit lifetime")
        compare.present(anchor: anchor, in: host, neverAsk: true); _ = compare.handleKey(.enter); _ = compare.handleKey(.enter)
        check(comparisons == [true], "Return confirms compare once with the persistence value")
        clock.advance(by: 0.16); compare.present(anchor: anchor, in: host, neverAsk: false); _ = compare.handleKey(.escape)
        check(compareCancels == 2 && comparisons.count == 1, "Esc cancels Compare")
        clock.advance(by: 0.16)
        compare.present(anchor: anchor, in: host, neverAsk: false); _ = compare.outsideClick(at: .zero)
        compare.present(anchor: anchor, in: host, neverAsk: true); clock.advance(by: 0.16)
        check(compare.isShowing && !compare.isDismissing, "Old modal removal cannot retire a re-presented Compare")
        compare.dismiss(reason: .programmatic, animated: false)

        let archive = SheetArchiveUndoToast(clock: clock), notice = SheetNotice(clock: clock)
        var undos = 0; archive.onUndo = { undos += 1 }
        archive.present(archivedTitle: parent.title, anchor: anchor, in: host)
        check(archive.card.bounds.height == 32 && archive.card.frame.maxY == anchor.minY - 10, "Archive toast uses 32pt capsule and its own dock anchor")
        check(archive.hitTest(CGPoint(x: 1, y: 1)) == nil && archive.hitTest(CGPoint(x: archive.card.frame.midX, y: archive.card.frame.midY)) != nil, "Toast hits only the capsule; outside remains interactive")
        clock.advance(by: 8); check(archive.isShowing && !archive.isDismissing, "Archive Undo does not inherit the notice timeout")
        try render(archive, "archive-toast")
        archive.undo(); archive.undo(); check(undos == 1 && archive.isDismissing, "Undo fires once and closes")
        clock.advance(by: 0.2); check(!archive.isShowing, "Undo hit retires after fade")
        notice.present(message: "Workspace updated", anchor: anchor, in: host); try render(notice, "notice")
        clock.advance(by: 2.999); check(!notice.isDismissing, "Notice remains before 3 seconds")
        clock.advance(by: 0.001); check(notice.isDismissing && notice.isShowing, "Notice starts fade at exactly 3 seconds")
        notice.present(message: "A newer notice", anchor: CGRect(x: 80, y: 500, width: 40, height: 24), in: host)
        clock.advance(by: 0.2); check(notice.isShowing && !notice.isDismissing && notice.card.frame.maxY == 490, "Old removal cannot retire a new notice; its anchor is independent")
        archive.present(archivedTitle: "Other chat", anchor: anchor, in: host)
        check(!notice.isShowing && archive.isShowing, "Shared toast slot replaces notice immediately without inheriting its deadline")
        clock.advance(by: 4); check(archive.isShowing, "Replaced notice timer cannot dismiss archive Undo")
        archive.closeButton.performClick(nil); clock.advance(by: 0.2)
        check(!archive.isShowing && undos == 1, "Close is independent of Undo")

        let form = SheetForm(clock: clock)
        let request = SheetFormRequest(title: "Workspace on the Core host", message: "Enter an absolute path on the connected host. Core will validate it when the chat starts.", confirmTitle: "Use Workspace", fields: [
            .init(id: "cwd", label: "Workspace", placeholder: "/absolute/path", required: true, validation: .absolutePath),
            .init(id: "exact-response-id", label: "Response", value: "{}", required: true, validation: .jsonObject),
            .init(id: "token", label: "Token", required: true, secret: true)
        ])
        var formResults: [[String: String]] = [], formCancels = 0
        form.onConfirm = { formResults.append($0) }; form.onCancel = { formCancels += 1 }
        form.present(request, in: host); check(!form.isValid && !form.confirmButton.isEnabled, "Required fields gate the default action")
        _ = form.handleKey(.enter); check(formResults.isEmpty, "Return cannot bypass invalid form values")
        check(!form.setValue("unknown", fieldID: "other"), "Form preserves exact field IDs and rejects unknown IDs")
        _ = form.setValue("relative/path", fieldID: "cwd"); _ = form.setValue(" x ", fieldID: "token")
        check(!form.isValid, "Workspace rejects relative paths")
        _ = form.setValue("/tmp\n/other", fieldID: "cwd"); check(!form.isValid, "Workspace rejects multiline paths")
        _ = form.setValue(" /core/workspace ", fieldID: "cwd"); _ = form.setValue("[]", fieldID: "exact-response-id")
        check(!form.isValid, "JSON response must be an object")
        _ = form.setValue("{\"decision\":\"allow\"}", fieldID: "exact-response-id")
        check(form.isValid && form.confirmButton.isEnabled && form.values["token"] == " x ", "All-valid gates unlock; secret bytes are not trimmed")
        check(descendants(form).contains { $0 is SheetSecretField }, "Secret input uses the draw-overriding secure native field")
        try render(form, "form")
        _ = form.handleKey(.enter); check(formResults.first?["cwd"] == "/core/workspace" && formResults.first?["exact-response-id"] == "{\"decision\":\"allow\"}", "Form returns exact IDs and JSON, trimming only the path")
        clock.advance(by: 0.16)
        form.present(.init(title: "Malformed", message: "", fields: [.init(id: "x", label: "A"), .init(id: "x", label: "B")]), in: host)
        check(!form.isValid && form.validationError?.contains("unique") == true, "Duplicate field IDs fail closed without a dictionary trap")
        _ = form.handleKey(.escape); check(formCancels == 1, "Form Esc cancels once")
        clock.advance(by: 0.16)

        let context = SheetContextPicker(clock: clock)
        var contexts: [String] = [], contextCancels = 0
        context.onSelect = { contexts.append($0) }; context.onCancel = { contextCancels += 1 }
        context.present(title: "Device", options: [.init(id: "mac", title: "This Mac", detail: "Local Core"), .init(id: "offline", title: "Offline host", enabled: false, disabledReason: "Device is not connected"), .init(id: "host", title: "Build host", detail: "Remote Core")], selectedID: "mac", anchor: anchor, in: host)
        _ = context.handleKey(.down); check(context.highlightedID == "host" && context.selectedID == "mac", "Context navigation skips disabled items without committing")
        check(!context.select("offline") && descendants(context).compactMap { $0 as? SheetButton }.contains { !$0.isEnabled && $0.toolTip == "Device is not connected" }, "Disabled device exposes its reason and cannot commit")
        try render(context, "context-picker")
        _ = context.handleKey(.enter); check(contexts == ["host"], "Context Return commits the stable device ID")
        clock.advance(by: 0.16)
        context.present(title: "Workspace", options: [], selectedID: nil, anchor: anchor, in: host); _ = context.handleKey(.enter); _ = context.handleKey(.escape)
        check(contexts.count == 1 && contextCancels == 1, "Empty context list is safe and cancels without a selection")
        clock.advance(by: 0.16)

        var fakeWindows: [SheetTestWindow] = []
        let windows = SheetSubAgentWindows(factory: { config, close in let w = SheetTestWindow(config, close); fakeWindows.append(w); return w })
        var windowOpens: [String] = [], windowCloses: [String] = []
        windows.onOpen = { windowOpens.append($0) }; windows.onDismiss = { windowCloses.append($0) }
        check(windows.present(subagentID: "r1", of: parent, at: CGPoint(x: 1000, y: 700)), "Subagent window accepts an existing satellite and screen drop point")
        let history = windows.history(subagentID: "r1")!
        check(windows.present(subagentID: "r1", of: parent) && fakeWindows.count == 1 && fakeWindows[0].presentations.count == 2 && windows.history(subagentID: "r1") === history, "Repeated subagent ID reuses and raises the same history/window")
        check(fakeWindows[0].presentations.first! == CGPoint(x: 1000, y: 700) && fakeWindows[0].title.contains(parent.title), "Drop point remains screen coordinates and title names the parent")
        check(!windows.present(subagentID: "missing", of: parent), "Missing subagent never creates a window")
        let impostor = Conversation(id: "other-parent", title: "Other"); impostor.satellites = [.init(id: "r1", face: "•ᴗ•")]
        check(!windows.present(subagentID: "r1", of: impostor) && history.parentID == parent.id, "Reused ID cannot be rebound to another parent")
        check(history.projection !== parent && history.projection.isLiveConversation && history.projection.approvals.isEmpty && history.projection.userInput == nil && history.transcript.onEditMessage == nil && history.transcript.onForkMessage == nil && history.transcript.onRevertChanges == nil, "Read-only projection is isolated and has no runtime/mutation callbacks")
        check(history.projection.items.contains { $0.text.contains("SidebarView.swift") }, "Mock history uses the fixed per-index product log")
        let historySpinners=descendants(history).compactMap{$0 as? NSProgressIndicator}
        check(historySpinners.count==2 && Set(historySpinners.map{$0.controlSize.rawValue})==Set([NSControl.ControlSize.small.rawValue,NSControl.ControlSize.mini.rawValue]),"M9 subagent Running/Working use the product's small/mini native spinners")
        check(historySpinners.allSatisfy{$0.style == .spinning && $0.isIndeterminate && !$0.isDisplayedWhenStopped && $0.usesThreadedAnimation},"M9 subagent spinners keep AppKit animation, not a Swift frame timer")
        try render(history, "subagent-history")
        let body = descendants(history).compactMap { $0 as? NativeTranscriptTextView }.first!
        let oldText = body.string; body.setAccessibilityValue("mutate")
        check(!body.isEditable && body.isSelectable && body.string == oldText, "History supports native selection but rejects AX text writes")
        parent.backendThreadID = "core-parent"; parent.satellites[2].threadID = "core-agent"; parent.satellites[2].items = [.init(id: "live-answer", turnID: "turn", kind: .assistant, text: "Read **real** history and `code`.")]
        windows.refresh(parent: parent); history.layoutSubtreeIfNeeded()
        check(history.projection.items.first?.id == "live-answer" && history.transcript.displayedText(itemID: "live-answer")?.contains("real") == true, "Live satellites display their real thread items through NativeTranscript")
        parent.satellites[2].items = []; windows.refresh(parent: parent)
        check(history.projection.items.contains { $0.id == "history-waiting" } && !history.projection.items.contains { $0.text.contains("LayoutTests") }, "Empty live history waits and never invents mock logs")
        parent.satellites[2].done=true;windows.refresh(parent:parent)
        check(historySpinners.allSatisfy(\.isHidden),"M9 done retires both native spinners")
        parent.satellites[2].done=false;windows.refresh(parent:parent)
        windows.dismiss(subagentID: "r1"); check(windows.openIDs.isEmpty && fakeWindows[0].dismissals == 1 && windowCloses == ["r1"], "Programmatic window close clears the ID once")
        _ = windows.present(subagentID: "r1", of: parent); fakeWindows[0].onClose()
        check(windows.openIDs == ["r1"], "Stale close callback cannot remove a newly reopened window")
        fakeWindows[1].onClose(); check(windows.openIDs.isEmpty && windowCloses.count == 2, "Native close clears the registry and callback once")

        let native = SheetNativeDialog(clock: clock, factory: { config, close in let w = SheetTestWindow(config, close); fakeWindows.append(w); return w })
        var nativeConfirmations = 0, nativeCancels = 0
        native.onConfirm = { _ in nativeConfirmations += 1 }; native.onCancel = { nativeCancels += 1 }
        native.present(.init(title: "Use this response?", message: "Review its exact value before sending.", confirmTitle: "Send response")) { $0.present(at: nil) }
        check(native.isShowing && native.form.request.fields.isEmpty && native.form.isValid, "Native confirmation adapter presents the same valid AppKit body via an injected window")
        native.form.confirm(); check(!native.isShowing && nativeConfirmations == 1 && nativeCancels == 0, "Native confirmation ends sheet and calls confirm once")
        let retiredNative = fakeWindows.last!
        native.present(request) { $0.present(at: nil) }; retiredNative.onClose()
        check(native.isShowing, "Retired native sheet callback cannot close its successor")
        _ = native.form.handleKey(.escape); check(!native.isShowing && nativeCancels == 1, "Native sheet Esc cancels once despite a synchronous close notification")
        let nativeCustomize = SheetCustomizeChatWindow(clock: clock, factory: { config, close in let w = SheetTestWindow(config, close); fakeWindows.append(w); return w })
        var nativeCustomResults: [SheetChatCustomization] = [], nativeCustomCancels = 0
        nativeCustomize.onDone = { nativeCustomResults.append($0) }; nativeCustomize.onCancel = { nativeCustomCancels += 1 }
        nativeCustomize.present(name: "Original", identity: .assigned(1), level: 0.4) { $0.present(at: nil) }
        nativeCustomize.sheet.setName(" Native name "); nativeCustomize.sheet.selectSymbol(.neptune); nativeCustomize.sheet.commit()
        check(!nativeCustomize.isShowing && nativeCustomResults == [.init(name: "Native name", symbol: .neptune, tint: .indigo)] && nativeCustomCancels == 0, "Native Customize window-sheet returns name/symbol/tint once and closes")
        let oldCustomizeWindow = fakeWindows.last!
        nativeCustomize.present(name: "Again", identity: .assigned(0), level: 0) { $0.present(at: nil) }; oldCustomizeWindow.onClose()
        check(nativeCustomize.isShowing, "Old native Customize close cannot retire its replacement")
        nativeCustomize.dismiss(); check(nativeCustomCancels == 1 && !nativeCustomize.isShowing, "Native Customize dismiss cancels without committing")

        let unflipped = NSView(frame: host.frame)
        compare.present(anchor: CGRect(x: 350, y: 52, width: 40, height: 28), in: unflipped, neverAsk: false)
        check(compare.anchorRect.minY == 740 && compare.card.frame.maxY == 730, "Unflipped host anchor converts once into top-left sheet coordinates")
        compare.card.frame.origin.y += 0.25; compare.viewDidChangeBackingProperties()
        check(compare.card.frame.maxY == 730, "Backing-scale notification re-aligns existing sheet geometry")
        compare.dismiss(reason: .anchorInvalidated, animated: false)
        check(!compare.isShowing && compare.superview == nil, "Host can retire a moving/stale anchor immediately")
        let retiring = SheetCompareConfirmation(clock: clock), superseded = SheetForm(clock: clock), newer = SheetContextPicker(clock: clock)
        retiring.onCancel = { newer.present(title: "Newer request", options: [], selectedID: nil, anchor: anchor, in: host) }
        retiring.present(anchor: anchor, in: host, neverAsk: false)
        superseded.present(.init(title: "Superseded", message: ""), in: host)
        check(newer.isShowing && !retiring.isShowing && !superseded.isShowing && host.subviews.compactMap { $0 as? SheetSurface }.count == 1, "A callback's newer modal request wins without leaving multiple shields")
        newer.dismiss(reason: .programmatic, animated: false)
        let reentrant = SheetCompareConfirmation(clock: clock); var reopened = false
        reentrant.onCancel = { if !reopened { reopened = true; reentrant.present(anchor: anchor, in: host, neverAsk: true) } }
        reentrant.present(anchor: anchor, in: host, neverAsk: false); reentrant.dismiss(); clock.advance(by: 0.16)
        check(reentrant.isShowing && !reentrant.isDismissing && reentrant.neverAsk, "Reentrant cancellation cannot schedule an old removal onto the new presentation")
        reentrant.onCancel = nil; reentrant.dismiss(reason: .programmatic, animated: false)
        let renewedNotice = SheetNotice(clock: clock); var renewed = false
        renewedNotice.onDismiss = { reason in if reason == .close && !renewed { renewed = true; renewedNotice.present(message: "Renewed", anchor: anchor, in: host) } }
        renewedNotice.present(message: "Old", anchor: anchor, in: host); renewedNotice.closeButton.performClick(nil); clock.advance(by: 0.2)
        check(renewedNotice.isShowing && !renewedNotice.isDismissing, "Reentrant toast renewal keeps its own hit/deadline lifetime")
        renewedNotice.dismiss(reason: .programmatic, animated: false)
        agents.reduceMotion = true; agents.present(conversation: parent, anchor: anchor, upward: true, in: host)
        check(agents.card.content.layer?.animationKeys()?.isEmpty != false && descendants(agents).allSatisfy { $0.layer?.animationKeys()?.isEmpty != false }, "Reduce Motion leaves no new sheet/row entrance animations")
        agents.dismiss(reason: .programmatic, animated: false); windows.dismiss()
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "Verification did not open a window or run the app")
        let report = "Sheets verification: \(checks) checks, \(findings.count) findings\n" + findings.map { "FAIL: " + $0 }.joined(separator: "\n") + "\n"
        try report.write(to: output.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
        print(report, terminator: ""); if !findings.isEmpty { exit(1) }
    }
}
#endif
