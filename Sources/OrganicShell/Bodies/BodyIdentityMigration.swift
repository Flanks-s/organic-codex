import Foundation

/// Pure data only: no UserDefaults, ConversationStore, Core RPC, or window mutation.
enum BodyIdentityMigration {
    static let version = 1
    static let legacyBodies = ["mercury","venus","earth","mars","jupiter","saturn","uranus","neptune","pluto","ceres","eris","haumea","makemake"]
    static let legacyTints = ["silver","peach","ocean","rust","sand","gold","cyan","indigo","rose","slate","lilac","mint","clay"]
    struct Record: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var identityIndex: Int
        var symbol: String?
        var tint: String?
        var migrationVersion: Int = 0
        init(id:String,title:String,identityIndex:Int,symbol:String?,tint:String?,migrationVersion:Int=0) {
            self.id=id;self.title=title;self.identityIndex=identityIndex;self.symbol=symbol;self.tint=tint;self.migrationVersion=migrationVersion
        }
        private enum CodingKeys:String,CodingKey {case id,title,identityIndex,symbol,tint,migrationVersion}
        init(from decoder:any Decoder)throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            id=try c.decode(String.self,forKey:.id);title=try c.decode(String.self,forKey:.title);identityIndex=try c.decode(Int.self,forKey:.identityIndex)
            symbol=try c.decodeIfPresent(String.self,forKey:.symbol);tint=try c.decodeIfPresent(String.self,forKey:.tint)
            migrationVersion=try c.decodeIfPresent(Int.self,forKey:.migrationVersion) ?? 0
        }
    }
    static func legacy(_ index: Int) -> (symbol: String,tint: String) {
        let n = max(0,index), body = n % legacyBodies.count, round = n / legacyBodies.count
        return (legacyBodies[body],legacyTints[round == 0 ? body:(body+round*5)%legacyTints.count])
    }
    static func migrate(_ records: [Record], choices: [String]) -> [Record] {
        var result = records
        // Reserve explicit and resolved identities before allocating replacements, independent of record order.
        var occupied = Set(records.map { $0.symbol ?? legacy($0.identityIndex).symbol }.filter { choices.contains($0) })
        let preferred = (["neptune"] + choices.filter{$0 != "neptune"}).filter{choices.contains($0)}
        for i in result.indices where result[i].migrationVersion < version {
            let old = legacy(result[i].identityIndex)
            result[i].symbol = result[i].symbol ?? old.symbol
            result[i].tint = result[i].tint ?? old.tint
            if result[i].symbol == "earth", let replacement = preferred.first(where:{!occupied.contains($0)}) ?? preferred.first {
                result[i].symbol = replacement
                occupied.insert(replacement)
            }
            result[i].migrationVersion = version
        }
        return result
    }
    static func defaultColor(bodyID: String, catalogue: BodyCatalogue) -> (name: String,hex: String)? {
        guard let body = catalogue.bodies.first(where:{$0.id == bodyID}), body.role == nil else { return nil }
        return (body.tone,body.colorHex)
    }
}
