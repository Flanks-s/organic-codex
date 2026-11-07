import AppKit
import QuartzCore

/// PhotoN is below the independent Dock surface. Give that surface the complementary authored
/// phase so its glass, necks and ink cannot paint over opaque Normie. PhotoO has LiveN above it,
/// which already supplies source-over coverage; applying another fade there would square it.
@MainActor final class ModeContentDockExposure {
    private weak var target:CALayer?
    private struct ClockKey:Equatable {let session:String,time:Double,direction:Double}
    private var phaseKey:ClockKey?
    func apply(to view:NSView,session:ModeContentSession,time:Double) {
        guard session.photoMode == "normie",let layer=view.layer else {clear();return}
        let key=ClockKey(session:session.id,time:session.anchorTime,direction:session.direction)
        if target === layer,phaseKey == key,layer.animation(forKey:"mode.content.phase") != nil {return}
        target=layer;phaseKey=key
        layer.removeAnimation(forKey:"mode.dock")
        // A separate server channel samples u on every retarget. It never restarts a 0→1 ease on a turn.
        session.animate(layer,at:time,photoOnTop:false,invert:true)
    }
    func clear() {target?.removeAnimation(forKey:"mode.content.phase");target?.opacity=1;target=nil;phaseKey=nil}
    #if M11_MODE_SELFTEST
    var verificationBars:[CALayer] {target.map {[$0]} ?? []}
    #endif
}
