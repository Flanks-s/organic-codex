import Foundation

/// Opt-in six-state specimen, using the same Core notifications as normal mock playback.
@MainActor enum MockPhaseDemonstration {
    struct Notification { let thread:String;let method:String;let params:[String:JSONValue] }
    static func prepare(store:ConversationStore)->[Notification] {
        var result:[Notification]=[]
        for (i,id) in ["A","B","C","D","E","F"].enumerated() {
            guard let c=store.conversation(id) else {continue}
            c.approvals=[];c.question=nil;c.userInput=nil;c.error=nil
            let turn=id+"-phase-demo"
            func add(_ method:String,_ params:[String:JSONValue]) {result.append(.init(thread:id,method:method,params:params))}
            add("turn/started",["turn":["id":.string(turn)]])
            if i != 1 {
                let done=i == 3 ? 5:1
                let plan=(0..<5).map{JSONValue.object(["step":.string("Phase demonstration step \($0+1)"),"status":.string($0<done ? "completed":"pending")])}
                add("turn/plan/updated",["turnId":.string(turn),"plan":.array(plan)])
            }
            if i == 2 {add("core/approvalRequested",["turnId":.string(turn),"approvalId":"phase-demo-approval","request":["method":"item/commandExecution/requestApproval","params":["command":"Preview only"]]])}
            if i >= 3 {add("turn/completed",["turn":["id":.string(turn),"status":.string(i == 3 ? "completed":i == 4 ? "failed":"interrupted")]])}
        }
        return result
    }
    static func notifications(at tick:Int)->[Notification] {
        let first="A-phase-demo",second="A-phase-retry",third="A-phase-cancel"
        func event(_ method:String,_ values:[String:JSONValue],turn:String?=nil)->Notification {
            var p=values;if p["turn"] == nil {p["turnId"] = .string(turn ?? first)}
            return .init(thread:"A",method:method,params:p)
        }
        func plan(_ done:Int)->[String:JSONValue] {
            ["plan":.array((0..<5).map{["step":.string("Demonstration step \($0+1)"),"status":.string($0<done ? "completed":"pending")]})]
        }
        switch tick {
        case 8:return [event("turn/plan/updated",plan(3))]
        case 16:return [event("turn/plan/updated",["plan":[]])]
        case 24:return [event("item/completed",["item":["id":"phase-unknown-event","type":"agentMessage","text":"Unknown progress event"]])]
        case 32:return [event("core/approvalRequested",["approvalId":"phase-live-approval","request":["method":"item/commandExecution/requestApproval","params":["command":"Preview only"]]])]
        case 40:return [event("core/approvalResponded",["approvalId":"phase-live-approval"]),event("turn/plan/updated",plan(4))]
        case 48:return [event("turn/completed",["turn":["id":.string(first),"status":"completed"]])]
        case 56:return [event("turn/started",["turn":["id":.string(second)]],turn:second)]
        case 64:return [event("error",["willRetry":true],turn:second)]
        case 72:return [event("error",["willRetry":false],turn:second)]
        case 80:return [event("turn/started",["turn":["id":.string(third)]],turn:third)]
        case 88:return [event("turn/completed",["turn":["id":.string(third),"status":"interrupted"]],turn:third)]
        default:return []
        }
    }

}
