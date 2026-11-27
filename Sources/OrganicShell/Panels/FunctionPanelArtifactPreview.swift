import AppKit
import ImageIO

enum FunctionPanelArtifactPreview: Equatable, @unchecked Sendable {
    case text(String), raster(CGImage)
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): a == b
        case (.raster(let a), .raster(let b)): a === b
        default: false
        }
    }
    static func supports(_ mime: String) -> Bool {
        mime.hasPrefix("image/") || mime.hasPrefix("text/") ||
            ["application/pdf", "application/json", "application/xml", "application/javascript"].contains(mime)
    }
    static func decode(_ data: Data, mime: String) throws -> Self {
        if mime.hasPrefix("image/") {
            let options: [String: Any] = [kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: 520]
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw CoreWire.failure("The image could not be decoded.")
            }
            return .raster(image)
        }
        if mime == "application/pdf" {
            let rect = CGRect(x: 0, y: 0, width: 520, height: 520)
            guard let provider = CGDataProvider(data: data as CFData), let page = CGPDFDocument(provider)?.page(at: 1),
                  let context = CGContext(data: nil, width: 520, height: 520, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else {
                throw CoreWire.failure("The PDF first page is unavailable.")
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { throw CoreWire.failure("The PDF first page is unavailable.") }
            return .raster(image)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return .text(text)
    }
}

/// A page lease owns the list, visible content and action receipts. All host capabilities are injected.
@MainActor final class FunctionPanelArtifactPreviewOwner {
    typealias Scope = CoreArtifactsController.ArtifactScope
    let controller: CoreArtifactsController
    let endpoint: () -> String
    let current: () -> Conversation?
    let connected: () -> Bool
    let id = UUID().uuidString
    var open: ((URL) throws -> Void)?
    var copy: ((Data, String) throws -> Void)?
    var changed: () -> Void = {}
    var feedback: String?
    private(set) var revision = 0
    private(set) var listing: FunctionPanelValue<[CoreArtifact]> = .unloaded
    private(set) var previews: [String: FunctionPanelValue<FunctionPanelArtifactPreview>] = [:]
    private var payloads: [String: Data] = [:]
    private var read: Task<Void, Never>?
    private var jobs: [String: Task<Void, Never>] = [:]
    private var opening: Task<Void, Never>?
    private var scope: Scope?
    private weak var conversation: Conversation?
    private var visible: Set<String> = []
    private var generation = 0
    init(controller: CoreArtifactsController, endpoint: @escaping () -> String,
         current: @escaping () -> Conversation?, connected: @escaping () -> Bool) {
        self.controller = controller
        self.endpoint = endpoint
        self.current = current
        self.connected = connected
    }
    func load(_ target: Conversation, page: FunctionPanelPage, mapped: [String: String]) {
        guard [.library, .files, .outputs].contains(page), let thread = target.backendThreadID, !thread.isEmpty else {
            stop()
            return
        }
        let scope = Scope(thread: thread, endpoint: endpoint(), mapped: Set(mapped.filter { $0.value == thread }.keys))
        if scope == self.scope, conversation === target, connected() {
            if case .loading = listing { return }
            if case .known = listing { return }
        }
        stop()
        self.scope = scope
        conversation = target
        guard connected() else { return }
        listing = .loading
        let ticket = generation
        read = Task { [weak self, controller] in
            let result = await controller.readArtifacts(scope)
            guard let self, self.accepts(ticket) else { return }
            switch result {
            case .empty: listing = .known([])
            case .content(let rows): listing = .known(rows)
            case .failed(let error): listing = .failed(error.localizedDescription)
            default: return
            }
            revision += 1
            changed()
        }
    }
    private func accepts(_ ticket: Int) -> Bool {
        ticket == generation && !Task.isCancelled && matchesTarget && connected()
    }
    private func acceptsPreview(_ ticket: Int, _ id: String) -> Bool {
        if accepts(ticket) && visible.contains(id) { return true }
        if !Task.isCancelled && ticket == generation { jobs[id] = nil }
        return false
    }
    private var matchesTarget: Bool {
        guard let conversation, let scope else { return false }
        return current() === conversation && conversation.backendThreadID == scope.thread &&
            endpoint() == scope.endpoint
    }
    func show(_ ids: Set<String>) {
        guard ids != visible, let scope else { return }
        visible = ids
        for id in Set(previews.keys).subtracting(ids) {
            jobs.removeValue(forKey: id)?.cancel()
            previews[id] = nil
            payloads[id] = nil
        }
        let ticket = generation
        for artifact in listing.value ?? [] where ids.contains(artifact.id) && previews[artifact.id] == nil {
            guard FunctionPanelArtifactPreview.supports(artifact.mime), !artifact.previewUnavailable else { continue }
            let id = artifact.id
            previews[id] = .loading
            jobs[id] = Task { [weak self, controller] in
                let result = await controller.readArtifact(.init(scope: scope, artifact: artifact))
                guard let self, acceptsPreview(ticket, id) else { return }
                let decoded: Result<FunctionPanelArtifactPreview, Error>?
                if case .content(let bytes) = result {
                    decoded = await Task.detached(priority: .userInitiated) {
                        Result { try FunctionPanelArtifactPreview.decode(bytes, mime: artifact.mime) }
                    }.value
                } else { decoded = nil }
                guard acceptsPreview(ticket, id) else { return }
                jobs[id] = nil
                do {
                    switch result {
                    case .content(let bytes):
                        previews[id] = .known(try decoded!.get())
                        payloads[id] = bytes
                    case .empty: previews[id] = .known(.text("Empty artifact"))
                    case .failed(let error): throw error
                    default: return
                    }
                } catch { previews[id] = .failed(error.localizedDescription) }
                changed()
            }
        }
    }
    private func row(_ id: String, file: Bool) -> CoreArtifact? {
        let rows = listing.value ?? []
        guard file else { return rows.first { $0.id == id } }
        let matches = rows.filter { $0.path == id || $0.raw["sourcePath"]?.stringValue == id }
        return matches.count == 1 ? matches[0] : nil
    }
    func capabilities(_ input: FunctionPanelInput) -> FunctionPanelMaterials {
        var value = FunctionPanelMaterials(previews: previews)
        guard connected(), matchesTarget else { return value }
        if open != nil, controller.localPathsAvailable {
            value.openIDs = Set((listing.value ?? []).filter { $0.path.hasPrefix("/") && !$0.sha.isEmpty }.map(\.id))
            value.fileIDs = Set((input.files.value ?? []).filter {
                row($0.id, file: true).map { value.openIDs.contains($0.id) } == true
            }.map(\.id))
        }
        if copy != nil { value.copyIDs = Set(payloads.keys).union(diffs(input).map(\.id)) }
        return value
    }
    func submit(_ action: FunctionPanelAction, input: FunctionPanelInput) -> Bool {
        let request: (id: String, file: Bool, copies: Bool)
        switch action {
        case .openCover(let id), .openOutput(let id): request = (id, false, false)
        case .openFile(let id): request = (id, true, false)
        case .copyCover(let id), .copyOutput(let id): request = (id, false, true)
        default: return false
        }
        do {
            try qualify()
            if request.copies {
                guard let copy else { throw CoreWire.failure("Copy is no longer available.") }
                if let diff = diffs(input).first(where: { $0.id == request.id }) {
                    try copy(Data(diff.content.utf8), "text/plain")
                } else {
                    guard let artifact = row(request.id, file: false), let bytes = payloads[artifact.id] else {
                        throw CoreWire.failure("This artifact content is not loaded.")
                    }
                    try copy(bytes, artifact.mime)
                }
                feedback = "Copied artifact"
            } else {
                guard let scope, let artifact = row(request.id, file: request.file),
                      open != nil, controller.localPathsAvailable, opening == nil else {
                    throw CoreWire.failure("Open is not available.")
                }
                let ticket = generation
                opening = Task { [weak self, controller] in
                    do {
                        let url = try await controller.artifactURL(.init(scope: scope, artifact: artifact))
                        guard let self, generation == ticket else { return }
                        try qualify()
                        guard let open else { throw CoreWire.failure("Open is no longer available.") }
                        try open(url)
                        finish("Opened artifact", ticket)
                    } catch { self?.finish(error.localizedDescription, ticket) }
                }
                return true
            }
        } catch { feedback = error.localizedDescription }
        changed()
        return true
    }
    private func qualify() throws {
        guard matchesTarget else { throw CoreWire.failure("The conversation or artifact source changed.") }
        guard connected() else { throw CoreWire.failure("Disconnected. Reconnect before submitting.") }
    }
    private func diffs(_ input: FunctionPanelInput) -> [FunctionPanelOutput] {
        (input.outputs.value ?? []).filter { $0.id.hasPrefix("diff:") }
    }
    private func finish(_ message: String, _ ticket: Int) {
        guard generation == ticket else { return }
        opening = nil
        feedback = message
        changed()
    }
    func stop() {
        generation += 1
        revision += 1
        read?.cancel()
        read = nil
        opening?.cancel()
        opening = nil
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        scope = nil
        conversation = nil
        visible = []
        listing = .unloaded
        previews.removeAll()
        payloads.removeAll()
        feedback = nil
    }
}
