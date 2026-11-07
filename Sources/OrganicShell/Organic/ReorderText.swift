import AppKit
import QuartzCore

/// Reorder-only readability choices. The geometry and its springs are never changed.
@MainActor enum M1111ReorderText {
    enum Style:String {case yield,fade}
    static let style=Style(rawValue:ProcessInfo.processInfo.environment["M1111_REORDER_TEXT"] ?? "yield") ?? .yield
    #if M10_DOCK_SELFTEST
    static let disabled=ProcessInfo.processInfo.environment["M1111_TEXT_NEGATIVE"] == "1"
    #else
    static let disabled=false
    #endif
    static func levels(_ rects:[String:CGRect],held:String)->[String:Double] {
        var result=rects.mapValues{_ in 1.0}
        guard !disabled else {return result}
        let keys=rects.keys.sorted()
        for i in keys.indices {for j in keys.indices where j>i {
            let a=keys[i],b=keys[j],ra=rects[a]!,rb=rects[b]!
            let gap=max(ra.minX-rb.maxX,rb.minX-ra.maxX)
            // Finish yielding before the column edges meet. The last 12 pt of the ordinary
            // inter-column gap provide the continuous fade; reversal retraces the same envelope.
            let level=smoothstep(0,12,Double(gap))
            if style == .fade {result[a]=min(result[a]!,level);result[b]=min(result[b]!,level)}
            else {
                let yielding=a == held ? b:(b == held ? a:b)
                result[yielding]=min(result[yielding]!,level)
            }
        }}
        return result
    }
}

extension AutoScene {
    func beginReorderText(_ prepared:Prepared,reason:String,at time:Double) {
        let applies=["drag-preview","drag-drop","drag-cancel"].contains(reason)
        guard applies,let id=reorderTextCandidate else {clearReorderText();return}
        // Keep the readable owner through an interrupted landing, including a rapid second pickup.
        // Changing priority in the middle of a crossing would exchange two opacities in one frame.
        let owner=reorderTextHeld ?? id
        reorderTextHeld=owner
        reorderTextRects=prepared.rects
        let timeline=Timeline(began:0,duration:prepared.duration,rate:Timeline.rate(frameInterval:profile.frameInterval))
        let levels=timeline.map {t in M1111ReorderText.levels(prepared.rects.mapValues{$0.sample(t).rect},held:owner)}
        for c in columns + Array(leaving.values) {
            let values=levels.map{NSNumber(value:$0[c.conversation.id] ?? 1)}
            // This is the headless transcript carrier. HeaderIsland lives in the native plane;
            // its capsule/title/event must keep their authored opacity while only body ink yields.
            let layers=[c.card]+(flights[c.conversation.id] ?? []).map(\.replicator)
            for layer in layers {
                layer.opacity=values.last!.floatValue
                if let track=timeline.track(layer,"opacity",values) {
                    Track(layer:layer,key:"shell.m1111.reorder",animation:track.animation).start(at:time)
                }
            }
        }
    }
    func clearReorderText() {
        guard !reorderTextRects.isEmpty else {return}
        for c in nodes.values {
            c.card.removeAnimation(forKey:"shell.m1111.reorder");c.card.opacity=1
        }
        reorderTextRects=[:];reorderTextHeld=nil
    }
}
