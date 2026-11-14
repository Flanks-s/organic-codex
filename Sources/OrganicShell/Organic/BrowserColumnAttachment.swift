import AppKit

/// A presentation lease; the original transcript, composer, conversation and notification models stay owned.
@MainActor final class BrowserColumnAttachment {
    private weak var column: ColumnNode?
    private let cardHidden: Bool
    private let nativeHidden: Bool
    private let nativeAXHidden: Bool
    private let offset: CGPoint
    private let following: Bool
    private(set) var covers = false
    init(column: ColumnNode) {
        self.column = column
        cardHidden = column.card.isHidden
        nativeHidden = column.native.isHidden
        nativeAXHidden = column.native.isAccessibilityHidden()
        offset = column.native.scrollOffset
        following = column.native.followsEnd
    }
    func cover() {
        guard !covers, let column else { return }
        covers = true
        column.card.isHidden = true
        column.setNative(visible: false)
        column.native.setAccessibilityHidden(true)
        column.island?.setBrowserPresentationSuspended(true)
        column.island?.isHidden = true
    }
    func restore() {
        guard let column else { return }
        covers = false
        column.card.isHidden = cardHidden
        column.island?.setBrowserPresentationSuspended(false)
        column.native.followsEnd = following
        column.native.scrollOffset = offset
        column.native.setAccessibilityHidden(nativeAXHidden)
        column.setNative(visible: !nativeHidden)
    }
}
