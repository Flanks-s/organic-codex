import AppKit
import QuartzCore

/// A finite-work texture leaf. Glass, water, badges and satellite clocks belong to the orb host.
@MainActor final class BodyPresentationLeaf {
    let layer=CALayer()
    private let resources: BodyResources
    private var sprite: BodySpriteLayer?
    private var input: BodyPresentationInput?
    private weak var geometryView: NSView?
    private var center=CGPoint.zero
    private var spriteKey: String?
    private var hd: BodyHDPresentation?
    private var hdGeometry=""
    private var disposed=false
    var displayedImage: CGImage? { spriteKey.flatMap { resources.sprites.value($0)?.image } }
    var lightBin:Int {input?.bin ?? 12}
    var samplingTier:Int {input?.tier ?? 56}
    private(set) var imageChanges=0
    var onPictureChange: (() -> Void)?
    init(resources: BodyResources = .shared) {
        self.resources=resources
        layer.name="organic.body.texture"
        layer.setValue(0,forKey:"cpuJobs"); layer.setValue(0,forKey:"gpuSubmissions")
        layer.actions=["contents":NSNull(),"sublayers":NSNull(),"bounds":NSNull(),"position":NSNull(),"hidden":NSNull()]
        layer.masksToBounds=true
        BodyLightRegistry.shared.register(self)
    }
    func configure(bodyID: String, outer: CGFloat, drawingSize: CGFloat, scale: CGFloat, unknown: Bool, visible: Bool, keyWindow: Bool) {
        let old=input
        let drawingChanged=layer.bounds.width != drawingSize
        let coordinates=geometryView.map { BodyLightRegistry.shared.coordinates(view:$0,center:center) }
        // The finite completion scale is 1.12; reserve its host spring overshoot before any motion starts.
        input=BodyPresentationInput(bodyID:bodyID,outer:outer,scale:scale>=1.5 ? 2:1,ll:coordinates?.ll ?? CGPoint(x:-1,y:-1),center:coordinates?.center ?? .zero,unknown:unknown,visible:visible,keyWindow:keyWindow,rasterOuter:drawingSize*1.14)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.bounds=CGRect(x:0,y:0,width:drawingSize,height:drawingSize)
        layer.position=CGPoint(x:drawingSize/2,y:drawingSize/2)
        layer.cornerRadius=drawingSize/2
        CATransaction.commit()
        if old != input { update() }
        else if drawingChanged { onPictureChange?() }
    }
    func setGeometry(view: NSView, center: CGPoint) {
        geometryView=view; self.center=center; refreshLight()
    }
    func refreshLight() {
        guard var next=input,let view=geometryView,!disposed else { return }
        let converted=BodyLightRegistry.shared.coordinates(view:view,center:center)
        next.ll=converted.ll; next.center=converted.center
        guard next != input else { return }
        input=next; update()
    }
    func setVisibility(_ visible: Bool, keyWindow: Bool) {
        guard var next=input else { return }
        next.visible=visible; next.keyWindow=keyWindow
        guard next != input else { return }
        input=next; update()
    }
    private func update() {
        guard !disposed,let input else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.isHidden = !input.visible
        guard input.visible else {
            hd?.dispose(); hd=nil
            // Keep the already displayed picture. No decoding, map preparation or rendering is allowed here.
            return
        }
        guard input.keyWindow else { hd?.suspend(); return }
        if spriteKey != input.spriteKey,let key=resources.load(input),let next=resources.sprites.makeLayer(key:key,at:0) {
            sprite?.dispose(); sprite=next; spriteKey=key
            layer.insertSublayer(next.layer,at:0)
            next.layer.frame=layer.bounds
            next.setActivity(.init(visible:true),at:0)
            imageChanges += 1
            onPictureChange?()
        }
        sprite?.layer.frame=layer.bounds
        if input.outer>56 {
            let geometry="\(input.outer)|\(input.scale)"
            if hdGeometry != geometry { hd?.dispose(); hd=nil; hdGeometry=geometry }
            if hd == nil { hd=BodyHDPresentation(resources:resources,parent:layer,hostView:geometryView) }
            hd?.update(input)
        } else { hd?.dispose(); hd=nil }
        layer.setValue(input.bodyID,forKey:"bodyID")
        layer.setValue(input.bin,forKey:"lightBin")
        layer.setValue(input.outer,forKey:"logicalOuter")
        layer.setValue(imageChanges,forKey:"imageChanges")
        layer.setValue(resources.sprites.residentBytes,forKey:"sharedSpriteBytes")
        layer.setValue(resources.sprites.peakBytes,forKey:"sharedSpritePeakBytes")
    }
    var work: [String:Int] { ["imageChanges":imageChanges,"cpuJobs":layer.value(forKey:"cpuJobs") as? Int ?? 0,"gpuSubmissions":layer.value(forKey:"gpuSubmissions") as? Int ?? 0] }
    func dispose() {
        guard !disposed else { return }; disposed=true
        BodyLightRegistry.shared.remove(self)
        hd?.dispose(); hd=nil; sprite?.dispose(); sprite=nil; input=nil
        onPictureChange=nil; layer.contents=nil; layer.removeAllAnimations(); layer.removeFromSuperlayer()
    }
    isolated deinit { BodyLightRegistry.shared.remove(self); hd?.dispose(); sprite?.dispose() }
}
