#if TOOLS_SELFTEST
import AppKit
import PDFKit
import CoreText
import QuartzCore

@MainActor enum ToolsPDFVerification {
    /// PDFKit/CA retirement is asynchronous even without a window. This bounded test drain is never app code.
    private static func drainPDFCommit() {
        CATransaction.flush(); CFRunLoopRunInMode(.defaultMode, 0.01, true)
    }
    static func fixture() -> Data {
        let data = NSMutableData(), consumer = CGDataConsumer(data: data as CFMutableData)!
        var bounds = CGRect(x: 0, y: 0, width: 360, height: 480)
        let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        for page in 1...3 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor); context.fill(bounds)
            context.setFillColor((page == 2 ? NSColor.systemTeal : NSColor.systemBlue).cgColor)
            context.fill(CGRect(x: 24, y: 24, width: 312, height: 20))
            let text = "PDF page \(page): native selection and annotation"
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 13, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor
            ]))
            context.textPosition = CGPoint(x: 24, y: 390); CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
    static func run(directory: URL) async throws {
        let check = ToolsVerification.check, bytes = fixture()
        let artifact = CoreArtifact(raw: ["id": "pdf", "name": "Native PDF.pdf", "mimeType": "application/pdf", "sha256": "pdf-fixture", "threadId": "original-thread"])
        for scale: CGFloat in [1, 2] {
            let preview = ToolsArtifactPreview(frame: CGRect(x: 0, y: 0, width: 640, height: 510)); preview.verificationScale = scale
            var quotes: [String] = [], pages: [Int] = []
            preview.onQuote = { quotes.append($0) }; preview.onPage = { pages.append($0) }
            preview.configure(artifact: artifact, data: bytes); preview.layoutSubtreeIfNeeded()
            let pdf = preview.pdfView, document = pdf.document!
            check(preview.kind == .pdf && preview.pageCount == 3 && pdf.superview === preview && !pdf.isHidden, "S3 PDFView is the actual preview child")
            check(pdf.displayMode == .singlePageContinuous && pdf.autoScales && document.page(at: 1)?.string?.contains("PDF page 2") == true, "S3 native continuous PDF pages retain selectable text")
            check(preview.textScroll.isHidden && preview.text.string.isEmpty, "S3 PDF uses no extracted-text surrogate")
            check(pdf.responds(to: NSSelectorFromString("copy:")) && pdf.acceptsFirstResponder, "S3 native PDF Copy and focus actions remain available")
            check(pdf.accessibilityLabel() == "Read-only PDF preview" && !(pdf.accessibilityChildren() ?? []).isEmpty, "S3 PDF retains its native AX children and label")
            check(!pdf.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilityValue:")) && !pdf.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilitySelectedText:")), "S3 PDF AX refuses document content writes")
            preview.showPage(2)
            check(preview.page == 2 && pdf.currentPage === document.page(at: 1) && pages.last == 2, "S3 page buttons navigate the native PDFView and publish 1-based page")
            let selection = document.page(at: 1)!.selection(for: NSRange(location: 0, length: 10))!
            pdf.setCurrentSelection(selection, animate: false)
            check(quotes.last == selection.string && preview.page == 2, "S3 real PDF selection notification forwards quote and source page")
            let oldSelection = pdf.currentSelection, oldScale = pdf.scaleFactor
            preview.configure(artifact: artifact, data: bytes); preview.layoutSubtreeIfNeeded()
            check(pdf.document === document && pdf.currentSelection === oldSelection && pdf.scaleFactor == oldScale, "S3 same artifact update preserves document selection and zoom")
            let quoteCount = quotes.count, pageCount = pages.count
            preview.restorePDFPage(3)
            check(preview.page == 3 && pdf.currentPage === document.page(at: 2) && pages.count == pageCount && quotes.count == quoteCount, "S3 retained page restore changes native view without emitting an annotation edit")
            preview.showPage(999); check(preview.page == 3 && !preview.next.isEnabled, "S3 upper page bound and Next disable")
            preview.showPage(-1); check(preview.page == 1 && !preview.previous.isEnabled, "S3 lower page bound and Previous disable")
            let autoScale = pdf.scaleFactor
            pdf.zoomIn(nil); check(pdf.scaleFactor > autoScale, "S3 native PDF zoom action changes magnification")
            pdf.zoomOut(nil); check(pdf.scaleFactor < autoScale * 1.5, "S3 native PDF zoom out remains available")
            pdf.keyDown(with: ToolsVerification.event(124))
            check(preview.page == 2, "S3 focused PDF arrow uses native page navigation")
            preview.frame.size = CGSize(width: 641.3, height: 509.7); preview.needsLayout = true; preview.layoutSubtreeIfNeeded()
            check([pdf, preview.previous, preview.next, preview.pdfText].allSatisfy { v in
                [v.frame.minX, v.frame.minY, v.frame.maxX, v.frame.maxY].allSatisfy { abs($0 * scale - ($0 * scale).rounded()) < 0.0001 }
            }, "S3 PDF viewport and controls align to backing pixels")
            let bitmap = preview.snapshot(scale: scale)
            check(bitmap.width == Int(preview.bounds.width * scale) && bitmap.height == Int(preview.bounds.height * scale), "S3 native PDF cacheDisplay has the requested scale")
            try ToolsVerification.write(bitmap, directory.appendingPathComponent("native-pdf@\(Int(scale))x.png"))
            ToolsVerification.audit(preview)
            let count = quotes.count
            preview.configure(artifact: CoreArtifact(raw: ["id": "text-after-pdf", "mimeType": "text/plain"]), data: Data("Next artifact".utf8))
            NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: pdf)
            check(pdf.document == nil && pdf.currentSelection == nil && pdf.isHidden && quotes.count == count, "S3 retiring PDF releases document/selection and ignores stale native notifications")
        }

        let fake = CoreControllerFixture(), store = ConversationStore(), chat = Conversation(id: "pdf-destination", title: "PDF destination")
        chat.backendThreadID = "destination-thread"; store.add(chat)
        fake.artifacts = [artifact.raw]; fake.content["pdf"] = bytes
        let runtime = MockConversationRuntime(store: store, animatePlayback: false)
        defer { runtime.shutdown() }
        let controller = CoreArtifactsController(storage: CoreMemoryStorage()); controller.configure(client: fake.transport, runtime: runtime, endpoint: "pdf-fixture")
        let root = ToolsRootView(artifacts: controller, terminal: CoreTerminalController())
        root.frame = CGRect(x: 0, y: 0, width: 1000, height: 740); root.setDestination(chat.id)
        await ToolsVerification.wait("S3 PDF artifact list") { !controller.busy && controller.artifacts.count == 1 }
        root.selectArtifact("pdf"); await ToolsVerification.wait("S3 loaded PDF bytes") { controller.selectedData != nil }
        root.update(); root.layoutSubtreeIfNeeded()
        let pdf = root.preview.pdfView, doc = pdf.document!
        root.preview.showPage(2)
        let selection = doc.page(at: 1)!.selection(for: NSRange(location: 0, length: 10))!
        pdf.setCurrentSelection(selection, animate: false)
        check(controller.quote == selection.string && controller.page == 2 && root.quote.stringValue == selection.string, "S3 native PDF selection reaches the retained annotation editor")
        root.comment.stringValue = "PDF native note"; root.comment.onEdit?("PDF native note"); root.save.performClick(nil)
        await ToolsVerification.wait("S3 PDF annotation saved") { !controller.busy && !controller.annotations.isEmpty }
        let body = fake.requests.last { $0.key == "/preview/annotations" && $0.method == "POST" }?.body
        check(body?["artifactId"] == "pdf" && body?["page"] == 2 && body?["quote"]?.stringValue == selection.string && body?["text"] == "PDF native note", "S3 annotation wire contains original artifactId page and quote")
        var deliveries: [CoreArtifactDelivery] = []
        controller.onDeliver = { value, finish in deliveries.append(value); finish(.accepted) }
        root.update()
        root.attach.performClick(nil); await ToolsVerification.wait("S3 PDF attachment delivery") { !controller.busy && deliveries.count == 1 }
        check(deliveries.first?.destinationID == chat.id && deliveries.first?.send == false && deliveries.first?.annotations.first?["page"] == 2, "S3 artifact delivery keeps its existing destination UUID/send/annotation contract")
        if let delivery = deliveries.first {
            let envelope = delivery.composeDraft(current: "Question")
            check(envelope.contains("original-thread") && envelope.contains("PDF page 2") && envelope.contains("\"page\":2"), "S3 cross-thread annotation envelope retains PDF page and quote provenance")
        } else { check(false, "S3 cross-thread annotation delivery unavailable") }
        let retainedPage = controller.page, retainedQuote = controller.quote
        root.selectSection(.browser); await ToolsVerification.wait("S3 unrelated tab") { !controller.busy }
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: pdf)
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: pdf)
        check(controller.page == retainedPage && controller.quote == retainedQuote, "S3 hidden PDF notifications cannot overwrite another Tools tab's annotation state")
        root.selectSection(.artifacts); await ToolsVerification.wait("S3 PDF tab restored") { !controller.busy }; root.update(); root.layoutSubtreeIfNeeded()
        check(root.preview.page == retainedPage, "S3 returning to the artifact restores the annotation page")
        weak var released: ToolsArtifactPreview?
        autoreleasepool { let v = ToolsArtifactPreview(frame: CGRect(x: 0, y: 0, width: 600, height: 480)); v.configure(artifact: artifact, data: bytes); released = v }
        check(released == nil, "S3 PDF notification observers do not retain a retired preview")
        for component in [false, true] {
            weak var retiredDocument: PDFDocument?
            autoreleasepool {
                let view: PDFView = component ? ToolsPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 480)) : PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 480))
                let doc = PDFDocument(data: bytes)!
                retiredDocument = doc
                if let view = view as? ToolsPDFView { view.replaceDocument(doc) } else { view.document = doc }
                view.layoutDocumentView()
                if let view = view as? ToolsPDFView { view.replaceDocument(nil) } else { view.document = nil }
            }
            for _ in 0..<5 { drainPDFCommit(); await Task.yield(); if retiredDocument == nil { break } }
            check(retiredDocument == nil, component ? "S3 retired component PDFDocument releases after its CA commit" : "S3 unmodified PDFView control releases its retired PDFDocument")
        }
        check(NSApp.windows.isEmpty, "S3 PDF checks never open a window")
    }
}
#endif
