import AppKit
import QuartzCore

/// Opt-in CPU/capture trace. No logging, timers, or file writes in the production/default path.
/// Live roots begin at the scene callback (not NativeComposer's earlier sending presentation).
@MainActor enum M10ColumnWorkTrace {
    struct Event { var name:String,start:Double,end:Double,parent:Int,fields:[String:Any] }
    @MainActor struct Span {
        let index:Int
        func end() {
            guard index>=0,index<events.count else{return}
            events[index].end=CACurrentMediaTime()
            if stack.last==index {_ = stack.popLast()}
        }
    }
    static let requested=ProcessInfo.processInfo.environment["M10_COLUMN_TRACE"]=="1"
    static var active=false
    static private(set) var events:[Event]=[]
    static private var stack:[Int]=[]
    static private var sequence=0,generation=0
    static func reset() {generation+=1;events=[];events.reserveCapacity(2048);stack=[];active=true}
    static func scope(_ name:String,_ fields:@autoclosure ()->[String:Any]=[:])->Span {
        guard active else{return Span(index:-1)}
        let n=events.count
        events.append(.init(name:name,start:CACurrentMediaTime(),end:0,parent:stack.last ?? -1,fields:fields()));stack.append(n)
        return Span(index:n)
    }
    static func count(_ name:String,_ fields:@autoclosure ()->[String:Any]=[:]) {let s=scope(name,fields());s.end()}
    static func beginWindow(_ label:String) {
        guard requested,!active else{return}
        reset();let g=generation
        DispatchQueue.main.asyncAfter(deadline:.now()+2) {
            guard g==generation else{return}
            let prefix=ProcessInfo.processInfo.environment["M10_COLUMN_TRACE_OUT"] ?? "/tmp/sol-column-work"
            sequence+=1
            try? write(to:URL(fileURLWithPath:prefix+"-"+label+"-\(sequence).json"))
        }
    }
    static func report()->[String:Any] {
        let origin=events.first?.start ?? CACurrentMediaTime()
        return ["mediaTimeOrigin":origin,"pid":ProcessInfo.processInfo.processIdentifier,"mainThread":Thread.isMainThread,
                "boundary":"scene callback spans; not the earlier NativeComposer sending presentation or presented-frame timing",
                "events":events.enumerated().map{i,e -> [String:Any] in
                    ["id":i,"name":e.name,"parent":e.parent,"startMs":(e.start-origin)*1000,
                     "durationMs":max(0,e.end-e.start)*1000,"fields":e.fields]}]
    }
    static func write(to url:URL) throws {
        active=false
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:report(),options:[.prettyPrinted,.sortedKeys]).write(to:url)
    }
}
