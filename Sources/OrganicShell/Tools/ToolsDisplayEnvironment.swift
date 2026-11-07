import AppKit

/// Independent Tools compilation does not depend on Orb. Same system policy as CanopyCanvas.
@MainActor final class ToolsDisplayEnvironment {
    struct Options:Equatable {
        var increaseContrast=false,reduceTransparency=false
        var opaqueSurfaces:Bool { increaseContrast || reduceTransparency }
    }
    static let shared=ToolsDisplayEnvironment()
    private(set) var options:Options
    private var override:Options?,notification:NSObjectProtocol?
    private var observers:[UUID:()->Void]=[:]
    private init() {
        options=Self.systemOptions()
        notification=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    isolated deinit { if let notification { NSWorkspace.shared.notificationCenter.removeObserver(notification) } }
    private static func systemOptions()->Options {
        .init(increaseContrast:NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
              reduceTransparency:NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
    func observe(_ action:@escaping ()->Void)->UUID { let id=UUID(); observers[id]=action; return id }
    func removeObserver(_ id:UUID) { observers[id]=nil }
    func setOverride(_ value:Options?) { override=value; NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil) }
    private func refresh() {
        let next=override ?? Self.systemOptions(); guard next != options else { return }; options=next
        for observer in Array(observers.values) { observer() }
    }
    static let canvas=NSColor(srgbRed:0.105,green:0.112,blue:0.108,alpha:1)
    static func surface(_ color:NSColor,opacity:CGFloat)->NSColor {
        guard shared.options.opaqueSurfaces else { return color.withAlphaComponent(opacity) }
        let c=color.usingColorSpace(.sRGB) ?? .white,a=min(1,max(0,opacity))
        return NSColor(srgbRed:c.redComponent*a+0.105*(1-a),green:c.greenComponent*a+0.112*(1-a),blue:c.blueComponent*a+0.108*(1-a),alpha:1)
    }
}
