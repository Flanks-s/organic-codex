import AppKit
import QuartzCore

extension AutoScene {
    struct FunctionPanelRequest {
        let target: Conversation
        let destination: FunctionPanelDestination
        let generation: Int
        let reason: String
        var sceneGeneration: Int? = nil
    }

    @discardableResult func cancelFunctionPanelRequest() -> Bool {
        guard functionPanelRequest != nil else { return false }
        functionPanelRequest = nil
        functionPanelRequestGeneration &+= 1
        return true
    }

    @discardableResult
    func requestFunctionPanel(_ target: Conversation, destination: FunctionPanelDestination) -> Bool {
        guard canRequestFunctionPanel?() == true else { return false }
        dismissPeek()
        guard let ticket = beginFunctionPanelRequest(target, destination: destination, reason: "panel-entry") else {
            return true
        }
        let previousGeneration = generation
        enterFunctionPanelTarget(target.id, reason: "panel-entry")
        finishFunctionPanelEntry(ticket, previousGeneration: previousGeneration)
        return true
    }

    private func beginFunctionPanelRequest(_ target: Conversation, destination: FunctionPanelDestination,
                                           reason: String) -> Int? {
        cancelFunctionPanelRequest()
        guard canRequestFunctionPanel?() == true, !modeHandoffActive,
              functionPanelTargetIsValid(target) else { return nil }
        functionPanelRequestGeneration &+= 1
        functionPanelRequest = .init(target: target, destination: destination,
                                     generation: functionPanelRequestGeneration, reason: reason)
        return functionPanelRequestGeneration
    }

    private func functionPanelTargetIsValid(_ target: Conversation) -> Bool {
        !target.archived && store.conversation(target.id) === target && members.contains { $0 === target }
    }

    func functionPanelTransitionWillCommit(_ prepared: Prepared, reason: String) {
        onRetireFunctionPanel?()
        guard let request = functionPanelRequest else { return }
        if request.sceneGeneration != nil || request.reason != reason || !functionPanelTargetIsValid(request.target)
            || !prepared.members.contains(where: { $0 === request.target }) {
            cancelFunctionPanelRequest()
        }
    }

    private func finishFunctionPanelEntry(_ ticket: Int, previousGeneration: Int) {
        guard let request = functionPanelRequest, request.generation == ticket else { return }
        guard current == request.target.id, isFull(current), functionPanelTargetIsValid(request.target) else {
            cancelFunctionPanelRequest()
            return
        }
        functionPanelRequest?.sceneGeneration = generation
        if previousGeneration == generation && !isMoving { fulfillFunctionPanelRequest() }
    }

    func fulfillFunctionPanelRequest() {
        guard let request = functionPanelRequest, let expected = request.sceneGeneration else { return }
        guard generation == expected, canRequestFunctionPanel?() == true, current == request.target.id,
              isFull(current), functionPanelTargetIsValid(request.target), shownPeek == nil else {
            cancelFunctionPanelRequest()
            return
        }
        // Resize and appearance changes can settle the views before the transition's scheduled completion.
        guard !isMoving else { return }
        cancelFunctionPanelRequest()
        _ = onFunctionPanelRequest?(request.target, request.destination)
    }

    /// Only the ordinary island decides whether its current interaction is held.
    var peekInteractionHolds:Bool {
        peekOpen
            && ((peekNode.headerVisible && peekNode.header.hostPresentation.holdsPeek)
                || peekReply?.holdsPeek == true
                || peekReply.flatMap { $0.isCurrent ? overlay(for: $0.id)?.holdsOverlay : nil } == true)
    }

    func wirePeekIsland(_ id:String) {
        guard peekNode.wiredConversation != id else {return}
        let work=M10ColumnWorkTrace.scope("peek.header.wire");defer {work.end()}
        wireIsland(peekNode.header,for:id,sheets:{ [weak self] in self?.overlayPlane },reveal:{ [weak self] in
            self?.openPeekConversation(id, showPanels: false)
        })
        peekNode.wiredConversation=id
        peekNode.header.actions.planet = { [weak self] in
            self?.openPeekConversation(id)
            return true
        }
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
        peekNode.header.planetButton.setAccessibilityHelp("Opens the conversation overview")
    }

    /// #166: the planet's request follows the existing enter-and-reveal path to its final column.
    func openPeekConversation(_ id: String, showPanels: Bool = true) {
        guard shownPeek==id,let c=conversation(id),!c.archived,members.contains(where:{$0 === c}) else {return}
        dismissPeek()
        let reason = "peek-island"
        let ticket = showPanels ? beginFunctionPanelRequest(c, destination: .overview, reason: reason) : nil
        let previousGeneration = generation
        enterFunctionPanelTarget(id, reason: reason)
        jumpToLatest(id)
        if let ticket { finishFunctionPanelEntry(ticket, previousGeneration: previousGeneration) }
    }

    private func enterFunctionPanelTarget(_ id: String, reason: String) {
        if scheme.mode == .focused {
            if !scheme.split.contains(id) {
                guard let plan=OrbSwitchPlan.make(source:id,target:current,members:members.map(\.id),current:current,
                    scheme:scheme,columns:columns.map{$0.conversation.id},explicitColumn:false) else {return}
                transition(to: plan.members.compactMap(conversation), current: id, scheme: plan.scheme,
                           spring: Self.focusSpring, reason: reason)
            } else if id != current {
                transition(to: members, current: id, scheme: scheme, spring: Self.focusSpring, reason: reason)
            }
            focusMember(id)
        } else {
            land(id, reason: reason)
            activate(id, reason: reason)
        }
    }
}
