import AppKit
import QuartzCore

/// Tide registers one frozen attachment with the host's outgoing-photo mechanism.
@MainActor final class TideModeExit {
    private var surfaces:[ModeDepartureSurfaces.Surface]=[]
    private var lease:ModeDepartureSurfaces.Lease?
    var isExiting:Bool {lease != nil}
    var photo:NSView? {lease?.picture}
    var probe:[String:Any] {
        var p=lease?.screenState ?? ["attached":false,"opacity":0]
        p["active"]=(p["attached"] as? Bool==true) && CACurrentMediaTime()<(p["started"] as? Double ?? 0)+0.22
        p["retained"]=lease != nil;p["duration"]=0.22;p["revealing"]=false
        return p
    }
    func include(_ views:[NSView],plane:ModeDepartureSurfaces.Plane = .foreground) {
        for view in views {surfaces.append(.init(view,plane:view is NSGlassEffectView ? .material:plane))}
    }
    func start(using pictures:ModeDepartureSurfaces,in host:NSView,at time:Double) {
        guard lease == nil,!surfaces.isEmpty else{return}
        lease=pictures.retain(surfaces,in:host,at:time)
        surfaces=[]
        // Submit the source picture before the mode's bounded native/cold-photo preparation begins.
        CATransaction.flush()
    }
    func clear() {lease=nil;surfaces=[]}
}
