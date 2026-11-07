import AppKit

extension DockNode {
    /// Warm an inactive editor in its actual window/backing before a late member publication.
    /// No glass, label, role, or visible composer changes; a foreign host is never borrowed here.
    func prepareModeSelectionComposer(_ composer:NativeComposer,id:String,bar:CGRect,slot:Int,count:Int,focused:Bool) {
        guard ModeFlight.orreryEnabled,let item=items[id],!item.full,
              item.composer == nil || item.composer === composer,
              composer.superview == nil || composer.superview === item.barFace else {return}
        if composer.superview == nil {
            composer.isHidden=true;composer.alphaValue=0
            item.barFace.addSubview(composer);item.composer=composer
        }
        guard composer.isHidden || composer.alphaValue<=0.001 else {return}
        let leading:CGFloat=focused && slot == 0 ? bar.height:0
        composer.segment=focused ? NativeComposerSegment(index:slot,isLast:slot == count-1):nil
        composer.targetWidth=bar.width-leading
        composer.frame=CGRect(x:leading,y:0,width:bar.width-leading,height:bar.height)
        composer.layoutSubtreeIfNeeded()
    }
}
