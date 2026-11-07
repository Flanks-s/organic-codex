#if M1_SELFTEST
import AppKit

@MainActor enum NativeVoiceVerification {
    static func run(check:(Bool,String)->Void){
        let composer=NativeComposer();composer.frame=CGRect(x:0,y:0,width:620,height:48)
        check(composer.enableVoiceDemo(),"f112 demo callbacks install without any audio/backend")
        let demo=composer.voiceDemo!
        check(demo.start() && composer.state.voice=="","f112 starts Listening with empty heard text")
        demo.advance(by:0.89);check(composer.state.voice=="","f112 product listening delay is 0.9 seconds")
        demo.advance(by:0.01);check(composer.state.voice=="Can","f112 first word arrives at 0.9 seconds")
        demo.advance(by:0.23);check(composer.state.voice=="Can you","f112 subsequent words arrive every 0.23 seconds")
        composer.isHidden=true;let phase=demo.elapsed;demo.advance(by:10)
        check(demo.elapsed==phase && composer.state.voice=="Can you","f112 hidden demo pauses without losing progress")
        composer.isHidden=false;demo.advance(by:0.23)
        check(composer.state.voice=="Can you summarize","f112 resumed demo continues its phase")
        demo.end();demo.advance(by:100);check(composer.state.voice==nil && !demo.active,"f112 cancel prevents old progress from updating the composer")
        _ = demo.start();check(!composer.sendVoice(),"f112 Listening cannot submit an empty transcript")
        demo.advance(by:Double.greatestFiniteMagnitude);let heard=NativeVoiceDemo.words.joined(separator:" ")
        check(composer.state.voice==heard,"f112 full demo phrase matches the product")
        var sent:[NativeComposerSubmission]=[];composer.onSubmit={sent.append($0)}
        composer.state.online=false;check(!composer.sendVoice() && composer.state.voice==heard,"f112 offline send preserves what was heard")
        composer.state.online=true;check(composer.sendVoice() && sent.count==1 && sent[0].text==heard,"f112 send uses the normal immutable submission contract")
        check(composer.state.voice==heard && !composer.sendVoice(),"f112 pending send keeps heard text and rejects duplicates")
        _ = composer.completeSubmission(sent[0].id,outcome:.failed("Prototype failure"))
        check(composer.state.voice==heard,"f112 failed send keeps heard text")
        check(composer.sendVoice(),"f112 failed voice submission can be explicitly retried")
        _ = composer.completeSubmission(sent.last!.id,outcome:.accepted)
        check(composer.state.voice==nil,"f112 only accepted send clears the heard transcript")
        composer.state.usesLiveCore=true;check(!demo.start(),"f112 Live never starts prototype recognition")
        let custom=NativeComposer();custom.onVoice={};check(!custom.enableVoiceDemo(),"f112 host-owned voice callbacks are preserved")
    }
}
#endif
