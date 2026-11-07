/// Optional App-owned observation boundary. Standalone Organic verifiers do not depend on Debug / OSLog.
@MainActor enum M10ColumnModeProbe {
    static var enabled:(()->Bool)?
    static var record:((StaticString,Bool,String)->Void)?
    static func measure<T>(_ phase:StaticString,detail:@autoclosure ()->String = "",_ body:()->T)->T {
        guard enabled?() == true,let record else{return body()}
        let message=detail();record(phase,true,message);defer{record(phase,false,message)}
        return body()
    }
}
