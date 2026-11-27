import Foundation
import ObjectiveC

/// Immutable process-lifetime identity token; it never contains cross-thread mutable state.
private final class PhaseProjectionAssociationKey: @unchecked Sendable {}
private let phaseProjectionAssociationKey = PhaseProjectionAssociationKey()

/// Owned by the conversation through an association, without retaining the conversation or its store.
@MainActor private final class ConversationPhaseProjection {
    let owner:ObjectIdentifier,conversationID:String,sourceID:String
    var state:ConversationPhaseFacts.State?
    var fraction:Double?
    var event:BodyPhaseEvent?
    var factsSerial:UInt64?
    var planEvent:BodyPhaseEvent?
    init(owner:ObjectIdentifier,conversationID:String) {
        self.owner=owner;self.conversationID=conversationID
        sourceID=String(describing:owner)+":"+conversationID
    }
}

@MainActor private func phaseProjection(_ c:Conversation)->ConversationPhaseProjection {
    let owner=c.phaseStore.map{ObjectIdentifier($0)} ?? ObjectIdentifier(c)
    let key=Unmanaged.passUnretained(phaseProjectionAssociationKey).toOpaque()
    if let cached=objc_getAssociatedObject(c,key) as? ConversationPhaseProjection,
       cached.owner == owner,cached.conversationID == c.id {return cached}
    let cached=ConversationPhaseProjection(owner:owner,conversationID:c.id)
    objc_setAssociatedObject(c,key,cached,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return cached
}

@MainActor func conversationPhaseEvent(_ c:Conversation)->BodyPhaseEvent {
    let facts=c.phaseFacts
    let cached=phaseProjection(c)
    let unknown=(c.isLiveConversation || c.backendThreadID != nil) && !c.contextUsageReported
    let reportedState=facts.state(in:c)
    let state:ConversationPhaseFacts.State = reportedState == .unknown ? .running : reportedState
    let fraction:Double? = unknown ? 0 : c.contextShown
    let animate = !facts.isReplay || (cached.event != nil && cached.fraction != fraction)
        || (cached.factsSerial == facts.serial && cached.event?.animate == true)
    if let event=cached.event,cached.factsSerial == facts.serial,event.animate == animate,
       cached.state == state,cached.fraction == fraction {return event}
    let serial=(cached.event?.serial ?? 0) &+ 1
    let phase=BodyPhaseState(rawValue:state.rawValue) ?? .unknown
    let value=BodyPhaseValue(phase,fraction:fraction,contextBased:true)
    let event=BodyPhaseEvent(sourceID:cached.sourceID,value:value,serial:serial,animate:animate)
    cached.state=state
    cached.fraction=fraction
    cached.factsSerial=facts.serial
    cached.event=event
    return event
}

@MainActor func satellitePhaseEvent(_ satellite:Satellite,parent:Conversation)->BodyPhaseEvent {
    if let id=satellite.threadID,let child=parent.phaseStore?.conversation(id),child !== parent {
        let facts=child.phaseFacts
        let cached=phaseProjection(child)
        let state=BodyPhaseState(rawValue:facts.state(in:child).rawValue) ?? .unknown
        let value=BodyPhaseValue(state,fraction:facts.fraction)
        let event=BodyPhaseEvent(sourceID:cached.sourceID+":plan",value:value,
                                 serial:facts.serial,animate:!facts.isReplay)
        if let previous=cached.planEvent,previous == event {return previous}
        cached.planEvent=event
        return event
    }
    // A collab done flag also includes errored/notFound; it cannot prove success.
    return .init(sourceID:phaseSourceID(parent)+":satellite:"+satellite.id,value:.init(.unknown),serial:0)
}

@MainActor private func phaseSourceID(_ c:Conversation)->String {
    phaseProjection(c).sourceID
}
