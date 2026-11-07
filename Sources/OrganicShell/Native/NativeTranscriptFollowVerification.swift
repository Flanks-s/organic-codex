import AppKit

/// A height correction can enter near-bottom slack without changing the reader's explicit intent.
@MainActor enum NativeTranscriptFollowVerification {
    static func run(check:(Bool,String)->Void) {
        let c=Conversation(id:"freeze-follow",title:"Offline follow intent")
        c.items=(0..<160).map {i in TranscriptItem(id:"follow-\(i)",kind:.assistant,text:"Paragraph \(i). " + String(repeating:"A measured row keeps the correction deterministic. ",count:6),running:false)}
        let native=NativeTranscript(conversation:c)
        native.frame=CGRect(x:0,y:0,width:640,height:560)
        native.refresh(preservingOffset:false)
        native.refineColdHeights(budget:30)
        defer {native.dispose()}
        native.scrollToEnd()
        let clip=native.scrollView.contentView
        clip.scroll(to:CGPoint(x:0,y:clip.bounds.minY-30))
        native.scrollView.reflectScrolledClipView(clip)
        native.scrollView.documentView?.frame.size.height -= 12
        check(native.distanceFromEnd>0.5 && native.distanceFromEnd<=24,"FREEZE cold correction fixture enters bottom slack after a 30 pt reader scroll")
        native.refineColdHeights(budget:0.000001)
        check(native.distanceFromEnd>=29.5,"FREEZE cold correction never re-arms end follow after user scroll")
    }
}
