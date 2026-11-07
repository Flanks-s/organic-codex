import AppKit

extension DockNode {
    /// First send keeps a draft's editor in the same bar, at exactly the same size. There is no editor
    /// motion to bake here. Admit its existing native presentation after the ordinary dock geometry commit;
    /// the motion-content observer can refresh its dirty ink at rest, and the next moving commit still prepares it.
    /// This adapter belongs in DockNode.adoptDraftBar once that file's ownership is available (M11-3 debt).
    @discardableResult func transitionAdoptingStationaryDraft(_ composer: NativeComposer, id: String,
        to layout: AutoLayout, order: [String], full: Set<String>, springs: [String: RectSpring], duration: Double) -> Bool {
        guard let item=items[id],let slot=order.firstIndex(of:id),layout.bars.indices.contains(slot),
              full == [id],item.role == .bar,item.composer == nil,composer.segment == nil,
              springs[id]?.duration == 0,item.spring.target == layout.bars[slot],
              composer.frame == CGRect(origin:.zero,size:layout.bars[slot].size) else {return false}
        // Arrange the other members normally. This bar already has its target geometry and live editor layout;
        // withholding only its new full role avoids capturing an unused whole editor in arrange(atCommit:).
        transition(to:layout,order:order,full:[],springs:springs,duration:duration)
        item.composer=composer;item.full=true
        item.barFace.addSubview(composer)
        item.label.alphaValue=0
        composer.isHidden=false;composer.alphaValue=1
        return true
    }
}
