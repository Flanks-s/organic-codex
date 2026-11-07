import AppKit
import QuartzCore

/// One work item per distinct display ticket. Wall-clock spacing applies only to the hidden-window timer.
@MainActor enum ModeContentWorkBoundary {
    private struct Job {
        weak var host:NSView?
        let interval:Double,trace:ModeSignposts.Trace?,body:@MainActor ()->Void
    }
    private struct Ticket {
        let timestamp:Double,target:Double,interval:Double,display:Bool
    }
    @MainActor private final class Clock:NSObject {
        var link:CADisplayLink?,timer:Timer?
        weak var window:NSWindow?
        func start(for job:Job) {
            #if M11_MODE_SELFTEST
            if verificationManualTickets {stop();return}
            if let hz=Double(ProcessInfo.processInfo.environment["M1131_SIM_HZ"] ?? ""),hz>0 {
                if timer != nil {return};stop()
                let interval=1/hz,origin=CACurrentMediaTime()
                let timer=Timer(timeInterval:interval,repeats:true) {_ in MainActor.assumeIsolated {
                    let tick=origin+floor((CACurrentMediaTime()-origin)/interval)*interval
                    ticket(Ticket(timestamp:tick,target:tick+interval,interval:interval,display:true))
                }}
                self.timer=timer;RunLoop.main.add(timer,forMode:.common);return
            }
            #endif
            if let host=job.host,let window=host.window,window.isVisible {
                if link != nil,self.window === window {return}
                stop();self.window=window
                let link=host.displayLink(target:self,selector:#selector(frame(_:)))
                let hz=Float(window.screen?.maximumFramesPerSecond ?? 60)
                link.preferredFrameRateRange=CAFrameRateRange(minimum:hz,maximum:hz,preferred:hz)
                link.add(to:.main,forMode:.common);self.link=link
            } else if timer == nil {
                stop()
                let earliest=max(lastSubmission+job.interval,lastStarted+job.interval)
                let delay=max(0.001,earliest-CACurrentMediaTime())
                let timer=Timer(timeInterval:delay,repeats:false) { [weak self] _ in MainActor.assumeIsolated {
                    self?.timer=nil
                    let now=CACurrentMediaTime()
                    ticket(Ticket(timestamp:now,target:now+job.interval,interval:job.interval,display:false))
                    if !awaitingCommit,!executing,let next=jobs.first {self?.start(for:next)}
                }}
                self.timer=timer;RunLoop.main.add(timer,forMode:.common)
            }
        }
        @objc private func frame(_ link:CADisplayLink) {
            ticket(Ticket(timestamp:link.timestamp,target:link.targetTimestamp,interval:max(0.001,link.targetTimestamp-link.timestamp),display:true))
        }
        func stop() {link?.invalidate();link=nil;timer?.invalidate();timer=nil;window=nil}
    }
    private static let clock=Clock()
    private static var jobs:[Job]=[]
    private static var awaitingCommit=false,executing=false,lastSubmission = -Double.infinity,lastStarted = -Double.infinity,serial:UInt64=0
    private static var lastDisplayTimestamp = -Double.infinity,activeTicket:Ticket?,activeWorkStarted:Double?
    static func schedule(in host:NSView?=nil,interval:Double,_ body:@escaping @MainActor ()->Void) {
        jobs.append(Job(host:host,interval:max(0.001,interval),trace:ModeSignposts.current ?? (ModeSignposts.enabled ? ModeSignposts.Trace():nil),body:body))
        if !executing,!awaitingCommit {clock.start(for:jobs[0])}
    }
    static func flightSubmitted(interval:Double) {lastSubmission=CACurrentMediaTime()}
    static func cancel(in host:NSView) {
        jobs.removeAll {$0.host === host}
        if jobs.isEmpty {clock.stop()}
    }
    /// Budget CPU time from this item's actual start, independent of the callback's display phase.
    /// Keep a commit reserve inside the execution cycle; a late callback must not shrink every batch.
    static func captureBudget(at now:Double=CACurrentMediaTime())->Double {
        guard let ticket=activeTicket,let started=activeWorkStarted else {return 0.0035}
        let reserve=max(0.002,ticket.interval*0.15)
        let deadline=started+ticket.interval-reserve
        return min(0.006,ticket.interval*0.48,max(0,deadline-now))
    }
    #if M11_MODE_SELFTEST
    static var verificationManualTickets=false
    static func verificationDisplayTicket(timestamp:Double,target:Double,interval:Double) {
        ticket(Ticket(timestamp:timestamp,target:target,interval:interval,display:true))
    }
    static var verificationState:[String:Any] {
        ["jobs":jobs.count,"awaitingCommit":awaitingCommit,"executing":executing,"timer":clock.timer != nil,"displayLink":clock.link != nil,"frame":serial]
    }
    #endif
    private static func ticket(_ ticket:Ticket) {
        let trace=jobs.first?.trace ?? ModeSignposts.current
        func record(_ result:String,_ reason:String) {
            trace?.record("ModeContentTicket",detail:"source=\(ticket.display ? "display":"timer") result=\(result) reason=\(reason) queued=\(jobs.count)",timestamp:ticket.timestamp,target:ticket.target)
        }
        guard !jobs.isEmpty else {record("rejected","empty");clock.stop();return}
        if ticket.display {
            guard ticket.timestamp>lastDisplayTimestamp else {record("rejected","duplicate-display");return}
            // Consume the physical ticket even when an older submission is still pending.
            lastDisplayTimestamp=ticket.timestamp
        }
        guard !awaitingCommit,!executing else {record("rejected",awaitingCommit ? "awaiting-commit":"executing");return}
        guard let job=jobs.first else {return}
        guard CACurrentMediaTime()>=lastSubmission+job.interval else {record("rejected","flight-first-fence");return}
        if !ticket.display,CACurrentMediaTime()<lastStarted+job.interval*0.9 {record("rejected","timer-spacing");return}
        serial &+= 1;let frame=serial
        record("accepted","new-cycle");awaitingCommit=true
        let observer=CFRunLoopObserverCreateWithHandler(nil,CFRunLoopActivity.beforeWaiting.rawValue,false,CFIndex.max) {_,_ in
            MainActor.assumeIsolated {
                awaitingCommit=false
                guard !jobs.isEmpty else {clock.stop();return}
                let next=jobs.removeFirst()
                guard CACurrentMediaTime()>=lastSubmission+next.interval else {
                    jobs.insert(next,at:0);record("deferred","new-flight-submission");clock.start(for:next);return
                }
                let began=CACurrentMediaTime();lastStarted=began;executing=true;activeTicket=ticket;activeWorkStarted=began
                ModeSignposts.withTrace(next.trace,next.body)
                activeTicket=nil;activeWorkStarted=nil;executing=false
                next.trace?.record("ModeContentSlice",detail:"frame=\(frame) source=\(ticket.display ? "display":"timer") displayTimestamp=\(ticket.timestamp) workStarted=\(began) workDeadline=\(began+ticket.interval-max(0.002,ticket.interval*0.15)) ms=\((CACurrentMediaTime()-began)*1000)",timestamp:ticket.timestamp,target:ticket.target)
                if jobs.isEmpty {clock.stop()} else {clock.start(for:jobs[0])}
            }
        }!
        CFRunLoopAddObserver(CFRunLoopGetMain(),observer,.commonModes)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
