import AppKit
import QuartzCore
import CoreImage

@MainActor enum IslandEventPhaseVerification {
    static func run(to output:URL,check:(Bool,String)->Void) {
        try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        HeaderPickupPaintVerification.run(to:output.appendingPathComponent("pickup"),check:check)
        IslandEventRenderingVerification.run(to:output.appendingPathComponent("rendered"),check:check)
        var records=[[String:Any]]()
        for scale:CGFloat in [1,2] {for reduced in [false,true] {
            let root=IslandPlane(frame:CGRect(x:0,y:0,width:400,height:300)),header=HeaderIsland()
            root.addSubview(header)
            var time=1000.0;header.now={time};header.motionExposure.enabled=false
            header.configure(.init(id:"phase",title:"Activity phase",columnWidth:400,band:44,reduceMotion:reduced,ambient:false,scale:scale))
            defer {header.dispose();withExtendedLifetime(root){}}
            let event=HeaderIslandEvent(kind:.approval,text:"1 approval needs you",at:time)
            header.receive(event,at:time)
            let began=time,tag="\(Int(scale))x-\(reduced ? "reduced":"motion")"
            for dt in [0.0,0.04,0.08,0.125,0.17,0.3] {
                time=began+dt;header.sampleMotion(at:time)
                let expected:CGFloat
                if reduced {expected=dt == 0 ? 0:dt>=0.12 ? 1:dt == 0.04 ? 0.488349:dt == 0.08 ? 0.843836:1}
                else {expected=dt<=0.08 ? 0:dt>=0.17 ? 1:0.684643}
                // Independent oracle constants are the product's easeOut samples (0,0,.58,1).
                check(abs(header.eventButton.alphaValue-expected)<0.00002,"M11.21 entry opacity \(tag) t=\(dt)")
                if dt == 0.04 {check(!header.eventButton.isHidden,"M11.21 entry retained during its delay \(tag)")}
                let blur=(header.eventButton.layer?.filters?.first as? NSObject)?.value(forKey:"inputRadius") as? NSNumber
                if reduced {check((blur?.doubleValue ?? 0)==0,"M11.21 reduced phase has no blur \(tag) t=\(dt)")}
                else if dt == 0 {check(abs((blur?.doubleValue ?? 0)-2)<0.00001,"M11.21 entry starts at 2pt blur \(tag)")}
                if !reduced && dt == 0.125 {check(abs((blur?.doubleValue ?? 0)-2*(1-0.684643))<0.00002,"M11.21 entry blur follows the product phase \(tag)")}
                check(header.eventButton.layer?.mask is CAShapeLayer,"M11.21 live capsule clips activity even during localMotion \(tag) t=\(dt)")
                let baseY=header.geometry.event!.minY
                check(abs(header.eventButton.frame.minY-baseY-(reduced ? 0:4*(1-expected)))<0.0001,"M11.21 entry rises 4pt with product phase \(tag) t=\(dt)")
                func glass(_ v:NSView)->[NSGlassEffectView] { (v as? NSGlassEffectView).map{[$0]} ?? v.subviews.flatMap{glass($0)} }
                let capsule=glass(header).first{$0.frame.width>100 && !$0.isHidden}!
                let clipped=(header.eventButton.layer?.mask as? CAShapeLayer)?.path?.boundingBoxOfPath.offsetBy(dx:header.eventButton.frame.minX,dy:header.eventButton.frame.minY)
                check(clipped.map{abs($0.minY-capsule.frame.minY)<0.001 && abs($0.maxY-capsule.frame.maxY)<0.001} ?? false,"M11.21 clip follows live glass during localMotion \(tag) t=\(dt)")
                records.append(["capsule":NSStringFromRect(capsule.frame),"tag":tag,"leg":"in","time":dt,"alpha":header.eventButton.alphaValue,"y":header.eventButton.frame.minY,"blur":blur?.doubleValue ?? 0])
                Offscreen.write(header.snapshot(scale:scale),output.appendingPathComponent("in-\(tag)-\(Int(dt*1000)).png"))
            }
            time=began+event.hold;header.advance(to:time)
            check(!header.eventButton.isHidden && abs(header.eventButton.alphaValue-1)<0.00001,"M11.21 expiry retains outgoing drawing \(tag)")
            let out=time
            time=out+0.03;header.sampleMotion(at:time)
            check(header.eventButton.alphaValue>0 && header.eventButton.alphaValue<1,"M11.21 expiry fades rather than disappears \(tag)")
            let alpha=header.eventButton.alphaValue
            header.receive(.init(kind:.approval,text:"1 approval needs you",at:time),at:time)
            check(abs(header.eventButton.alphaValue-alpha)<0.00001,"M11.21 reversal continues current opacity \(tag)")
            time+=0.04;header.sampleMotion(at:time)
            if !reduced {check(abs(header.eventButton.alphaValue-alpha)<0.00001,"M11.21 reversal holds its current pose through entry delay \(tag)")}
            time+=0.4;header.sampleMotion(at:time)
            check(abs(header.eventButton.alphaValue-1)<0.00001,"M11.21 reversal lands visible \(tag)")
            time+=5;header.advance(to:time);time+=reduced ? 0.12:0.06;header.sampleMotion(at:time)
            check(header.eventButton.isHidden && header.eventButton.alphaValue==0,"M11.21 outgoing drawing retires at authored deadline \(tag)")
            // Arrival while a column is in flight must wait for the existing host-motion handoff.
            header.beginMotion();header.receive(.init(kind:.done,text:"Done",at:time),at:time)
            check(header.eventButton.isHidden,"M11.21 mid-flight arrival stays suppressed \(tag)")
            header.endMotion();check(header.eventButton.alphaValue==0,"M11.21 landing begins the delayed phase \(tag)")
            time+=0.3;header.sampleMotion(at:time)
            check(header.eventButton.alphaValue==1,"M11.21 landing phase reaches its endpoint \(tag)")
        }}
        try? JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("samples.json"))
    }
}
