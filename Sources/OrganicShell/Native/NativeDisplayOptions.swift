import AppKit

/// Shared only inside Shell v2. Workspace changes redraw retained views; no window or scene is owned here.
@MainActor final class NativeDisplayOptions {
    struct State:Equatable {var increaseContrast:Bool,reduceTransparency:Bool;var reducesEffects:Bool{increaseContrast || reduceTransparency}}
    static let shared=NativeDisplayOptions()
    private(set) var state:State
    private(set) var revision=0
    private var token:NSObjectProtocol?
    private var observers:[UUID:()->Void]=[:]
    private var verificationState:State?
    private init(){state=Self.systemState();token=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.refresh()}}}
    isolated deinit{if let token{NSWorkspace.shared.notificationCenter.removeObserver(token)}}
    private static func systemState()->State{.init(increaseContrast:NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,reduceTransparency:NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)}
    func refresh(){let next=verificationState ?? Self.systemState();guard state != next else{return};state=next;revision+=1;for callback in Array(observers.values){callback()}}
    @discardableResult func observe(_ callback:@escaping()->Void)->UUID{let id=UUID();observers[id]=callback;return id}
    func removeObserver(_ id:UUID){observers[id]=nil}
    /// Offscreen tests only: a notification still drives refresh, exactly as the system does.
    func setVerificationState(_ value:State?){verificationState=value;NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)}
    static var appearance:NSAppearance?{NSAppearance(named:shared.state.increaseContrast ? .accessibilityHighContrastDarkAqua:.darkAqua)}
    static func plate(_ tint:NSColor=NSColor.white,alpha:CGFloat,background:NSColor? = nil)->NSColor {
        guard shared.state.reducesEffects else{return tint.withAlphaComponent(alpha)}
        let base=((background ?? NativePalette.canvas).usingColorSpace(.sRGB) ?? NSColor(white:0.1,alpha:1)).withAlphaComponent(1)
        return (base.blended(withFraction:min(1,max(0,alpha)),of:tint.usingColorSpace(.sRGB) ?? .white) ?? base).withAlphaComponent(1)
    }
}
