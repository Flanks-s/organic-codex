import Foundation

/// Independent port of Normie/ApprovalCard decision labels. The wire value is never rewritten.
enum NativeApprovalDecisions {
    static func title(_ value:JSONValue)->String {
        switch value.stringValue{case "accept":return "Allow once";case "acceptForSession":return "Allow for this session";case "decline":return "Decline";case "cancel":return "Cancel turn";default:break}
        if value["acceptWithExecpolicyAmendment"] != nil{return "Always allow matching commands"}
        if let rule=value["applyNetworkPolicyAmendment"]?["network_policy_amendment"] {if rule["action"]?.stringValue == "allow"{return "Always allow this host"};if rule["action"]?.stringValue == "deny"{return "Always deny this host"}}
        return "Review response…"
    }
    static func known(_ value:JSONValue)->Bool{title(value) != "Review response…"}
    static func scope(_ value:JSONValue)->String? {
        if value.stringValue == "acceptForSession"{return "Session approval applies to future matching prompts in this session."}
        if let rule=value["acceptWithExecpolicyAmendment"]?["execpolicy_amendment"]?.arrayValue{return "Persistent command rule: "+rule.compactMap(\.stringValue).joined(separator:" ")}
        if let host=value["applyNetworkPolicyAmendment"]?["network_policy_amendment"]?["host"]?.stringValue{return "Persistent network rule for: "+host}
        return nil
    }
    static func exact(_ value:JSONValue)->String{let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];return (try? encoder.encode(value)).map{String(decoding:$0,as:UTF8.self)} ?? "null"}
}
