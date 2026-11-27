import AppKit

/// Resolved host contract, independent of Settings so Native still compiles on its own.
@MainActor enum NativeAppearance {
    struct Look:Equatable {
        var accent:NSColor?,background:NSColor?,foreground:NSColor?,wash:NSColor?
        var clearGlass=false
        var textScale:CGFloat=1
        var code=NativeTranscriptCodeStyle()
        var label:NSColor{foreground?.withAlphaComponent(0.9) ?? .labelColor}
        var secondary:NSColor{foreground?.withAlphaComponent(0.58) ?? .secondaryLabelColor}
        var tertiary:NSColor{foreground?.withAlphaComponent(0.28) ?? .tertiaryLabelColor}
        var canvas:NSColor{background ?? .windowBackgroundColor}
        var accentColor:NSColor{accent ?? .controlAccentColor}
    }
    struct Change {
        let revision:Int
        let redrawSnapshots:Bool
        let geometryChanged:Bool
        let clearGlass:Bool
        let glassTint:NSColor?
        let textScale:CGFloat
        var effectiveMode:String{"dark"}
    }
    static private(set) var current=Look(),previous=Look(),revision=0
    private static var observers:[UUID:()->Void]=[:]
    @discardableResult static func observe(_ callback:@escaping()->Void)->UUID{let key=UUID();observers[key]=callback;return key}
    static func removeObserver(_ key:UUID){observers[key]=nil}
    /// Main thread, semantic changes only. No view creation, reparenting, scene/window reads, or persistence.
    @discardableResult static func apply(_ value:Look)->Change{
        var look=value
        look.textScale=look.textScale.isFinite ? min(2,max(0.85,look.textScale)):1
        look.code.pointSize=look.code.pointSize.isFinite ? min(32,max(8,look.code.pointSize)):12
        let changed=look != current,geometry=look.textScale != current.textScale || look.code.fontID != current.code.fontID || look.code.pointSize != current.code.pointSize
        if changed{previous=current;current=look;revision+=1;NSAnimationContext.beginGrouping();NSAnimationContext.current.duration=0;for callback in Array(observers.values){callback()};NSAnimationContext.endGrouping()}
        return .init(revision:revision,redrawSnapshots:changed,geometryChanged:changed && geometry,clearGlass:look.clearGlass,glassTint:look.background?.withAlphaComponent(look.clearGlass ? 0.2:0.55),textScale:look.textScale)
    }
    /// Preserve semantic warning/error colours while updating cached system/theme label colours.
    static func recolor(_ view:NSView){
        func mapped(_ color:NSColor?)->NSColor?{guard let color else{return nil};for (old,new) in [(previous.label,current.label),(previous.secondary,current.secondary),(previous.tertiary,current.tertiary)] where color == old{return new};return color}
        if let field=view as? NSTextField{field.textColor=mapped(field.textColor)}
        if let button=view as? NSButton{button.contentTintColor=button.contentTintColor == nil && current.foreground != nil ? current.label:mapped(button.contentTintColor)}
        view.needsDisplay=true;view.subviews.forEach(recolor)
    }
}
