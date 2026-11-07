import Foundation

struct CoreArtifact: Identifiable, Equatable, Sendable {
    let raw: JSONValue
    init(raw: JSONValue) {
        var metadata = raw.objectValue ?? [:]
        metadata.removeValue(forKey: "input"); metadata.removeValue(forKey: "dataBase64")
        self.raw = .object(metadata)
    }
    var id: String { raw["id"]?.stringValue ?? "" }
    var name: String { raw["name"]?.stringValue ?? "Artifact" }
    var mime: String { raw["mimeType"]?.stringValue ?? "application/octet-stream" }
    var path: String { raw["path"]?.stringValue ?? "" }
    var threadID: String? { raw["threadId"]?.stringValue }
    var sha: String { raw["sha256"]?.stringValue ?? "" }
    var bytes: Int { raw["bytes"]?.intValue ?? 0 }
    var previewUnavailable: Bool { raw["previewUnavailable"]?.boolValue == true }
    var generatedItemID: String? { raw["generatedItemId"]?.stringValue }
    var generationStatus: String? { raw["generationStatus"]?.stringValue }
    static let unavailableMessage = "The image reference was received, but this connection has not provided a viewable file."
}

/// All tool windows share Core's artifact/annotation records and the Shell's drafts.
@MainActor final class CoreArtifactsController {
    static let shared = CoreArtifactsController()
    enum Section: String, CaseIterable { case artifacts = "Artifacts", browser = "Browser", capture = "Appshots" }
    var section: Section = .artifacts
    var conversationID: String = ""
    private(set) var artifacts: [CoreArtifact] = [] { didSet { notify() } }
    var selectedID: String = ""
    private(set) var selectedData: Data? { didSet { notify() } }
    private(set) var annotations: [JSONValue] = [] { didSet { notify() } }
    var comment = ""
    var quote = ""
    var page = 1
    var region: JSONValue?
    var annotationKind = "comment"
    var browserURL = "https://example.com"
    private(set) var tabs: [JSONValue] = [] { didSet { notify() } }
    var selectedTabID = ""
    private(set) var browserSnapshot = "" { didSet { notify() } }
    private(set) var browserImage: Data? { didSet { notify() } }
    var captureMode = "window"
    var captureApp = ""
    private(set) var captureSummary = "" { didSet { notify() } }
    private(set) var busy = false { didSet { notify() } }
    private(set) var localPathsAvailable = false
    var error: String? { didSet { notify() } }
    var notice: String? { didSet { notify() } }
    private var client: (any CoreTransport)?
    private weak var runtime: (any ConversationRuntime)?
    var onShow: ((Section, Conversation?) -> Void)?
    var onChange: (() -> Void)?
    private var observers:[UUID:()->Void]=[:]
    func observe(_ callback:@escaping ()->Void)->UUID { let id=UUID(); observers[id]=callback; return id }
    func removeObserver(_ id:UUID) { observers[id]=nil }
    private func notify() { onChange?(); for callback in Array(observers.values) { callback() } }
    var onOpenURL: ((URL) -> Void)?
    var onDeliver: ((CoreArtifactDelivery, @escaping @MainActor (CoreSubmissionResult) -> Void) -> Void)?
    private(set) var endpointIdentity = ""
    private var reconcilingCaptures = Set<String>()
    private var seen = Set<String>()
    private var seenOrder: [String] = []
    private var loadingID: UUID?
    private var loadingAnnotations=false
    private var annotationEvents:[CoreEvent]=[]
    private var generatedArtifacts: [String: CoreArtifact] = [:]
    private var registeringGenerated = Set<String>()
    private var attemptedGenerated = Set<String>()
    private var rejectedGeneratedPaths = Set<String>()
    var revealConversation: ((ConversationID) -> Void)?
    struct PendingCapture: Codable {
        let requestID: String
        let conversationID: String
        let threadID: String
        let endpoint: String
        let created: TimeInterval
        var captureID: String?
    }
    private var pendingCaptures: [String: PendingCapture] = [:]
    private var recoveringCaptures = Set<String>()
    private let storage: any CorePresentationStorage
    private static let pendingCaptureKey = "organic.capture.pending.v1"
    static let contentLimit = 32 * 1024 * 1024
    init(storage: any CorePresentationStorage = CoreDefaultsStorage()) { self.storage = storage }

    var conversations: [Conversation] { runtime?.store.conversations.filter { !$0.archived } ?? [] }
    var conversation: Conversation? { runtime?.store.conversation(conversationID) }
    var selected: CoreArtifact? { artifacts.first { $0.id == selectedID } }
    var selectedTab: JSONValue? { tabs.first { $0["tabId"]?.stringValue == selectedTabID } }

    func configure(client: any CoreTransport, runtime: any ConversationRuntime, endpoint: String) {
        guard self.client == nil || endpointIdentity == endpoint else { error = "Create a new Tools controller when changing Core endpoints."; return }
        self.client = client; self.runtime = runtime; endpointIdentity = endpoint
        do {
            if let data = try storage.read(key: Self.pendingCaptureKey + endpoint), let saved = try? JSONDecoder().decode([String: PendingCapture].self, from: data) {
                pendingCaptures = saved.filter { $0.value.endpoint == endpoint && Date().timeIntervalSince1970-$0.value.created < 86400 }
            }
        } catch { self.error = error.localizedDescription }
        if !pendingCaptures.isEmpty { recoverCaptures() }
    }
    var hasPendingCapture: Bool { !pendingCaptures.isEmpty }
    var captureDestinationID: String? { pendingCaptures.values.min(by: { $0.created < $1.created })?.conversationID }
    func showCaptureApprovals() { if let id = captureDestinationID { revealConversation?(id) } }
    @discardableResult private func savePendingCaptures() -> Bool {
        do { try storage.write(JSONEncoder().encode(pendingCaptures), key: Self.pendingCaptureKey + endpointIdentity); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func trackCapture(requestID: String, target: Conversation) throws {
        guard let threadID = target.backendThreadID else { throw CoreError(code: nil, message: "Choose a chat with an existing Core session before capturing.", data: nil, httpStatus: nil) }
        pendingCaptures[requestID] = PendingCapture(requestID: requestID, conversationID: target.id, threadID: threadID,
                                                   endpoint: endpointIdentity, created: Date().timeIntervalSince1970)
        guard savePendingCaptures() else { pendingCaptures[requestID]=nil; throw CoreWire.failure("The capture request could not be saved. No capture was started.") }
    }
    /// Set only after CoreService matches local dataDir, PID and runtime-instance nonce.
    func setLocalPathsAvailable(_ available: Bool) { localPathsAvailable = available }
    func showArtifacts(conversation: Conversation?) { show(.artifacts, conversation: conversation) }
    func showBrowser(conversation: Conversation?) { show(.browser, conversation: conversation) }
    func showCapture(conversation: Conversation?) { show(.capture, conversation: conversation) }
    private func show(_ section: Section, conversation: Conversation?) {
        self.section = section
        if let conversation { conversationID = conversation.id }
        onShow?(section, conversation)
        if section == .artifacts { refreshArtifacts() }
        if section == .browser { refreshTabs() }
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; notice = nil
        Task { defer { busy = false }; do { try await work() } catch { self.error = error.localizedDescription } }
    }
    private func requiredClient() throws -> any CoreTransport {
        guard let client else { throw CoreError(code: nil, message: "Connect to Core first.", data: nil, httpStatus: nil) }
        return client
    }
    private func path(_ route: String, query: [String: String]) -> String {
        var components = URLComponents(); components.path = route
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.string!
    }
    private func merge(_ raw: JSONValue, refreshSelection:Bool=true) {
        var metadata = raw.objectValue ?? [:]
        if let source = generatedArtifacts.values.first(where: { $0.id == raw["id"]?.stringValue }) {
            for key in ["generatedItemId", "fileId", "generationStatus", "previewUnavailable"] { metadata[key] = source.raw[key] }
        }
        let artifact = CoreArtifact(raw: .object(metadata)); guard !artifact.id.isEmpty else { return }
        let changedSelection=artifact.id == selectedID && selected?.sha != artifact.sha
        if let i = artifacts.firstIndex(where: { $0.id == artifact.id }) { artifacts[i] = artifact }
        else { artifacts.insert(artifact, at: 0) }
        if changedSelection && refreshSelection { select(artifact.id) }
    }
    func refreshArtifacts() {
        perform { [self] in
            let result = try await requiredClient().request(path: "/preview/artifacts")
            reconcileArtifactList(result.arrayValue ?? [])
        }
    }
    func select(_ id: String) {
        selectedID = id; selectedData = nil; annotations = []; region = nil; quote = ""; comment = ""; page=1
        let token = UUID(); loadingID = token; loadingAnnotations=false; annotationEvents=[]
        guard let artifact = selected, !artifact.previewUnavailable, let client else { return }
        loadingAnnotations=true
        Task {
            do {
                let notes = try await client.request(path: path("/preview/annotations", query: ["artifactId": id]))
                guard loadingID == token else { return }
                var reconciled=notes.arrayValue ?? []
                for event in annotationEvents {
                    if event.method == "preview/annotationDeleted" { reconciled.removeAll { $0["id"] == event.params["id"] } }
                    else if !reconciled.contains(where: { $0["id"] == event.params["id"] }) { reconciled.append(event.params) }
                }
                loadingAnnotations=false; annotationEvents=[]; annotations = reconciled
                guard artifact.bytes <= Self.contentLimit else {
                    error = "This artifact exceeds the 32 MiB preview limit. Open the original file to inspect it."; return
                }
                let content = try await client.request(path: path("/preview/content", query: ["id": id]))
                guard loadingID == token else { return }
                guard let encoded = content["dataBase64"]?.stringValue, encoded.utf8.count <= (Self.contentLimit+2)/3*4, let data = Data(base64Encoded: encoded) else { throw URLError(.cannotDecodeContentData) }
                guard data.count <= Self.contentLimit else { throw CoreWire.failure("Artifact exceeds the 32 MiB preview limit.") }
                guard selected?.sha == artifact.sha else { select(id); return }
                selectedData = data; error = nil
            } catch { if loadingID == token { loadingAnnotations=false; annotationEvents=[]; self.error = error.localizedDescription } }
        }
    }
    func addAnnotation() {
        guard let selected, !selected.previewUnavailable, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let artifactID = selected.id
        var body: [String: JSONValue] = ["artifactId": .string(artifactID), "kind": .string(annotationKind), "text": .string(comment)]
        if !quote.isEmpty { body["quote"] = .string(quote) }
        if selected.mime == "application/pdf" { body["page"] = .number(Double(max(1, page))) }
        if let region { body["geometry"] = region; body["kind"] = "region" }
        perform { [self] in
            let note = try await requiredClient().request("POST", path: "/preview/annotations", body: .object(body))
            if selectedID == artifactID {
                if !annotations.contains(where: { $0["id"] == note["id"] }) { annotations.append(note) }
                comment = ""; notice = "Annotation saved to Core."
            }
        }
    }
    func deleteAnnotation(_ note: JSONValue) {
        guard let id = note["id"]?.stringValue else { return }
        perform { [self] in
            _ = try await requiredClient().request("POST", path: "/preview/annotations/delete", body: ["id": .string(id)])
            annotations.removeAll { $0["id"]?.stringValue == id }
        }
    }
    static func envelope(artifact: CoreArtifact, annotations: [JSONValue], request: String) -> String {
        var actualRequest = request; var existing: [JSONValue] = []
        if request.hasPrefix("# Response annotations:"),
           let start = request.range(of: "<response-annotations>"), let end = request.range(of: "</response-annotations>"), start.upperBound <= end.lowerBound {
            existing = (try? JSONDecoder().decode([JSONValue].self, from: Data(request[start.upperBound..<end.lowerBound].utf8))) ?? []
            if let marker = request.range(of: "## My request:", range: end.upperBound..<request.endIndex) { actualRequest = String(request[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let fresh = annotations.map { note -> JSONValue in
            var organic: [String: JSONValue] = ["artifactId": .string(artifact.id), "sha256": .string(artifact.sha), "originThreadId": artifact.threadID.map(JSONValue.string) ?? .null,
                                                "sourcePath": artifact.raw["sourcePath"] ?? .string(artifact.path), "kind": note["kind"] ?? "comment"]
            organic["geometry"] = note["geometry"]; organic["page"] = note["page"]
            return ["id": note["id"] ?? .string(artifact.id), "text": note["quote"] ?? .string(artifact.name), "annotation": note["text"] ?? "", "organic": .object(organic)]
        }
        let freshIDs = Set(fresh.compactMap { $0["id"]?.stringValue })
        existing.removeAll { freshIDs.contains($0["id"]?.stringValue ?? "") }; existing.append(contentsOf: fresh)
        guard !existing.isEmpty else { return actualRequest }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(existing)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return "# Response annotations:\n<response-annotations>\n" + encoded + "\n</response-annotations>\n\n## My request:\n" + actualRequest
    }
    func attachSelected(send: Bool = false) {
        guard let artifact=selected,let target=conversation,let data=selectedData,!artifact.previewUnavailable else { error="Select a loaded artifact and a destination chat."; return }
        let notes=annotations,destination=target.id,thread=target.backendThreadID
        guard onDeliver != nil else { error="Artifact delivery is not connected to the composer."; return }
        perform { [self] in
            var body:[String:JSONValue] = ["name":.string(artifact.name),"mimeType":.string(artifact.mime),"dataBase64":.string(data.base64EncodedString())]
            if let thread { body["threadId"] = .string(thread) }
            let uploaded=try await requiredClient().request("POST",path:"/attachments",body:.object(body))
            guard let input=uploaded["input"] else { throw URLError(.cannotParseResponse) }
            let reference="Artifact \(artifact.name); source thread=\(artifact.threadID ?? "unassigned"); artifactId=\(artifact.id); sha256=\(artifact.sha)."
            let files=[Attachment(id:"artifact:"+artifact.id,name:artifact.name,symbol:artifact.mime.hasPrefix("image/") ? "photo":"doc",input:input,mimeType:artifact.mime),
                       Attachment(id:"reference:"+artifact.id,name:"Artifact reference",symbol:"link",input:["type":"text","text":.string(reference)])]
            try await deliver(.init(destinationID:destination,attachments:files,artifact:artifact,annotations:notes,send:send))
        }
    }
    private func deliver(_ value:CoreArtifactDelivery) async throws {
        guard let onDeliver else { throw CoreWire.failure("Artifact delivery is not connected to the composer.") }
        let result:CoreSubmissionResult=await withCheckedContinuation { continuation in
            var completed=false
            onDeliver(value) { result in guard !completed else { return }; completed=true; continuation.resume(returning:result) }
        }
        switch result {
        case .accepted: notice=value.send ? "Accepted by the destination chat.":"Attached to the destination draft."
        case .failed(let reason): throw CoreWire.failure(reason)
        case .outcomeUnknown(let reason): throw CoreWire.failure("Delivery outcome unknown. Review the destination before sending again. " + reason)
        }
    }
    func openOriginal() {
        guard localPathsAvailable else { error = "This Core has not been verified as the local managed instance. Use its downloaded preview."; return }
        if let selected, !selected.path.isEmpty { onOpenURL?(URL(fileURLWithPath: selected.path)) }
    }
    func refreshTabs() {
        perform { [self] in tabs = try await requiredClient().request(path: "/browser/tabs")["tabs"]?.arrayValue ?? [] }
    }
    func openBrowser() {
        perform { [self] in
            let result = try await requiredClient().request("POST", path: "/browser/open", body: ["url": .string(browserURL)])
            selectedTabID = result["tabId"]?.stringValue ?? ""
            tabs = try await requiredClient().request(path: "/browser/tabs")["tabs"]?.arrayValue ?? []
        }
    }
    func closeBrowserTab() {
        guard !selectedTabID.isEmpty else { return }; let id = selectedTabID
        perform { [self] in
            _ = try await requiredClient().request("POST", path: "/browser/close", body: ["tabId": .string(id)])
            tabs.removeAll { $0["tabId"]?.stringValue == id }; if selectedTabID == id { selectedTabID = ""; browserImage = nil; browserSnapshot = "" }
        }
    }
    func inspectBrowser() {
        guard !selectedTabID.isEmpty else { return }; let id = selectedTabID
        perform { [self] in
            let result = try await requiredClient().request("POST", path: "/browser/snapshot", body: ["tabId": .string(id)])
            if selectedTabID == id { browserSnapshot = result["dom"]?.stringValue ?? Self.json(result) }
        }
    }
    func selectBrowserTab(_ id: String) { selectedTabID = id; browserImage = nil; browserSnapshot = "" }
    func screenshotBrowser(attach: Bool = false) {
        let destination=conversation
        guard !attach || (destination != nil && onDeliver != nil) else { error="Choose a destination and connect delivery."; return }
        guard !selectedTabID.isEmpty else { return }; let id = selectedTabID
        perform { [self] in
            let target = destination
            let result = try await requiredClient().request("POST", path: "/browser/screenshot", body: ["tabId": .string(id)])
            guard let encoded = result["data"]?.stringValue, let data = Data(base64Encoded: encoded) else { throw URLError(.cannotDecodeContentData) }
            if selectedTabID == id { browserImage = data }
            var body: [String: JSONValue] = ["name": "Browser screenshot.png", "mimeType": result["mimeType"] ?? "image/png", "dataBase64": .string(encoded)]
            if let tid = target?.backendThreadID { body["threadId"] = .string(tid) }
            let uploaded = try await requiredClient().request("POST", path: "/attachments", body: .object(body)); merge(uploaded)
            if attach, let target, let input = uploaded["input"] {
                let files=[Attachment(id:"browser:"+(uploaded["id"]?.stringValue ?? UUID().uuidString),name:"Browser screenshot",symbol:"photo",input:input,mimeType:"image/png"),
                           Attachment(id:UUID().uuidString,name:"Browser source",symbol:"link",input:["type":"text","text":.string("Browser screenshot source: " + Self.json(result["metadata"] ?? .null))])]
                try await deliver(.init(destinationID:target.id,attachments:files,send:false))
            }
        }
    }
    func openBrowserExternally() {
        if let value = selectedTab?["url"]?.stringValue, let url = URL(string: value), ["https", "http"].contains(url.scheme ?? "") { onOpenURL?(url) }
    }
    func captureToDraft() {
        let destination=conversation
        guard onDeliver != nil else { error="Capture delivery is not connected to the composer."; return }
        guard !hasPendingCapture else { notice = "A capture is already waiting. Open its chat to review permissions, or recover its result."; return }
        perform { [self] in
            guard let target=destination else { throw CoreWire.failure("Choose a destination chat.") }
            guard let tid = target.backendThreadID else { throw CoreError(code: nil, message: "Choose a chat with an existing Core session before capturing. Send its first message or choose another chat.", data: nil, httpStatus: nil) }
            let requestID = UUID().uuidString
            try trackCapture(requestID: requestID, target: target)
            captureSummary = "Waiting for capture. If an application permission is requested, review it in \(target.title)."
            var body: [String: JSONValue] = ["threadId": .string(tid), "mode": .string(captureMode), "clientRequestId": .string(requestID), "destinationConversationId": .string(target.id)]
            if !captureApp.isEmpty { body["app"] = .string(captureApp) }
            do {
                let result = try await requiredClient().request("POST", path: "/capture", body: .object(body), timeout: 420)
                try await reconcileCapture(result, requestID: requestID)
            } catch {
                guard pendingCaptures[requestID] != nil else { return } // SSE already delivered it.
                if CoreWire.isAmbiguous(error) {
                    captureSummary = "The capture connection ended. Its result is still being tracked for \(target.title); review any pending permission in that chat."
                    recoverCapture(requestID)
                } else {
                    if let failure = error as? CoreError, failure.code != nil {
                        pendingCaptures[requestID] = nil; savePendingCaptures()
                    }
                    if pendingCaptures[requestID] == nil { captureSummary = "Capture did not complete." }
                    throw error
                }
            }
        }
    }
    /// HTTP completion and replayed SSE converge here; destination never comes from the current picker.
    func reconcileCapture(_ result: JSONValue, requestID: String) async throws {
        guard let pending = pendingCaptures[requestID],reconcilingCaptures.insert(requestID).inserted else { return }
        defer { reconcilingCaptures.remove(requestID) }
        guard result["clientRequestId"]?.stringValue == requestID, result["threadId"]?.stringValue == pending.threadID,
              let target = runtime?.store.conversation(pending.conversationID), target.backendThreadID == pending.threadID else {
            throw CoreError(code: nil, message: "Capture destination does not match the original chat. The saved result has not been attached.", data: nil, httpStatus: nil)
        }
        guard result["success"]?.boolValue == true else {
            pendingCaptures[requestID] = nil; savePendingCaptures()
            error = "Capture did not produce an image. " + Self.json(result["errors"] ?? result)
            captureSummary = "Capture finished without an image."
            return
        }
        guard let captureID = result["id"]?.stringValue else { throw CoreError(code: nil, message: "Capture response has no saved result ID.", data: nil, httpStatus: nil) }
        let images = (result["contentItems"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "inputImage" && $0["imageUrl"]?.stringValue?.hasPrefix("data:image/") == true }
        guard !images.isEmpty else { throw CoreError(code: nil, message: "Capture metadata arrived without image bytes. Recover the saved result to attach it.", data: nil, httpStatus: nil) }
        var files:[Attachment]=images.enumerated().map { index,image in
            Attachment(id:captureID+":"+String(index),name:"Appshot \(index+1)",symbol:"photo",input:["type":"image","url":image["imageUrl"]!])
        }
        let context="Appshot source: " + Self.json(result["source"] ?? .null) + "\n" + (result["text"]?["content"]?.stringValue ?? "")
        files.append(Attachment(id:captureID+":context",name:"Appshot context",symbol:"doc.text",input:["type":"text","text":.string(context)]))
        try await deliver(.init(destinationID:target.id,attachments:files,send:false))
        pendingCaptures[requestID] = nil; savePendingCaptures()
        captureSummary = "Captured \(images.count) image(s). Attached to \(target.title)'s draft."
        error = nil; notice = captureSummary
    }
    func recoverCaptures() { for requestID in pendingCaptures.keys { recoverCapture(requestID) } }
    private func recoverCapture(_ requestID: String) {
        guard let pending = pendingCaptures[requestID], let client, recoveringCaptures.insert(requestID).inserted else { return }
        Task { [self] in
            defer { recoveringCaptures.remove(requestID) }
            do {
                let query = pending.captureID.map { ["id": $0] } ?? ["clientRequestId": requestID]
                let result = try await client.request(path: path("/capture/result", query: query), timeout: 60)
                if result["pending"]?.boolValue != true { try await reconcileCapture(result, requestID: requestID) }
            } catch { if pendingCaptures[requestID] != nil { self.error = "Capture recovery: " + error.localizedDescription } }
        }
    }
    static func json(_ value: JSONValue) -> String { (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
    static func artifactPaths(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[[^\]]*\]\((?:<(/[^>]+)>|(/[^\)]+))\)"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let r = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            guard let range = Range(r, in: text) else { return nil }
            let path = String(text[range]); let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            return ["png", "jpg", "jpeg", "webp", "gif", "pdf", "html", "htm", "txt", "md", "csv"].contains(ext) ? path : nil
        }
    }
    func receive(_ event: CoreEvent) {
        let p = event.params
        if event.method == "core/captureReady", let requestID = p["clientRequestId"]?.stringValue, var pending = pendingCaptures[requestID] {
            pending.captureID = p["id"]?.stringValue; pendingCaptures[requestID] = pending; savePendingCaptures()
            recoverCapture(requestID)
        }
        if event.method == "core/captureFailed", let requestID = p["clientRequestId"]?.stringValue, pendingCaptures[requestID] != nil {
            pendingCaptures[requestID] = nil; savePendingCaptures()
            error = p["message"]?.stringValue ?? "Capture did not complete."
            // The waiting-for-permission line would contradict the error (10-29 Live check, f161).
            captureSummary = "Capture did not complete."
        }
        if event.method == "core/approvalRequested", let tid = p["threadId"]?.stringValue,
           pendingCaptures.values.contains(where: { $0.threadID == tid }) {
            captureSummary = "Application permission is waiting in the destination chat. Review it there to continue the capture."
        }
        if event.method == "preview/artifactRegistered" { merge(p); return }
        if event.method == "preview/annotationCreated", p["artifactId"]?.stringValue == selectedID {
            if loadingAnnotations { annotationEvents.append(event) }
            if !annotations.contains(where: { $0["id"] == p["id"] }) { annotations.append(p) }; return
        }
        if event.method == "preview/annotationDeleted" {
            if loadingAnnotations { annotationEvents.append(event) }
            annotations.removeAll { $0["id"] == p["id"] }; return
        }
        let tid = p["threadId"]?.stringValue
        if event.method == "core/toolResult" || event.method == "browser/result" || event.method == "core/captureReady" {
            for image in p["images"]?.arrayValue ?? [] { if let path = image["path"]?.stringValue { register(path: path, threadID: tid, eventID: event.id) } }
        }
        if event.method == "item/completed", let item = p["item"] {
            if item["type"]?.stringValue == "agentMessage" { for path in Self.artifactPaths(in: item["text"]?.stringValue ?? "") { register(path: path, threadID: tid, eventID: event.id) } }
            if item["type"]?.stringValue == "imageGeneration" {
                receiveGeneratedImage(item, threadID: tid)
            }
        }
    }
    private func remember(_ key: String) -> Bool {
        guard seen.insert(key).inserted else { return false }; seenOrder.append(key)
        if seenOrder.count > 2048 { seen.remove(seenOrder.removeFirst()) }; return true
    }
    private func register(path: String, threadID: String?, eventID: Int) {
        let key = String(eventID) + ":" + (threadID ?? "") + ":" + path
        guard let client, remember(key) else { return }
        Task {
            do {
                var body: [String: JSONValue] = ["path": .string(path)]
                if let threadID { body["threadId"] = .string(threadID) }
                merge(try await client.request("POST", path: "/preview/artifacts", body: .object(body)))
            } catch { seen.remove(key) }
        }
    }
    /// Metadata-only placeholders never turn a file identity into a path or guessed URL.
    static func generatedImageRequest(_ item: JSONValue, threadID: String?) -> (path: String, body: JSONValue)? {
        var body: [String: JSONValue] = [:]
        if let threadID { body["threadId"] = .string(threadID) }
        // This is the backend's path namespace, including Windows on a remote Core.
        // Send it back unchanged; Core validates allowed roots. Never open it as a client URL.
        if let path = item["savedPath"]?.stringValue, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["path"] = .string(path)
            return ("/preview/artifacts", .object(body))
        }
        if let encoded = item["result"]?.stringValue, !encoded.isEmpty,
           let bytes = Data(base64Encoded: encoded), !bytes.isEmpty {
            body["name"] = "Generated image.png"; body["mimeType"] = "image/png"; body["dataBase64"] = .string(encoded)
            return ("/attachments", .object(body))
        }
        return nil
    }
    static func generatedImageFallback(_ item: JSONValue, threadID: String?, after error: Error) -> (path: String, body: JSONValue)? {
        // This exact Core validation occurs before reading or persisting any file.
        // Transport errors, malformed responses and other server failures are ambiguous.
        guard generatedPathWasRejected(error) else { return nil }
        var inline = item.objectValue ?? [:]; inline.removeValue(forKey: "savedPath")
        return generatedImageRequest(.object(inline), threadID: threadID)
    }
    private static func generatedPathWasRejected(_ error: Error) -> Bool {
        guard let failure = error as? CoreError else { return false }
        return failure.httpStatus == 400 && failure.code == -32603 && failure.message == "Preview file must be inside the selected workspace or Core data directory"
    }
    private static func generatedKey(itemID: String, threadID: String?) -> String {
        "generated:\(threadID?.utf8.count ?? 0):\(threadID ?? ""):\(itemID)"
    }
    func receiveGeneratedImage(_ item: JSONValue, threadID: String?) {
        guard let itemID = item["id"]?.stringValue, !itemID.isEmpty else { return }
        let key = Self.generatedKey(itemID: itemID, threadID: threadID)
        if generatedArtifacts[key]?.previewUnavailable == false { return }
        var metadata: [String: JSONValue] = ["id": .string(key), "name": "Generated image", "mimeType": "image/png",
                                           "generatedItemId": .string(itemID), "previewUnavailable": true]
        if let threadID { metadata["threadId"] = .string(threadID) }
        metadata["fileId"] = item["fileId"] ?? generatedArtifacts[key]?.raw["fileId"]
        metadata["generationStatus"] = item["status"] ?? generatedArtifacts[key]?.raw["generationStatus"]
        let placeholder = CoreArtifact(raw: .object(metadata))
        generatedArtifacts[key] = placeholder; merge(placeholder.raw)
        guard var request = Self.generatedImageRequest(item, threadID: threadID), let client,
              !registeringGenerated.contains(key) else { return }
        let pathKey = key + ":" + (item["savedPath"]?.stringValue ?? "")
        if rejectedGeneratedPaths.contains(pathKey) {
            var inline = item.objectValue ?? [:]; inline.removeValue(forKey: "savedPath")
            guard let fallback = Self.generatedImageRequest(.object(inline), threadID: threadID) else { return }
            request = fallback
        }
        // Dedupe the supplied source, including after an ambiguous HTTP outcome.
        let signature = key + request.path + String((request.body["path"]?.stringValue ?? request.body["dataBase64"]?.stringValue ?? "").hashValue)
        guard attemptedGenerated.insert(signature).inserted else { return }
        registeringGenerated.insert(key)
        let initialRequest = request
        Task {
            defer { registeringGenerated.remove(key) }
            do {
                let registered: JSONValue
                do {
                    registered = try await client.request("POST", path: initialRequest.path, body: initialRequest.body)
                } catch {
                    guard initialRequest.path == "/preview/artifacts", Self.generatedPathWasRejected(error) else { throw error }
                    rejectedGeneratedPaths.insert(pathKey)
                    guard let fallback = Self.generatedImageFallback(item, threadID: threadID, after: error) else { throw error }
                    let fallbackSignature = key + fallback.path + String((fallback.body["dataBase64"]?.stringValue ?? "").hashValue)
                    guard attemptedGenerated.insert(fallbackSignature).inserted else { return }
                    registered = try await client.request("POST", path: fallback.path, body: fallback.body)
                }
                completeGeneratedImageRegistration(itemID: itemID, threadID: threadID, artifact: registered)
            } catch { self.error = error.localizedDescription }
        }
    }
    /// Called only after Core returned an actual registered artifact, never for a bare file ID.
    func completeGeneratedImageRegistration(itemID: String, threadID: String?, artifact: JSONValue) {
        let key = Self.generatedKey(itemID: itemID, threadID: threadID)
        guard let previous = generatedArtifacts[key], let id = artifact["id"]?.stringValue, !id.isEmpty else { return }
        var metadata = artifact.objectValue ?? [:]
        metadata["generatedItemId"] = .string(itemID)
        metadata["fileId"] = previous.raw["fileId"]
        metadata["generationStatus"] = previous.raw["generationStatus"]
        metadata["threadId"] = threadID.map(JSONValue.string)
        metadata["previewUnavailable"] = false
        let resolved = CoreArtifact(raw: .object(metadata))
        generatedArtifacts[key] = resolved
        artifacts.removeAll { $0.id == key }
        merge(resolved.raw)
        if selectedID == key { selectedID = id; select(id) }
    }
    func reconcileArtifactList(_ values: [JSONValue]) {
        let previous=selected
        artifacts = values.map(CoreArtifact.init(raw:)).sorted { ($0.raw["createdAt"]?.doubleValue ?? 0) > ($1.raw["createdAt"]?.doubleValue ?? 0) }
        for artifact in generatedArtifacts.values { merge(artifact.raw,refreshSelection:false) }
        if previous != nil,selected == nil { select("") }
        else if previous?.sha != selected?.sha { select(selectedID) }
    }
}
