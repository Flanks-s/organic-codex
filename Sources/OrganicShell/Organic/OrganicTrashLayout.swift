import AppKit

/// Only column position/weight certificates. Conversation membership and Scheme remain scene-owned.
struct OrganicTrashLayout {
    var mode: OrganicMemberLayout.Mode
    var columns: [OrganicMemberLayout.Column]

    @MainActor func arrange(_ members: [Conversation], current: String, scheme: AutoScene.Scheme,
                            size: CGSize, metrics m: AutoLayout.Metrics, scale: CGFloat) -> (AutoLayout,[String])? {
        let ids=members.map(\.id), shown=columns.map(\.member)
        guard !scheme.draft, (scheme.mode == .focused) == (mode == .focused),
              !shown.isEmpty, shown.allSatisfy(ids.contains), shown.contains(current) else { return nil }
        let parked=scheme.parked.filter { ids.contains($0) && !shown.contains($0) }
        let left=scheme.left.filter { ids.contains($0) && !shown.contains($0) }
        let right=scheme.right.filter { ids.contains($0) && !shown.contains($0) && !left.contains($0) }
        let rest=ids.filter { !shown.contains($0) && !parked.contains($0) && !left.contains($0) && !right.contains($0) }
        var l: AutoLayout
        let order: [String]
        if mode == .focused {
            guard scheme.split == shown else { return nil }
            let f=FocusLayout(size:size,segments:shown.count,leftOrbs:left.count,rightOrbs:right.count+rest.count,satellites:false,metrics:m)
            l=AutoLayout();l.focused=true;l.columns=f.columns;l.bars=f.segments;l.me=f.me;l.orbs=f.leftOrbs+f.rightOrbs
            order=shown+left+right+rest
        } else {
            l=AutoLayout(size:size,count:shown.count,fullIndex:shown.firstIndex(of:current),leading:parked.count,metrics:m)
            order=shown+parked+left+right+rest
            l.leading=parked.count
            let bank=order.count-shown.count-parked.count
            let span=CGFloat(bank)*m.orb+CGFloat(max(0,bank-1))*m.orbGap
            let row=l.me.midY
            l.orbs=Array(l.orbs.prefix(parked.count))+(0..<bank).map { i in
                CGRect(x:size.width-m.inset-span+CGFloat(i)*(m.orb+m.orbGap),y:row-m.orb/2,width:m.orb,height:m.orb)
            }
        }
        guard l.columns.count == shown.count, let first=l.columns.first, let last=l.columns.last else { return nil }
        let total=columns.reduce(0) { $0+$1.weight }
        guard total > 0 else { return nil }
        let available=last.maxX-first.minX-CGFloat(shown.count-1)*m.gap
        func edge(_ x:CGFloat)->CGFloat { (x*scale).rounded()/scale }
        var cursor=first.minX
        l.columns=columns.enumerated().map { i,slot in
            let end=i == columns.count-1 ? last.maxX:cursor+available*slot.weight/total
            defer { cursor=end+m.gap }
            return CGRect(x:edge(cursor),y:first.minY,width:edge(end)-edge(cursor),height:first.height)
        }
        l.fullColumn=shown.firstIndex(of:current) ?? 0
        let row=l.bars.first?.midY ?? l.me.midY
        l.bars=l.columns.enumerated().map { i,column in
            var a=column.minX, b=column.maxX
            if mode == .focused {
                if i>0 { a-=m.gap/2 };if i<shown.count-1 { b+=m.gap/2 }
            } else {
                if i==0 { a=max(a,l.me.maxX+m.gap+CGFloat(parked.count)*AutoLayout.parkedSlot) }
                if i==shown.count-1, let orb=l.orbs.dropFirst(parked.count).first { b=min(b,orb.minX-m.orbGap) }
            }
            return CGRect(x:edge(a),y:row-m.barHeight/2,width:max(m.barHeight,edge(b)-edge(a)),height:m.barHeight)
        }
        return (l,order)
    }
}
