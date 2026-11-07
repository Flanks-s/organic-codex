#if M1_SELFTEST
import AppKit

@MainActor enum NativeComposerBarFocusVerification {
    static func run(output: URL, check: (Bool, String) -> Void) throws {
        let host = NativeFlippedView(frame: CGRect(x: 0, y: 0, width: 800, height: 240))
        let composer = NativeComposer()
        host.addSubview(composer)
        let editor = composer.textView
        let undo = editor.undoManager
        var focused = false
        composer.onFocusChange = { focused = $0 }

        func settle() {
            composer.needsLayout = true
            composer.layoutSubtreeIfNeeded()
            composer.measureNow()
        }
        func insertionRect(scale: CGFloat) -> CGRect? {
            guard let manager = editor.layoutManager, let container = editor.textContainer else { return nil }
            manager.ensureLayout(for: container)
            let selected = editor.selectedRange()
            var count = 0
            guard let rects = manager.rectArray(forCharacterRange: NSRange(location: selected.location, length: 0),
                                               withinSelectedCharacterRange: selected, in: container, rectCount: &count),
                  count > 0 else { return nil }
            var rect = rects[0].offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
            rect.origin.x = (rect.minX * scale).rounded() / scale
            rect.origin.y = (rect.minY * scale).rounded() / scale
            rect.size.width = 1
            rect.size.height = ceil(rect.height * scale) / scale
            return composer.convert(rect, from: editor)
        }
        // cacheDisplay omits AppKit's WindowServer insertion indicator. Freeze its visible phase using the real
        // TextKit insertion rect and NSTextView's public drawing method; never create or show an NSWindow.
        func capture(caret: CGRect?, scale: CGFloat) -> CGImage {
            let body = VerificationRaster.capture(composer, scale: scale)
            let rep = VerificationRaster.bitmap(width: body.width, height: body.height)
            rep.size = composer.bounds.size
            memset(rep.bitmapData!, 0, rep.bytesPerRow * rep.pixelsHigh)
            NSGraphicsContext.saveGraphicsState()
            let graphics = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.current = graphics
            graphics.cgContext.draw(body, in: composer.bounds)
            graphics.cgContext.translateBy(x: 0, y: composer.bounds.height)
            graphics.cgContext.scaleBy(x: 1, y: -1)
            if let caret {
                NSBezierPath(rect: composer.scrollView.frame).addClip()
                let origin = composer.convert(CGPoint.zero, from: editor)
                graphics.cgContext.translateBy(x: origin.x, y: origin.y)
                editor.drawInsertionPoint(in: editor.convert(caret, from: composer), color: editor.insertionPointColor, turnedOn: true)
            }
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage!
        }
        func save(_ image: CGImage, _ name: String) throws {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent(name + ".png"))
        }
        func changedColumns(_ image: CGImage, _ other: CGImage) -> Set<Int> {
            let a = NSBitmapImageRep(cgImage: image), b = NSBitmapImageRep(cgImage: other)
            var columns = Set<Int>()
            for y in 0..<a.pixelsHigh {
                for x in 0..<a.pixelsWide where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { columns.insert(x) }
            }
            return columns
        }

        for scale: CGFloat in [1, 2] {
            composer.verificationScale = scale
            for width: CGFloat in [320, 418, 640] {
                // Exactly the host's retained handoff: Normie mounts .growing/nil, Organic supplies targetWidth
                // then the bar frame. The test must not repair layoutMode on behalf of the receiving host.
                composer.targetWidth = nil
                composer.layoutMode = .growing
                composer.frame = CGRect(x: 0, y: 0, width: width, height: 112)
                settle()
                composer.targetWidth = width
                composer.frame.size.height = 48
                settle()
                check(composer.layoutMode == .fullBar, "N1 bar target switches a retained growing composer at \(width)/\(scale)x")
                check(composer.textView === editor && editor.undoManager === undo, "N1 bar handoff retains editor and Undo")

                for (name, text, wantsFocus) in [("empty-unfocused", "", false), ("empty-focused", "", true),
                                                ("typed-focused", "Message typed", true),
                                                ("running-recovery-focused", "", true)] {
                    let recovery = name == "running-recovery-focused"
                    composer.state = recovery ? NativeComposerState(running: true, usesLiveCore: true, operationError: "Fixture error") : NativeComposerState()
                    composer.queued = recovery ? [.init(id: "n1-queue", text: "Waiting")] : []
                    composer.onStop = {}
                    _ = composer.setText(text)
                    editor.setSelectedRange(NSRange(location: 0, length: 0))
                    if wantsFocus { check(editor.becomeFirstResponder(), "N1 native editor accepts focus") }
                    else { _ = editor.resignFirstResponder() }
                    settle()
                    check(focused == wantsFocus && editor.string == text, "N1 focus changes neither draft nor placeholder content")
                    let caret = insertionRect(scale: scale)
                    check(caret != nil, "N1 TextKit supplies the actual insertion position")
                    let origin = composer.convert(editor.textContainerOrigin, from: editor)
                    let clip = composer.scrollView.frame
                    let placeholderSize = (editor.placeholder as NSString).size(withAttributes: [.font: editor.font!])
                    let placeholder = CGRect(origin: origin, size: placeholderSize).intersection(clip)
                    let controls: [NSView] = [composer.attachButton, composer.accessButton, composer.modelButton,
                        composer.sendButton, composer.voiceButton, composer.dictationButton, composer.stopButton,
                        composer.contextButton, composer.historyRefreshButton, composer.queueButton]
                    let shown = controls.filter { !$0.isHidden }
                    check(shown.enumerated().allSatisfy { index, view in
                        shown.dropFirst(index + 1).allSatisfy { !view.frame.intersects($0.frame) }
                    }, "N1 visible controls do not overlap each other")
                    check(shown.allSatisfy { !$0.frame.intersects(clip) }, "N1 every visible control stays outside the editor viewport")
                    check(shown.allSatisfy { !$0.frame.intersects(placeholder) }, "N1 shield and controls do not overlap Message placeholder")
                    check(shown.allSatisfy { !$0.frame.intersects(caret ?? .zero) }, "N1 controls do not overlap the insertion point")
                    check(abs((caret?.minX ?? -100) - origin.x) <= 0.5 / scale,
                          "N1 insertion at zero aligns with the placeholder start, before M")
                    check(caret.map { clip.contains($0) } == true, "N1 insertion point is fully inside the bar viewport")
                    check(clip.minX >= composer.accessButton.frame.maxX + 4,
                          "N1 horizontal bar reserves the permissions control before the editor")
                    let noCaret = capture(caret: nil, scale: scale)
                    let image = capture(caret: wantsFocus ? caret : nil, scale: scale)
                    check(image.width == Int(width * scale) && image.height == Int(48 * scale), "N1 bar capture has exact backing dimensions")
                    if wantsFocus {
                        let columns = changedColumns(image, noCaret)
                        check(!columns.isEmpty, "N1 focused image includes a visible native-drawn caret: \(name) \(width)/\(scale)x")
                        check(columns.allSatisfy { CGFloat($0) >= floor(caret!.minX * scale) && CGFloat($0) < ceil(caret!.maxX * scale) },
                              "N1 caret pixels occupy the placeholder start column, never after M or on the shield")
                    }
                    try save(image, "composer-n1-\(name)-\(Int(width))@\(Int(scale))x")
                }
                // Returning to Normie still explicitly restores its editor-above-controls layout.
                composer.layoutMode = .growing
                composer.targetWidth = nil
                composer.frame.size.height = 112
                settle()
                check(composer.layoutMode == .growing && composer.scrollView.frame.maxY <= composer.accessButton.frame.minY,
                      "N1 Normie remount retains the separate control row")
            }
        }
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "N1 focus rendering opens no windows")
    }
}
#endif
