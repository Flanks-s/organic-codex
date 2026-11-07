#if CORE_SELFTEST
import Foundation

@MainActor private final class S3InputProbe: CoreAttachmentInputStorage {
    let files: CoreFileAttachmentInputs
    var persists = 0, reads = 0, removes = 0
    var failWrite = false, failRemove = false
    init(root: URL) { files = CoreFileAttachmentInputs(root: root) }
    func persist(_ input: JSONValue, scope: String) throws -> String {
        persists += 1
        if failWrite { throw CoreWire.failure("fixture sidecar write failure") }
        return try files.persist(input, scope: scope)
    }
    func restore(_ reference: String, scope: String) throws -> JSONValue { reads += 1; return try files.restore(reference, scope: scope) }
    func remove(_ reference: String, scope: String) throws {
        removes += 1
        if failRemove { throw CoreWire.failure("fixture cleanup failure") }
        try files.remove(reference, scope: scope)
    }
}

/// Filesystem cases have one injected temporary root. No backend/data directory/default presentation I/O.
@MainActor enum CoreAttachmentVerification {
    static func run(check: (Bool, String) -> Void) throws {
        let manager = FileManager.default
        // A root that does not exist yet under the home directory, as the real one is (/tmp and /var have a /private
        // prefix Foundation treats specially, which hid this): the first save makes its directories and is not taken for
        // a symbolic link. Removed after.
        let fresh = manager.homeDirectoryForCurrentUser.appending(path: "Library/Caches/organic-sidecar-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: fresh) }
        let freshInputs = CoreFileAttachmentInputs(root: fresh.appendingPathComponent("Presentation", isDirectory: true))
        let freshSaved = try? freshInputs.persist(["type": "text", "text": "first save"], scope: "https://fixture.invalid/fresh")
        check(freshSaved.map { manager.fileExists(atPath: $0) } == true, "S3 sidecar: the first save under a root not made yet succeeds")
        check(freshSaved.flatMap { try? freshInputs.restore($0, scope: "https://fixture.invalid/fresh") } == ["type": "text", "text": "first save"], "S3 sidecar: and restores")
        let temporary = URL(fileURLWithPath: "/tmp/sol-s3-sidecars-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let probe = S3InputProbe(root: temporary.appendingPathComponent("Presentation", isDirectory: true))
        let metadata = CoreMemoryStorage(), store = ConversationStore(), scope = "https://fixture.invalid/core-a"
        let state = LocalPresentationState(store: store, scope: scope, storage: metadata, attachmentInputs: probe)
        let first: JSONValue = ["type": "image", "image_url": .string("data:image/png;base64," + String(repeating: "q", count: 350_000))]
        let second: JSONValue = ["type": "text", "text": "queued payload with a stable id"]
        let windowInput: JSONValue = ["type": "text", "text": "unsent window attachment"]
        let original = Attachment(id: "same-id", name: "图 with spaces.png", symbol: "photo", input: first, mimeType: "image/png")
        var queuedFile = original; queuedFile.input = second
        let c = Conversation(id: "draft", title: "Unsent identity"); c.draft = "not submitted"; c.attachments = [original]; store.add(c)
        c.queued = [.init(id: "queued", text: "queued", attachments: [queuedFile], settings: c.next, access: .full, waitingForTurnID: "previous")]
        let outbound = CoreSubmission(identity: c.id, text: "ambiguous", attachments: [original], settings: c.next)
        state.setOutbound(outbound, in: c)
        state.setWindows([.init(id: "new-window", payload: ["draft": "New Chat", "project": "project-id"], files: [.init(.init(id: "window-file", name: "new.txt", symbol: "doc", input: windowInput))])])
        try state.save()
        let key = "organic.shell.presentation.v2." + Data(scope.utf8).base64EncodedString()
        let encoded = metadata.values[key]!, serialized = try JSONDecoder().decode(LocalPresentationState.Saved.self, from: encoded)
        let refs = [serialized.chats[0].files[0], serialized.chats[0].queue[0].files[0], serialized.chats[0].outbound[0].files[0], serialized.windows[0].files![0]]
        check(serialized.version == 3, "S3 presentation v3 remains in the existing scoped key")
        check(refs.allSatisfy { $0.input == nil && $0.inputFile != nil }, "S3 draft queue outbound and new-window payloads become sidecar references")
        check(encoded.count < 6000 && !String(decoding: encoded, as: UTF8.self).contains("data:image"), "S3 metadata excludes large inline input bytes")
        check(refs[0].inputFile == refs[2].inputFile && refs[0].inputFile != refs[1].inputFile, "S3 same payload deduplicates while same ID with changed input cannot collide")
        for ref in Set(refs.compactMap(\.inputFile)) {
            check(ref.hasPrefix(probe.files.directory(scope: scope).path + "/"), "S3 path belongs to the injected endpoint directory")
            let mode = try manager.attributesOfItem(atPath: ref)[.posixPermissions] as? NSNumber
            check(mode?.intValue == 0o600, "S3 sidecar mode is 0600")
        }
        for url in [probe.files.root, probe.files.directory(scope: scope).deletingLastPathComponent(), probe.files.directory(scope: scope)] {
            let mode = try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            check(mode?.intValue == 0o700, "S3 private directory mode is 0700")
        }
        let again = ConversationStore(), restored = LocalPresentationState(store: again, scope: scope, storage: metadata, attachmentInputs: CoreFileAttachmentInputs(root: probe.files.root))
        restored.restore(); let chat = again.conversation(c.id)!
        check(chat.draft == c.draft && chat.attachments[0].input == first && chat.attachments[0].name == original.name && chat.attachments[0].mimeType == "image/png", "S3 restart restores exact draft payload metadata and Unicode filename")
        check(chat.queued[0].attachments[0].input == second && chat.queued[0].access == .full && chat.queued[0].waitingForTurnID == "previous", "S3 restart restores queue payload and submission settings")
        check(restored.restoredOutbound(in: chat).first?.id == outbound.id && restored.restoredOutbound(in: chat).first?.attachments[0].input == first && chat.sendOutcomeUnknown, "S3 outbound UUID remains unresolved and restores its original attachment")
        check(restored.restoreAttachments(restored.windows[0].files!)[0].input == windowInput && restored.windows[0].payload["project"] == "project-id", "S3 unsent window attachment hydrates without touching opaque layout payload")
        check(chat.items.isEmpty && !chat.running && chat.approvals.isEmpty, "S3 payload restoration fabricates no backend history or execution")
        let other = LocalPresentationState(store: ConversationStore(), scope: "another-endpoint", storage: metadata, attachmentInputs: probe)
        other.restore(); check(other.store.conversations.isEmpty, "S3 endpoint metadata isolation")
        check(other.restoreAttachments([refs[0]])[0].input == nil && other.lastError != nil, "S3 a foreign endpoint reference is rejected")
        let counts = (probe.persists, probe.reads, probe.removes)
        metadata.writeError = CoreWire.failure("fixture must not write an unchanged snapshot")
        c.items.append(.init(id: "stream", turnID: "turn", kind: .assistant, text: "delta")); try state.save()
        check(counts == (probe.persists, probe.reads, probe.removes) && metadata.values[key] == encoded, "S3 transcript-only delta performs no metadata write or sidecar I/O")
        metadata.writeError = nil

        // Migration uses a v2 inline record; resolving legacy input must not read its untrusted old path.
        let legacy = CoreMemoryStorage(); var old = serialized; old.version = 2
        old.chats[0].files[0].input = first; old.chats[0].files[0].inputFile = "/not-read/foreign-sidecar"
        old.windows = [.init(id: "old-window", payload: ["draft": "legacy"])]
        legacy.values[key] = try JSONEncoder().encode(old)
        let oldStore = ConversationStore(), migration = LocalPresentationState(store: oldStore, scope: scope, storage: legacy, attachmentInputs: probe)
        migration.restore(); check(oldStore.conversation(c.id)?.attachments[0].input == first, "S3 v2 inline payload is still readable without loading an arbitrary path")
        try migration.save()
        let migrated = try JSONDecoder().decode(LocalPresentationState.Saved.self, from: legacy.values[key]!)
        check(migrated.version == 3 && migrated.chats[0].files[0].input == nil && migrated.chats[0].files[0].inputFile == refs[0].inputFile, "S3 first successful save migrates legacy inline bytes")
        check(migration.windows[0].files == nil, "S3 old opaque window records without files remain decodable")

        // A failed metadata commit may create a new sidecar, but can never delete the old committed input.
        c.attachments[0].input = ["type": "text", "text": "changed input"]
        metadata.writeError = CoreWire.failure("fixture metadata failure")
        do { try state.save(); check(false, "S3 metadata failure must throw") } catch { check(state.lastError != nil, "S3 metadata error surfaces") }
        check(metadata.values[key] == encoded && manager.fileExists(atPath: refs[0].inputFile!), "S3 failed commit keeps old metadata and old sidecar intact")
        check(c.attachments[0].input?["text"] == "changed input", "S3 failed save does not clear the editor's payload")
        metadata.writeError = nil; try state.save()
        check(manager.fileExists(atPath: refs[0].inputFile!), "S3 old payload remains referenced by outbound after draft revision")
        c.queued = []; state.clearOutbound(outbound.id, in: c); try state.save()
        check(!manager.fileExists(atPath: refs[0].inputFile!) && !manager.fileExists(atPath: refs[1].inputFile!), "S3 successful removal prunes only payloads no longer referenced anywhere")
        check(manager.fileExists(atPath: refs[3].inputFile!), "S3 unsent window keeps its independent sidecar alive")
        state.setWindows([]); try state.save()
        check(!manager.fileExists(atPath: refs[3].inputFile!), "S3 removing an unsent window releases its last reference")
        c.attachments = [original]; try state.save()
        let recreated = try probe.files.restore(refs[0].inputFile!, scope: scope)
        check(manager.fileExists(atPath: refs[0].inputFile!) && recreated == first, "S3 reattaching a pruned payload recreates it instead of reusing a dead cache entry")
        probe.failWrite = true; c.attachments[0].input = ["type": "text", "text": "unwritten"]
        let beforeFailure = metadata.values
        do { try state.save(); check(false, "S3 payload write failure must throw") } catch { check(metadata.values == beforeFailure, "S3 failed sidecar write cannot commit a dead reference") }
        probe.failWrite = false

        // Missing/corrupt refs remain visible, but queue release cannot pretend the payload was recovered.
        try manager.removeItem(atPath: refs[0].inputFile!)
        let brokenStore = ConversationStore(), broken = LocalPresentationState(store: brokenStore, scope: scope, storage: legacy, attachmentInputs: probe)
        broken.restore(); let brokenChat = brokenStore.conversation(c.id)!
        check(brokenChat.attachments.count == 1 && brokenChat.attachments[0].input == nil && brokenChat.operationError?.contains("attachment") == true, "S3 missing input keeps a removable chip and exposes restoration failure")
        check(broken.restoredOutbound(in: brokenChat).first?.attachments[0].input == nil && brokenChat.sendOutcomeUnknown, "S3 missing outbound data never clears unknown-send protection")
        let queuePath = refs[1].inputFile!
        try Data("damaged".utf8).write(to: URL(fileURLWithPath: queuePath))
        let damagedStore = ConversationStore(), damaged = LocalPresentationState(store: damagedStore, scope: scope, storage: legacy, attachmentInputs: probe)
        damaged.restore(); check(damagedStore.conversation(c.id)?.queued.first?.deliveryError != nil && damaged.lastError != nil, "S3 corrupt queued payload gets a visible delivery error")

        let local = temporary.appendingPathComponent("file with spaces.txt")
        try Data("url fixture".utf8).write(to: local)
        let fallback = Attachment(id: "url", name: "file with spaces.txt", symbol: "doc", url: local, persistedInputPath: "/not-read/outside")
        check(try broken.resolveAttachment(fallback).url == local, "S3 surviving original URL remains available when sidecar is unavailable")
        let outside = temporary.appendingPathComponent("outside.json"), sentinel: JSONValue = ["type": "text", "text": "never overwrite"]
        let bytes = try CoreAttachmentInputEncoding.encode(sentinel); try bytes.write(to: outside)
        let linked = probe.files.directory(scope: scope).appendingPathComponent(CoreAttachmentInputEncoding.digest(bytes) + ".json")
        try manager.createSymbolicLink(at: linked, withDestinationURL: outside)
        do { _ = try probe.files.restore(linked.path, scope: scope); check(false, "S3 file symlink rejected") } catch { check(true, "S3 file symlink rejected") }
        do { _ = try probe.files.persist(sentinel, scope: scope); check(false, "S3 cannot overwrite through file symlink") } catch { check(try Data(contentsOf: outside) == bytes, "S3 symlink target remains intact") }
        let linkedScope = "symlink-scope", linkedDir = probe.files.directory(scope: linkedScope).deletingLastPathComponent()
        try manager.createSymbolicLink(at: linkedDir, withDestinationURL: temporary)
        do { _ = try probe.files.persist(sentinel, scope: linkedScope); check(false, "S3 directory symlink rejected") } catch { check(true, "S3 directory symlink rejected") }
        do { _ = try probe.files.restore(outside.path, scope: scope); check(false, "S3 arbitrary reference rejected") } catch { check(true, "S3 arbitrary reference rejected without reading it") }
        let orphan = try probe.files.persist(["type": "text", "text": "unowned by metadata"], scope: scope)
        check(manager.fileExists(atPath: orphan), "S3 fixture orphan created only under injected temporary root")
        let cleanupStore = ConversationStore(), cleanupMetadata = CoreMemoryStorage()
        let cleanup = LocalPresentationState(store: cleanupStore, scope: "cleanup", storage: cleanupMetadata, attachmentInputs: probe)
        let retired = Conversation(id: "retired", title: "Retired"); cleanupStore.add(retired)
        let cleanupInput: JSONValue = ["type": "text", "text": "retry cleanup"]
        retired.attachments = [.init(id: "retired-file", name: "retired.txt", symbol: "doc", input: cleanupInput)]
        try cleanup.save()
        let retiredPath = try probe.files.persist(cleanupInput, scope: "cleanup")
        probe.failRemove = true; retired.attachments = []; try cleanup.save()
        check(cleanup.lastError != nil && manager.fileExists(atPath: retiredPath), "S3 cleanup failure leaves committed metadata valid and old file intact")
        probe.failRemove = false; try cleanup.save()
        check(cleanup.lastError == nil && !manager.fileExists(atPath: retiredPath), "S3 unchanged snapshot retries deferred cleanup and clears its notice")
        let abandoned: JSONValue = ["type": "text", "text": "prepared then abandoned"]
        retired.attachments = [.init(id: "abandoned", name: "abandoned.txt", symbol: "doc", input: abandoned)]
        cleanupMetadata.writeError = CoreWire.failure("fixture commit rejected")
        do { try cleanup.save(); check(false, "S3 abandoned prepare must fail commit") } catch { check(true, "S3 abandoned prepare fails commit") }
        let abandonedPath = try probe.files.persist(abandoned, scope: "cleanup")
        cleanupMetadata.writeError = nil; retired.attachments = []; try cleanup.save()
        check(!manager.fileExists(atPath: abandonedPath) && cleanup.lastError == nil, "S3 reverting a failed save removes this instance's uncommitted prepared input")
        check(manager.fileExists(atPath: orphan), "S3 cleanup never sweeps unknown files or another instance's uncommitted work")
        check(probe.files.root.path.hasPrefix(temporary.resolvingSymlinksInPath().path), "S3 all filesystem cases stay inside the injected temporary root")
    }
}
#endif
