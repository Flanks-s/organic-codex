import AppKit

/// Product NormieDetailView.OfflineBanner: solid canvas under the orange tint, a contrast outline.
@MainActor final class NormieOfflineBanner:NormieView {
    private let heading=NormieDrawing.label(size:12,weight:.medium),message=NormieDrawing.label(size:12)
    var stringValue=""{didSet{let parts=stringValue.split(separator:"\n",maxSplits:1,omittingEmptySubsequences:false);heading.stringValue=parts.first.map(String.init) ?? "";message.stringValue=parts.count>1 ? String(parts[1]):"";setAccessibilityLabel(stringValue);needsLayout=true}}
    override init(frame:NSRect){super.init(frame:frame);message.maximumNumberOfLines=3;message.lineBreakMode = .byWordWrapping;message.textColor = NativePalette.secondaryLabel;addSubview(heading);addSubview(message);setAccessibilityElement(true);setAccessibilityRole(.group);heading.setAccessibilityElement(false);message.setAccessibilityElement(false)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func layout(){super.layout();place(heading,CGRect(x:34,y:9,width:max(1,bounds.width-46),height:16));place(message,CGRect(x:34,y:25,width:max(1,bounds.width-46),height:max(1,bounds.height-32)))}
    override func draw(_ dirtyRect:NSRect){
        let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:10,yRadius:10)
        let contrast=NativeDisplayOptions.shared.state.increaseContrast
        let tint=NSColor(srgbRed:0.945,green:0.514,blue:0.133,alpha:1)
        // Alpha compositing onto the actual canvas must happen before making the plate opaque.
        let base=NativePalette.canvas.usingColorSpace(.sRGB) ?? NSColor(white:0.12,alpha:1)
        (base.blended(withFraction:contrast ? 0.18:0.10,of:tint) ?? base).setFill();shape.fill()
        if contrast{NSColor.systemOrange.setStroke();shape.lineWidth=1;shape.stroke()}
        NSImage(systemSymbolName:"exclamationmark.triangle.fill",accessibilityDescription:nil)?.withSymbolConfiguration(.init(paletteColors:[.systemOrange]))?.draw(in:NormieDrawing.rect(CGRect(x:12,y:12,width:14,height:14),scale:scale),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
}
