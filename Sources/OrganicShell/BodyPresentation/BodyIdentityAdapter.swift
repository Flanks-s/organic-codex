import AppKit

/// Persistent body IDs are independent of the frozen thirteen-symbol drawing enum.
enum BodyIdentityAdapter {
    static let choices = ConversationBodyIdentity.choices
    static let allocationBase = ConversationBodyIdentity.allocationBase
    @MainActor static func identity(index: Int, symbol: String?, tint: String?) -> OrbIdentity {
        let key = ConversationIdentity.resolved(index: index, symbol: symbol, tint: tint)
        var result = OrbIdentity.assigned(index < allocationBase ? index : 0)
        result.bodyID = key.symbol
        result.tintID = key.tint
        if let old = OrbCelestialBody.allCases.first(where: { String(describing: $0) == key.symbol }) { result.symbol = old }
        if let color = OrbTint.allCases.first(where: { String(describing: $0) == key.tint }) { result.tint = color }
        return result
    }
}

extension OrbIdentity {
    var resolvedBodyID: String { bodyID ?? String(describing: symbol) }
    @MainActor var bodyTintColor: NSColor {
        guard let id=tintID,id.hasPrefix("body."),let catalogue=BodyResources.shared.catalogue,
              let value=BodyTintCatalogue.resolve(id,catalogue:catalogue),let hex=UInt32(value.hex.dropFirst(),radix:16) else { return tint.color }
        return NSColor(srgbRed:CGFloat(hex >> 16 & 255)/255,green:CGFloat(hex >> 8 & 255)/255,blue:CGFloat(hex & 255)/255,alpha:1)
    }
}

/// Reusable input for M11.40; this milestone does not create a color-bead interface.
@MainActor struct BodyIdentityOption {
    let body: BodyDefinition
    var id: String { body.id }
    var defaultTint: BodyTintCatalogue.Tint { BodyTintCatalogue.defaultTint(body) }
    var image: NSImage? { BodyResources.shared.menuImage(id) }
    static var choices: [Self] { BodyResources.shared.catalogue?.bodies.filter { BodyIdentityAdapter.choices.contains($0.id) }.map { Self(body:$0) } ?? [] }
}
