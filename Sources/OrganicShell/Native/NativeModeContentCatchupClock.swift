import AppKit
import QuartzCore

/// One stream budget per window and display cycle, shared by its retained split/column transcripts.
@MainActor final class NativeModeContentCatchupClock {
    static let shared=NativeModeContentCatchupClock()
    private var groups:[ObjectIdentifier:Group]=[:]
    private var membership:[ObjectIdentifier:ObjectIdentifier]=[:]
    #if M11_MODE_SELFTEST
    private(set) var verificationFrameSerial=0
    #endif
    func enqueue(_ view:NSView,step:@escaping (inout Int)->Bool) {
        let id=ObjectIdentifier(view),key=view.window.map(ObjectIdentifier.init) ?? id
        if let old=membership[id],old != key {groups[old]?.remove(id)}
        let group=groups[key] ?? Group(owner:self,key:key)
        groups[key]=group;membership[id]=key;group.enqueue(view,step:step)
    }
    func cancel(_ view:NSView) {
        let id=ObjectIdentifier(view)
        if let key=membership.removeValue(forKey:id) {groups[key]?.remove(id)}
    }
    private func finished(_ id:ObjectIdentifier,in group:Group) {
        if membership[id] == group.key {membership[id]=nil}
    }
    private func stopped(_ group:Group) {if groups[group.key] === group {groups[group.key]=nil}}

    @MainActor private final class Group:NSObject {
        private struct Pending {weak var view:NSView?;let step:(inout Int)->Bool}
        weak var owner:NativeModeContentCatchupClock?
        let key:ObjectIdentifier
        private var pending:[ObjectIdentifier:Pending]=[:],order:[ObjectIdentifier]=[]
        private var link:CADisplayLink?,fallback:Timer?
        init(owner:NativeModeContentCatchupClock,key:ObjectIdentifier) {self.owner=owner;self.key=key}
        func enqueue(_ view:NSView,step:@escaping (inout Int)->Bool) {
            let id=ObjectIdentifier(view)
            if pending[id] == nil {order.append(id)}
            pending[id]=Pending(view:view,step:step)
            guard link == nil,fallback == nil else {return}
            if view.window?.isVisible == true {
                let link=view.displayLink(target:self,selector:#selector(tick(_:)))
                link.add(to:.main,forMode:.common);self.link=link
            } else {
                // A never-ordered verification window has no display callbacks.
                let interval=view.window?.screen.map {DisplayProfile.of($0).frameInterval} ?? 1/60
                let timer=Timer(timeInterval:interval,repeats:true) { [weak self] _ in MainActor.assumeIsolated {self?.drain()}}
                fallback=timer;RunLoop.main.add(timer,forMode:.common)
            }
        }
        func remove(_ id:ObjectIdentifier) {pending[id]=nil;order.removeAll {$0 == id};if pending.isEmpty {stop()}}
        @objc private func tick(_ link:CADisplayLink) {drain()}
        private func drain() {
            #if M11_MODE_SELFTEST
            owner?.verificationFrameSerial+=1
            #endif
            var budget=8
            let turn=order;order=[]
            for id in turn {
                guard let value=pending[id],let view=value.view else {pending[id]=nil;owner?.finished(id,in:self);continue}
                let destination=view.window.map(ObjectIdentifier.init) ?? id
                if destination != key {
                    pending[id]=nil;owner?.enqueue(view,step:value.step);continue
                }
                if budget>0,!value.step(&budget) {pending[id]=nil;owner?.finished(id,in:self)}
                if pending[id] != nil {order.append(id)}
            }
            // A second viewport gets the next normal stream packet rather than an extra packet this cycle.
            if order.count>1 {order.append(order.removeFirst())}
            if pending.isEmpty {stop()}
        }
        private func stop() {link?.invalidate();link=nil;fallback?.invalidate();fallback=nil;owner?.stopped(self)}
    }
}
