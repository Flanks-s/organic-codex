import AppKit
import QuartzCore

/// StatusInspector / ChangesList's snappy reflows. Rest controls remain exactly the existing native views.
/// This admits no new layout at rest: it animates the frames between two already-built native layouts.
@MainActor final class NormieInspectorMotion {
    struct Previous {let key:String,rect:CGRect,picture:NormieMotionPicture}
    private weak var host:NSView?,scroll:NSScrollView?
    let clock=NormieMotionClock()
    var enabled=ProcessInfo.processInfo.environment["M10_COMPOSER_SHARP"] != "1"
    private(set) var motions:[NormieDetailItemMotion]=[]
    private var ends:[(NSView,CGRect)]=[]
    func attach(_ host:NSView,scroll:NSScrollView){self.host=host;self.scroll=scroll;clock.attach(host);clock.onSuspend={[weak self] in self?.settle()};clock.frame={[weak self] t,p in self?.advance(t,p) ?? false}}
    func settle(){clock.stop();motions.forEach{$0.proxy.retire()};motions=[];for (v,r) in ends{v.frame=r};ends=[]}
    func before(_ document:NSView,animated:NormieDetailItemMotion.Kind?)->[Previous]{
        // Sample interruption before retiring; selected read-only text and the commit field stay mounted.
        if clock.running{_ = advance(clock.now,clock.profile)}
        guard animated != nil,let host,(host.window?.isVisible == true || clock.manualTime != nil),!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else{settle();return []}
        var result:[Previous]=[]
        let visible=scroll?.convert(scroll!.bounds,to:host) ?? host.bounds
        for v in document.subviews where !v.isHidden{
            let r=v.convert(v.bounds,to:host)
            guard r.intersects(visible),let key=v.identifier?.rawValue,let picture=NormieMotionPicture.capture(v,scale:(host as? NormieView)?.scale ?? 2) else{continue}
            result.append(.init(key:key,rect:r,picture:picture))
        }
        settle();return result
    }
    func after(_ document:NSView,before:[Previous],kind:NormieDetailItemMotion.Kind?){
        guard !before.isEmpty,let host,let kind else{return}
        let previous=Dictionary(before.map{($0.key,$0)},uniquingKeysWith:{a,_ in a}),now=clock.now
        let visible=scroll?.convert(scroll!.bounds,to:host) ?? host.bounds
        var keep=Set<String>()
        for v in document.subviews where !v.isHidden{
            guard let key=v.identifier?.rawValue else{continue};keep.insert(key)
            let r=v.convert(v.bounds,to:host),old=previous[key]
            guard r.intersects(visible) || old?.rect.intersects(visible) == true,
                  let picture=NormieMotionPicture.capture(v,scale:(host as? NormieView)?.scale ?? 2) else{continue}
            let proxy=NormieMotionProxy(source:v,picture:picture,in:host);proxy.clippingView=scroll
            motions.append(.init(proxy:proxy,from:old?.rect ?? r,to:r,start:now,kind:kind,fade:old == nil))
            ends.append((v,v.frame))
        }
        for old in before where !keep.contains(old.key){
            let proxy=NormieMotionProxy(source:nil,picture:old.picture,in:host);proxy.clippingView=scroll
            motions.append(.init(proxy:proxy,from:old.rect,to:old.rect,start:now,kind:kind,appearing:false))
        }
        _ = advance(now,clock.profile);clock.start()
    }
    @discardableResult func advance(_ t:Double,_ profile:DisplayProfile)->Bool{
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion{settle();return false}
        CATransaction.begin();CATransaction.setDisableActions(true)
        motions.removeAll{motion in
            let r=motion.rect(at:t)
            if let v=motion.proxy.nativeSource,let parent=v.superview,let host{v.frame=parent.convert(r,from:host)}
            if motion.advance(t,profile:profile,enabled:enabled){return false};motion.proxy.retire();return true
        }
        CATransaction.commit()
        if motions.isEmpty{for (v,r) in ends{v.frame=r};ends=[];return false};return true
    }
    isolated deinit{settle()}
}
