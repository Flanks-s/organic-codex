import Foundation

/// Stable string IDs; the legacy thirteen-by-thirteen allocator remains unchanged.
enum ConversationBodyIdentity {
    static let choices = ["mercury","venus","mars","jupiter","saturn","uranus","neptune","pluto","ceres","pallas","juno","vesta","astraea","hygiea","chiron","pholus","nessus","orcus","haumea","quaoar","makemake","gonggong","eris","sedna"]
    static let allocationBase = 1_000_000
    static func allocated(_ index: Int) -> ConversationIdentity.Key {
        let n=max(0,index-allocationBase),body=n%choices.count,round=n/choices.count
        let oldDefaults=["mercury":"silver","venus":"peach","mars":"rust","jupiter":"sand","saturn":"gold"]
        return .init(symbol:choices[body],tint:round == 0 ? oldDefaults[choices[body]] ?? "body.\(choices[body])" : ConversationIdentity.tints[(body+round*5)%13])
    }
}
