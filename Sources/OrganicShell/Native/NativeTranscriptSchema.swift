import Foundation

/// Compatibility entry for existing callers. Schema semantics belong to M7 Core, never to a second UI validator.
enum NativeTranscriptSchema {
    static func error(_ value:JSONValue,schema:JSONValue,path:String="$",depth:Int=0)->String? {
        CoreElicitationSchema.error(value,schema:schema,path:path,depth:depth)
    }
}
