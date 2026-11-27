import Foundation
import os

/// Q4 deliberately retains Core's single-question slot. A replacement is diagnostic only, never another UI surface.
@MainActor final class TideQuestionDiagnostics {
    private var pending:[String:String]=[:]
    private var cursors:[String:Int]=[:]
    private var reported:Set<String>=[]
    private(set) var warnings:[[String:String]]=[]
    var onWarning:(([String:String])->Void)?
    private let logger=Logger(subsystem:"OrganicShell",category:"Tide")
    func observe(_ snapshot:ConversationNoticeSnapshot,owner:String) {
        let next=snapshot.pending.first{$0.kind == .question}?.requestID
        let cursor=cursors[owner] ?? 0
        cursors[owner]=max(cursor,snapshot.journal.last?.id ?? 0)
        let liveQuestion=snapshot.journal.contains{$0.id>cursor && $0.kind == .question && $0.requestID==next}
        if liveQuestion,let old=pending[owner],let next,old != next {
            let key=owner+"\u{1f}"+old+"\u{1f}"+next
            if reported.insert(key).inserted {
                let row=["warning":"single-question-replaced","owner":owner,"previousRequestID":old,"incomingRequestID":next]
                warnings.append(row)
                if warnings.count>64 {warnings.removeFirst();reported.removeAll()}
                logger.warning("Single pending question replaced: owner=\(owner,privacy:.public) previous=\(old,privacy:.public) incoming=\(next,privacy:.public)")
                onWarning?(row)
            }
        }
        pending[owner]=next
    }
}
