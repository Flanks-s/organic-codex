import AppKit
import QuartzCore

struct TideMaterialPose:Equatable {
    let owner: String
    let body: CGRect
    var tailAmount = 1.0
    var lean = 26.0
    var horizontalVelocity = 0.0
    var retracting=false
    var contour: TideContour { .init(body: body, tailAmount: tailAmount, lean: lean, horizontalVelocity: horizontalVelocity,retracting:retracting) }
}

@MainActor private final class TideShadowView:NSView {override var isFlipped:Bool {true};override func hitTest(_ point:NSPoint)->NSView? {nil}}

/// Retained native glass. Warmup allocates parts outside event delivery; identical poses do no material work.
@MainActor final class DockTideShape {
    let owner:String
    private(set) var views:[NSGlassEffectView]=[]
    private(set) var contour:TideContour?
    private(set) var constructionMS=0.0
    private weak var bodyGlass:NSGlassEffectView?
    private weak var parent:NSView?
    private let originalTint:NSColor?
    private let shadowHost=TideShadowView()
    private let shadow=CALayer()
    private var styleAmount:Double?
    private(set) var tone:[Double]=[]
    var onTintWrite:(()->Void)?
    var onAllocation:(()->Void)?
    var ready:Bool {views.count==TideTailBudget.pieces}

    init(owner:String,parent:NSView,material:NSGlassEffectView,shadowParent:NSView?=nil,allocate:Bool=true) {
        self.owner=owner;self.parent=parent;bodyGlass=material;originalTint=material.tintColor
        shadowHost.wantsLayer=true;shadowHost.frame=(shadowParent ?? parent).bounds
        shadowHost.layer?.masksToBounds=false;shadowHost.layer?.addSublayer(shadow)
        shadow.frame=shadowHost.bounds;shadow.isGeometryFlipped=true
        shadow.shadowColor=NSColor.black.cgColor;shadow.shadowRadius=12;shadow.shadowOffset=CGSize(width:0,height:6)
        let host=shadowParent ?? parent
        host.addSubview(shadowHost,positioned:.below,relativeTo:host.subviews.first{$0 is NSGlassEffectContainerView})
        shadowHost.isHidden=true
        if allocate {while !ready {prepareOne()}}
    }
    func matches(_ glass:NSGlassEffectView)->Bool {bodyGlass === glass}
    func prepareOne() {
        guard !ready,let parent,let bodyGlass else{return}
        let start=CACurrentMediaTime(),glass=NSGlassEffectView()
        onAllocation?()
        glass.identifier = .init("tide.tail.\(owner).\(views.count)")
        glass.style=bodyGlass.style;glass.tintColor=bodyGlass.tintColor;glass.isHidden=true
        parent.addSubview(glass,positioned:.below,relativeTo:bodyGlass);views.append(glass)
        constructionMS += (CACurrentMediaTime()-start)*1000
    }
    func apply(_ input:TideContour,write:(NSGlassEffectView,CGRect,Bool)->Void) {
        let next=input.limited(to:views.count)
        guard contour?.parts != next.parts else{return}
        contour=next
        for (i,glass) in views.enumerated() {
            if next.tail.indices.contains(i) {write(glass,next.tail[i].rect,false)}
            else if !glass.isHidden {write(glass,.zero,true)}
        }
        let path=CGMutablePath()
        for part in next.parts {path.addRoundedRect(in:part.rect,cornerWidth:part.radius,cornerHeight:part.radius)}
        shadow.shadowPath=path
    }
    func style(identity:NSColor,amount:Double) {
        let a=min(1,max(0,amount))
        guard styleAmount != a else{return};styleAmount=a
        let c=identity.usingColorSpace(.sRGB) ?? identity
        tone=[58*0.84+Double(c.redComponent)*255*0.16,59*0.84+Double(c.greenComponent)*255*0.16,58*0.84+Double(c.blueComponent)*255*0.16]
        let from=originalTint?.usingColorSpace(.sRGB)
        // R2 measured about 60% of the board's chroma at alpha .55. This remains a screen-calibration input.
        let targetAlpha=0.92
        let tint:NSColor?
        if a==0 {tint=originalTint}
        else {
            let rgb=zip([from.map{Double($0.redComponent)} ?? tone[0]/255,from.map{Double($0.greenComponent)} ?? tone[1]/255,from.map{Double($0.blueComponent)} ?? tone[2]/255],tone).map{$0.0+($0.1/255-$0.0)*a}
            let alpha=Double(from?.alphaComponent ?? 0)+(targetAlpha-Double(from?.alphaComponent ?? 0))*a
            tint=NSColor(srgbRed:rgb[0],green:rgb[1],blue:rgb[2],alpha:alpha)
        }
        for glass in [bodyGlass].compactMap({$0})+views where glass.tintColor != tint {glass.tintColor=tint;onTintWrite?()}
        shadow.shadowOpacity=Float(0.25*a);shadowHost.isHidden=a<=0
    }
    /// Return to the exact previous material continuously before parking the reusable parts.
    func park() {
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        if bodyGlass?.tintColor != originalTint {bodyGlass?.tintColor=originalTint;onTintWrite?()}
        for glass in views where !glass.isHidden {glass.isHidden=true;onTintWrite?()}
        shadowHost.isHidden=true;shadow.shadowOpacity=0;contour=nil;styleAmount=nil
    }
    func fadeModeExit(_ fade:TideModeExit) {fade.include(views);fade.include([shadowHost],plane:.behindMaterial)}
    func dispose() {park();shadowHost.removeFromSuperview();views.forEach{$0.removeFromSuperview()};views=[]}
    var probe:[String:Any] {
        let actual=views.enumerated().filter{!$0.element.isHidden && $0.element.frame.width>0}.map { i,g in
            ["id":"tide.tail.\(owner).\(i)","rect":Self.rect(g.frame),"radius":g.cornerRadius] as [String:Any]
        }
        return ["owner":owner,"nativeParts":actual.count+(bodyGlass?.isHidden == false ? 1:0),"allocatedTailViews":views.count,"tailBudget":TideTailBudget.pieces,
                "constructionMS":constructionMS,"nativeFusionVerified":false,"body":bodyGlass.map{Self.rect($0.frame)} ?? [],"logicalBody":contour.map{Self.rect($0.body.rect)} ?? [],"tail":actual,
                "toneRGB":tone,"shadowOpacity":shadow.shadowOpacity,"shadowOutsideGlassContainer":shadowHost.superview !== parent,"tintAmount":styleAmount ?? 0,"usesMask":views.contains{$0.layer?.mask != nil},"glassFilters":([bodyGlass].compactMap{$0}+views).reduce(0){$0+($1.layer?.filters?.count ?? 0)},"usesPaintedFill":false]
    }
    static func rect(_ r:CGRect)->[CGFloat] {[r.minX,r.minY,r.width,r.height]}
}
