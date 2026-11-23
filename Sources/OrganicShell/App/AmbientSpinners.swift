import AppKit

@MainActor protocol AmbientSpinner {
    func refreshAmbientSpinner()
}
@MainActor extension NSWindow {
    private static let spinnerStates = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
    var spinnerAmbientRunning: Bool? { Self.spinnerStates.object(forKey: self)?.boolValue }
    func setSpinnerAmbient(_ running: Bool) {
        guard running != spinnerAmbientRunning else { return }
        Self.spinnerStates.setObject(NSNumber(value: running), forKey: self)
        contentView?.refreshAmbientSpinners()
    }
}

@MainActor extension NSView {
    var canAnimateSpinner: Bool {
        guard let window else { return false }
        return window.spinnerAmbientRunning.map { $0 && !visibleRect.isEmpty } ?? true
    }

    func refreshAmbientSpinners() {
        (self as? any AmbientSpinner)?.refreshAmbientSpinner()
        for child in subviews { child.refreshAmbientSpinners() }
    }
}
