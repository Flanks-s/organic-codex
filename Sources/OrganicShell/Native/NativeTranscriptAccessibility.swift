import AppKit

private struct NativeTranscriptAXTransfer<Value>:@unchecked Sendable{let value:Value}

/// Semantic document only: layout, scrolling and TextKit remain in the existing retained views.
/// Raw [Any] relations deliberately avoid SDK27's typed-row bridge to macOS26 informal rows.
@MainActor final class NativeTranscriptTable:NativeFlippedView {
    weak var surface:NativeTranscript?
    private(set) var semanticRows:[NativeTranscriptAXRow]=[]
    private var cache:[String:NativeTranscriptAXRow]=[:]
    override init(frame:NSRect){super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.table);setAccessibilityLabel("Conversation transcript")}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    func update(_ views:[(String,NSView)]){
        updateVirtual(views.enumerated().map { ($0.element.0, $0.element.1, $0.offset) })
    }
    func updateVirtual(_ views: [(String, NSView, Int)]) {
        let keep=Set(views.map(\.0));for key in Array(cache.keys) where !keep.contains(key){cache[key]?.content=nil;cache[key]=nil}
        semanticRows=views.map{pair in let row=cache[pair.0] ?? NativeTranscriptAXRow(table:self,key:pair.0);cache[pair.0]=row;row.content=pair.1;row.index=pair.2;(pair.1 as? NativeTranscriptRow)?.semanticParent=row;(pair.1 as? NativeTranscriptCard)?.semanticParent=row;return row}
    }
    var visibleRows:[NativeTranscriptAXRow]{semanticRows.filter{!$0.accessibilityFrame().isEmpty}}
    override func accessibilityChildren()->[Any]?{visibleRows}
    override func accessibilityRows()->[Any]?{visibleRows}
    override func accessibilityVisibleRows()->[Any]?{visibleRows}
    override func accessibilitySelectedRows()->[Any]?{visibleRows.filter(\.hasSelection)}
    override func accessibilitySelectedChildren()->[Any]?{accessibilitySelectedRows()}
    override func accessibilityAttributeNames()->[NSAccessibility.Attribute]{Array(Set(super.accessibilityAttributeNames()+[.rows,.visibleRows,.selectedRows]))}
    override func accessibilityParent()->Any?{enclosingScrollView}
    override func accessibilityAttributeValue(_ attribute:NSAccessibility.Attribute)->Any?{
        nativeInteractionAXResult{switch attribute{case .rows:return self.accessibilityRows();case .visibleRows:return self.accessibilityVisibleRows();case .selectedRows,.selectedChildren:return self.accessibilitySelectedRows();case .children:return self.accessibilityChildren();case .parent:return self.accessibilityParent();default:return super.accessibilityAttributeValue(attribute)}}
    }
}

@MainActor final class NativeTranscriptAXRow:NSAccessibilityElement,@unchecked Sendable {
    private nonisolated func onAXMain<Value>(_ query:@MainActor (NativeTranscriptAXRow)->Value)->Value{let reference=NativeTranscriptAXTransfer(value:self);return MainActor.assumeIsolated{NativeTranscriptAXTransfer(value:query(reference.value))}.value}
    private nonisolated func baseAttribute(_ attribute:NSAccessibility.Attribute)->Any?{super.accessibilityAttributeValue(attribute)}
    weak var table:NativeTranscriptTable?,content:NSView?
    let key:String
    var index=0
    init(table:NativeTranscriptTable,key:String){self.table=table;self.key=key;super.init()}
    var hasSelection:Bool{
        func selected(_ view:NSView)->Bool{if let text=view as? NSTextView,text.selectedRange().length>0{return true};return view.subviews.contains(where:selected)}
        return content.map(selected) ?? false
    }
    override func accessibilityRole()->NSAccessibility.Role?{.row}
    override func accessibilityIdentifier()->String{"transcript.row."+key}
    override func accessibilityLabel()->String?{onAXMain{$0.content?.accessibilityLabel()}}
    override func accessibilityParent()->Any?{onAXMain{$0.table}}
    override func accessibilityRowIndexRange()->NSRange{onAXMain{NSRange(location:$0.index,length:1)}}
    override func accessibilityFrame()->NSRect{
        onAXMain{row in
        guard let table=row.table,let surface=table.surface,let content=row.content,content.superview === table,let frame=surface.sourceFrame(content)else{return .zero}
        let clipped=frame.intersection(surface.screenClip);return clipped.isNull ? .zero:clipped
        }
    }
    override func isAccessibilityElement()->Bool{!accessibilityFrame().isEmpty}
    override func isAccessibilityHidden()->Bool{accessibilityFrame().isEmpty}
    override func accessibilityChildren()->[Any]?{
        onAXMain{row in
        guard !row.accessibilityFrame().isEmpty,let content=row.content else{return []}
        // An approval is an independently labelled nested group. Message/tool rows expose their native leaves.
        return [content]
        }
    }
    override func accessibilityActionNames()->[NSAccessibility.Action]{[]}
    override func accessibilityAttributeNames()->[NSAccessibility.Attribute]{[.role,.parent,.children,.position,.size,.rowIndexRange,.selected,.description]}
    override func accessibilityAttributeValue(_ attribute:NSAccessibility.Attribute)->Any?{
        onAXMain{row in switch attribute{case .parent:return row.table;case .rowIndexRange:return NSValue(range:row.accessibilityRowIndexRange());case .children:return row.accessibilityChildren();case .selected:return row.hasSelection;default:return row.baseAttribute(attribute)}}
    }
}
