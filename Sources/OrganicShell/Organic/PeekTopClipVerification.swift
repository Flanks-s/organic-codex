import AppKit
import QuartzCore

@MainActor enum PeekTopClipVerification {
    static func run(to output:URL,check:(Bool,String)->Void) {
        try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for scale:CGFloat in [1,2] {for top:CGFloat in [52,144] {
            let size=CGSize(width:900,height:820),c=LongConversationVerification.fixture(160)
            c.running=false
            let peek=PeekNode(size:size,scale:scale);peek.ambient=false;peek.motionEnabled=false
            defer {peek.clear();peek.header.dispose()}
            let g=AutoLayout.Peek(blur:CGRect(x:280,y:top,width:300,height:560),capsule:CGRect(x:296,y:top+468,width:268,height:48),
                                  lyrics:CGRect(x:280,y:top,width:300,height:458),rowsTop:top+520,column:nil)
            peek.open(c,geometry:g)
            let lyrics=peek.verificationLyricsLayer,expected=max(g.lyrics.minY,peek.header.geometry.contentTop-18)
            let tag="\(Int(scale))x-top\(Int(top))"
            check(lyrics.frame.minY==expected && lyrics.frame.maxY==g.lyrics.maxY,"M11.22 brief contentTop clip with unchanged bottom \(tag)")
            check(lyrics.masksToBounds,"M11.22 top is a real content clip \(tag)")
            let mask=lyrics.mask as? CAGradientLayer,maskID=mask.map(ObjectIdentifier.init)
            let end=mask?.locations?.last?.doubleValue ?? -1
            check(abs(end*lyrics.bounds.height-16)<0.0001,"M11.22 existing brief 16pt edge fade \(tag)")
            check(mask?.contents == nil,"M11.22 no synchronous raster mask \(tag)")
            let halo=peek.verificationHalo,haloMask=halo.mask.contents as AnyObject?,header=peek.headerFrame
            for dy:CGFloat in [10_000,-10_000,80] {
                peek.scroll(by:dy)
                check(lyrics.frame.minY==expected && peek.headerFrame==header,"M11.22 scrolling retains the header boundary \(tag)")
                check(lyrics.mask.map(ObjectIdentifier.init)==maskID,"M11.22 scroll reuses the gradient mask \(tag)")
            }
            let p=peek.header.geometry.planet.offsetBy(dx:header!.minX,dy:0)
            check(peek.view.hitTest(CGPoint(x:p.midX,y:p.midY)) === peek.view,"M11.22 M11.12 passive header hit owner retained \(tag)")
            peek.fadeLyrics();peek.retract();peek.clear();peek.open(c,geometry:g)
            check(lyrics.mask.map(ObjectIdentifier.init)==maskID,"M11.22 open/close reuses the gradient mask \(tag)")
            check((peek.verificationHalo.mask.contents as AnyObject?) === haloMask,"M11.22 fog mask cache untouched \(tag)")
            let image=NativeViewBitmap.capture(peek.view,scale:scale)
            Offscreen.write(image,output.appendingPathComponent("peek-\(tag).png"))
        }}
    }
}
