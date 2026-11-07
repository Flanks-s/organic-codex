import AppKit
import Darwin
import ObjectiveC

// Independent AppKit port of NativeColumnCarrier AX forwarding; no product module dependency.
/// AppKit's legacy AX entry points are nonisolated, but dispatch synchronously on the UI thread.
/// This private box exists only across the synchronous, runtime-checked assumeIsolated call;
/// it is never queued or transferred to another thread, and the proxy itself remains actor isolated.
private struct NativeInteractionAXValue: @unchecked Sendable { let value: Any? }
private struct NativeInteractionAXTransfer<Value>: @unchecked Sendable { let value: Value }
nonisolated func nativeInteractionAXResult(_ query: @MainActor () -> Any?) -> Any? {
    MainActor.assumeIsolated { NativeInteractionAXValue(value: query()) }.value
}

/// SwiftUI virtual nodes expose public ObjC AX selectors without declaring the complete
/// NSAccessibilityProtocol. Native macOS26 table rows may expose only informal AX instead.
/// Query object-returning collection selectors as raw arrays: SDK27's typed row/navigation
/// collections cannot safely bridge every actual NSTableRow to a modern protocol.
@MainActor private func nativeInteractionAXObjects(_ source: NSObject, _ method: String,
                                             legacy attribute: NSAccessibility.Attribute) -> [Any]? {
    let selector = NSSelectorFromString(method)
    if source.responds(to: selector), let values = source.perform(selector)?.takeUnretainedValue() as? [Any] {
        return values // An empty modern array is an intentional gate, not a request for legacy fallback.
    }
    return source.accessibilityAttributeValue(attribute) as? [Any]
}
@MainActor private func nativeInteractionAXAttribute(_ source: NSObject, _ attribute: NSAccessibility.Attribute) -> Any? {
    let object = source as AnyObject
    let modern: Any?
    switch attribute {
    case .role: modern = object.accessibilityRole?()?.rawValue
    case .subrole: modern = object.accessibilitySubrole?()?.rawValue
    case .roleDescription: modern = object.accessibilityRoleDescription?()
    case .identifier: modern = object.accessibilityIdentifier?()
    case .placeholderValue: modern = object.accessibilityPlaceholderValue?()
    case .valueDescription: modern = object.accessibilityValueDescription?()
    case .url: modern = object.accessibilityURL?()
    case .description: modern = object.accessibilityLabel?()
    case .title: modern = object.accessibilityTitle?()
    case .help: modern = object.accessibilityHelp?()
    case .value: modern = object.accessibilityValue?()
    case .enabled: modern = object.isAccessibilityEnabled?()
    case .focused: modern = object.isAccessibilityFocused?()
    case .window: modern = object.accessibilityWindow?()
    case .topLevelUIElement: modern = object.accessibilityTopLevelUIElement?()
    default: modern = nil
    }
    return modern ?? source.accessibilityAttributeValue(attribute)
}
@MainActor func nativeInteractionAXFrame(_ source: NSObject) -> CGRect? {
    guard (source as? NSView)?.isHiddenOrHasHiddenAncestor != true,
          (source as AnyObject).isAccessibilityHidden?() != true else { return nil }
    if let frame = (source as AnyObject).accessibilityFrame?() { return frame }
    guard source.responds(to: NSSelectorFromString("accessibilityAttributeValue:")),
          let position = source.accessibilityAttributeValue(.position) as? NSValue,
          let size = source.accessibilityAttributeValue(.size) as? NSValue else { return nil }
    return CGRect(origin: position.pointValue, size: size.sizeValue)
}

/// Forward native text/control capabilities while constraining public frames and hit tests to the card.
/// Own queried elements while visible; SwiftUI may vend temporary AX objects. Parent queries prune
/// removed children, and hiding/detaching/disposal disconnects the complete cached subtree.
// AppKit's nonisolated AX overrides synchronously check MainActor before state access.
// NSAccessibilityElement itself is non-Sendable; this bridge is never queued across threads.
@MainActor final class NativeInteractionProxy: NSAccessibilityElement, @MainActor NSAccessibilityElementProtocol {
    // This reference box crosses only this synchronous, checked call; it is never enqueued.
    private nonisolated func onAXMain<Value>(_ query: @MainActor (NativeInteractionProxy) -> Value) -> Value {
        let reference = NativeInteractionAXTransfer(value: self)
        return MainActor.assumeIsolated { NativeInteractionAXTransfer(value: query(reference.value)) }.value
    }
    private nonisolated func baseResponds(to selector: Selector) -> Bool { super.responds(to: selector) }
    private nonisolated func baseSelectorAllowed(_ selector: Selector) -> Bool { super.isAccessibilitySelectorAllowed(selector) }
    private(set) var source: NSObject?
    private let epoch:UInt64
    weak var owner: NativeInteractionSurface?
    weak var parent: AnyObject?
    init(source: NSObject, owner: NativeInteractionSurface, parent: AnyObject) {
        self.source = source; self.owner = owner; self.parent = parent;self.epoch=owner.presentationEpoch
        super.init()
    }
    // These are the optional mutations implemented by this proxy, not a new getter map.
    // NSView and NSAccessibilityElement inherit every action selector; presence alone
    // would invent capabilities which their public action inventories do not declare.
    private static let actionSelectors: [(Selector, NSAccessibility.Action)] = [
        (NSSelectorFromString("accessibilityPerformPress"), .press),
        (NSSelectorFromString("accessibilityPerformShowMenu"), .showMenu),
        (NSSelectorFromString("accessibilityPerformConfirm"), .confirm),
        (NSSelectorFromString("accessibilityPerformCancel"), .cancel),
        (NSSelectorFromString("accessibilityPerformIncrement"), .increment),
        (NSSelectorFromString("accessibilityPerformDecrement"), .decrement),
        (NSSelectorFromString("accessibilityPerformDelete"), .delete),
        (NSSelectorFromString("accessibilityPerformPick"), .pick),
        (NSSelectorFromString("accessibilityPerformRaise"), .raise),
        (NSSelectorFromString("accessibilityPerformShowAlternateUI"), .showAlternateUI),
        (NSSelectorFromString("accessibilityPerformShowDefaultUI"), .showDefaultUI)
    ]
    private static let setterSelectors: [(Selector, NSAccessibility.Attribute)] = [
        (NSSelectorFromString("setAccessibilityValue:"), .value),
        (NSSelectorFromString("setAccessibilityFocused:"), .focused),
        (NSSelectorFromString("setAccessibilitySelectedText:"), .selectedText),
        (NSSelectorFromString("setAccessibilitySelectedTextRange:"), .selectedTextRange),
        (NSSelectorFromString("setAccessibilitySelectedTextRanges:"), .selectedTextRanges),
        (NSSelectorFromString("setAccessibilitySelectedChildren:"), .selectedChildren),
        (NSSelectorFromString("setAccessibilitySelectedRows:"), .selectedRows),
        (NSSelectorFromString("setAccessibilitySelectedColumns:"), .selectedColumns)
    ]
    private func sourceActionNames() -> [NSAccessibility.Action] {
        guard let source, source.responds(to: NSSelectorFromString("accessibilityActionNames")) else { return [] }
        return source.accessibilityActionNames()
    }
    private func sourceSelectorPermission(_ selector: Selector, source: NSObject) -> Bool? {
        guard source.responds(to: selector),
              source.responds(to: NSSelectorFromString("isAccessibilitySelectorAllowed:")) else { return nil }
        return (source as AnyObject).isAccessibilitySelectorAllowed?(selector)
    }
    private func allowsSourceAction(_ action: NSAccessibility.Action) -> Bool {
        guard !accessibilityFrame().isEmpty, let source else { return false }
        let selector = Self.actionSelectors.first { $0.1 == action }?.0
        if let selector, sourceSelectorPermission(selector, source: source) == false { return false }
        if sourceActionNames().contains(action) { return true }
        // SwiftUI's partial modern buttons expose Press without a legacy action list.
        return action == .press && (source as AnyObject).accessibilityRole?() == .button &&
            source.responds(to: NSSelectorFromString("accessibilityPerformPress"))
    }
    private func allowsSourceWrite(_ attribute: NSAccessibility.Attribute) -> Bool {
        guard !accessibilityFrame().isEmpty, let source else { return false }
        let selector = Self.setterSelectors.first { $0.1 == attribute }?.0
        let modern = selector.map { source.responds(to: $0) } == true
        if let selector, let allowed = sourceSelectorPermission(selector, source: source) { return allowed }
        if source.responds(to: NSSelectorFromString("accessibilityIsAttributeSettable:")) {
            return source.accessibilityIsAttributeSettable(attribute) &&
                (modern || source.responds(to: NSSelectorFromString("accessibilitySetValue:forAttribute:")))
        }
        return modern // A partial modern NSObject may implement just its actual setter.
    }
    private func writeSourceValue(_ value: Any?, for attribute: NSAccessibility.Attribute) {
        guard allowsSourceWrite(attribute), let source else { return }
        if source.responds(to: NSSelectorFromString("accessibilitySetValue:forAttribute:")) {
            source.accessibilitySetValue(value, forAttribute: attribute)
            return
        }
        // Pure modern elements need no legacy NSObject AX methods.
        let object = source as AnyObject
        switch attribute {
        case .value: object.setAccessibilityValue?(value)
        case .focused: if let value = value as? Bool { object.setAccessibilityFocused?(value) }
        case .selectedText: object.setAccessibilitySelectedText?(value as? String)
        case .selectedTextRange:
            if let value = value as? NSValue { object.setAccessibilitySelectedTextRange?(value.rangeValue) }
        case .selectedTextRanges: object.setAccessibilitySelectedTextRanges?(value as? [NSValue])
        case .selectedChildren: object.setAccessibilitySelectedChildren?(value as? [Any])
        case .selectedRows: object.setAccessibilitySelectedRows?(value as? [Any])
        case .selectedColumns: object.setAccessibilitySelectedColumns?(value as? [Any])
        default: break
        }
    }
    private var sourceAncestorHidden: Bool {
        var element: NativeInteractionProxy? = self
        // Canonical proxy parents already follow the source tree. A retained virtual child
        // can outlive its host's visibility until the next prune, so gate that cached chain now.
        while let current = element {
            guard let source = current.source else { return true }
            if (source as? NSView)?.isHiddenOrHasHiddenAncestor == true ||
                (source as AnyObject).isAccessibilityHidden?() == true { return true }
            element = current.parent as? NativeInteractionProxy
        }
        return false
    }
    override func accessibilityFrame() -> NSRect {
        onAXMain { p in
            guard let owner=p.owner,owner.presentationEpoch == p.epoch,!p.sourceAncestorHidden,let source=p.source,owner.admits(source),let sourceFrame=owner.sourceFrame(source) else{return .zero}
            let clipped = sourceFrame.intersection(owner.screenClip)
            return clipped.isNull ? .zero : clipped
        }
    }
    override func accessibilityParent() -> Any? { onAXMain { p in p.parent } }
    override func accessibilityRole() -> NSAccessibility.Role? { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .role) as? String }.map(NSAccessibility.Role.init(rawValue:)) } }
    override func accessibilityLabel() -> String? { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .description) as? String } } }
    override func accessibilityTitle() -> String? { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .title) as? String } } }
    override func accessibilityHelp() -> String? { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .help) as? String } } }
    // NSAccessibilityElement supplies complete protocol defaults. Explicitly delegate the
    // native scalar/text capabilities those defaults would otherwise hide from the source.
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .subrole) as? String }.map(NSAccessibility.Subrole.init(rawValue:)) } }
    override func accessibilityRoleDescription() -> String? { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .roleDescription) as? String } } }
    override func accessibilityIdentifier() -> String { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .identifier) as? String } ?? "" } }
    override func accessibilityPlaceholderValue() -> String? { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .placeholderValue) as? String } } }
    override func accessibilityValueDescription() -> String? { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .valueDescription) as? String } } }
    override func accessibilityURL() -> URL? { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .url) as? URL } } }
    override func accessibilityValue() -> Any? { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .value) } } }
    override func setAccessibilityValue(_ value: Any?) {
        let input = NativeInteractionAXValue(value: value)
        onAXMain { p in p.writeSourceValue(input.value, for: .value) }
    }
    override func isAccessibilityEnabled() -> Bool { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .enabled) as? Bool } ?? false } }
    override func isAccessibilityFocused() -> Bool { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .focused) as? Bool } ?? false } }
    override func setAccessibilityFocused(_ focused: Bool) {
        onAXMain { p in p.writeSourceValue(focused, for: .focused) }
    }
    override func accessibilityWindow() -> Any? { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .window) } } }
    override func accessibilityTopLevelUIElement() -> Any? { onAXMain { p in p.source.flatMap { nativeInteractionAXAttribute($0, .topLevelUIElement) } } }
    override func accessibilityHorizontalScrollBar() -> Any? { onAXMain { p in p.clippedValue(p.source?.accessibilityAttributeValue(.horizontalScrollBar)) } }
    override func accessibilityVerticalScrollBar() -> Any? { onAXMain { p in p.clippedValue(p.source?.accessibilityAttributeValue(.verticalScrollBar)) } }
    override func isAccessibilitySelected() -> Bool { onAXMain { p in p.source?.accessibilityAttributeValue(.selected) as? Bool ?? false } }
    override func accessibilityRowIndexRange() -> NSRange { onAXMain { p in p.sourceRange(.rowIndexRange) } }
    override func accessibilityColumnIndexRange() -> NSRange { onAXMain { p in p.sourceRange(.columnIndexRange) } }
    override func accessibilitySelectedText() -> String? { onAXMain { p in p.source?.accessibilityAttributeValue(.selectedText) as? String } }
    override func setAccessibilitySelectedText(_ text: String?) {
        onAXMain { p in p.writeSourceValue(text, for: .selectedText) }
    }
    override func accessibilitySelectedTextRange() -> NSRange { onAXMain { p in p.sourceRange(.selectedTextRange) } }
    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        onAXMain { p in p.writeSourceValue(NSValue(range: range), for: .selectedTextRange) }
    }
    override func accessibilitySelectedTextRanges() -> [NSValue]? { onAXMain { p in p.source?.accessibilityAttributeValue(.selectedTextRanges) as? [NSValue] } }
    override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        let input = NativeInteractionAXValue(value: ranges)
        onAXMain { p in p.writeSourceValue(input.value, for: .selectedTextRanges) }
    }
    override func accessibilityVisibleCharacterRange() -> NSRange { onAXMain { p in p.sourceRange(.visibleCharacterRange) } }
    override func accessibilityNumberOfCharacters() -> Int { onAXMain { p in p.source?.accessibilityAttributeValue(.numberOfCharacters) as? Int ?? 0 } }
    override func accessibilityInsertionPointLineNumber() -> Int { onAXMain { p in p.source?.accessibilityAttributeValue(.insertionPointLineNumber) as? Int ?? 0 } }
    private func sourceRange(_ attribute: NSAccessibility.Attribute) -> NSRange {
        (source?.accessibilityAttributeValue(attribute) as? NSValue)?.rangeValue ?? NSRange(location: NSNotFound, length: 0)
    }
    private func sourceParameter(_ attribute: NSAccessibility.ParameterizedAttribute, _ parameter: Any) -> Any? {
        source?.accessibilityAttributeValue(attribute, forParameter: parameter)
    }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? { onAXMain { p in p.sourceParameter(.attributedStringForRange, NSValue(range: range)) as? NSAttributedString } }
    override func accessibilityString(for range: NSRange) -> String? { onAXMain { p in p.sourceParameter(.stringForRange, NSValue(range: range)) as? String } }
    override func accessibilityRange(forLine line: Int) -> NSRange { onAXMain { p in (p.sourceParameter(.rangeForLine, line) as? NSValue)?.rangeValue ?? NSRange(location: NSNotFound, length: 0) } }
    override func accessibilityRange(for point: NSPoint) -> NSRange { onAXMain { p in (p.sourceParameter(.rangeForPosition, NSValue(point: point)) as? NSValue)?.rangeValue ?? NSRange(location: NSNotFound, length: 0) } }
    override func accessibilityRange(for index: Int) -> NSRange { onAXMain { p in (p.sourceParameter(.rangeForIndex, index) as? NSValue)?.rangeValue ?? NSRange(location: NSNotFound, length: 0) } }
    override func accessibilityRTF(for range: NSRange) -> Data? { onAXMain { p in p.sourceParameter(.rtfForRange, NSValue(range: range)) as? Data } }
    override func accessibilityStyleRange(for index: Int) -> NSRange { onAXMain { p in (p.sourceParameter(.styleRangeForIndex, index) as? NSValue)?.rangeValue ?? NSRange(location: NSNotFound, length: 0) } }
    override func accessibilityLine(for index: Int) -> Int { onAXMain { p in p.sourceParameter(.lineForIndex, index) as? Int ?? NSNotFound } }
    override func isAccessibilityElement() -> Bool { onAXMain { p in !p.accessibilityFrame().isEmpty } }
    override func isAccessibilityHidden() -> Bool { onAXMain { p in p.accessibilityFrame().isEmpty } }
    override func accessibilityIsIgnored() -> Bool { onAXMain { p in p.accessibilityFrame().isEmpty } }
    override func accessibilityChildren() -> [Any]? {
        onAXMain { p in
            guard !p.accessibilityFrame().isEmpty, let source = p.source, let owner = p.owner else { return [] }
            let children = nativeInteractionAXObjects(source, "accessibilityChildren", legacy: .children) ?? []
            return owner.visibleProxies(children, parent: p, pruneChildren: true)
        }
    }
    private func related(_ values: [Any]?) -> [Any]? {
        guard !accessibilityFrame().isEmpty else { return [] }
        return owner?.visibleProxies(values ?? [], parent: self, adoptParent: false) ?? []
    }
    private func originals(_ values: [Any]?) -> [Any]? {
        values?.map { ($0 as? NativeInteractionProxy)?.source ?? $0 }
    }
    private func clippedValue(_ value: Any?) -> Any? {
        if let values = value as? [Any] { return values.compactMap(clippedValue) }
        if let element = value as? NSObject, owner?.sourceFrame(element) != nil {
            if element === source { return self }
            return owner?.proxy(element, parent: self, adoptParent: false)
        }
        return value
    }
    override func accessibilityVisibleChildren() -> [Any]? { onAXMain { p in p.related(p.source.flatMap { nativeInteractionAXObjects($0, "accessibilityVisibleChildren", legacy: .visibleChildren) }) } }
    override func accessibilitySelectedChildren() -> [Any]? { onAXMain { p in p.related(p.source.flatMap { nativeInteractionAXObjects($0, "accessibilitySelectedChildren", legacy: .selectedChildren) }) } }
    override func accessibilityChildrenInNavigationOrder() -> [any NSAccessibilityElementProtocol]? {
        onAXMain { p in
            // Only wrapped proxies enter this SDK-typed collection; raw native rows never do.
            p.related(p.source.flatMap { nativeInteractionAXObjects($0, "accessibilityChildrenInNavigationOrder", legacy: .childrenInNavigationOrderAttribute) })?
                .compactMap { $0 as? any NSAccessibilityElementProtocol }
        }
    }
    override func accessibilityContents() -> [Any]? { onAXMain { p in p.related(p.source.flatMap { nativeInteractionAXObjects($0, "accessibilityContents", legacy: .contents) }) } }
    override func accessibilityRows() -> [Any]? { onAXMain { p in p.related(p.source.flatMap{nativeInteractionAXObjects($0,"accessibilityRows",legacy:.rows)}) } }
    override func accessibilityVisibleRows() -> [Any]? { onAXMain { p in p.related(p.source.flatMap{nativeInteractionAXObjects($0,"accessibilityVisibleRows",legacy:.visibleRows)}) } }
    override func accessibilitySelectedRows() -> [Any]? { onAXMain { p in p.related(p.source.flatMap{nativeInteractionAXObjects($0,"accessibilitySelectedRows",legacy:.selectedRows)}) } }
    override func accessibilityColumns() -> [Any]? { onAXMain { p in p.related(p.source?.accessibilityAttributeValue(.columns) as? [Any]) } }
    override func accessibilityVisibleColumns() -> [Any]? { onAXMain { p in p.related(p.source?.accessibilityAttributeValue(.visibleColumns) as? [Any]) } }
    override func accessibilitySelectedColumns() -> [Any]? { onAXMain { p in p.related(p.source?.accessibilityAttributeValue(.selectedColumns) as? [Any]) } }
    override func accessibilitySelectedCells() -> [Any]? { onAXMain { p in p.related(p.source?.accessibilityAttributeValue(.selectedCells) as? [Any]) } }
    override func accessibilityVisibleCells() -> [Any]? { onAXMain { p in p.related(p.source?.accessibilityAttributeValue(.visibleCells) as? [Any]) } }
    override func accessibilityRowHeaderUIElements() -> [Any]? { onAXMain { p in p.related(p.source?.accessibilityAttributeValue(.rowHeaderUIElements) as? [Any]) } }
    override func accessibilityColumnHeaderUIElements() -> [Any]? { onAXMain { p in p.related(p.source?.accessibilityAttributeValue(.columnHeaderUIElements) as? [Any]) } }
    override func setAccessibilitySelectedChildren(_ children: [Any]?) {
        let input = NativeInteractionAXValue(value: children)
        onAXMain { p in p.writeSourceValue(p.originals(input.value as? [Any]), for: .selectedChildren) }
    }
    override func setAccessibilitySelectedRows(_ rows: [Any]?) {
        let input = NativeInteractionAXValue(value: rows)
        onAXMain { p in p.writeSourceValue(p.originals(input.value as? [Any]), for: .selectedRows) }
    }
    override func setAccessibilitySelectedColumns(_ columns: [Any]?) {
        let input = NativeInteractionAXValue(value: columns)
        onAXMain { p in p.writeSourceValue(p.originals(input.value as? [Any]), for: .selectedColumns) }
    }
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        onAXMain { p in
            guard !p.accessibilityFrame().isEmpty,let source=p.source,let owner=p.owner else{return .zero}
            let sourceFrame: CGRect
            if let element = source as? NSAccessibilityProtocol { sourceFrame = element.accessibilityFrame(for: range) }
            else if source.responds(to: NSSelectorFromString("accessibilityAttributeValue:forParameter:")),
                    let value = source.accessibilityAttributeValue(.boundsForRange, forParameter: NSValue(range: range)) as? NSValue {
                sourceFrame = value.rectValue
            } else { return .zero }
            let frame = sourceFrame.intersection(owner.screenClip)
            return frame.isNull ? .zero : frame
        }
    }
    func disconnect() {
        NSAccessibility.post(element: self, notification: .uiElementDestroyed)
        source = nil; owner = nil; parent = nil
    }
    override var accessibilityNotifiesWhenDestroyed: Bool { true }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        onAXMain { p in
            guard !p.accessibilityFrame().isEmpty, let source = p.source else { return [] }
            guard let actions = (source as AnyObject).accessibilityCustomActions?() else { return nil }
            guard !p.accessibilityFrame().isEmpty else { return [] }
            let names = actions.map(\.name)
            // SwiftUI vends fresh action objects on every query. A wrapper identifies a
            // current ordered slot, never an old handler or an opaque source-action ID.
            return names.indices.map { ordinal in
                NSAccessibilityCustomAction(name: names[ordinal], handler: { [weak p] in
                    guard let p else { return false }
                    return p.onAXMain { $0.performCurrentCustomAction(at: ordinal, names: names) }
                })
            }
        }
    }
    private func performCurrentCustomAction(at ordinal: Int, names: [String]) -> Bool {
        guard !accessibilityFrame().isEmpty, let source,
              let actions = (source as AnyObject).accessibilityCustomActions?(),
              actions.map(\.name) == names, actions.indices.contains(ordinal),
              !accessibilityFrame().isEmpty else { return false }
        // The getter can synchronously change source visibility or retire this proxy.
        // Recheck the same native gate before dispatch, then preserve the source BOOL.
        let action = actions[ordinal]
        guard !accessibilityFrame().isEmpty else{return false}
        if let handler = action.handler { return handler() }
        guard let target = action.target as? NSObject, let selector = action.selector,
              let method = class_getInstanceMethod(object_getClass(target), selector) else { return false }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard ["B", "c"].contains(String(cString: returnType)) else { return false }
        switch method_getNumberOfArguments(method) {
        case 2:
            typealias Call = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method_getImplementation(method), to: Call.self)(target, selector)
        case 3:
            guard let argumentType = method_copyArgumentType(method, 2) else { return false }
            defer { free(argumentType) }
            guard String(cString: argumentType).hasPrefix("@") else { return false }
            typealias Call = @convention(c) (AnyObject, Selector, NSAccessibilityCustomAction) -> Bool
            return unsafeBitCast(method_getImplementation(method), to: Call.self)(target, selector, action)
        default: return false
        }
    }
    // Preserve the source's public action result (including a deliberate false). Legacy-only
    // objects keep their original action-name/performAction contract. Every entry shares the
    // same clipping and canonical-ancestor gate as press.
    private func performSourceAction(_ action: NSAccessibility.Action) -> Bool {
        guard allowsSourceAction(action), let source else { return false }
        let modern: Bool?
        switch action {
        case .press: modern = (source as AnyObject).accessibilityPerformPress?()
        case .showMenu: modern = (source as AnyObject).accessibilityPerformShowMenu?()
        case .confirm: modern = (source as AnyObject).accessibilityPerformConfirm?()
        case .cancel: modern = (source as AnyObject).accessibilityPerformCancel?()
        case .increment: modern = (source as AnyObject).accessibilityPerformIncrement?()
        case .decrement: modern = (source as AnyObject).accessibilityPerformDecrement?()
        case .delete: modern = (source as AnyObject).accessibilityPerformDelete?()
        case .pick: modern = (source as AnyObject).accessibilityPerformPick?()
        case .raise: modern = (source as AnyObject).accessibilityPerformRaise?()
        case .showAlternateUI: modern = (source as AnyObject).accessibilityPerformShowAlternateUI?()
        case .showDefaultUI: modern = (source as AnyObject).accessibilityPerformShowDefaultUI?()
        default: modern = nil
        }
        if let modern { return modern }
        guard sourceActionNames().contains(action),
              source.responds(to: NSSelectorFromString("accessibilityPerformAction:")) else { return false }
        source.accessibilityPerformAction(action)
        return true
    }
    override func accessibilityPerformPress() -> Bool { onAXMain { p in p.performSourceAction(.press) } }
    override func accessibilityPerformShowMenu() -> Bool { onAXMain { p in p.performSourceAction(.showMenu) } }
    override func accessibilityPerformConfirm() -> Bool { onAXMain { p in p.performSourceAction(.confirm) } }
    override func accessibilityPerformCancel() -> Bool { onAXMain { p in p.performSourceAction(.cancel) } }
    override func accessibilityPerformIncrement() -> Bool { onAXMain { p in p.performSourceAction(.increment) } }
    override func accessibilityPerformDecrement() -> Bool { onAXMain { p in p.performSourceAction(.decrement) } }
    override func accessibilityPerformDelete() -> Bool { onAXMain { p in p.performSourceAction(.delete) } }
    override func accessibilityPerformPick() -> Bool { onAXMain { p in p.performSourceAction(.pick) } }
    override func accessibilityPerformRaise() -> Bool { onAXMain { p in p.performSourceAction(.raise) } }
    override func accessibilityPerformShowAlternateUI() -> Bool { onAXMain { p in p.performSourceAction(.showAlternateUI) } }
    override func accessibilityPerformShowDefaultUI() -> Bool { onAXMain { p in p.performSourceAction(.showDefaultUI) } }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        onAXMain { p in
            guard let owner = p.owner, owner.containsScreenPoint(point), p.accessibilityFrame().contains(point) else { return nil }
            for child in p.accessibilityChildren() ?? [] {
                if let hit = (child as? NativeInteractionProxy)?.accessibilityHitTest(point) { return hit }
            }
            return p
        }
    }
    override func responds(to selector: Selector!) -> Bool {
        onAXMain { p in
            if let action = Self.actionSelectors.first(where: { $0.0 == selector })?.1 { return p.allowsSourceAction(action) }
            if let attribute = Self.setterSelectors.first(where: { $0.0 == selector })?.1 { return p.allowsSourceWrite(attribute) }
            return p.baseResponds(to: selector) || p.source?.responds(to: selector) == true
        }
    }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        onAXMain { p in
            if let action = Self.actionSelectors.first(where: { $0.0 == selector })?.1 { return p.allowsSourceAction(action) }
            if let attribute = Self.setterSelectors.first(where: { $0.0 == selector })?.1 { return p.allowsSourceWrite(attribute) }
            return p.baseSelectorAllowed(selector)
        }
    }
    override func forwardingTarget(for selector: Selector!) -> Any? { onAXMain { p in p.source } }
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        onAXMain { p in
            // The proxy supplies these public attributes even when a partial modern SwiftUI
            // source does not advertise them through NSObject's legacy attribute list.
            var names = p.source?.accessibilityAttributeNames() ?? []
            for attribute: NSAccessibility.Attribute in [.role, .parent, .children, .visibleChildren,
                .childrenInNavigationOrderAttribute, .position, .size, .window, .topLevelUIElement,
                .description, .title, .help, .value, .enabled, .focused, .contents] where !names.contains(attribute) {
                names.append(attribute)
            }
            return names
        }
    }
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        onAXMain { p in
            switch attribute {
            case .parent: return p.parent
            case .children: return p.accessibilityChildren()
            case .visibleChildren: return p.accessibilityVisibleChildren()
            case .childrenInNavigationOrderAttribute: return p.accessibilityChildrenInNavigationOrder()
            case .contents: return p.accessibilityContents()
            case .position: return NSValue(point: p.accessibilityFrame().origin)
            case .size: return NSValue(size: p.accessibilityFrame().size)
            case .window, .topLevelUIElement: return p.source.flatMap { nativeInteractionAXAttribute($0, attribute) }
            default: return p.clippedValue(p.source.flatMap { nativeInteractionAXAttribute($0, attribute) })
            }
        }
    }
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        onAXMain { p in p.allowsSourceWrite(attribute) }
    }
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        let input = NativeInteractionAXValue(value: value)
        onAXMain { p in
            let unwrapped: Any? = (input.value as? [Any]).flatMap(p.originals) ?? (input.value as? NativeInteractionProxy)?.source ?? input.value
            p.writeSourceValue(unwrapped, for: attribute)
        }
    }
    override func accessibilityParameterizedAttributeNames() -> [NSAccessibility.ParameterizedAttribute] {
        onAXMain { p in p.source?.accessibilityParameterizedAttributeNames() ?? [] }
    }
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.ParameterizedAttribute, forParameter parameter: Any?) -> Any? {
        let input = NativeInteractionAXValue(value: parameter)
        return onAXMain { p in
            let value = p.source?.accessibilityAttributeValue(attribute, forParameter: input.value)
            if attribute == .boundsForRange,let rect=value as? NSValue,let owner=p.owner,!p.accessibilityFrame().isEmpty {
                let clipped = rect.rectValue.intersection(owner.screenClip)
                return NSValue(rect: clipped.isNull ? .zero : clipped)
            }
            return p.clippedValue(value)
        }
    }
    override var accessibilityFocusedUIElement: Any? {
        onAXMain { p in p.clippedValue(p.source?.accessibilityFocusedUIElement) }
    }
    override func accessibilityActionNames() -> [NSAccessibility.Action] {
        onAXMain { p in
            guard !p.accessibilityFrame().isEmpty, p.source != nil else { return [] }
            var names = p.sourceActionNames().filter { p.allowsSourceAction($0) }
            if !names.contains(.press), p.allowsSourceAction(.press) { names.append(.press) }
            return names
        }
    }
    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        onAXMain { p in
            guard p.allowsSourceAction(action) else { return }
            if action == .press { _ = p.accessibilityPerformPress() }
            else if p.sourceActionNames().contains(action),
                    let source = p.source, source.responds(to: NSSelectorFromString("accessibilityPerformAction:")) {
                source.accessibilityPerformAction(action)
            }
        }
    }
}
