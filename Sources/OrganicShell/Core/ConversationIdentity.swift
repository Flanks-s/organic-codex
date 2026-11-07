import Foundation

/// Pure identity key used by allocation/persistence. Names and the stride mirror Model/Identity.swift.
/// No drawing or AppKit dependency; Island verifies these keys against OrbIdentity's rendering values.
enum ConversationIdentity {
    static let symbols=["mercury","venus","earth","mars","jupiter","saturn","uranus","neptune","pluto","ceres","eris","haumea","makemake"]
    static let tints=["silver","peach","ocean","rust","sand","gold","cyan","indigo","rose","slate","lilac","mint","clay"]
    static let combinationCount=13*13
    struct Key:Hashable { let symbol:String,tint:String }
    static func assigned(_ index:Int)->Key {
        let n=max(0,index),body=n%13,round=n/13
        return .init(symbol:symbols[body],tint:tints[round == 0 ? body:(body+(round%13)*5)%13])
    }
    static func resolved(index:Int,symbol:String?,tint:String?)->Key {
        let base=assigned(index)
        return .init(symbol:symbol.flatMap { symbols.contains($0) ? $0:nil } ?? base.symbol,
                     tint:tint.flatMap { tints.contains($0) ? $0:nil } ?? base.tint)
    }
}
