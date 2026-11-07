import AppKit
import QuartzCore

/// Product MockEngine.startVoice: 0.9s Listening, then one word every 0.23s. No audio or backend API.
@MainActor final class NativeVoiceDemo {
    static let words="Can you summarize what changed in this conversation so far?".split(separator:" ").map(String.init)
    private weak var composer:NativeComposer?
    private var clock:Timer?,lastTime=0.0
    private(set) var active=false,elapsed=0.0
    init(composer:NativeComposer){self.composer=composer}
    isolated deinit{clock?.invalidate()}
    @discardableResult func start()->Bool{
        guard let composer,composer.isPresentationVisible,!composer.state.usesLiveCore,composer.state.online,!composer.isComposing,!composer.state.loading,!composer.state.running,!composer.hasPendingSubmission,composer.text.isEmpty,composer.attachments.isEmpty else{return false}
        elapsed=0;active=true;composer.setDemoVoice("");synchronizeClock();return true
    }
    func end(){active=false;stopClock();composer?.setDemoVoice(nil)}
    func advance(by seconds:Double){
        guard seconds.isFinite,seconds>=0,active,let composer,!composer.state.usesLiveCore,composer.isPresentationVisible,composer.state.voice != nil else{return}
        elapsed=min(0.9+Double(Self.words.count)*0.23,elapsed+seconds);let count=elapsed<0.9 ? 0:min(Self.words.count,Int(floor((elapsed-0.9)/0.23+1e-8))+1)
        composer.setDemoVoice(Self.words.prefix(count).joined(separator:" "))
        if count==Self.words.count{stopClock()}
    }
    func synchronizeClock(){
        guard active,let composer,!composer.state.usesLiveCore,composer.isPresentationVisible,composer.window != nil,composer.state.voice != nil,elapsed<0.9+Double(Self.words.count)*0.23 else{stopClock();return}
        guard clock == nil else{return};lastTime=CACurrentMediaTime()
        let timer=Timer(timeInterval:0.05,repeats:true){[weak self] _ in MainActor.assumeIsolated{guard let self else{return};let now=CACurrentMediaTime(),dt=now-self.lastTime;self.lastTime=now;self.advance(by:dt)}};clock=timer;RunLoop.main.add(timer,forMode:.common)
    }
    private func stopClock(){clock?.invalidate();clock=nil}
}
