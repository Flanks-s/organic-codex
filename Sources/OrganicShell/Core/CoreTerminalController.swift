import Foundation

/// Session ownership and I/O only. Tools supplies the native renderer; Core owns all live PTYs.
@MainActor final class CoreTerminalController {
    private(set) var isConfigured=false
    private(set) var sessions:[CoreTerminalSession]=[]
    private(set) var restorationError:String?
    var selected:[ConversationID:UUID]=[:]{didSet{if selected != oldValue{notify()}}}
    var onChange:(()->Void)?
    private var observers:[UUID:()->Void]=[:]
    func observe(_ callback:@escaping ()->Void)->UUID { let id=UUID(); observers[id]=callback; return id }
    func removeObserver(_ id:UUID) { observers[id]=nil }
    private func notify() { onChange?(); for callback in Array(observers.values) { callback() } }
    private var client:(any CoreTransport)?
    private weak var store:ConversationStore?
    private var restoration:Task<Bool,Never>?
    private let clock:any CoreRuntimeClock
    init(clock:any CoreRuntimeClock=CoreSystemClock()) { self.clock=clock }
    func configure(client:any CoreTransport,store:ConversationStore) { guard !isConfigured else { return }; self.client=client; self.store=store; isConfigured=true; notify() }
    func sessions(for conversation:ConversationID)->[CoreTerminalSession] { sessions.filter { $0.conversationID == conversation } }
    func active(for conversation:ConversationID)->CoreTerminalSession? { let values=sessions(for:conversation); return values.first { $0.id == selected[conversation] } ?? values.last }
    @discardableResult func open(for conversation:Conversation,cwd:String?=nil) async -> CoreTerminalSession? {
        guard let client,await restore() else { return nil }
        guard let path=cwd ?? conversation.cwd ?? store?.project(conversation.projectID)?.path,!path.isEmpty else { restorationError="Choose a backend working directory before opening a terminal."; notify(); return nil }
        if let unresolved=sessions(for:conversation.id).first(where: { $0.opening || $0.openOutcomeUnknown }) { return unresolved }
        let session=CoreTerminalSession(conversationID:conversation.id,threadID:conversation.backendThreadID,cwd:path,client:client,clock:clock)
        install(session); selected[conversation.id]=session.id; await session.open(); notify(); return session
    }
    private func install(_ session:CoreTerminalSession) { sessions.append(session); session.onChange={ [weak self] in self?.notify() }; notify() }
    func receive(_ event:CoreEvent) {
        guard ["core/terminalOutput","core/terminalExited"].contains(event.method),let id=event.params["sessionId"]?.stringValue else { return }
        sessions.first { $0.backendID == id }?.receive(event)
    }
    @discardableResult func restore() async -> Bool {
        if let restoration { return await restoration.value }
        guard let client,let store else { return false }
        let task=Task { @MainActor in
            do {
                let value=try await client.request(path:"/terminal/sessions")
                restoreDescriptors(value["sessions"]?.arrayValue ?? value.arrayValue ?? [],store:store)
                for session in sessions where session.backendID != nil { await session.catchUp() }
                restorationError=nil; notify(); return true
            } catch { restorationError=error.localizedDescription; notify(); return false }
        }
        restoration=task; let result=await task.value; restoration=nil; return result
    }
    func restoreDescriptors(_ descriptors:[JSONValue],store:ConversationStore) {
        guard let client else { return }
        for value in descriptors {
            guard let id=value["id"]?.stringValue,!sessions.contains(where: { $0.backendID == id }) else { continue }
            let conversation:Conversation?
            if let tid=value["threadId"]?.stringValue { conversation=store.backendConversation(tid) }
            else { conversation=value["conversationId"]?.stringValue.flatMap(store.conversation) }
            guard let conversation,let cwd=value["cwd"]?.stringValue else { continue } // Never match cwd alone.
            if let unknown=sessions(for:conversation.id).first(where: { $0.backendID == nil && $0.openOutcomeUnknown }) {
                unknown.attach(backendID:id,running:value["running"]?.boolValue ?? false); continue
            }
            let session=CoreTerminalSession(conversationID:conversation.id,threadID:conversation.backendThreadID,cwd:cwd,client:client,clock:clock)
            session.attach(backendID:id,running:value["running"]?.boolValue ?? false); install(session)
            if selected[conversation.id] == nil { selected[conversation.id]=session.id }
        }
    }
    func reconnect() async { _ = await restore() }
    /// Closing a pane/window detaches its view; it does not call close on sessions.
}

@MainActor final class CoreTerminalSession:Identifiable {
    struct Output { let text:String; let reset:Bool }
    let id=UUID(),conversationID:ConversationID
    let threadID:String?
    private(set) var backendID:String?,cwd:String,title="Terminal",running=false,opening=true,openOutcomeUnknown=false
    private(set) var error:String?,sequence=0,output="",columns=80,rows=24
    var onChange:(()->Void)?
    private let client:any CoreTransport,clock:any CoreRuntimeClock
    private var restoring=false,buffered:[CoreEvent]=[],openingAttempted=false
    private var observers:[UUID:(Output)->Void]=[:]
    private var pendingInput=Data(),writeTask:Task<Void,Never>?,resizeTask:Task<Void,Never>?
    init(conversationID:ConversationID,threadID:String?=nil,cwd:String,client:any CoreTransport,clock:any CoreRuntimeClock=CoreSystemClock()) {
        self.conversationID=conversationID; self.threadID=threadID; self.cwd=cwd; self.client=client; self.clock=clock
    }
    isolated deinit { resizeTask?.cancel() }
    func observeOutput(_ callback:@escaping (Output)->Void)->UUID { let id=UUID(); observers[id]=callback; callback(.init(text:output,reset:true)); return id }
    func removeOutputObserver(_ id:UUID) { observers[id]=nil }
    private func feed(_ text:String) { output += text; if output.utf8.count>512*1024 { output=String(output.suffix(256*1024)) }; for callback in Array(observers.values) { callback(.init(text:text,reset:false)) } }
    func attach(backendID:String,running:Bool) { self.backendID=backendID; self.running=running; opening=false; openOutcomeUnknown=false; onChange?() }
    func open() async {
        guard !openingAttempted,backendID == nil else { return }; openingAttempted=true
        defer { opening=false; onChange?() }
        do {
            let value=try await client.request("POST",path:"/terminal/open",body:["cwd":.string(cwd),"cols":.number(Double(columns)),"rows":.number(Double(rows)),"conversationId":.string(conversationID),"threadId":threadID.map(JSONValue.string) ?? .null])
            guard let id=value["id"]?.stringValue else { openOutcomeUnknown=true; throw CoreWire.failure("Core did not return the opened terminal ID. Restore sessions before opening another.") }
            attach(backendID:id,running:value["running"]?.boolValue ?? true); await catchUp()
        } catch { self.error=error.localizedDescription; if CoreWire.isAmbiguous(error) { openOutcomeUnknown=true } }
    }
    func catchUp() async {
        guard let backendID,!restoring else { return }; restoring=true
        var success=false
        defer {
            restoring=false; onChange?()
            if success { let waiting=buffered.sorted { ($0.params["sequence"]?.intValue ?? 0)<($1.params["sequence"]?.intValue ?? 0) }; buffered=[]; for e in waiting { receive(e) } }
        }
        do {
            var p=URLComponents(); p.path="/terminal/output"; p.queryItems=[.init(name:"id",value:backendID),.init(name:"since",value:String(sequence))]
            let result=try await client.request(path:p.string!)
            if result["truncated"] == true { feed("\r\n[Older terminal output is no longer available.]\r\n") }
            for chunk in (result["chunks"]?.arrayValue ?? []).sorted(by: { ($0["sequence"]?.intValue ?? 0)<($1["sequence"]?.intValue ?? 0) }) {
                append(chunk["data"]?.stringValue ?? "",sequence:chunk["sequence"]?.intValue ?? 0)
            }
            running=result["running"]?.boolValue ?? false; sequence=max(sequence,result["lastSequence"]?.intValue ?? sequence); error=nil; success=true
        } catch { self.error=error.localizedDescription }
    }
    func receive(_ event:CoreEvent) {
        guard event.params["sessionId"]?.stringValue == backendID,let incoming=event.params["sequence"]?.intValue,incoming>sequence else { return }
        if restoring { buffered.append(event); return }
        if incoming>sequence+1 { buffered.append(event); Task { await catchUp() }; return }
        if event.method == "core/terminalExited" { sequence=incoming; running=false; onChange?() }
        else { append(event.params["data"]?.stringValue ?? "",sequence:incoming) }
        // Output observers invalidate only the terminal renderer; don't relayout the entire Tools tree for each chunk.
    }
    private func append(_ text:String,sequence incoming:Int) { guard incoming>sequence else { return }; sequence=incoming; feed(text) }
    func close() async {
        guard let backendID else { return }
        do { _ = try await client.request("POST",path:"/terminal/close",body:["id":.string(backendID)]); running=false; error=nil }
        catch { self.error=error.localizedDescription }; onChange?()
    }
    func send(_ text:String) {
        guard running,backendID != nil else { return }
        guard pendingInput.count+text.utf8.count<=1024*1024 else { error="Terminal input buffer is full. Input was not replayed."; onChange?(); return }
        pendingInput.append(contentsOf:text.utf8); guard writeTask == nil else { return }
        writeTask=Task { [weak self] in
            guard let self,let backendID else { return }; defer { writeTask=nil; onChange?() }
            while !pendingInput.isEmpty {
                var bytes=Data(pendingInput.prefix(64*1024))
                while String(data:bytes,encoding:.utf8) == nil { bytes.removeLast() }
                let part=String(decoding:bytes,as:UTF8.self); pendingInput.removeFirst(bytes.count)
                do { _ = try await client.request("POST",path:"/terminal/write",body:["id":.string(backendID),"data":.string(part)]) }
                catch { self.error="Terminal input outcome unknown; input was not replayed. " + error.localizedDescription; pendingInput.removeAll(); return }
            }
        }
    }
    func resize(columns:Int,rows:Int) {
        let cols=min(1000,max(1,columns)),rows=min(1000,max(1,rows))
        guard cols != self.columns || rows != self.rows else { return }; self.columns=cols; self.rows=rows
        resizeTask?.cancel(); guard let backendID else { return }
        resizeTask=Task { [weak self] in
            do {
                guard let self else { return }; try await clock.sleep(seconds:0.05); try Task.checkCancellation()
                _ = try await client.request("POST",path:"/terminal/resize",body:["id":.string(backendID),"cols":.number(Double(self.columns)),"rows":.number(Double(self.rows))])
            } catch is CancellationError {} catch { self?.error=error.localizedDescription; self?.onChange?() }
        }
    }
    func setTitle(_ value:String) { guard value != title else { return }; title=value; onChange?() }
    func updateDirectory(_ directory:String?) { if let directory,let url=URL(string:directory),url.isFileURL,url.path != cwd { cwd=url.path; onChange?() } }
}
