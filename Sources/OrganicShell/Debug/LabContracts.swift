import AppKit

struct TransitionLabParameters:Equatable {
    var fullWidth=620.0,briefWidth=250.0,height=640.0
    var response=0.42,damping=0.86,burst=28.0,swirl=35.0,pop=0.12,stagger=0.035
    mutating func normalize(){
        func clamp(_ x:Double,_ range:ClosedRange<Double>,_ fallback:Double)->Double{x.isFinite ? min(range.upperBound,max(range.lowerBound,x)):fallback}
        fullWidth=clamp(fullWidth,480...900,620);briefWidth=clamp(briefWidth,200...420,250);height=clamp(height,420...760,640)
        response=clamp(response,0.05...1.2,0.42);damping=clamp(damping,0.2...1.2,0.86)
        burst=clamp(burst,0...80,28);swirl=clamp(swirl,-90...90,35);pop=clamp(pop,0...0.4,0.12);stagger=clamp(stagger,0...0.12,0.035)
    }
}
struct TransitionLabRequest:Equatable {
    var conversationID:String,form:Double,towardBrief:Bool,parameters:TransitionLabParameters
    var outlines=false,frozen=true
    var interpolatedWidth:Double{parameters.briefWidth+(parameters.fullWidth-parameters.briefWidth)*form}
}
struct LabAnchor {var name:String;var full:CGRect;var brief:CGRect}
struct LabPath {var name:String;var points:[CGPoint]}
struct TransitionLabFrame {
    var image:CGImage?
    /// All coordinates use the returned image's logical viewport, origin at top-left.
    var anchors:[LabAnchor]=[],paths:[LabPath]=[]
    /// E.g. "Production driver B" or "Historical reference". Always shown and exported.
    var provenance:String
}
@MainActor protocol TransitionLabHost:AnyObject {
    func transitionLabAttach()
    func transitionLabRender(_ request:TransitionLabRequest,size:CGSize,scale:CGFloat)->TransitionLabFrame
    func transitionLabDetach()
}
extension TransitionLabHost {func transitionLabAttach(){};func transitionLabDetach(){}}

/// Deterministic transport; hosts receive the actual sampled form, rather than an already-changed endpoint.
struct TransitionLabTransport {
    private(set) var form=1.0,towardBrief=true,playing=false
    var slow=1.0,loop=false
    private var elapsed=0.0,start=1.0,target=0.0
    mutating func scrub(_ value:Double){guard value.isFinite else{return};form=min(1,max(0,value));playing=false}
    mutating func nudge(_ amount:Double){towardBrief=amount<0;scrub(form+amount)}
    mutating func play(toBrief:Bool,fromEndpoint:Bool=true){towardBrief=toBrief;start=fromEndpoint ? (toBrief ? 1:0):form;form=start;target=toBrief ? 0:1;elapsed=0;playing=true}
    mutating func stop(){playing=false}
    mutating func advance(_ dt:Double,parameters:TransitionLabParameters){
        guard playing,dt.isFinite,dt>=0 else{return};elapsed+=dt/max(0.1,slow)
        let spring=LabSpring(response:parameters.response,damping:parameters.damping)
        form=start+(target-start)*spring.value(elapsed)
        if elapsed>=spring.settlingTime {form=target;playing=false;if loop{play(toBrief:!towardBrief)}}
    }
    static var filmstrip:[(Bool,Double)]{[true,false].flatMap{direction in (0...10).map{(direction,direction ? 1-Double($0)/10:Double($0)/10)}}}
}

enum LabSpringVariant:String,CaseIterable {case system="System spring",truncated="Truncated spring",fitted="Fitted curve"}
struct SpringLabRequest:Equatable {
    var conversationID="A",variant:LabSpringVariant = .system
    var response=0.42,damping=0.86,distance=370.0,slow=1.0
    var from=0.0,target=1.0,initialVelocity=0.0
    var realColumn=false,runs=4
    mutating func normalize(){
        response=response.isFinite ? min(1,max(0.1,response)):0.42;damping=damping.isFinite ? min(1,max(0.4,damping)):0.86
        distance=distance.isFinite ? min(600,max(10,distance)):370;slow=[1,2,4,10].contains(slow) ? slow:1;runs=min(12,max(2,runs))
    }
}
struct SpringLabMeasurement:Equatable {
    var variant:LabSpringVariant,frames:Int,tailFrames:Int,duration:Double,visibleEnd:Double,busyMilliseconds:Double,tailBusyMilliseconds:Double
    /// "Host actual scene", or "Lab draw CPU"; never compare unlike measurement methods without this label.
    var provenance:String
    var preset:String="Current",subject:String="Lanes"
}
@MainActor protocol SpringLabHost:AnyObject {
    func springLabAttach()
    func springLabPlay(_ request:SpringLabRequest)
    func springLabInterrupt(_ request:SpringLabRequest)
    func springLabFrame(size:CGSize,scale:CGFloat)->CGImage?
    func springLabMeasure(_ request:SpringLabRequest) async throws->[SpringLabMeasurement]
    func springLabStop()
    func springLabDetach()
}
extension SpringLabHost {func springLabAttach(){};func springLabDetach(){}}
