#if CORE_SELFTEST || TOOLS_SELFTEST || SETTINGS_SELFTEST
import Foundation

/// Recorded protocol shapes, in-process only. No URLSession, file reads, backend process or sockets.
final class CoreControllerFixtureTransport:CoreTransport,@unchecked Sendable {
    let respond:@Sendable (String,String,JSONValue?) async throws -> JSONValue
    init(_ respond:@escaping @Sendable (String,String,JSONValue?) async throws -> JSONValue) { self.respond=respond }
    func request(_ method:String,path:String,body:JSONValue?,timeout:TimeInterval?) async throws -> JSONValue { try await respond(method,path,body) }
    func events(since:Int,threadID:String?)->AsyncThrowingStream<CoreEvent,Error> { AsyncThrowingStream { $0.finish() } }
}
@MainActor final class CoreControllerFixture {
    struct Request { let method:String,path:String,body:JSONValue?; var key:String { body?["method"]?.stringValue ?? path }; var params:JSONValue { body?["params"] ?? [:] } }
    var requests:[Request]=[],failures:[String:Error]=[:]
    var before:((Request) async throws -> JSONValue?)?
    var artifacts:[JSONValue]=[["id":"text","name":"Notes.md","mimeType":"text/markdown","bytes":28,"sha256":"text-sha","threadId":"t1","createdAt":1],["id":"image","name":"Image.png","mimeType":"image/png","bytes":68,"sha256":"image-sha","threadId":"t2","createdAt":2]]
    var png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+k9O0AAAAASUVORK5CYII=")!
    var content:[String:Data]=["text":Data("# Notes\n\nRecorded artifact.\n".utf8)]
    var annotations:[JSONValue]=[],tabs:[JSONValue]=[["tabId":"tab&1","title":"Recorded page","url":"https://example.com"]]
    var terminalDescriptors:[JSONValue]=[],chunks:[String:[JSONValue]]=[:],terminalRunning:[String:Bool]=[:]
    var truncated=false,configVersion="v1",repeatModelCursor=false
    var captures:[String:JSONValue]=[:]
    var transport:any CoreTransport { CoreControllerFixtureTransport { [self] in try await respond(.init(method:$0,path:$1,body:$2)) } }
    func count(_ key:String)->Int { requests.filter { $0.key == key }.count }
    func respond(_ request:Request) async throws -> JSONValue {
        requests.append(request); if let v=try await before?(request) { return v }; if let failure=failures[request.key] { throw failure }
        let p=request.params,b=request.body ?? [:],parts=URLComponents(string:request.path),route=parts?.path ?? request.path
        let query=Dictionary(uniqueKeysWithValues:(parts?.queryItems ?? []).map { ($0.name,$0.value ?? "") })
        switch request.key {
        case "/capabilities": return ["version":"recorded-core-v8","features":["terminal":["available":true],"captureWindow":["available":true],"scheduler":["available":false,"version":"recorded-v1","reason":"not deployed"],"voice":[:]]]
        case "/health": return ["name":"Organic Codex Core","backendConnected":true,"lastEventId":0,"instanceId":"fake-instance","pid":999,"dataDir":"/fixture","authorizationCount":0]
        case "account/read": return ["account":["email":"fixture@example.invalid","planType":"recorded"]]
        case "account/rateLimits/read": return ["rateLimits":[:]]
        case "account/login/start": return ["loginId":"login-1","authUrl":"https://auth.example.invalid/recorded"]
        case "account/login/cancel","account/logout","mcpServer/oauth/login/completed": return [:]
        case "mcpServer/oauth/login": return ["authorizationUrl":"https://auth.example.invalid/mcp"]
        case "config/read": return ["config":["model":"recorded-model"],"layers":[["name":["type":"user","file":"/fixture/config.toml"],"version":.string(configVersion)]]]
        case "config/batchWrite":
            guard p["expectedVersion"] == .string(configVersion) else { throw CoreError(code:409,message:"version conflict",data:nil,httpStatus:409) }; configVersion="v2"; return [:]
        case "model/list":
            if p["cursor"] == "models-2" { return repeatModelCursor ? ["data":[],"nextCursor":"models-2"]:["data":[["id":"model2"]]] }
            return ["data":[["id":"model1"]],"nextCursor":"models-2"]
        case "mcpServerStatus/list": return p["cursor"] == "mcp-2" ? ["data":[["name":"second"]]]:["data":[["name":"first"]],"nextCursor":"mcp-2"]
        case "plugin/install","plugin/uninstall","skills/config/write","config/mcpServer/reload": return [:]
        case "thread/list": return ["data":[["id":"t1","name":"First"]]]
        case "thread/archive","thread/unarchive": return [:]
        default: break
        }
        switch route {
        case "/app-server/plugins/list": return ["marketplaces":[]]
        case "/app-server/skills/list": return ["data":[]]
        case "/scheduler/jobs","/scheduler/runs","/notifications","/authorizations": return ["data":[]]
        case "/scheduler/pause","/notifications/ack": return [:]
        case "/capture/hotkey": return request.method == "POST" ? b:["enabled":false,"mode":"window"]
        case "/preview/artifacts":
            if request.method == "GET" { return .array(artifacts) }
            let id="registered-"+String(count("/preview/artifacts")); let value:JSONValue=["id":.string(id),"path":b["path"] ?? "","name":b["name"] ?? "Registered image","mimeType":b["mimeType"] ?? "image/png","threadId":b["threadId"] ?? .null,"bytes":68,"sha256":.string(id)]
            artifacts.append(value); content[id]=png; return value
        case "/preview/content":
            let id=query["id"] ?? "",bytes=content[id] ?? (id == "image" ? png:Data())
            return ["id":.string(id),"dataBase64":.string(bytes.base64EncodedString())]
        case "/preview/annotations":
            if request.method == "GET" { return .array(annotations.filter { $0["artifactId"]?.stringValue == query["artifactId"] }) }
            var value=b.objectValue ?? [:]; value["id"] = .string("note-"+String(annotations.count+1)); annotations.append(.object(value)); return .object(value)
        case "/preview/annotations/delete": annotations.removeAll { $0["id"] == b["id"] }; return [:]
        case "/attachments":
            let id="upload-"+String(count("/attachments")),mime=b["mimeType"]?.stringValue ?? "text/plain",raw=b["dataBase64"]?.stringValue ?? ""
            let value:JSONValue=["id":.string(id),"name":b["name"] ?? "Upload","mimeType":.string(mime),"sha256":.string(id),"bytes":.number(Double(Data(base64Encoded:raw)?.count ?? 0)),"input":mime.hasPrefix("image/") ? ["type":"image","url":.string("data:"+mime+";base64,"+raw)]:["type":"text","text":"Uploaded file"]]
            artifacts.append(value); content[id]=Data(base64Encoded:raw); return value
        case "/browser/tabs": return ["tabs":.array(tabs)]
        case "/browser/open": let tab:JSONValue=["tabId":"new-tab","title":"Recorded new page","url":b["url"] ?? ""]; tabs.append(tab); return tab
        case "/browser/close": tabs.removeAll { $0["tabId"] == b["tabId"] }; return [:]
        case "/browser/snapshot": return ["dom":"Recorded DOM\nbutton: Continue"]
        case "/browser/screenshot": return ["data":.string(png.base64EncodedString()),"mimeType":"image/png","metadata":["tabId":b["tabId"] ?? "","url":"https://example.com","title":"Recorded page"]]
        case "/capture":
            let requestID=b["clientRequestId"]?.stringValue ?? ""
            let value:JSONValue=["id":.string("capture-"+requestID),"success":true,"clientRequestId":.string(requestID),"threadId":b["threadId"] ?? "","source":["app":"Fixture"],"contentItems":[["type":"inputImage","imageUrl":.string("data:image/png;base64,"+png.base64EncodedString())]],"text":["content":"Recorded accessibility text"]]
            captures[requestID]=value; return value
        case "/capture/result": return captures[query["clientRequestId"] ?? ""] ?? captures.values.first(where: { $0["id"]?.stringValue == query["id"] }) ?? ["pending":true]
        case "/terminal/sessions": return .array(terminalDescriptors)
        case "/terminal/open":
            let id="pty-"+String(count("/terminal/open")),value:JSONValue=["id":.string(id),"threadId":b["threadId"] ?? .null,"conversationId":b["conversationId"] ?? .null,"cwd":b["cwd"] ?? "","running":true]
            terminalDescriptors.append(value); terminalRunning[id]=true; chunks[id]=[]; return value
        case "/terminal/output":
            let id=query["id"] ?? "",all=chunks[id] ?? [],since=Int(query["since"] ?? "0") ?? 0
            return ["id":.string(id),"chunks":.array(all.filter { ($0["sequence"]?.intValue ?? 0)>since }),"lastSequence":.number(Double(all.last?["sequence"]?.intValue ?? 0)),"running":.bool(terminalRunning[id] ?? false),"truncated":.bool(truncated)]
        case "/terminal/write": return ["written":.number(Double(b["data"]?.stringValue?.utf8.count ?? 0))]
        case "/terminal/resize": return b
        case "/terminal/close": if let id=b["id"]?.stringValue { terminalRunning[id]=false }; return ["running":false]
        default:
            if route.hasPrefix("/authorizations/"),request.method == "DELETE" { return [:] }
            throw CoreWire.failure("Unexpected in-memory controller fixture route: "+request.key)
        }
    }
}
#endif
