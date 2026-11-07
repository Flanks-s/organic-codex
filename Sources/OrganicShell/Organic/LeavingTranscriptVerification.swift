#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

extension M10DockVerification {
    /// A mode return admits an overflow member full, then rapid switches demote it while it is still leaving.
    static func leavingTranscripts(output:URL) async throws {
        var rows=[[String:Any]]()
        for scale:CGFloat in [1,2] {for idle in [false,true] {for shared in [false,true] {
            let f=HeaderFixture(scale:scale,shared:shared);defer{f.dispose()}
            let size=CGSize(width:1460,height:860)
            f.root.setFrameSize(size);f.scene.resize(to:size,live:false);f.scene.settle()
            f.scene.verificationPresented=true
            f.scene.show("F");f.scene.settle()
            let outgoing=f.scene.nodes["F"]!
            check(outgoing.ownsNative && !outgoing.native.isHidden,"mode-return fixture starts with a mounted visible full native")
            var exposed=0,samples=0,restingDeparture=0
            func scan() {
                for node in f.scene.nodes.values where !f.scene.columns.contains(where:{$0 === node}) {
                    samples+=1
                    let visible=node.ownsNative && !node.native.isHidden && !(node.native.layer?.isHidden ?? false)
                    if visible {exposed+=1}
                    check(!visible,"departed native stays hidden @\(scale)x idle=\(idle) id=\(node.conversation.id)")
                }
            }
            let departureAtEnd=outgoing.native.shouldFollowEnd && outgoing.native.isAtEnd
            for (step,index) in [1,2,1,2].enumerated() {
                let target=f.scene.columns[index].conversation.id
                let p:AutoScene.Prepared
                if idle {
                    p=try await f.scene.prepareInIdle(members:f.scene.members,current:target,at:f.time,idle:M11IdlePreparation(interval:0.0001,valid:{true}))
                } else {p=f.scene.prepare(members:f.scene.members,current:target,at:f.time)}
                let resting=p.presence["F"]?.duration == 0
                if resting {
                    restingDeparture+=1
                    outgoing.atEndBeforeMotion=false;outgoing.motionOffset=17;outgoing.followBeforeMotion=false
                }
                f.scene.commit(p,reason:idle ? "mode-return-going-idle":"mode-return-going",prewarmed:idle,start:CACurrentMediaTime())
                if step==0 {check(outgoing.atEndBeforeMotion == departureAtEnd,"initial departure records reader intent without consuming it")}
                if resting {
                    check(outgoing.atEndBeforeMotion == false && outgoing.motionOffset == 17 && outgoing.followBeforeMotion == false,"leaving commit preserves reader/follow/motion state")
                }
                scan()
                for _ in 0..<78 {f.tick(1/120);scan()}
            }
            check(restingDeparture>0,"fixture reaches zero-duration outgoing presence before settle")
            check(exposed==0,"no native resurrection after interrupted mode return")
            f.scene.settle();scan()
            // Reuse must end host motion and retain the real transcript's mount.
            f.scene.show("F");f.scene.settle()
            check(f.scene.columns.contains{$0 === outgoing},"departed retained node can rejoin")
            check(outgoing.island?.canDragOrb == true,"rejoined header ends host motion and accepts normal input")
            rows.append(["scale":scale,"idle":idle,"shared":shared,"samples":samples,"visibleDepartedSamples":exposed,"zeroDurationDepartures":restingDeparture])
        }}}
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("leaving-transcripts.json"))
    }
}
#endif
