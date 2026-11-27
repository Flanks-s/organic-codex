import Foundation

/// Legacy storage IDs/raw values remain stable. New choices use explicit names and RGB values, not enum indexes.
enum BodyTintCatalogue {
    struct Tint: Equatable, Sendable {
        let id,name,hex:String
        let legacyRawValue:Int?
    }
    static let legacy:[Tint] = zip(
        ["silver","peach","ocean","rust","sand","gold","cyan","indigo","rose","slate","lilac","mint","clay"],
        ["#bdb7b0","#f0b98a","#5db4f0","#f2734d","#e2a86e","#e8c45a","#6ed7dd","#8a97ff","#e89daa","#a7b4c2","#c3a6f2","#7fd9a8","#db8c6b"]
    ).enumerated().map { index,pair in
        let names=["Silver","Peach","Sky Blue","Coral","Caramel","Gold","Turquoise","Indigo","Rose","Slate","Lavender","Mint","Clay"]
        return Tint(id:pair.0,name:names[index],hex:pair.1,legacyRawValue:index)
    }
    static func defaultTint(_ body:BodyDefinition)->Tint {
        if let old=legacy.first(where:{$0.hex==body.colorHex}) {return Tint(id:old.id,name:body.tone,hex:old.hex,legacyRawValue:old.legacyRawValue)}
        return Tint(id:"body.\(body.id)",name:body.tone,hex:body.colorHex,legacyRawValue:nil)
    }
    static func choices(_ catalogue:BodyCatalogue)->[Tint] {
        catalogue.conversationChoices.compactMap {id in catalogue.bodies.first{$0.id==id}.map(defaultTint)}
    }
    static func resolve(_ id:String,catalogue:BodyCatalogue)->Tint? {
        legacy.first{$0.id==id} ?? choices(catalogue).first{$0.id==id}
    }
}
