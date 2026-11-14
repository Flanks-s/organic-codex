import AppKit

/// A streamed Earth-only presentation. The owner supplies event time and finite sampling.
/// Static output is admitted first, so refusing the extra animation lease can still show the endpoint.
@MainActor final class BrowserEarthPresentation {
    let resources: BodyResources
    private(set) var motion: BrowserEarthMotion
    let outer: Float, scale: Int
    var lightDegrees: Float
    var reduceMotion: Bool
    var utcOffsetSeconds: Int
    private var renderer: BodyRenderer?
    private var maps: BodyPreparedMaps?
    private var staticLease: UUID?, animationLease: UUID?
    private var waiter: CheckedContinuation<Void, Never>?
    private var retirement: Task<Void, Never>?
    private var lastPose: BodyEarthPose?
    private var lastLightDegrees: Float?
    private var disposed = false
    private var lastTime = 0.0
    private(set) var image: CGImage?
    private(set) var lastRaster: BodyRaster?
    private(set) var framesGenerated = 0
    private(set) var animatedFrames = 0
    private(set) var refusedAnimations = 0
    private(set) var lastGenerationSeconds = 0.0
    private(set) var reservedBytes = 0
    var generatedOffMain: Bool { renderer?.lastCPUWasOffMain ?? false }
    var cpuJobs: Int { renderer?.cpuJobs ?? 0 }
    var gpuSubmissions: Int { renderer?.metalSubmissions ?? 0 }
    var hasPendingWork: Bool { waiter != nil || renderer?.hasPendingWork == true || retirement != nil }
    var needsSample: Bool { motion.isActive }
    init(resources: BodyResources, outer: Float, scale: Int, reduceMotion: Bool, utcOffsetSeconds: Int, lightDegrees: Float = 180) {
        self.resources = resources; self.outer = outer; self.scale = scale
        self.reduceMotion = reduceMotion; self.utcOffsetSeconds = utcOffsetSeconds; self.lightDegrees = lightDegrees
        motion = .init(initialTurn: resources.catalogue?.bodies.first(where: { $0.id == "earth" })?.initialTurn ?? 0.62)
    }
    func prepare() async throws {
        guard !disposed, renderer == nil, [32, 56].contains(outer), [1, 2].contains(scale), let queue = resources.queue else { throw BodyError.invalid("Invalid Earth presentation") }
        let maps = try await queue.prepare("earth", maximumWidth: 512)
        try Task.checkCancellation()
        guard !disposed else { return }
        let side = Int(outer)*scale
        let bytes = maps.map.byteCount + (maps.clouds?.byteCount ?? 0) + side*side*16
        guard let lease = resources.reserveHD(bytes: bytes) else { throw BodyError.invalid("Earth static endpoint exceeds shared reservation") }
        staticLease = lease; reservedBytes = bytes; self.maps = maps
        let renderer = BodyRenderer(compiler: resources.compiler)
        renderer.onFrame = { [weak self] frame in
            guard let self, !self.disposed else { return }
            if case .cpu(let raster) = frame.storage { self.lastRaster = raster; self.image = try? raster.image(); self.framesGenerated += 1 }
            self.waiter?.resume(); self.waiter = nil
        }
        self.renderer = renderer
    }
    func receive(_ event: BrowserHomeEvent, at time: Double) {
        guard !disposed, renderer != nil else { return }
        let old = motion.acceptedEvents
        motion.receive(event, at: max(lastTime, time), utcOffsetSeconds: utcOffsetSeconds, reduceMotion: reduceMotion)
        guard motion.acceptedEvents != old, motion.isActive else { return }
        if animationLease == nil {
            let bytes = Int(outer)*scale*Int(outer)*scale*8
            if let lease = resources.reserveHD(bytes: bytes) { animationLease = lease; reservedBytes += bytes }
            else { refusedAnimations += 1; motion.finish() }
        }
    }
    func sample(at time: Double) async throws {
        guard !disposed, waiter == nil, time.isFinite, time >= lastTime else { return }
        if reduceMotion { motion.freeze(at: lastTime) } else { motion.sample(at: time) }
        lastTime = time
        if !motion.isActive, let animationLease {
            resources.releaseHD(animationLease); self.animationLease = nil
            reservedBytes -= Int(outer)*scale*Int(outer)*scale*8
        }
        guard let pose = motion.pose, pose != lastPose || lightDegrees != lastLightDegrees, let maps, let renderer else { return }
        let began = ContinuousClock.now
        let request = BodyRenderRequest(outer: outer, scale: scale, lightDegrees: lightDegrees, pose: pose)
        await withCheckedContinuation { continuation in
            waiter = continuation
            do { try renderer.update(body: maps.body, map: maps.map, clouds: maps.clouds, request: request, activity: .init()) }
            catch { waiter?.resume(); waiter = nil }
        }
        guard !disposed else { return }
        let duration = began.duration(to: .now).components
        lastGenerationSeconds = Double(duration.seconds) + Double(duration.attoseconds)/1e18
        lastPose = pose; lastLightDegrees = lightDegrees
        if motion.isActive { animatedFrames += 1 }
        if !motion.isActive, let animationLease { resources.releaseHD(animationLease); self.animationLease = nil; reservedBytes -= Int(outer)*scale*Int(outer)*scale*8 }
    }
    /// Freeze at an explicitly supplied instant, retaining a static image and no sampling deadline.
    func freeze(at time: Double) async throws {
        motion.freeze(at: max(lastTime, time))
        try await sample(at: max(lastTime, time))
    }
    func cancel() {
        guard !disposed else { return }; disposed = true; motion.freeze(at: lastTime)
        waiter?.resume(); waiter = nil
        let task = renderer?.retire(), resources = resources, a = staticLease, b = animationLease
        renderer = nil; maps = nil; image = nil; lastRaster = nil; staticLease = nil; animationLease = nil
        retirement = Task { @MainActor [weak self] in
            await task?.value
            if let a { resources.releaseHD(a) }; if let b { resources.releaseHD(b) }
            self?.reservedBytes = 0; self?.retirement = nil
        }
    }
    func dispose() async { cancel(); await retirement?.value; retirement = nil }
    isolated deinit { cancel() }
}
