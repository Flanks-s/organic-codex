#if M10_DOCK_SELFTEST
import AppKit

/// Deterministic applied geometry for comparing logging off/on and the unchanged production input.
@MainActor enum DockFrameLogVerification {
    static func run(to output: URL, check: (Bool, String) -> Void) throws {
        NativeAppearance.apply(.init()); ModelCatalog.models = ModelCatalog.mockModels
        var rows: [[String: Any]] = []
        for scale: CGFloat in [1, 2] { for exposure in [false, true] {
            let f = DockCapsuleVerification.Fixture(scale: scale, exposure: exposure)
            f.now = 1000; f.began = f.now
            let auto = f.auto(), owner = f.all[0].id
            f.dock.install(auto.0, metrics: f.metrics, order: f.all, full: [owner], store: f.store)
            func frame(_ phase: String, _ time: Double) {
                f.now = f.began + time
                f.dock.frame(at: f.now, elapsed: time)
                let items = f.dock.items.keys.sorted().map { id -> [String: Any] in
                    let item = f.dock.items[id]!
                    return ["id":id,"frame":DockFrameLog.rect(item.glass.frame),"hidden":item.glass.isHidden,
                            "layerHidden":item.glass.layer?.isHidden ?? false,"alpha":item.glass.alphaValue,
                            "logical":item.motion.rect.map { DockFrameLog.rect($0) as Any } ?? NSNull()]
                }
                rows.append(["scale":scale,"exposure":exposure,"phase":phase,"time":f.now,
                    "items":items,"capsule":DockFrameLog.rect(f.glass.frame),"capsuleHidden":f.glass.isHidden,
                    "capsuleAlpha":f.glass.alphaValue,"me":DockFrameLog.rect(f.dock.mePaintedFrame),
                    "meLogical":DockFrameLog.rect(f.dock.meLogicalFrame)])
            }
            func walk(_ phase: String, _ duration: Double) {
                for step in 0...Int(duration*120) { frame(phase, Double(step)/120) }
            }
            frame("idle",0)
            f.transition(f.focused(owner)); walk("enter-partial",0.15)
            f.transition(auto); walk("reverse",1.2)
            f.transition(f.focused(owner)); walk("enter",1.2)
            f.transition(auto); walk("exit",1.2)
            f.dock.still = false
            let orb = f.dock.items[f.all[4].id]!.glass.frame
            _ = f.dock.pointer(CGPoint(x:orb.midX,y:orb.midY),now:f.now)
            f.began = f.now; walk("hover",0.4)
            let id = f.all[1].id, source = f.dock.items[id]!.glass.frame
            f.dock.hold(id,at:CGPoint(x:source.midX,y:source.midY),now:f.now,spring:(0.30,0.80))
            f.began = f.now
            for step in 0...48 {
                f.dock.moveHeld(to:CGPoint(x:source.midX-CGFloat(step)*3,y:source.midY))
                frame("drag",Double(step)/120)
            }
            f.dock.release(forTear:true)
        } }
        check(rows.count == 2212, "frame log comparison covers every deterministic display sample")
        try JSONSerialization.data(withJSONObject:rows, options:[.sortedKeys]).write(to:output.appendingPathComponent("geometry.json"))
    }
}
#endif
