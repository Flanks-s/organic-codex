import AppKit

/// A picture owns frozen ink and an independent system material, never a borrowed live control or split item.
/// The opaque body image remains underneath, so a glass surface cannot reveal another mode at full contrast.
@MainActor struct ModeContentMaterial {
    let kind:String,rect:CGRect,inkRect:CGRect,clip:CGRect,ink:CGImage
    let style:NSGlassEffectView.Style,tint:NSColor?,radius:CGFloat,appearance:NSAppearance
    func makeView(scale:CGFloat)->NSView {
        let host=ModeMaterialClip(frame:clip);host.wantsLayer=true;host.layer?.masksToBounds=true
        let glass=NSGlassEffectView(frame:rect.offsetBy(dx:-clip.minX,dy:-clip.minY))
        glass.identifier=NSUserInterfaceItemIdentifier("mode.photo.glass."+kind)
        glass.style=style;glass.tintColor=tint;glass.cornerRadius=radius;glass.appearance=appearance
        let content=ModeMaterialClip(frame:CGRect(origin:.zero,size:rect.size));content.wantsLayer=true
        let image=CALayer();image.isGeometryFlipped=true;image.contentsScale=scale;image.contents=ink
        image.frame=inkRect.offsetBy(dx:-rect.minX,dy:-rect.minY);content.layer?.addSublayer(image)
        glass.contentView=content;host.addSubview(glass)
        host.setAccessibilityElement(false);host.setAccessibilityHidden(true)
        return host
    }
}
@MainActor private final class ModeMaterialClip:NSView {
    override var isFlipped:Bool {true}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
}

