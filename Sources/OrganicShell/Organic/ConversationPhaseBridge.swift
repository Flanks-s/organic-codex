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

/// Presentation has no fallback to context, token usage, elapsed time, or child counts.
@MainActor func conversationPhaseEvent(_ c:Conversation)->BodyPhaseEvent {
    let facts=c.phaseFacts,cached=phaseProjection(c),state=facts.state(in:c),fraction=facts.fraction
    // Fallback approval/error state can change before a turn exists, independently of the serial.
    if let event=cached.event,event.serial == facts.serial,event.animate == !facts.isReplay,
       cached.state == state,cached.fraction == fraction {return event}
    let event=BodyPhaseEvent(sourceID:cached.sourceID,value:.init(BodyPhaseState(rawValue:state.rawValue) ?? .unknown,fraction:fraction),serial:facts.serial,animate:!facts.isReplay)
    cached.state=state;cached.fraction=fraction;cached.event=event
    return event
}

@MainActor func satellitePhaseEvent(_ satellite:Satellite,parent:Conversation)->BodyPhaseEvent {
    if let id=satellite.threadID,let child=parent.phaseStore?.conversation(id),child !== parent {
        return conversationPhaseEvent(child)
    }
    // A collab done flag also includes errored/notFound; it cannot prove success.
    return .init(sourceID:phaseSourceID(parent)+":satellite:"+satellite.id,value:.init(.unknown),serial:0)
}

@MainActor private func phaseSourceID(_ c:Conversation)->String {
    phaseProjection(c).sourceID
}
