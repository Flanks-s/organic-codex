import AppKit

enum FunctionPanelPictureQuality: String { case identity, preview, panelHD }
enum FunctionPanelPhaseLoading: String { case unloaded, loading, preview, budgetRefused, ready, failed }

/// Immutable rendering output. Its producer owns the resources, tasks and provenance.
struct FunctionPanelPicture {
    let image: CGImage
    let quality: FunctionPanelPictureQuality
    let bodyID: String
    let event: BodyPhaseEvent?
    let turnID: String?
    let nativeOuter: Int
    let scale: Int
}

struct FunctionPanelBodySnapshot {
    let entries: [String: FunctionPanelPicture]
    let planet: FunctionPanelPicture?
    let loading: String?
    let phaseLoading: FunctionPanelPhaseLoading
    static let empty = Self(
        entries: [:], planet: nil, loading: nil, phaseLoading: .unloaded
    )
    static func key(_ id: String, outer: Int) -> String { "\(id):\(outer)" }
}

/// Phase is an explicit fact, independent of Context. Turn provenance accompanies every image.
struct FunctionPanelPhaseInput: Equatable {
    let bodyID: String
    let event: BodyPhaseEvent
    let turnID: String
    let scale: Int
    let bin: Int
    let quality: FunctionPanelPictureQuality
    let animate: Bool
    init(bodyID: String, event: BodyPhaseEvent, turnID: String, scale: Int, bin: Int,
         quality: FunctionPanelPictureQuality, animate: Bool = false) {
        self.bodyID = bodyID; self.event = event; self.turnID = turnID; self.scale = scale
        self.bin = bin; self.quality = quality; self.animate = animate
    }
}

enum FunctionPanelTrackLayout {
    static let drawCollapsedDots = true
    static let headerHeight: CGFloat = 32
    static func parkedY(option: Int, index: Int) -> CGFloat {
        let positions: [[CGFloat]] = [[0, 235, 243, 251, 259], [14, 0, 208, 215, 222], [11, 19, 0, 210, 218]]
        return positions[option][index]
    }
}
