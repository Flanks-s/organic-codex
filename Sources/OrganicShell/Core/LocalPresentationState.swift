import Foundation

@MainActor protocol CorePresentationStorage: AnyObject {
    func read(key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
}
@MainActor final class CoreDefaultsStorage: CorePresentationStorage {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    func read(key: String) throws -> Data? { defaults.data(forKey: key) }
    func write(_ data: Data, key: String) throws {
        let previous=defaults.data(forKey:key)
        defaults.set(data, forKey: key)
        // Queue acceptance must wait for a preferences-domain write, not just its in-memory mutation.
        guard defaults.synchronize() else {
            // A failed synchronization must not expose an uncommitted migration marker to the next reader.
            if let previous { defaults.set(previous,forKey:key) } else { defaults.removeObject(forKey:key) }
            _=defaults.synchronize()
            throw CoreWire.failure("The local presentation state could not be written to disk.")
        }
    }
}
@MainActor final class CoreMemoryStorage: CorePresentationStorage {
    var values: [String: Data] = [:]
    var writeError: Error?
    let attachmentInputs = CoreMemoryAttachmentInputs()
    func read(key: String) throws -> Data? { values[key] }
    func write(_ data: Data, key: String) throws { if let writeError { throw writeError }; values[key] = data }
}

/// Endpoint-scoped UI metadata only. Never serializes transcript, approvals, execution or cached backend truth.
@MainActor final class LocalPresentationState {
    struct FileState: Codable, Equatable {
        var id: String, name: String, symbol: String
        var url: URL?, input: JSONValue?, mime: String?, inputFile: String?
        init(_ a: Attachment) { id = a.id; name = a.name; symbol = a.symbol; url = a.url; input = a.input; mime = a.mimeType; inputFile = a.persistedInputPath }
        var attachment: Attachment { .init(id: id, name: name, symbol: symbol, url: url, input: input, mimeType: mime, persistedInputPath: inputFile) }
    }
    struct ModelState: Codable, Equatable {
        var id: String, effort: String, speed: Int, daybreak: Bool, memory: [String: String]
        init(_ m: ModelSettings) { id = m.modelID; effort = m.effort.rawValue; speed = m.speed.rawValue; daybreak = m.daybreak; memory = m.memory.mapValues(\.rawValue) }
        var settings: ModelSettings { var m = ModelSettings(); m.modelID = id; m.effort = Effort(rawValue: effort) ?? .none; m.speed = Speed(rawValue: speed) ?? .standard; m.daybreak = daybreak; m.memory = memory.compactMapValues(Effort.init(rawValue:)); return m }
    }
    struct QueueState: Codable, Equatable {
        var id: String, text: String, files: [FileState], model: ModelState, access: String
        var waiting: String?, error: String?
        init(_ q: QueuedMessage) { id = q.id; text = q.text; files = q.attachments.map(FileState.init); model = ModelState(q.settings); access = q.access.rawValue; waiting = q.waitingForTurnID; error = q.deliveryError }
        var message: QueuedMessage { .init(id: id, text: text, attachments: files.map(\.attachment), settings: model.settings, access: Access(rawValue: access) ?? .auto, waitingForTurnID: waiting, deliveryError: error) }
    }
    struct OutboundState: Codable, Equatable {
        var id: UUID, identity: String?, action: CoreSubmissionAction, text: String, files: [FileState], model: ModelState, access: String, waiting: String?
        init(_ s: CoreSubmission) { id = s.id; identity = s.identity; action = s.action; text = s.text; files = s.attachments.map(FileState.init); model = ModelState(s.settings); access = s.access.rawValue; waiting = s.waitingForTurnID }
        @MainActor var submission: CoreSubmission { .init(id: id, identity: identity, action: action, text: text, attachments: files.map(\.attachment), settings: model.settings, access: Access(rawValue: access) ?? .auto, waitingForTurnID: waiting) }
    }
    struct ChatState: Codable, Equatable {
        var key: String, backend: String?, title: String, project: String?, device: String, cwd: String?
        var draft: String, files: [FileState], model: ModelState, access: String, queue: [QueueState]
        var identityIndex: Int, symbol: String?, tint: String?, pinned: Bool, unknown: Bool
        var archivedUnsent: Bool
        var outbound: [OutboundState]
    }
    /// App owns the opaque layout payload. Unsent window drafts put their files in this typed field so they
    /// participate in the same sidecar transaction and reference lifetime as conversation/queue attachments.
    struct WindowState: Codable, Equatable { var id: String; var payload: JSONValue; var files: [FileState]? = nil }
    struct ProjectState: Codable, Equatable {
        var id: String, name: String, device: String, color: String?, pinned: Bool, path: String?
        init(_ p: Project) { id = p.id; name = p.name; device = p.deviceID; color = p.colorHex; pinned = p.pinned; path = p.path }
        var project: Project { .init(id: id, name: name, deviceID: device, colorHex: color, pinned: pinned, path: path) }
    }
    struct Saved: Codable, Equatable { var version = 3; var chats: [ChatState]; var projects: [ProjectState]; var windows: [WindowState]; var newModel: ModelState; var accepted: [UUID]; var bodyMigrationVersion: Int? = nil }
    let store: ConversationStore
    let scope: String
    private let storage: any CorePresentationStorage
    let attachmentInputs: any CoreAttachmentInputStorage
    private let clock: any CoreRuntimeClock
    private let key: String
    private var saved: Saved?
    private var lastSnapshot: Saved?
    private var inputCache: [String: (JSONValue, String)] = [:]
    private var preparedInputs: Set<String> = []
    private var obsoleteInputs: Set<String> = []
    private var observation: UUID?, pending: Task<Void, Never>?
    private var outbound: [String: [UUID: CoreSubmission]] = [:]
    private(set) var accepted: Set<UUID> = []
    private(set) var windows: [WindowState] = []
    private(set) var lastError: String?
    private var writeProtection: String?
    init(store: ConversationStore, scope: String, storage: any CorePresentationStorage = CoreDefaultsStorage(), clock: any CoreRuntimeClock = CoreSystemClock(), attachmentInputs: (any CoreAttachmentInputStorage)? = nil) {
        self.store = store; self.scope = scope; self.storage = storage; self.clock = clock
        store.bodyIdentitiesReady = false
        store.bodyIdentityMigrationRequired = true
        self.attachmentInputs = attachmentInputs ?? (storage as? CoreMemoryStorage)?.attachmentInputs ?? CoreFileAttachmentInputs()
        key = "organic.shell.presentation.v2." + Data(scope.utf8).base64EncodedString()
        do {
            if let data = try storage.read(key: key) {
                struct Header: Decodable { let version: Int }
                let version = try JSONDecoder().decode(Header.self, from: data).version
                switch version {
                case 2:
                    // v2 has inline attachment inputs and no WindowState.files.
                    // save() migrates these through persistFile and commits v3 only after success.
                    saved = try JSONDecoder().decode(Saved.self, from: data)
                case 3: saved = try JSONDecoder().decode(Saved.self, from: data)
                default:
                    writeProtection = "Presentation version \(version) is unsupported. The original state is read-only."
                    lastError = writeProtection
                }
            }
            accepted = Set(saved?.accepted ?? []); windows = saved?.windows ?? []
        } catch { writeProtection = error.localizedDescription; lastError = writeProtection }
    }
    isolated deinit { pending?.cancel(); if let observation { store.removeObserver(observation) } }
    func localID(forBackend id: String) -> String? { saved?.chats.first { $0.backend == id }?.key }
    func restore() {
        for project in saved?.projects ?? [] { store.addProject(project.project) }
        for state in saved?.chats ?? [] {
            let c = state.backend.flatMap(store.backendConversation) ?? store.conversation(state.key) ?? {
                let c = Conversation(id: state.key, identityIndex: state.identityIndex, title: state.title, projectID: state.project, deviceID: state.device, updated: Date(), contextUsed: 0)
                c.isLiveConversation = true; c.branch = ""; c.backendThreadID = state.backend; c.cwd = state.cwd; c.archived = state.backend == nil && state.archivedUnsent; store.add(c); return c
            }()
            apply(state, to: c)
        }
        if let m = saved?.newModel { store.newChatSettings = m.settings }
        if (saved?.bodyMigrationVersion ?? 0) >= BodyIdentityMigration.version { store.bodyIdentitiesReady = true }
        else { do { try migrateBodyIdentities() } catch { lastError = error.localizedDescription } }
    }
    /// Change only identity fields and the body version in an existing durable snapshot.
    /// Attachment conversion, queue recovery, drafts and window payloads are not part of this transaction.
    private func migrateBodyIdentities() throws {
        guard var value=saved else { try save(); return }
        guard (value.bodyMigrationVersion ?? 0)<BodyIdentityMigration.version else { store.bodyIdentitiesReady=true; return }
        let records=value.chats.map { BodyIdentityMigration.Record(id:$0.key,title:$0.title,identityIndex:$0.identityIndex,symbol:$0.symbol,tint:$0.tint) }
        let migrated=BodyIdentityMigration.migrate(records,choices:ConversationBodyIdentity.choices)
        for i in value.chats.indices { value.chats[i].symbol=migrated[i].symbol; value.chats[i].tint=migrated[i].tint }
        value.bodyMigrationVersion=BodyIdentityMigration.version
        try storage.write(JSONEncoder().encode(value),key:key)
        saved=value; lastSnapshot=nil; lastError=nil
        for state in value.chats {
            if let c=store.conversation(state.key) ?? state.backend.flatMap(store.backendConversation) { c.identitySymbol=state.symbol; c.identityTint=state.tint }
        }
        store.bodyIdentitiesReady=true
    }
    func apply(to c: Conversation) { if let state = saved?.chats.first(where: { $0.key == c.id || $0.backend != nil && $0.backend == c.backendThreadID }) { apply(state, to: c) } }
    private func apply(_ s: ChatState, to c: Conversation) {
        c.draft = s.draft; c.attachments = restoreAttachments(s.files); c.next = s.model.settings; c.access = Access(rawValue: s.access) ?? .auto
        c.queued = s.queue.map { state in
            var message = state.message; message.attachments = restoreAttachments(state.files)
            if message.attachments.contains(where: Self.unavailable), message.deliveryError == nil { message.deliveryError = "An attachment could not be restored. Remove it and attach the file again before sending." }
            return message
        }; c.pinned = s.pinned; c.identityIndex = s.identityIndex; c.identitySymbol = s.symbol; c.identityTint = s.tint
        c.sendOutcomeUnknown = s.unknown || !s.outbound.isEmpty; c.sending = false
        outbound[c.id] = Dictionary(s.outbound.map { state in
            let old = state.submission
            let message = CoreSubmission(id: old.id, identity: old.identity, action: old.action, text: old.text,
                                         attachments: restoreAttachments(state.files), settings: old.settings, access: old.access, waitingForTurnID: old.waitingForTurnID)
            return (state.id, message)
        }, uniquingKeysWith: { _, b in b })
        if c.sendOutcomeUnknown { c.operationError = "The previous send outcome was not saved. Refresh history before sending again." }
        for i in c.queued.indices where c.sendOutcomeUnknown && c.queued[i].deliveryError == nil { c.queued[i].deliveryError = "A previous send is unresolved. Refresh history before restoring this message." }
        if c.attachments.contains(where: Self.unavailable) {
            let message = "An attachment could not be restored. Remove it and attach the file again before sending."
            c.operationError = c.operationError.map { $0 + " " + message } ?? message
        }
    }
    private static func unavailable(_ file: Attachment) -> Bool { file.input == nil && file.url == nil }
    /// Resolve only through this endpoint's owned sidecar store. Never read an arbitrary serialized inputFile path.
    func resolveAttachment(_ file: Attachment) throws -> Attachment {
        guard file.input == nil, let reference = file.persistedInputPath else { return file }
        var restored = file
        do { restored.input = try attachmentInputs.restore(reference, scope: scope) }
        catch { if file.url == nil { throw CoreWire.failure("Could not restore attachment \(file.name): \(error.localizedDescription)") } }
        return restored
    }
    /// For opaque-window owners, use this instead of FileState.attachment to hydrate the optional files field.
    /// Missing inputs remain visible as removable chips; they never silently become a different attachment.
    func restoreAttachments(_ files: [FileState]) -> [Attachment] {
        files.map { file in
            do { return try resolveAttachment(file.attachment) }
            catch { lastError = error.localizedDescription; return file.attachment }
        }
    }
    func restoredOutbound(in c: Conversation) -> [CoreSubmission] { Array((outbound[c.id] ?? [:]).values) }
    func setOutbound(_ submission: CoreSubmission, in c: Conversation) { outbound[c.id, default: [:]][submission.id] = submission }
    func clearOutbound(_ id: UUID, in c: Conversation) { outbound[c.id]?[id] = nil }
    func recordAccepted(_ id: UUID) { accepted.insert(id); if accepted.count > 4096 { accepted.remove(accepted.first!) } }
    func setWindows(_ values: [WindowState]) { windows = values; scheduleSave() }
    func observe() { guard observation == nil else { return }; observation = store.observe { [weak self] _ in self?.scheduleSave() } }
    func scheduleSave() {
        guard writeProtection == nil else { return }
        guard pending == nil else { return } // Coalesce; a continuous stream must never postpone a draft indefinitely.
        let clock = clock
        pending = Task { [weak self] in do { try await clock.sleep(seconds: 0.2); try Task.checkCancellation(); try self?.save() } catch is CancellationError {} catch { self?.lastError = error.localizedDescription } }
    }
    func save() throws {
        if let reason = writeProtection { throw CoreWire.failure(reason) }
        pending?.cancel(); pending = nil
        let chats = store.conversations.map { c in
            ChatState(key: c.id, backend: c.backendThreadID, title: c.title, project: c.projectID, device: c.deviceID, cwd: c.cwd,
                      draft: c.draft, files: c.attachments.map(FileState.init), model: ModelState(c.next), access: c.access.rawValue, queue: c.queued.map(QueueState.init),
                      identityIndex: c.identityIndex, symbol: c.identitySymbol, tint: c.identityTint, pinned: c.pinned,
                      unknown: c.sendOutcomeUnknown || !(outbound[c.id] ?? [:]).isEmpty, archivedUnsent: c.archived, outbound: (outbound[c.id] ?? [:]).values.sorted { $0.id.uuidString < $1.id.uuidString }.map(OutboundState.init))
        }
        var snapshot = Saved(chats: chats, projects: store.projects.map(ProjectState.init), windows: windows, newModel: ModelState(store.newChatSettings), accepted: accepted.sorted { $0.uuidString < $1.uuidString })
        if snapshot == lastSnapshot {
            // Also retire payloads prepared by a failed save when the user reverted to the committed draft.
            obsoleteInputs.formUnion(preparedInputs); obsoleteInputs.subtract(Self.references(saved)); preparedInputs = []
            lastError = nil; cleanupInputs(); return // Ordinary streaming deltas perform no file I/O.
        }
        var value = snapshot
        value.bodyMigrationVersion = saved?.bodyMigrationVersion ?? 0
        if (value.bodyMigrationVersion ?? 0) < BodyIdentityMigration.version {
            let records = value.chats.map { BodyIdentityMigration.Record(id: $0.key, title: $0.title, identityIndex: $0.identityIndex, symbol: $0.symbol, tint: $0.tint) }
            let migrated = BodyIdentityMigration.migrate(records, choices: ConversationBodyIdentity.choices)
            for i in value.chats.indices { value.chats[i].symbol = migrated[i].symbol; value.chats[i].tint = migrated[i].tint }
            // Match the eventual store identities before sidecar conversion changes the storage-only representation.
            snapshot.chats = value.chats
            value.bodyMigrationVersion = BodyIdentityMigration.version
        }
        do {
            for i in value.chats.indices {
                value.chats[i].files = try value.chats[i].files.map(persistFile)
                for q in value.chats[i].queue.indices { value.chats[i].queue[q].files = try value.chats[i].queue[q].files.map(persistFile) }
                for q in value.chats[i].outbound.indices { value.chats[i].outbound[q].files = try value.chats[i].outbound[q].files.map(persistFile) }
            }
            for i in value.windows.indices { value.windows[i].files = try value.windows[i].files?.map(persistFile) }
            if value != saved { try storage.write(JSONEncoder().encode(value), key: key) }
            // Old payloads stay intact until the new reference set has been committed successfully.
            obsoleteInputs.formUnion(Self.references(saved)); obsoleteInputs.formUnion(preparedInputs)
            obsoleteInputs.subtract(Self.references(value)); preparedInputs = []
            saved = value; lastSnapshot = snapshot; lastError = nil; cleanupInputs()
            // Publish only after storage accepts the entire versioned snapshot. Failed writes leave both sides old.
            for state in value.chats {
                if let c = store.conversation(state.key) { c.identitySymbol = state.symbol; c.identityTint = state.tint }
            }
            store.bodyIdentitiesReady = true
        } catch { lastError = error.localizedDescription; throw error }
    }
    private func persistFile(_ original: FileState) throws -> FileState {
        var file = original
        if let input = file.input {
            let reference: String
            if let cached = inputCache[file.id], cached.0 == input { reference = cached.1 }
            else {
                reference = try attachmentInputs.persist(input, scope: scope); inputCache[file.id] = (input, reference)
                preparedInputs.insert(reference)
            }
            file.inputFile = reference; file.input = nil
        } else if let reference = file.inputFile {
            // A missing input must fail a durable queue/save, not accept a dead reference as success.
            do { _ = try attachmentInputs.restore(reference, scope: scope) }
            catch { if file.url == nil { throw error }; file.inputFile = nil }
        }
        return file
    }
    private static func references(_ saved: Saved?) -> Set<String> {
        guard let saved else { return [] }
        var files = saved.windows.flatMap { $0.files ?? [] }
        for chat in saved.chats {
            files.append(contentsOf: chat.files)
            files.append(contentsOf: chat.queue.flatMap(\.files))
            files.append(contentsOf: chat.outbound.flatMap(\.files))
        }
        return Set(files.compactMap(\.inputFile))
    }
    private func cleanupInputs() {
        let retrying = !obsoleteInputs.isEmpty
        for reference in obsoleteInputs {
            do {
                try attachmentInputs.remove(reference, scope: scope); obsoleteInputs.remove(reference)
                inputCache = inputCache.filter { $0.value.1 != reference }
            }
            catch { lastError = "Draft saved, but an unused attachment input could not be removed: " + error.localizedDescription }
        }
        if retrying, obsoleteInputs.isEmpty, lastError?.hasPrefix("Draft saved, but an unused attachment") == true { lastError = nil }
    }
    func setIdentity(_ c: Conversation, symbol: String?, tint: String?) throws {
        guard store.bodyIdentitiesReady, symbol == nil || ConversationBodyIdentity.choices.contains(symbol!) else { throw CoreWire.failure("The body identity is unavailable.") }
        let previous = (c.identitySymbol, c.identityTint)
        c.identitySymbol = symbol; c.identityTint = tint
        do { try save(); store.changed(c) } catch { c.identitySymbol = previous.0; c.identityTint = previous.1; throw error }
    }
}
