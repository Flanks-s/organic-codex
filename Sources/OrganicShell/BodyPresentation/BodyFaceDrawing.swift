import AppKit

/// Small menu/row faces share the same immutable direction images and cache as the orb leaf.
@MainActor enum BodyFaceDrawing {
    static func draw(_ bodyID: String, in rect: CGRect) {
        guard let cg=BodyResources.shared.image(bodyID:bodyID,outer:min(56,max(16,rect.width))) else { return }
        NSImage(cgImage:cg,size:rect.size).draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
}
