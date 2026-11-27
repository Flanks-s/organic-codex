import AppKit

/// One input arbiter per Dock window. It never installs a global event monitor.
@MainActor final class DockTideLifecycle {
    private weak var window:NSWindow?
    private var notifications:[NSObjectProtocol]=[]
    private var monitor:Any?
    var input:((NSEvent)->Bool)?
    var retire:(()->Void)?
    var deactivate:(()->Void)?
    var close:(()->Void)?
    func attach(_ next:NSWindow?) {
        guard window !== next else{return}
        detach();window=next
        guard let next else {retire?();return}
        for name in [NSWindow.didResignKeyNotification,NSWindow.willCloseNotification,NSWindow.didMiniaturizeNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName:name,object:next,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWindow.willCloseNotification {self?.close?()}
                    else if name == NSWindow.didResignKeyNotification {self?.deactivate?()}
                    else {self?.retire?()}
                }
            })
        }
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.mouseMoved]) { [weak self] event in
            guard let self,event.window === self.window else{return event}
            return self.input?(event) == true ? nil:event
        }
    }
    func detach() {
        for token in notifications {NotificationCenter.default.removeObserver(token)};notifications=[]
        if let monitor {NSEvent.removeMonitor(monitor)};monitor=nil;window=nil
    }
    isolated deinit {detach()}
}
