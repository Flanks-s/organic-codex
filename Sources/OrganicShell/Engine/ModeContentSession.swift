import AppKit
import QuartzCore

/// A session has one immutable picture and one live mode. Requested direction never changes its representation.
@MainActor final class ModeContentSession {
    let id=UUID().uuidString,photoID:String,photoMode:String,liveMode:String,revision:String,selection:String
    let image:CGImage,size:CGSize,scale:CGFloat
    private(set) var requestedMode:String
    private(set) var anchorU:Double,anchorTime:Double,direction:Double
    private(set) var isHeld=false
    var leaseGeneration:UInt64=0
    let trace:ModeSignposts.Trace?
    init(photo:ModeWarmPicture,target:String,time:Double,trace:ModeSignposts.Trace?) {
        photoID=photo.id;photoMode=photo.mode;liveMode=target;revision=photo.revision
        image=photo.image;size=photo.size;scale=photo.scale;selection=photo.selection;requestedMode=target
        anchorU=photo.mode == "normie" ? 1:0;anchorTime=time;direction=target == "normie" ? 1:-1;self.trace=trace
    }
    func progress(at time:Double)->Double {min(1,max(0,anchorU+(isHeld ? 0:direction*max(0,time-anchorTime)/0.220)))}
    static func alpha(_ u:Double)->Double {u*u*(3-2*u)}
    func turn(to target:String,at time:Double,presentedAlpha:Double?=nil) {
        if let alpha=presentedAlpha,alpha.isFinite {
            var low=0.0,high=1.0
            for _ in 0..<24 {let middle=(low+high)*0.5;if Self.alpha(middle)<alpha {low=middle}else{high=middle}}
            anchorU=alpha<=0.000001 ? 0:(alpha>=0.999999 ? 1:(low+high)*0.5)
        } else {anchorU=progress(at:time)}
        anchorTime=time;requestedMode=target;direction=target == "normie" ? 1:-1
    }
    func hold(at time:Double) {anchorU=progress(at:time);anchorTime=time;isHeld=true}
    func resume(at time:Double) {anchorTime=time;isHeld=false}
    func atDestination(_ time:Double)->Bool {!isHeld && progress(at:time) == (requestedMode == "normie" ? 1:0)}
    func record(at time:Double,renderedRevision:String?=nil,boundary:Bool=false) {
        let u=progress(at:time)
        trace?.record(boundary ? "ModeContentState":"ModeContentCommit",detail:"sessionID=\(id) photoID=\(photoID) liveMode=\(liveMode) requestedMode=\(requestedMode) u=\(u) a=\(Self.alpha(u)) leaseGeneration=\(leaseGeneration) renderedRevision=\(renderedRevision ?? revision)")
    }
    /// Sample the original smoothstep phase, rather than restarting an ease curve at each reversal.
    func animate(_ layer:CALayer,at time:Double,photoOnTop:Bool,invert:Bool=false) {
        let u=progress(at:time),target=requestedMode == "normie" ? 1.0:0.0
        let destination=isHeld ? u:target
        let duration=abs(destination-u)*0.220
        let animation=CAKeyframeAnimation(keyPath:"opacity")
        let count=max(2,Int(ceil(duration*240)))
        animation.values=(0...count).map {i in let a=Self.alpha(u+(destination-u)*Double(i)/Double(count));return invert ? 1-a:a}
        animation.keyTimes=(0...count).map {NSNumber(value:Double($0)/Double(count))}
        animation.calculationMode = .linear;animation.beginTime=layer.convertTime(time,from:nil)
        animation.duration=max(0.00001,duration);animation.fillMode = .both;animation.isRemovedOnCompletion=false
        ModeSignposts.frameRange(animation)
        layer.opacity=Float(invert ? 1-Self.alpha(destination):Self.alpha(destination));layer.add(animation,forKey:"mode.content.phase")
        record(at:time,boundary:true)
    }
}

@MainActor final class ModeWarmPicture {
    let id=UUID().uuidString,mode:String,revision:String,image:CGImage,size:CGSize,scale:CGFloat,selection:String
    let captureMS:Double,maximumSliceMS:Double
    let materials:[ModeContentMaterial]
    var bytes:Int {image.bytesPerRow*image.height+materials.reduce(0){$0+$1.ink.bytesPerRow*$1.ink.height}}
    init(mode:String,revision:String,image:CGImage,size:CGSize,scale:CGFloat,captureMS:Double,maximumSliceMS:Double,selection:String="",materials:[ModeContentMaterial]=[]) {
        self.mode=mode;self.revision=revision;self.image=image;self.size=size;self.scale=scale;self.captureMS=captureMS;self.maximumSliceMS=maximumSliceMS;self.selection=selection;self.materials=materials
    }
}

/// This input shield owns no native views and has exactly one image layer, with no history or composition groups.
@MainActor final class ModeContentPictureView:NSView {
    override var isFlipped:Bool {true}
    let imageLayer=CALayer()
    override init(frame:NSRect) {super.init(frame:frame);wantsLayer=true;layer?.addSublayer(imageLayer);imageLayer.isGeometryFlipped=true;setAccessibilityElement(false)}
    required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
    override func hitTest(_ point:NSPoint)->NSView? {bounds.contains(point) ? self:nil}
    override func mouseDown(with event:NSEvent) {}
    func install(_ picture:ModeWarmPicture) {
        subviews.forEach {$0.removeFromSuperview()}
        frame=CGRect(origin:.zero,size:picture.size);imageLayer.frame=bounds;imageLayer.contents=picture.image;imageLayer.contentsScale=picture.scale
        for material in picture.materials {addSubview(material.makeView(scale:picture.scale))}
    }
    func clear() {layer?.removeAllAnimations();imageLayer.contents=nil;subviews.forEach {$0.removeFromSuperview()};removeFromSuperview()}
}

/// One immutable tile set. Joining pixels has no AppKit or layer access and runs off the main thread.
struct ModeContentRaster: @unchecked Sendable {
    struct Tile {let rect:CGRect,image:CGImage}
    let tiles:[Tile],size:CGSize,scale:CGFloat
    func render()->CGImage? {
        guard let c=CGContext(data:nil,width:max(1,Int(ceil(size.width*scale))),height:max(1,Int(ceil(size.height*scale))),bitsPerComponent:8,bytesPerRow:0,space:tiles.first?.image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return nil}
        c.scaleBy(x:scale,y:scale)
        for tile in tiles {c.draw(tile.image,in:CGRect(x:tile.rect.minX,y:size.height-tile.rect.maxY,width:tile.rect.width,height:tile.rect.height))}
        return c.makeImage()
    }
}
