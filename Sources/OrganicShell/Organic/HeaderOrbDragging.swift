import AppKit

/// A top planet is another grip for the SAME Dock gesture. This adapter owns only event capture
/// and the header's short-click action; AutoScene and DockNode own every drag state and pixel.
@MainActor final class M104HeaderOrbDragging: IslandOrbDragGesture {
    @discardableResult static func install(in scene:AutoScene) -> M104HeaderOrbDragging {
        if let existing=scene.dock.headerOrbDragging {return existing}
        let result=M104HeaderOrbDragging(scene:scene)
        scene.dock.installHeaderOrbDragging(result)
        return result
    }
    // Keep the trace vocabulary consumed by the host's InputRun. Dock owns the return animation.
    enum Phase:String {case idle,pressed,carrying,returning,tearing}
    private weak var scene:AutoScene?
    private weak var source:HeaderIsland?
    private var id:String?,clickRect=CGRect.zero
    private var disposed=false
    private var monitor:Any?
    private weak var eventWindow:NSWindow?
    var phase:Phase {
        guard let scene,let id else {return .idle}
        if scene.tearing?.id == id {return .tearing}
        guard scene.pressedNode == id else {return .idle}
        return scene.isDragging ? .carrying:.pressed
    }
    var isActive:Bool {phase != .idle}
    var isCarrying:Bool {phase == .carrying}
    private init(scene:AutoScene) {self.scene=scene}

    @discardableResult func begin(from island:HeaderIsland,at point:CGPoint)->Bool {
        guard !disposed,!isActive,let scene,island.canDragOrb,
              let c=island.configuration,scene.nodes[c.id]?.island === island else {return false}
        stopInput()
        guard scene.pointerDown(point,member:c.id) else {return false}
        source=island;id=c.id
        clickRect=scene.dock.view.convert(island.draggableOrbRect,from:island)
        return true
    }
    func beginOrbDrag(from island:HeaderIsland,event:NSEvent)->(any IslandOrbDragGesture)? {
        guard let scene,event.type == .leftMouseDown,
              begin(from:island,at:scene.dock.view.convert(event.locationInWindow,from:nil)) else {return nil}
        eventWindow=island.window;scene.pressFromPointer=true
        // The original hit view can leave during preview. Keep its up/Esc from clicking through.
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDragged,.leftMouseUp,.keyDown]) { [weak self] event in
            guard let self,event.window === self.eventWindow else {return event}
            if event.type == .leftMouseDragged {self.dragged(with:event);return nil}
            if event.type == .leftMouseUp {self.released(with:event);return nil}
            if event.keyCode == 53 {self.cancel();return nil}
            return event
        }
        return self
    }
    func move(to point:CGPoint) {
        guard isActive,let scene else {stopInput();return}
        scene.pointerDragged(point)

    }
    @discardableResult func end(at point:CGPoint,performClick:Bool=true)->Bool {
        guard isActive,let scene else {stopInput();return false}
        let click=phase == .pressed && clickRect.contains(point),island=source
        let dragged=scene.pointerUp(point)
        stopInput()
        if performClick,!dragged,click,!scene.pressCancelled {island?.planetButton.performClick(nil)}
        return dragged
    }
    func cancel() {
        if isActive {scene?.cancelDrag()}
        stopInput()
    }
    func dragged(with event:NSEvent) {
        guard let scene else {stopInput();return}
        move(to:scene.dock.view.convert(event.locationInWindow,from:nil))
    }
    func released(with event:NSEvent) {
        guard let scene else {stopInput();return}
        _=end(at:scene.dock.view.convert(event.locationInWindow,from:nil))
    }
    private func stopInput() {
        if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}
        source?.planetButton.endPointerGesture();source=nil;eventWindow=nil
    }
    func cancelImmediately() {cancel();id=nil}
    func dispose() {cancelImmediately();disposed=true}
}
