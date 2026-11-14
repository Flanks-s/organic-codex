#if M1139_CHECK
import Foundation

@MainActor enum SunHoverVerification {
    static func state(_ check: (Bool, String) -> Void) {
        var t = 0.0
        let state = SunHoverState { t }
        state.pointer(in: [.ll])
        check(state.mode == .open, "state: entering LL opens immediately")
        t = 0.001; state.tick()
        check(state.satellites[5].value(at: t) > 0 && state.satellites[0].value(at: t) == 0, "state: farthest satellite departs first")
        t = 0.199; check(state.satellites[0].value(at: t) == 0, "state: nearest satellite waits 200ms")
        t = 0.201; check(state.satellites[0].value(at: t) > 0, "state: nearest satellite departs after 200ms")
        for (time, expected) in [(0.549, false), (0.550, true), (0.551, true)] {
            t = time; state.tick(); check(state.showsNumber == expected, "state: number dwell \(time)")
        }
        state.pointer(in: [.zone]); t = 1; state.tick()
        state.pointer(in: [])
        for (time, expected) in [(1.259, SunHoverMode.open), (1.260, .idle), (1.261, .idle)] {
            t = time; state.tick(); check(state.mode == expected, "state: grace boundary \(time)")
        }
        t = 2; let badge = SunHoverState { t }; badge.pointer(in: [.ll, .badge])
        for (time, expected) in [(2.139, SunHoverMode.open), (2.140, .panel(.attention)), (2.141, .panel(.attention))] {
            t = time; badge.tick(); check(badge.mode == expected, "state: badge dwell \(time)")
        }
        badge.pointer(in: [.panel]); t = 3; badge.pointer(in: [.ll])
        for (time, expected) in [(3.349, SunHoverMode.panel(.attention)), (3.350, .open), (3.351, .open)] {
            t = time; badge.tick(); check(badge.mode == expected, "state: return LL boundary \(time)")
        }
        t = 4; let labels = SunHoverState { t }; labels.pointer(in: [.ll])
        t = 4.1; labels.pointer(in: [.satellite(.newChat)])
        check(labels.activeLabel == nil, "state: unsettled satellite and neighbours cannot grow label")
        t = 6; labels.tick(); labels.pointer(in: [.satellite(.newChat)])
        t = 7; labels.tick(); check(labels.labels[0].value(at: t) > 0.99, "state: settled satellite can grow one label")
        labels.pointer(in: [.zone])
        t = 7.119; labels.tick(); check(labels.labels[0].target == 1, "state: label held at 119ms")
        t = 7.120; labels.tick(); check(labels.labels[0].target == 0, "state: label closes at 120ms")
        t = 7.121; labels.tick(); check(labels.labels[0].target == 0, "state: label remains closing at 121ms")
        labels.pointer(in: [.satellite(.addToDock)])
        var lo = t, hi = t + 0.3
        for _ in 0..<40 {
            let middle = (lo + hi) / 2
            if labels.labels[0].value(at: middle) > SunHoverParameters.labelPass { lo = middle } else { hi = middle }
        }
        t = lo - 0.001; labels.tick()
        check(labels.labels[0].value(at: t) > 0.6 && labels.labels[1].target == 0, "state: next label must wait above the 0.6 handoff threshold")
        t = hi + 0.001; labels.tick()
        check(labels.labels[0].value(at: t) <= 0.6 && labels.labels[0].value(at: t) > 0.1 && labels.labels[1].target == 1, "state: next label starts below 0.6 while outgoing geometry still exceeds 0.1")
        for i in 0..<100 {
            let sample = t + Double(i) * 0.002
            check(labels.labels.filter { $0.value(at: sample) > 0.62 }.count <= 1, "state: only one caption text is visible during handoff")
        }
        t = 8; labels.tick(); t = 9; labels.tick()
        let labelBeforePanel = labels.activeLabel
        labels.showPanel(.usage)
        check(labelBeforePanel != nil && labels.hasPendingFold && labels.foldStartedAt == nil, "state: folding waits while any label is still out")
        let before = labels.satellites.map { $0.value(at: t) }
        t += 0.01; labels.tick()
        check(labels.hasPendingFold && zip(before, labels.satellites).allSatisfy { abs($0 - $1.value(at: t)) < 0.01 }, "state: no satellite crosses an outgoing label")
        for _ in 0..<200 { t += 0.001; labels.tick() }
        check(!labels.hasPendingFold && labels.foldStartedAt != nil, "state: label gone releases folding")
        let foldStart = labels.foldStartedAt ?? t
        check(labels.satellites[0].value(at: foldStart + 0.001) < 1 && labels.satellites[5].value(at: foldStart + 0.001) > 0.99, "state: nearest satellite folds first, 22ms stagger")
        _ = labels.escape(); check(labels.mode == .open, "state: Esc removes only the top panel")
        _ = labels.escape(); labels.pointer(in: [.ll]); check(labels.mode == .idle, "state: Esc suppresses reopening under stationary LL pointer")
        labels.pointer(in: []); labels.pointer(in: [.ll]); check(labels.mode == .open, "state: leaving and reentering LL rearms hover")
        t += 2; labels.tick(); _ = labels.click(.addToDock)
        check(labels.mode == .picker, "state: Add enters picker after satellite becomes interactive")
        t += 0.029; check(labels.pickerBottom.value(at: t) == 0 && labels.pickerWidth.value(at: t) == 0, "picker-motion: top begins before bottom and width")
        t += 0.002; check(labels.pickerBottom.value(at: t) > 0 && labels.pickerWidth.value(at: t) == 0, "picker-motion: bottom begins at 30ms")
        t += 0.020; check(labels.pickerWidth.value(at: t) > 0 && labels.pickerSearch.value(at: t) == 0, "picker-motion: width begins at 50ms")
        t += 0.108; check(labels.pickerSearch.value(at: t) == 0, "picker-motion: search absent at 159ms")
        t += 0.002; check(labels.pickerSearch.value(at: t) > 0, "picker-motion: search begins at 160ms")
        check(labels.escape(hasMarkedText: true) == .cancelComposition && labels.mode == .picker, "state: IME Esc cancels composition before picker")
        t += 2; check(labels.searchCanTakeFocus, "picker-motion: focus is possible only after search becomes visible"); _ = labels.escape(); check(!labels.searchCanTakeFocus, "picker-motion: closing prevents any delayed focus request"); let closing = t
        let heldTop = labels.pickerTop.value(at: closing + 0.049)
        check(heldTop > 0.99 && labels.pickerTop.value(at: closing + 0.051) < heldTop - 1e-5, "picker-motion: close holds through 49ms and has begun shrinking at 51ms")
        let reduced = SunHoverState(reduceMotion: true) { t }; reduced.pointer(in: [.ll])
        check(reduced.ring.value(at: t) == 1 && reduced.ringDrawsImmediately, "reduced: ring draws immediately")
        check(abs(reduced.satellites[0].value(at: t + 0.06) - 0.5) < 1e-6 && reduced.satellites[5].value(at: t + 0.12) == 1, "reduced: satellites fade at destination over 120ms")
        let rows = SunHoverState { t }; rows.showPanel(.attention); rows.setPanelRows(["real-one", "real-two"])
        check(rows.rowVisibility("real-one", at: t + 0.069) == 0 && rows.rowVisibility("real-one", at: t + 0.201) == 1, "panel: first row has 70ms delay and 130ms entry")
        check(rows.rowVisibility("real-two", at: t + 0.099) == 0, "panel: next row is staggered 30ms")
        t += 1; rows.setPanelRows([])
        check(rows.rowVisibility("real-one", at: t + 0.071) == 0, "panel: removed rows leave in 70ms")
        check(rows.selectConversation("real-one", isStillActionable: { _ in true }) == nil, "panel: stale row ID cannot activate")
        rows.retire(); check(rows.mode == .idle && rows.regions.isEmpty, "state: retire cancels semantic timers")
        let usage = SunHoverState { t }; usage.pointer(in: [.ll]); usage.pointer(in: [.satellite(.usage)])
        check(usage.showsNumber, "state: hovering Usage shows number without LL dwell")
        _ = usage.escape(); usage.tick()
        check(!usage.showsNumber && usage.mode == .idle, "state: Esc clears numeric hover even before pointer regions refresh")
        var rt = 0.0
        let reentry = SunHoverState { rt }; reentry.pointer(in: [.ll])
        rt = 2; reentry.pointer(in: [.satellite(.newChat)])
        rt = 3; reentry.pointer(in: [.zone]); rt = 3.121; reentry.tick()
        check(reentry.labels[0].target == 0 && reentry.labels[0].value(at: rt) > 0.1, "state: reentry fixture has a closing label")
        rt = 3.131; reentry.pointer(in: [.satellite(.newChat)])
        check(reentry.labels[0].target == 1, "state: reentering the same closing label reverses its target")
        rt = 4; reentry.tick(); check(reentry.labels[0].value(at: rt) > 0.99, "state: reentered caption remains visible during stationary hover")
        let pickerExit = SunHoverState { rt }; pickerExit.pointer(in: [.ll]); rt += 2; pickerExit.tick(); _ = pickerExit.click(.addToDock)
        pickerExit.pointer(in: []); rt += 1; pickerExit.tick()
        check(pickerExit.mode == .picker, "state: picker remains open over scrim")
        _ = pickerExit.escape(); rt += 0.001; pickerExit.tick()
        check(pickerExit.mode == .open, "state: picker Esc starts a fresh grace instead of collapsing satellites immediately")
    }

    static func geometry(_ check: (Bool, String) -> Void) {
        let g = SunHoverGeometry(llCenter: .init(x: 48, y: 764), dockBaseline: 764, bounds: .init(x: 0, y: 0, width: 1280, height: 820), backingScale: 1)
        let positions: [(Double,Double,Double,Double)] = [(69.548,683.806,91.026,690.356), (97.970,647.839,112.165,663.605),
            (135.425,621.407,140.022,643.946), (178.837,606.680,143.251,644.547),
            (224.642,604.868,175.442,640.597), (269.082,616.118,239.430,640.013)]
        for key in SunHoverSatellite.allCases {
            let p = g.satelliteCenter(key), r = g.label(key), expected = positions[key.rawValue]
            check(abs(p.x-expected.0)<0.01 && abs(p.y-expected.1)<0.01 && abs(r.minX-expected.2)<0.01 && abs(r.minY-expected.3)<0.01, "geometry: board satellite and label \(key) match within 0.01pt")
            let moved = SunHoverGeometry(llCenter: .init(x: 98, y: 704), dockBaseline: 704, bounds: g.bounds, backingScale: 2)
            let q = moved.satelliteCenter(key), label = moved.label(key)
            check(abs(q.x-p.x-50)<1e-9 && abs(q.y-p.y+60)<1e-9 && abs(label.minX-r.minX-50)<1e-9 && abs(label.minY-r.minY+60)<1e-9, "geometry: raised/moved LL carries satellite and label \(key)")
        }
        check(g.panelTarget(.attention).minY == 512 && g.panelTarget(.usage).minY == 558 && g.panelTarget(.account).minY == 594 && g.pickerTarget == CGRect(x:22,y:170,width:408,height:560), "geometry: board panel/picker anchors follow Dock baseline")
        check(g.satellite(.newChat, progress:1).width == 34 && g.satelliteHitRect(.newChat, progress:1).width == 34, "geometry: pixel alignment preserves 34pt satellite and hit size")
        let shorter = SunHoverGeometry(llCenter: .init(x:48,y:584),dockBaseline:584,bounds:.init(x:0,y:0,width:1280,height:640),backingScale:1)
        check(shorter.pickerTarget.maxY == 550 && shorter.pickerTarget.minY == 10 && shorter.pickerTarget.height == 540, "geometry: shorter window reduces picker height while preserving Dock bottom anchor")
        let source = CGPoint(x:65,y:747), initial = g.panelRect(.attention, source: source, progress:0)
        check(initial == CGRect(x:58,y:740,width:14,height:14), "geometry: panel starts as actual source 14x14")
        var panel = SunHoverPanelMotion(source: source)
        panel.show(.attention, source: source, geometry: g, at: 0)
        check(panel.pose(at: 0, geometry: g).rect == initial, "geometry: independent panel channels begin at source")
        let beforeKindChange = panel.pose(at: 2, geometry: g).rect
        panel.show(.usage, source: g.satelliteCenter(.usage), geometry: g, at: 2)
        check(panel.pose(at: 2, geometry: g).rect == beforeKindChange, "geometry: switching open panel kind preserves current rectangle")
        check(panel.pose(at: 4, geometry: g).rect == g.panelTarget(.usage), "geometry: open panel channels settle at the new kind target")
        let beforeClose = panel.pose(at: 4, geometry: g).rect
        panel.close(at: 4)
        check(panel.pose(at: 4, geometry: g).rect == beforeClose && panel.pose(at: 6, geometry: g).rect.width == 14, "geometry: panel closes continuously to latest 14pt source")
        panel.show(.attention, source: source, geometry: g, at: 6)
        check(panel.pose(at: 6, geometry: g).rect == initial, "geometry: a fully closed panel reopens at the new badge source")
        for scale in [1.0,2.0] {
            let small = SunHoverGeometry(llCenter:.init(x:31.2,y:181.7),dockBaseline:181.7,bounds:.init(x:0,y:0,width:260,height:240),backingScale:scale)
            let rects = SunHoverSatellite.allCases.flatMap { [small.satellite($0,progress:1),small.label($0,aligned:true)] }
                + [small.pickerTarget,small.panelTarget(.attention,attentionCount:12),small.panelTarget(.usage)]
            check(rects.allSatisfy { $0.minX>=10 && $0.minY>=10 && $0.maxX<=250 && $0.maxY<=230 }, "geometry: small window clamps all glass inside 10pt at \(scale)x")
            check(rects.allSatisfy { r in [r.minX,r.minY,r.maxX,r.maxY].allSatisfy { abs($0*scale-($0*scale).rounded())<1e-9 } }, "geometry: all frame edges align at \(scale)x")
            check(small.pickerTarget.height >= 3*32+44+24, "geometry: small picker retains at least three lyric rows")
        }
        let store = ConversationStore(); store.clearCoreQuota()
        let unknown = g.ring(diameter:42,number:1,progress:1,usage:store.accountUsage,reduceMotion:false)
        check(unknown.used == nil && unknown.sweep == 0 && unknown.radius == 24.5, "geometry: unknown ring is track only")
        store.applyCoreRateLimits(["primary":["usedPercent":22],"secondary":["usedPercent":67]])
        check(g.ring(diameter:42,number:1,progress:0,usage:store.accountUsage,reduceMotion:true).sweep == 0.67, "geometry: reduced ring directly uses tightest used")
    }

    static func attention(_ check: (Bool, String) -> Void) {
        let a=Conversation(id:"parent",title:"\u{7236}\u{5bf9}\u{8bdd}"), b=Conversation(id:"error",title:"Error"), child=Conversation(id:"child",title:"Child")
        let archived=Conversation(id:"archive",title:"Archived"), background=Conversation(id:"background",title:"Background")
        archived.archived=true; archived.error = .stopped; background.error = .stopped
        child.backendThreadID="child-thread"; a.satellites=[.init(id:"sat",face:"S",threadID:"child-thread")]
        let store=ConversationStore(conversations:[a,b,child,archived,background]), projection=SunHoverAttentionProjection()
        a.approvals=[approval("one"),approval("two")]; a.userInput = .init(id:"question",questions:[.init(id:"q",header:"Q",prompt:"\u{7ee7}\u{7eed}\u{ff1f}",options:[])])
        child.approvals=[approval("child-approval")]; a.error = .running; a.operationError="still working"; b.error = .stopped
        let members:Set<String>=[a.id,b.id,archived.id]
        var model=projection.snapshot(store:store,memberIDs:members,at:10)
        check(model.conversationCount == 2 && model.eventCount == 6 && model.badgeCount == model.rows.count, "attention: event count 6, conversation count/badge/rows 2")
        check(projection.snapshot(store:store,memberIDs:members.union([child.id]),at:10).conversationCount==2, "attention: a represented child never becomes a second badge row")
        check(model.rows.flatMap(\.events).allSatisfy { !$0.waitStartReported }, "attention: pending without a Core arrival timestamp stays explicitly unreported")
        check(model.rows.map(\.conversationID)==[b.id,a.id] && model.rows[1].additionalCount==4, "attention: severity sort and +n merge")
        child.error = .stopped
        let withChildError = projection.snapshot(store:store,memberIDs:members.union([child.id]),at:10)
        let parentRow = withChildError.rows.first { $0.conversationID == a.id }
        check(withChildError.conversationCount == 2 && withChildError.eventCount == 7 && parentRow?.mostSevere.sourceID == child.id && parentRow?.mostSevere.severity == .stoppedError, "attention: member child stopped error survives merging into parent row")
        child.error = nil
        check(a.question == nil && model.rows[1].events.contains { $0.severity == .question }, "attention: structured userInput counts when question is nil")
        _=projection.activate(a.id,store:store,memberIDs:members,at:11)
        model=projection.snapshot(store:store,memberIDs:members,at:11)
        check(model.eventCount==5 && model.rows.first(where:{$0.conversationID==a.id})?.events.count==4, "attention: reviewing clears error, retains unanswered approvals/question")
        check(SunHoverAttentionProjection().snapshot(store:store,memberIDs:members,at:11).eventCount==5, "attention: reviewed error stays cleared across window projection recreation")
        a.approvals=[]; a.userInput=nil; child.approvals=[]
        check(projection.snapshot(store:store,memberIDs:members,at:12).conversationCount==1, "attention: expired/answered requests disappear")
        a.error=nil; b.error=nil
        check(projection.snapshot(store:store,memberIDs:members,at:13).rows.isEmpty, "attention: recovered errors do not persist from journal")
        store.apply(.init(id:1,time:20,method:"turn/started",params:["threadId":.string(a.id),"turnId":"old"]))
        store.apply(.init(id:2,time:21,method:"error",params:["threadId":.string(a.id),"willRetry":true,"message":"fixture error"]))
        check(projection.snapshot(store:store,memberIDs:members,at:22).conversationCount==1, "attention: new running error appears")
        store.apply(.init(id:3,time:23,method:"turn/completed",params:["threadId":.string(a.id),"turn":["id":"old","status":"completed"]]))
        check(projection.snapshot(store:store,memberIDs:members,at:24).rows.isEmpty, "attention: successful completion clears old running error")
        a.error = .stopped; store.apply(.init(id:4,time:25,method:"turn/started",params:["threadId":.string(a.id),"turnId":"new"]))
        check(projection.snapshot(store:store,memberIDs:members,at:26).rows.isEmpty, "attention: new turn clears previous failure")
        b.approvals=[approval("late")]; a.approvals=[approval("early")]
        store.recordAttentionEvent(.init(id:5,time:30,method:"core/approvalRequested",params:["threadId":.string(a.id),"approvalId":"early"]))
        store.recordAttentionEvent(.init(id:6,time:40,method:"core/approvalRequested",params:["threadId":.string(b.id),"approvalId":"late"]))
        a.updated=Date(timeIntervalSince1970:100)
        check(projection.snapshot(store:store,memberIDs:members,at:100).rows.map(\.conversationID)==[a.id,b.id], "attention: same severity sorts by original arrival, not recent activity")
        a.archived=true; check(projection.activate(a.id,store:store,memberIDs:members,at:101)==nil, "attention: activation revalidates archive and canonical ID")
        for i in 0..<8 { let c=Conversation(id:"many-\(i)",title:"Many");c.approvals=[approval("r\(i)")];store.add(c) }
        let all=Set(store.conversations.map(\.id)).subtracting([background.id,child.id])
        model=projection.snapshot(store:store,memberIDs:all,at:102)
        check(model.visibleRows.count==6 && model.conversationCount==9, "attention: max six visible rows, remaining rows retained for scrolling")
        let unsent=Conversation(id:"unsent",title:"Draft");unsent.exactTokensUsed=0;unsent.contextLimit=1000
        let unsentUsage = SunHoverUsagePanel(account:store.accountUsage,current:unsent).rows[2]
        check(unsentUsage.used == nil && unsentUsage.percentage == "\u{2014}", "usage-panel: unsent has no context percentage even if zero is cached")
        unsent.backendThreadID="sent";unsent.exactTokensUsed=250
        check(SunHoverUsagePanel(account:store.accountUsage,current:unsent).rows[2].used==0.25, "usage-panel: current context uses reported tokens and limit")
        unsent.contextLimit=nil
        check(SunHoverUsagePanel(account:store.accountUsage,current:unsent).rows[2].detail=="Not reported", "usage-panel: missing limit never invents 272K or zero")
        let access=SunHoverAccess(account:store.accountUsage,available:Set(SunHoverSatellite.allCases),disabledInLayout:[.newChat],accountActions:[.settings,.profile])
        check(access.satellites.count==6 && !access.satellites[0].enabled && access.accountTitle=="Louis L." && access.accountSource == .prototype, "access: data-only six actions, layout disabled flag and snapshot title")
        check(access.accountItems.last?.title=="Sign Out" && access.accountItems.last?.dividerBefore==true, "access: account actions include separated Sign Out")
    }
    static func approval(_ id:String)->Approval { .init(id:id,title:"Approve",command:"",note:"",acceptLabel:"Allow",toolItemID:id) }
}
#endif
