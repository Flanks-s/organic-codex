import AppKit
import QuartzCore

/// Driver-only evidence from the retained native card, without changing its presentation.
@MainActor enum TideRunVisibility {
    static func buttons(in view:NSView)->[NSButton] {
        if let button=view as? NSButton,button.title == "Run" {return [button]}
        return view.subviews.flatMap {buttons(in:$0)}
    }

    static func inspect(_ button:NSButton,window:NSWindow?,relativeTo coordinateView:NSView)->[String:Any] {
        let root=window?.contentView
        var chain:[[String:Any]]=[],view:NSView?=button,card:NativeTranscriptCard?
        var hidden=false,viewAlpha:CGFloat=1
        while let node=view {
            if card == nil {card=node as? NativeTranscriptCard}
            hidden = hidden || node.isHidden
            viewAlpha *= node.alphaValue
            chain.append(["class":String(describing:type(of:node)),"hidden":node.isHidden,
                          "alpha":Double(node.alphaValue),"rect":rect(node.convert(node.bounds,to:coordinateView))])
            view=node.superview
        }
        var layer=button.layer,layerAlpha:Float=1,layerHidden=false,layers:[[String:Any]]=[]
        while let node=layer {
            let opacity=node.presentation()?.opacity ?? node.opacity
            layerHidden = layerHidden || node.isHidden
            layerAlpha *= opacity
            layers.append(["class":String(describing:type(of:node)),"name":node.name ?? "",
                           "hidden":node.isHidden,"modelOpacity":node.opacity,"displayedOpacity":opacity])
            layer=node.superlayer
        }
        var visible=CGRect.zero,hit:NSView?
        if let root {
            visible=button.convert(button.bounds.intersection(button.visibleRect),to:root)
                .intersection(root.bounds).intersection(root.visibleRect)
            var ancestor=button.superview
            while let node=ancestor {
                if node.clipsToBounds || node is NSClipView {
                    visible=visible.intersection(node.convert(node.bounds,to:root))
                }
                ancestor=node.superview
            }
            let point=button.convert(CGPoint(x:button.bounds.midX,y:button.bounds.midY),to:root.superview)
            hit=root.hitTest(point)
        }
        let inWindow=window != nil && button.window === window && card?.window === window
        let alpha=min(Double(viewAlpha),Double(layerAlpha))
        let buttonClass=String(describing:type(of:button)),hitClass=hit.map {String(describing:type(of:$0))} ?? "nil"
        let visibleRect=visible.isNull || visible.isInfinite ? CGRect.zero:visible
        let nativeHit=hit === button && hitClass == "NativeCardButton" && buttonClass == "NativeCardButton"
        let shown=inWindow && card?.isApprovalCard == true && !hidden && !layerHidden && alpha>0 && !visibleRect.isEmpty
        return ["title":button.title,"enabled":button.isEnabled,"buttonClass":buttonClass,"hitClass":hitClass,
                "hitIsButton":hit === button,"nativeHit":nativeHit,"inWindow":inWindow,"cardInWindow":card?.window === window && window != nil,
                "windowVisible":window?.isVisible ?? false,"windowKey":window?.isKeyWindow ?? false,
                "hidden":hidden,"layerHidden":layerHidden,"viewAlpha":Double(viewAlpha),"layerAlpha":Double(layerAlpha),
                "effectiveAlpha":alpha,"visibleWindowRect":rect(visibleRect),"rect":rect(button.convert(button.bounds,to:coordinateView)),
                "cardRect":card.map {rect($0.convert($0.bounds,to:coordinateView))} ?? [],"ancestors":chain,"layers":layers,
                "shown":shown,"passed":shown && nativeHit && button.isEnabled]
    }

    static func passed(_ rows:[[String:Any]])->Bool {!rows.isEmpty && rows.allSatisfy {$0["passed"] as? Bool == true}}
    private static func rect(_ value:CGRect)->[CGFloat] {[value.minX,value.minY,value.width,value.height]}
}
