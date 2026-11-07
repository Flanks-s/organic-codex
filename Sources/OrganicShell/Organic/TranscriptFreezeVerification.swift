import AppKit
import QuartzCore

/// Synthetic, windowless regressions for the transcript's reading position and flight admission.
@MainActor enum TranscriptFreezeVerification {
    static func run(size:CGSize,check:(Bool,String)->Void) {
        let store=ConversationStore()
        let c=Conversation(id:"freeze-reader",title:"Reader")
        c.items=(0..<180).map { i in TranscriptItem(id:"freeze-\(i)",kind:i % 3 == 0 ? .user:.assistant,text:"Line \(i). " + String(repeating:"A wrapped paragraph for the retained reader. ",count:4),running:false) }
        c.items[179].text += String(repeating:"Tail paragraph. ",count:600)
        let n=ColumnNode(c,store:store,identity:.systemBlue,rect:CGRect(x:0,y:0,width:640,height:820),full:true,scale:2,logicalBottom:720)
        n.render(fullWidth:640,briefWidth:260);n.showRest(full:true)
        defer {n.native.dispose()}
        for steps in [1,2,5,12] {
            n.native.scrollToEnd();n.native.scrollOffset.y -= CGFloat(steps*30)
            let offset=n.native.scrollOffset.y
            n.showRest(full:false);n.hideGoal();n.showRest(full:false)
            n.render(fullWidth:640,briefWidth:260);n.showRest(full:true)
            check(abs(n.native.scrollOffset.y-offset)<0.51,"FREEZE reader returns at \(steps) wheel steps")
            check(n.native.layer?.animation(forKey:"column.settle.slide")==nil,"FREEZE reader has no settle slide at \(steps) steps")
            n.native.layer?.removeAllAnimations()
        }
        n.native.scrollToEnd();n.showRest(full:false);n.hideGoal();n.showRest(full:false)
        n.render(fullWidth:640,briefWidth:260);n.showRest(full:true)
        check(n.native.distanceFromEnd<0.51,"FREEZE end reader returns at end")
        // A goal in overscan just above the viewport must reveal in place, never fly over the header.
        n.native.refineColdHeights(budget:30)
        let goal=c.items[c.items.count-3].id
        n.native.scrollToItem(itemID:goal)
        if let text=n.native.textSnapshot(itemID:goal,scale:2) {
            n.native.scrollOffset.y += text.rect.maxY+1
            n.invalidateCaptures()
            let hidden=n.snapshot(fullWidth:640,briefWidth:260)
            check(!hidden.pieces.contains{$0.look == .goal && $0.source.minY<hidden.area.minY},"FREEZE overscan goal above viewport has no flight")
            checkIdleGoal(n,check:check,label:"outside")
            n.native.scrollOffset.y -= 12;n.invalidateCaptures()
            let partial=n.snapshot(fullWidth:640,briefWidth:260)
            check(!partial.pieces.contains{$0.look == .goal && $0.source.minY<partial.area.minY},"FREEZE partially clipped goal cannot land above header")
            checkIdleGoal(n,check:check,label:"partial")
        } else {check(false,"FREEZE goal fixture has native glyphs")}
        n.native.scrollToEnd()
        // Use the same bounds notification as a wheel/scroller; scrollOffset intentionally guards programmatic writes.
        let clip=n.native.scrollView.contentView
        clip.scroll(to:CGPoint(x:0,y:clip.bounds.minY-30))
        n.native.scrollView.reflectScrolledClipView(clip)
        // Simulate a height correction bringing the distance within the legacy 24 pt slack.
        let away=n.native.scrollOffset.y
        n.native.scrollView.documentView?.frame.size.height -= 12
        n.native.refineColdHeights(budget:0.000001)
        check(n.native.distanceFromEnd>0.5 && n.native.scrollOffset.y<=away+1,"FREEZE user scroll intent survives cold height correction")
    }
    private static func checkIdleGoal(_ node:ColumnNode,check:(Bool,String)->Void,label:String) {
        node.invalidateCaptures()
        var result:ColumnNode.Snapshot?,finished=false,error:String?
        let idle=M11IdlePreparation(interval:0.0001,valid:{true})
        let task=Task { @MainActor in
            defer {idle.finish();finished=true}
            do {result=try await node.idleSnapshot(fullWidth:640,briefWidth:260,idle:idle)}
            catch let failure {error=String(describing:failure)}
        }
        let deadline=Date().addingTimeInterval(5)
        while !finished,Date()<deadline {_=RunLoop.main.run(mode:.default,before:min(deadline,Date().addingTimeInterval(0.002)))}
        task.cancel()
        check(finished && error == nil && result != nil,"FREEZE idle goal fixture completes \(label): \(error ?? "ok")")
        if let result {check(!result.pieces.contains{$0.look == .goal && $0.source.minY<result.area.minY},"FREEZE idle goal cannot land above header \(label)")}
    }
}
