import AppKit
import PDFKit
import WebKit

/// Native image/PDF/text/HTML endpoints. PDFKit remains the actual selectable, accessible PDF endpoint.
@MainActor final class ToolsArtifactPreview:ToolsView,WKNavigationDelegate {
    enum Kind:String { case empty,image,pdf,html,text,binary,unavailable }
    private(set) var kind=Kind.empty,page=1,pageCount=0
    private(set) var region:JSONValue?
    var allowsRegionSelection=true
    private var image:NSImage?,pdf:PDFDocument?,key="",data:Data?
    private var start:CGPoint?
    private var web:WKWebView?
    let pdfView=ToolsPDFView(frame:.zero)
    private var changingPDF=false
    let text=ToolsTextView(frame:.zero),textScroll=ToolsScrollView()
    let caption=ToolsLabel(),previous=ToolsButton("‹"),next=ToolsButton("›"),pdfText=ToolsButton("Select PDF text")
    var onRegion:((JSONValue?)->Void)?,onQuote:((String)->Void)?,onPage:((Int)->Void)?,onOpenURL:((URL)->Void)?
    override init(frame:NSRect) {
        super.init(frame:frame); layer?.backgroundColor=ToolsDisplayEnvironment.surface(.black,opacity:0.13).cgColor
        caption.maximumNumberOfLines=0; caption.lineBreakMode = .byWordWrapping
        textScroll.documentView=text; textScroll.hasVerticalScroller=true; textScroll.drawsBackground=false
        for v in [textScroll,pdfView,caption,previous,next,pdfText] { addSubview(v) }
        previous.invoke={ [weak self] in guard let self else { return }; self.showPage(self.page-1) }
        next.invoke={ [weak self] in guard let self else { return }; self.showPage(self.page+1) }
        pdfText.invoke={ [weak self] in self?.pdfView.selectAll(nil) }
        pdfText.title="Select PDF text"; pdfText.setAccessibilityHelp("Select the PDF's native text. Command-C copies the selection.")
        NotificationCenter.default.addObserver(self,selector:#selector(pdfChanged(_:)),name:.PDFViewSelectionChanged,object:pdfView)
        NotificationCenter.default.addObserver(self,selector:#selector(pdfChanged(_:)),name:.PDFViewPageChanged,object:pdfView)
        text.onQuote={ [weak self] in self?.onQuote?($0) }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Artifact preview")
        configure(artifact:nil,data:nil)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    isolated deinit { NotificationCenter.default.removeObserver(self); pdfView.replaceDocument(nil) }
    override func displayOptionsDidChange() {
        layer?.backgroundColor=ToolsDisplayEnvironment.surface(.black,opacity:0.13).cgColor
        super.displayOptionsDidChange()
    }
    func configure(artifact:CoreArtifact?,data:Data?) {
        let newKey=(artifact?.id ?? "")+":"+(artifact?.sha ?? "")+":"+String(artifact?.previewUnavailable ?? false)
        guard newKey != key || self.data != data else { return }; key=newKey; self.data=data
        changingPDF=true
        pdfView.replaceDocument(nil)
        image=nil; pdf=nil; region=nil; page=1; pageCount=0
        defer { changingPDF=false }
        web?.removeFromSuperview(); web=nil
        if artifact?.previewUnavailable == true { kind = .unavailable; caption.stringValue=CoreArtifact.unavailableMessage }
        else if let artifact,let data {
            if artifact.mime.hasPrefix("image/"),let image=NSImage(data:data) { self.image=image; kind = .image }
            else if artifact.mime == "application/pdf",let pdf=PDFDocument(data:data),pdf.pageCount>0 {
                self.pdf=pdf; pageCount=pdf.pageCount; kind = .pdf
                pdfView.autoScales=true; pdfView.replaceDocument(pdf)
            }
            else if artifact.mime.contains("html"),let html=String(data:data,encoding:.utf8) {
                kind = .html
                let configuration=WKWebViewConfiguration(); let view=WKWebView(frame:.zero,configuration:configuration)
                view.navigationDelegate=self; addSubview(view); web=view; view.loadHTMLString(html,baseURL:nil)
            } else if let value=String(data:data,encoding:.utf8) { kind = .text; text.string=value }
            else { kind = .binary; caption.stringValue="No inline preview for this format." }
        } else { kind = .empty; caption.stringValue="Select and load an artifact." }
        caption.isHidden = ![.empty,.binary,.unavailable].contains(kind)
        textScroll.isHidden=kind != .text; previous.isHidden=kind != .pdf; next.isHidden=kind != .pdf; pdfText.isHidden=kind != .pdf
        pdfView.isHidden=kind != .pdf
        text.string=kind == .text ? text.string:""
        updatePDFButtons()
        setAccessibilityValue(kind.rawValue); needsLayout=true; needsDisplay=true
    }
    func showPage(_ value:Int) {
        setPDFPage(value,notify:true)
    }
    /// Restore the annotation editor's retained page when returning from another Tools tab, without editing it.
    func restorePDFPage(_ value:Int) { setPDFPage(value,notify:false) }
    private func setPDFPage(_ value:Int,notify:Bool) {
        guard let pdf,let target=pdf.page(at:min(max(1,value),pdf.pageCount)-1) else { return }
        let targetNumber=pdf.index(for:target)+1
        guard page != targetNumber || pdfView.currentPage !== target else { return }
        changingPDF=true; pdfView.clearSelection(); pdfView.go(to:target); changingPDF=false
        page=targetNumber; updatePDFButtons()
        if notify { onPage?(page) }
    }
    @objc private func pdfChanged(_ note:Notification) {
        guard !changingPDF,kind == .pdf,note.object as? PDFView === pdfView,let pdf,pdfView.document === pdf else { return }
        let selected=pdfView.currentSelection
        guard let current=selected?.pages.first ?? pdfView.currentPage else { return }
        let index=pdf.index(for:current)
        guard index != NSNotFound,index>=0,index<pdf.pageCount else { return }
        let value=index+1
        if page != value { page=value; onPage?(value) }
        if let quote=selected?.string,!quote.isEmpty { onQuote?(quote) }
        updatePDFButtons()
    }
    private func updatePDFButtons() {
        previous.isEnabled=kind == .pdf && page>1; next.isEnabled=kind == .pdf && page<pageCount
        pdfText.isEnabled=kind == .pdf
        pdfView.setAccessibilityHelp("Read-only PDF. Page \(page) of \(pageCount). Select text to quote it in an annotation.")
    }
    var imageRect:CGRect {
        guard let image else { return .zero }; let w=max(1,image.size.width),h=max(1,image.size.height),k=min(bounds.width/w,bounds.height/h)
        return Self.aligned(CGRect(x:(bounds.width-w*k)/2,y:(bounds.height-h*k)/2,width:w*k,height:h*k),scale:pixelScale)
    }
    func selectRegion(from a:CGPoint,to b:CGPoint) {
        let rect=imageRect; guard allowsRegionSelection,kind == .image,rect.width>0,rect.height>0 else { return }
        func n(_ point:CGPoint)->CGPoint { CGPoint(x:min(1,max(0,(point.x-rect.minX)/rect.width)),y:min(1,max(0,(point.y-rect.minY)/rect.height))) }
        let p=n(a),q=n(b)
        region=["x":.number(min(p.x,q.x)),"y":.number(min(p.y,q.y)),"width":.number(abs(p.x-q.x)),"height":.number(abs(p.y-q.y)),"units":"normalized","origin":"top-left","imageWidth":.number(Double(image?.size.width ?? 0)),"imageHeight":.number(Double(image?.size.height ?? 0))]
        onRegion?(region); needsDisplay=true
    }
    func clearRegion() { region=nil; onRegion?(nil); needsDisplay=true }
    /// Restore the artifact editor's retained region without emitting a new user edit.
    func restoreRegion(_ value:JSONValue?) { region=kind == .image ? value:nil; needsDisplay=true }
    override func mouseDown(with event:NSEvent) { let p=convert(event.locationInWindow,from:nil); start=imageRect.contains(p) ? p:nil }
    override func mouseDragged(with event:NSEvent) { if let start { selectRegion(from:start,to:convert(event.locationInWindow,from:nil)) } }
    override func mouseUp(with event:NSEvent) { start=nil }
    override func keyDown(with event:NSEvent) { if kind == .pdf,event.keyCode == 124 || event.keyCode == 121 { showPage(page+1) } else if kind == .pdf,event.keyCode == 123 || event.keyCode == 116 { showPage(page-1) } else { super.keyDown(with:event) } }
    override var acceptsFirstResponder:Bool { true }
    override func layout() {
        super.layout(); place(caption,bounds.insetBy(dx:14,dy:14)); place(web ?? textScroll,bounds)
        if kind == .text { place(textScroll,bounds) }
        if kind == .pdf {
            place(pdfView,CGRect(x:0,y:0,width:bounds.width,height:max(0,bounds.height-36)))
            pdfView.layoutDocumentView()
            place(previous,CGRect(x:8,y:bounds.height-30,width:28,height:24)); place(next,CGRect(x:42,y:bounds.height-30,width:28,height:24)); place(pdfText,CGRect(x:80,y:bounds.height-30,width:128,height:24))
        }
        text.fit(in:textScroll,scale:pixelScale)
    }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        if let image { image.draw(in:imageRect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil) }
        if let region {
            let r=imageRect,box=CGRect(x:r.minX+(region["x"]?.doubleValue ?? 0)*r.width,y:r.minY+(region["y"]?.doubleValue ?? 0)*r.height,width:(region["width"]?.doubleValue ?? 0)*r.width,height:(region["height"]?.doubleValue ?? 0)*r.height)
            if !ToolsDisplayEnvironment.shared.options.opaqueSurfaces { NSColor.systemBlue.withAlphaComponent(0.18).setFill(); NSBezierPath(rect:box).fill() }
            NSColor.systemBlue.setStroke(); NSBezierPath(rect:box).stroke()
        }
    }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url=action.request.url else { return .cancel }
        if ["about","data"].contains(url.scheme ?? "") { return .allow }
        if action.navigationType == .linkActivated,["http","https"].contains(url.scheme ?? "") { onOpenURL?(url) }; return .cancel
    }
}
