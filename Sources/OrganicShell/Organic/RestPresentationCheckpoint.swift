import AppKit
import QuartzCore

/// Some presence-track builders author their model endpoints as well as CA curves. Idle preparation must
/// restore those model values before returning, so parked/exiting columns keep their exact resting pixels.
@MainActor struct M11RestPresentation {
    private struct State {
        let layer:CALayer,position:CGPoint,bounds:CGRect,transform:CATransform3D,opacity:Float,hidden:Bool
        let color:CGColor?,radius:CGFloat,colors:[Any]?,locations:[NSNumber]?
        init(_ layer:CALayer) {
            self.layer=layer;position=layer.position;bounds=layer.bounds;transform=layer.transform
            opacity=layer.opacity;hidden=layer.isHidden;color=layer.backgroundColor;radius=layer.cornerRadius
            colors=(layer as? CAGradientLayer)?.colors;locations=(layer as? CAGradientLayer)?.locations
        }
        func restore() {
            layer.position=position;layer.bounds=bounds;layer.transform=transform;layer.opacity=opacity
            layer.isHidden=hidden;layer.backgroundColor=color;layer.cornerRadius=radius
            if let gradient=layer as? CAGradientLayer {gradient.colors=colors;gradient.locations=locations}
        }
    }
    private var layers:[State]=[]
    private var mappings:[(ColumnNode,ColumnNode.PresenceMapping,M10ColumnPlan)]=[]
    init(_ columns:[ColumnNode]) {
        func visit(_ layer:CALayer) {layers.append(State(layer));for child in layer.sublayers ?? [] {visit(child)};if let mask=layer.mask {visit(mask)}}
        for column in columns {
            mappings.append((column,column.presenceMapping,column.preparedMotion));visit(column.card);visit(column.separator)
        }
    }
    func restore() {
        CATransaction.begin();CATransaction.setDisableActions(true)
        for state in layers {state.restore()}
        for (column,mapping,motion) in mappings {column.presenceMapping=mapping;column.preparedMotion=motion}
        CATransaction.commit()
    }
}
