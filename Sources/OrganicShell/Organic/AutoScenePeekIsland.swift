import AppKit
import QuartzCore

extension AutoScene {
    /// Only the ordinary island decides whether its current interaction is held.
    var peekInteractionHolds:Bool {
        peekOpen
            && ((peekNode.headerVisible && peekNode.header.hostPresentation.holdsPeek)
                || peekReply?.holdsPeek == true)
    }

    func wirePeekIsland(_ id:String) {
        guard peekNode.wiredConversation != id else {return}
        let work=M10ColumnWorkTrace.scope("peek.header.wire");defer {work.end()}
        wireIsland(peekNode.header,for:id,sheets:{ [weak self] in self?.overlayPlane },reveal:{ [weak self] in
            self?.openPeekConversation(id)
        })
        peekNode.wiredConversation=id
        peekNode.header.planetButton.invoke={ [weak self] in self?.openPeekConversation(id) }
        peekNode.onHeaderPresentation={ [weak self] in
            guard let self,self.shownPeek==id else {return}
            self.syncPeekIslandHold()
            self.peekNode.pointerShield.reconcile()
        }
        peekNode.header.actions.expansion={ [weak self] open,_ in
            guard let self else {return}
            if open {for node in self.nodes.values {node.island?.setExpanded(false)}}
            self.syncPeekIslandHold()
            self.peekNode.pointerShield.reconcile()
        }
    }

    /// A notice publication refreshes only the retained island, never the lyrics or fog.
    func refreshPeekIsland(_ c:Conversation? = nil) {
        guard peekOpen,let id=shownPeek,let c=c ?? conversation(id),c.id==id else {return}
        peekNode.refreshHeader(c)
        peekNode.header.planetButton.text="Open " + c.title
        peekNode.header.planetButton.setAccessibilityHelp("Opens the conversation")
    }

    /// #166: enter the conversation; M11.40 will own any subsequent menu.
    func openPeekConversation(_ id:String) {
        guard shownPeek==id,let c=conversation(id),!c.archived,members.contains(where:{$0 === c}) else {return}
        dismissPeek()
        if scheme.mode == .focused {
            if !scheme.split.contains(id) {
                guard let plan=OrbSwitchPlan.make(source:id,target:current,members:members.map(\.id),current:current,
                    scheme:scheme,columns:columns.map{$0.conversation.id},explicitColumn:false) else {return}
                transition(to:plan.members.compactMap(conversation),current:id,scheme:plan.scheme,spring:Self.focusSpring,reason:"peek-island")
            } else {transition(to:members,current:id,scheme:scheme,spring:Self.focusSpring,reason:"peek-island")}
            focusMember(id)
        }
        else {land(id,reason:"peek-island");activate(id,reason:"peek-island")}
        jumpToLatest(id)
    }
}
