import AppKit

extension AutoScene {
    /// Modal controls and explicit header details retain the top input priority.
    var tideHasForegroundSurface:Bool {
        if orbTrash.hasForegroundSurface {return true}
        if orbMenu.state.isOpen {return true}
        if sunHover?.isShowing == true {return true}
        func modal(_ view:NSView)->Bool {
            if view.isHiddenOrHasHiddenAncestor {return false}
            if let surface=view as? OverlaySurface,surface.isShowing {return true}
            if let surface=view as? SheetSurface,surface.isShowing {return true}
            return view.subviews.contains(where:modal)
        }
        return modal(overlayPlane) || nodes.values.contains {node in
            guard let island=node.island,!island.isHiddenOrHasHiddenAncestor else{return false}
            return island.state.expanded || island.state.editing || island.state.pinned
        }
    }

    /// Real decision controls keep their complete hit area above any floating margin notification.
    var tideDecisionObstacles:[CGRect] {
        return columns.filter{isFull($0.conversation.id)}.flatMap {column -> [CGRect] in
            let frame=column.native.pinnedDecisionFrame
            guard !column.native.isHiddenOrHasHiddenAncestor,frame.width>0,frame.height>0,
                  let rail=column.native.subviews.first(where:{$0 is NSScrollView && $0.frame==frame}) else{return []}
            let clip=column.native.convert(frame,to:dock.view)
            func buttons(_ view:NSView)->[CGRect] {
                guard !view.isHiddenOrHasHiddenAncestor else{return []}
                if let button=view as? NSButton {
                    let rect=button.convert(button.bounds,to:dock.view).intersection(clip)
                    return rect.isNull || rect.isEmpty ? []:[rect]
                }
                return view.subviews.flatMap(buttons)
            }
            return buttons(rail)
        }
    }
    /// Reserve reading space with a translation of retained brief ink, without reflow or a second clock.
    func makeTideReadingRoom(_ cards:[CGRect]) {
        guard !modeContentEpochFrozen else{return}
        CATransaction.begin();CATransaction.setDisableActions(true);defer {CATransaction.commit()}
        for column in columns where !isFull(column.conversation.id) {
            let layer=column.briefContent
            let previous = -layer.transform.m42
            let natural=layer.convert(layer.bounds,to:sceneView.layer).offsetBy(dx:0,dy:previous)
            let lift=cards.filter {$0.minX<natural.maxX && $0.maxX>natural.minX && $0.maxY>natural.minY}
                .map {max(0,natural.maxY+12-$0.minY)}.max() ?? 0
            if abs(previous-lift)>0.000_001 {layer.transform=CATransform3DMakeTranslation(0,-lift,0)}
        }
    }

    /// Add's caller supplies the capacity verdict. Canonical layout owns every resulting ordinary orb.
    @discardableResult func admitWithTideSlots(_ additions:[Conversation],owner:String,capacityAllows:Bool)->Bool {
        guard presented,scheme.mode == .auto,!additions.isEmpty,capacityAllows else{return false}
        let nextMembers=members+additions.filter{c in !members.contains{$0.id==c.id}}
        let (next,nextOrder)=arrange(nextMembers,current:current)
        let oldBriefs=order.prefix(layout.bars.count).filter{!isFull($0)}
        let displaced=oldBriefs.filter{!nextOrder.prefix(next.bars.count).contains($0)}
        let decision=dock.reserveTideSlotsForAdd(owner:owner,count:displaced.count,capacityAllows:capacityAllows)
        guard decision.status == .granted,let token=decision.lease?.token,
              Set(decision.lease?.briefs ?? [])==Set(displaced) else {
            if let token=decision.lease?.token {dock.cancelTideAdd(token)}
            return false
        }
        let start=CACurrentMediaTime()
        let plan=prepare(members:nextMembers,current:current,at:start)
        commit(plan,reason:"tide-add-capacity",prewarmed:false,start:start)
        // A committed Add token survives all later Tide cleanup and stale callbacks.
        _=token
        return true
    }

    /// A click on the borrowed face uses the existing brief-to-full activation and retained editor.
    func reclaimTideBrief(_ id:String) {
        guard presented,scheme.mode == .auto,let c=conversation(id),!isFull(id) else{return}
        activate(id,reason:"tideReclaim")
        composer(for:c).focus()
    }

    /// Same request validation and runtime route as column Pulse and full decision cards.
    func performTideAction(_ action:ConversationNoticeAction,for id:String) {
        guard let c=conversation(id),!store.isOffline(c),!c.archived else{return}
        switch action {
        case .approval(let requestID,let response):
            guard let request=c.approvals.first(where:{$0.id==requestID}),!request.submitting,
                  CoreResponseValidation.approval(response,request:request)==nil else{return}
            islandActions?.approvalValue?(c,request,response)
        case .answer(let requestID,let answers):
            guard let request=c.userInput,request.id==requestID,!request.submitting,
                  CoreResponseValidation.answers(answers,request:request)==nil else{return}
            islandActions?.answer?(c,request,answers)
        case .review:
            dock.dismissTide()
            if isFocused {leaveFocused(reason:"tide-review")}
            show(id)
            jumpToLatest(id)
        }
    }
}
