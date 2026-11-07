import AppKit
import QuartzCore

/// One admitted operation per run-loop turn. No continuation can finish a cold plan on an input callback.
@MainActor final class M11IdlePreparation {
    enum Stop:Error {case interrupted,unsupportedSource(String)}
    let interval:Double
    var valid:()->Bool
    var recordSlices=false
    private(set) var slices:[(name:String,ms:Double)]=[]
    private var segment:(name:String,start:Double,span:M10ColumnWorkTrace.Span,trace:ModeSignposts.Trace?)?
    init(interval:Double,valid:@escaping ()->Bool) {self.interval=interval;self.valid=valid}
    func finish() {
        guard let segment else{return}
        let ms=(CACurrentMediaTime()-segment.start)*1000
        if recordSlices {slices.append((segment.name,ms))}
        segment.span.end();segment.trace?.record("OrganicPrewarmSlice",.end,detail:segment.name)
        self.segment=nil
    }
    func step<T>(_ name:String,_ body:()->T) async throws ->T {
        // Count the entire resumed segment, including assembly after the previous operation returned.
        finish()
        try await Task.sleep(for:.seconds(max(0.0001,interval)))
        let observing=recordSlices || M10ColumnWorkTrace.active || ModeSignposts.enabled
        let resumed=observing ? CACurrentMediaTime():0
        guard !Task.isCancelled,valid() else {throw Stop.interrupted}
        if observing {
            let trace=ModeSignposts.enabled ? ModeSignposts.Trace():nil
            trace?.record("OrganicPrewarmSlice",.begin,detail:name)
            segment=(name,resumed,M10ColumnWorkTrace.scope("scene.prewarm.slice",["phase":name]),trace)
        }
        return autoreleasepool(invoking:body)
    }
    /// The native root is deliberately admitted for capture; descendants retain their real visibility/masks.
    func capture(_ view:NSView,scale:CGFloat,around:@escaping (@MainActor ()->Void)->Void = {$0()}) async throws ->CGImage {
        func unsupported(_ v:NSView)->Bool {
            if v.isHidden || v.layer?.isHidden == true || v.layer?.mask?.bounds.isEmpty == true {return false}
            return String(describing:type(of:v)) == "ToolsTerminalView" || v.subviews.contains(where:unsupported)
        }
        var unsupportedSource=false
        let builder:M11IdleSurfaceBuilder = try await step("capture.setup") {
            var result:M11IdleSurfaceBuilder!
            around {unsupportedSource=unsupported(view);result=M11IdleSurfaceBuilder(view,scale:scale,includeWindowFrame:false)}
            return result
        }
        // Tools' draw ignores its dirty rect. A small tile still invokes its entire renderer (>8ms).
        if unsupportedSource {throw Stop.unsupportedSource("ToolsTerminalView")}
        // Several tiles to a slice: with one, most of a preparation's wall clock went to waiting for the next slice, and a
        // click 1.7 s after the last switch still found nothing prepared.
        while !builder.ready {
            try await step("capture.tile") {
                around {
                    let began=CACurrentMediaTime()
                    repeat {builder.step()} while !builder.ready && CACurrentMediaTime()-began<0.003
                }
            }
        }
        let picture=builder.finish()!
        let tiles=picture.tiles.map{($0.rect,$0.image)},size=picture.size
        finish() // pure immutable-image assembly is not main-thread work, nor part of a resumed slice
        let image=await Task.detached(priority:.utility) {
            let c=CGContext(data:nil,width:max(1,Int(ceil(size.width*scale))),height:max(1,Int(ceil(size.height*scale))),bitsPerComponent:8,bytesPerRow:0,
                space:tiles.first?.1.colorSpace ?? CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.scaleBy(x:scale,y:scale)
            for (rect,image) in tiles {c.draw(image,in:CGRect(x:rect.minX,y:size.height-rect.maxY,width:rect.width,height:rect.height))}
            return c.makeImage()!
        }.value
        return try await step("capture.ready") {image}
    }
}
