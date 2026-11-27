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
        let base=index >= ConversationBodyIdentity.allocationBase ? ConversationBodyIdentity.allocated(index) : assigned(index)
        return .init(symbol:symbol.flatMap { (symbols + ConversationBodyIdentity.choices).contains($0) ? $0:nil } ?? base.symbol,
                     tint:tint.flatMap { tints.contains($0) || ConversationBodyIdentity.choices.contains(String($0.dropFirst(5))) && $0.hasPrefix("body.") ? $0:nil } ?? base.tint)
    }
}
