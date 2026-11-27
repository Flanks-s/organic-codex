import AppKit
import QuartzCore

/// A mock-host producer. Views receive immutable images and never reach into this owner.
@MainActor final class FunctionPanelBodyOwner {
    let resources: BodyResources
    private let hd: BodyPhasePresentation
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var spriteJobs: [String: UUID] = [:]
    private var pictures: [String: FunctionPanelPicture] = [:]
    private var wanted: Set<String> = []
    private var retryID: UUID?
    private var input: FunctionPanelPhaseInput?
    private var generation = 0
    private var closed = true
    private var preview: FunctionPanelPicture?
    private var previewLease: UUID?
    private var high: FunctionPanelPicture?
    private(set) var loading: FunctionPanelPhaseLoading = .unloaded
    private(set) var requestCounts: [String: Int] = [:]
    private(set) var publicationCount = 0
    private(set) var rejectedFrames = 0
    private(set) var peakHD = 0
    private(set) var peakMap = 0
    private(set) var timings: [String: Double] = [:]
    private var began = 0.0
    var imageDelay: Duration = .zero
    var receive: (FunctionPanelBodySnapshot) -> Void = { _ in }
    var pendingImages: Int { jobs.count }
    var phaseWork: [String: Int] { hd.work }
    var hasPendingWork: Bool { !jobs.isEmpty || hd.work["pending"] == 1 }
    var currentPicture: FunctionPanelPicture? { high ?? preview }
    var requestTime: Double { began }
    static let maximumPrefetch = 0

    init(resources: BodyResources) {
        self.resources = resources; hd = BodyPhasePresentation(resources: resources)
        hd.onPictureChange = { [weak self] _ in self?.acceptHD() }
    }
    func present(_ next: FunctionPanelPhaseInput, candidates: [String], currentEntry: Bool = true) {
        let changed = input != next || closed
        if changed {
            let replace = closed || input?.bodyID != next.bodyID || input?.scale != next.scale || input?.turnID !=
                next.turnID || input?.event.sourceID != next.event.sourceID || input?.quality != next.quality
            cancelImages(); if replace { hd.dispose() }; generation += 1; closed = false
            input = next; preview = nil; high = nil; pictures = [:]; spriteJobs = [:]; wanted = []; retryID = nil
            if let previewLease { resources.sprites.releaseWorkingBytes(previewLease); self.previewLease = nil }
            began = CACurrentMediaTime(); timings = [:]; loading = .loading
            startPreview(next, generation: generation)
            if next.quality == .panelHD { requestHD() }
        }
        var desired = Set(candidates.map { FunctionPanelBodySnapshot.key($0, outer: 22) })
        if currentEntry { desired.insert(FunctionPanelBodySnapshot.key(next.bodyID, outer: 26)) }
        if !changed && wanted == desired { return }
        if wanted != desired {
            wanted = desired
            for (key, id) in Array(spriteJobs) where !desired.contains(key) {
                jobs[id]?.cancel()
                spriteJobs[key] = nil
            }
            for key in desired where pictures[key] == nil && spriteJobs[key] == nil { startSprite(key, input: next) }
        }
        publish()
    }
    /// Budget changes are explicit host events; there is no budget-polling timer.
    func retryVisibleHD() { guard !closed, high == nil, input?.quality == .panelHD else { return }; requestHD() }
    private func requestHD() {
        guard let input, !closed else { return }
        let refusedBefore = hd.work["refused", default: 0]
        hd.configure(event: input.event, bodyID: input.bodyID, outer: 150, scale: input.scale, bin: input.bin,
                     animate: input.animate, quality: .panelHD, targetOuter: 150, turnID: input.turnID)
        peakHD = max(peakHD, resources.hdReservedBytes)
        if hd.work["refused", default: 0] > refusedBefore && hd.image == nil { loading = .budgetRefused }
        else if high == nil && loading == .budgetRefused { loading = preview == nil ? .loading : .preview }
        if loading == .budgetRefused && retryID == nil { retryBudget() }
    }
    private func retryBudget() {
        let id = UUID(), generation = generation
        retryID = id
        jobs[id] = Task { [weak self] in
            defer { self?.jobs[id] = nil; if self?.retryID == id { self?.retryID = nil } }
            for seconds in [0.05, 0.15, 0.4] {
                do { try await Task.sleep(for: .seconds(seconds)); try Task.checkCancellation() } catch { return }
                guard let self, !self.closed, self.generation == generation, self.high == nil else { return }
                self.requestHD()
            }
        }
    }
    private func acceptHD() {
        guard !closed, let input, input.quality == .panelHD, let frame = hd.panelFrame else { return }
        guard frame.event == input.event, frame.turnID == input.turnID else { rejectedFrames += 1; return }
        peakMap = max(peakMap, frame.mapCacheBytes)
        high = FunctionPanelPicture(image: frame.image, quality: .panelHD, bodyID: input.bodyID,
                                    event: frame.event, turnID: frame.turnID, nativeOuter: Int(frame.outer),
                                        scale: frame.scale)
        preview = nil
        if let previewLease { resources.sprites.releaseWorkingBytes(previewLease); self.previewLease = nil }
        if let retryID { jobs[retryID]?.cancel() }
        loading = .ready; timings["firstHD"] = timings["firstHD"] ?? (CACurrentMediaTime() - began)
        publish()
    }
    private func startSprite(_ key: String, input: FunctionPanelPhaseInput) {
        let parts = key.split(separator: ":"), body = String(parts[0]), outer = Int(parts[1])!
        let id = UUID(), generation = generation, delay = imageDelay
        spriteJobs[key] = id
        jobs[id] = Task { [weak self] in
            defer {
                self?.jobs[id] = nil
                if self?.spriteJobs[key] == id { self?.spriteJobs[key] = nil }
            }
            do { try await Task.sleep(for: delay); try Task.checkCancellation() } catch { return }
            guard let self, !self.closed, self.generation == generation, self.wanted.contains(key) else { return }
            self.requestCounts[key, default: 0] += 1
            guard let image = self.resources.image(bodyID: body, outer: CGFloat(outer), scale: input.scale,
                                                  degrees: Float(input.bin) * 360 / 32) else { return }
            self.pictures[key] = .init(image: image, quality: .identity, bodyID: body, event: nil,
                                       turnID: nil, nativeOuter: outer, scale: input.scale)
            self.timings["firstTexture"] = self.timings["firstTexture"] ?? (CACurrentMediaTime() - self.began)
            self.publish()
        }
    }
    private func startPreview(_ input: FunctionPanelPhaseInput, generation: Int) {
        guard let queue = resources.queue else { loading = .failed; return }
        let side = 56 * input.scale
        let bytes = 3 * 512 * 512 * 4 + BodyPhaseLighting.workspaceBytes + side * side * 4 * 3
        guard let lease = resources.sprites.reserveWorkingBytes(bytes) else { loading = .failed; return }
        let id = UUID(), resources = resources
        jobs[id] = Task { [weak self] in
            var retained = false
            defer { if !retained { resources.sprites.releaseWorkingBytes(lease) }; self?.jobs[id] = nil }
            do {
                let maps = try await queue.prepare(input.bodyID, maximumWidth: 512)
                self?.peakMap = max(self?.peakMap ?? 0, maps.cacheBytes)
                try Task.checkCancellation()
                let worker = Task.detached(priority: .utility) { () -> CGImage? in
                    var request = BodyRenderRequest(outer: 56, scale: input.scale,
                                                    lightDegrees: Float(input.bin) * 360 / 32,
                                                        phase: input.event.value.terminal())
                    request.phaseLighting = .prepare(body: maps.body, map: maps.map, ring: maps.ring,
                        clouds: maps.clouds, request: request)
                    let raster = BodyRasterizer.render(body: maps.body, map: maps.map, ring: maps.ring,
                        clouds: maps.clouds,
                                                       request: request, isCancelled: { Task.isCancelled })
                    guard !Task.isCancelled else { return nil }; return try? raster.image()
                }
                let image = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, !self.closed, self.generation == generation, self.high == nil, let image else { return }
                self.previewLease = lease; retained = true
                self.preview = .init(image: image, quality: .preview, bodyID: input.bodyID, event: input.event,
                                      turnID: input.turnID, nativeOuter: 56, scale: input.scale)
                if self.high == nil && self.loading != .budgetRefused { self.loading = .preview }
                self.timings["firstPreview"] = CACurrentMediaTime() - self.began
                self.publish()
            } catch {
                if let self, self.generation == generation, !self.closed {
                    self.loading = .failed
                    self.publish()
                }
            }
        }
    }
    private func cancelImages() {
        for task in jobs.values { task.cancel() }
    }
    private func publish() {
        guard !closed else { return }
        publicationCount += 1
        receive(.init(entries: pictures.filter { wanted.contains($0.key) }, planet: high ?? preview,
                      loading: loading == .budgetRefused ? "Preview · HD budget unavailable" : nil,
                      phaseLoading: loading))
    }
    func close() {
        closed = true; generation += 1; cancelImages(); hd.dispose()
        wanted = []; spriteJobs = [:]; pictures = [:]; preview = nil; high = nil; loading = .unloaded
        receive(.empty)
        if let previewLease { resources.sprites.releaseWorkingBytes(previewLease); self.previewLease = nil }
    }
    isolated deinit {
        for task in jobs.values { task.cancel() }
        hd.dispose()
        if let previewLease { resources.sprites.releaseWorkingBytes(previewLease) }
    }
}
