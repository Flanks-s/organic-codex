import AppKit

/// Host-size changes share one finite Earth trajectory and one admitted renderer, never a frame bank.
@MainActor final class BrowserHostEarth {
    let resources: BodyResources
    private var maps: BodyPreparedMaps?
    private var renderer: BodyRenderer?
    private var lease: UUID?
    private var animationLease: UUID?
    private var motion: BrowserEarthMotion
    private var previous: BodyRenderRequest?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var image: CGImage?
    private(set) var reservedBytes = 0
    private(set) var disposed = false
    private(set) var generated = 0
    private(set) var refused = 0
    var needsSample: Bool { motion.isActive }
    var hasPendingWork: Bool { waiter != nil || renderer?.hasPendingWork == true }
    var cpuJobs: Int { renderer?.cpuJobs ?? 0 }
    var generatedOffMain: Bool {renderer?.lastCPUWasOffMain ?? false}
    var gpuSubmissions: Int { renderer?.metalSubmissions ?? 0 }
    var pose: BodyEarthPose? { motion.pose }
    init(resources: BodyResources, retainedMotion: BrowserEarthMotion? = nil) {
        self.resources = resources
        motion = retainedMotion ?? .init(initialTurn: resources.catalogue?.bodies.first(where: { $0.id == "earth" })?.initialTurn ?? 0.62)
    }
    func frozenMotion(at time: Double) -> BrowserEarthMotion {var result=motion;result.freeze(at:time);return result}
    func adoptHomeSnapshot(_ event:BrowserHomeEvent,at time:Double,reduced:Bool,utcOffset:Int) {
        motion.receive(event,at:time,utcOffsetSeconds:utcOffset,reduceMotion:reduced);motion.finish()
    }
    func prepare(scale: Int) async throws {
        guard let queue = resources.queue else { throw BodyError.invalid("Browser Earth resource queue unavailable") }
        let maps = try await queue.prepare("earth", maximumWidth: 512)
        try Task.checkCancellation()
        guard !disposed else { return }
        let bytes = maps.map.byteCount + (maps.clouds?.byteCount ?? 0) + 112*112*16
        guard let lease = resources.reserveHD(bytes: bytes) else {
            refused += 1; throw BodyError.invalid("Browser Earth endpoint exceeds shared budget")
        }
        self.lease = lease; reservedBytes = bytes; self.maps = maps
        let renderer = BodyRenderer(compiler: resources.compiler)
        renderer.onFrame = { [weak self] frame in
            guard let self, !self.disposed else { return }
            if case .cpu(let raster) = frame.storage { self.image = try? raster.image(); self.generated += 1 }
            self.waiter?.resume(); self.waiter = nil
        }
        self.renderer = renderer
    }
    func receive(_ event: BrowserHomeEvent, at time: Double, reduced: Bool, utcOffset: Int) {
        guard !disposed else { return }
        motion.receive(event, at: time, utcOffsetSeconds: utcOffset, reduceMotion: reduced)
        if motion.isActive, animationLease == nil {
            if let lease=resources.reserveHD(bytes:112*112*8) {animationLease=lease;reservedBytes += 112*112*8}
            else {refused += 1;motion.finish()}
        }
    }
    func needsRender(outer: Float, scale: Int, light: Float) -> Bool {
        previous != BodyRenderRequest(outer: outer, scale: scale, lightDegrees: light, pose: motion.pose)
    }
    func sample(at time: Double, outer: Float, scale: Int, light: Float, reduced: Bool) async throws {
        guard !disposed, waiter == nil, let renderer, let maps else { return }
        if reduced { motion.freeze(at: time) } else { motion.sample(at: time) }
        if !motion.isActive,let animationLease {
            resources.releaseHD(animationLease);self.animationLease=nil;reservedBytes -= 112*112*8
        }
        let request = BodyRenderRequest(outer: outer, scale: scale, lightDegrees: light, pose: motion.pose)
        guard previous != request else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
            do { try renderer.update(body: maps.body, map: maps.map, clouds: maps.clouds, request: request, activity: .init()) }
            catch { waiter?.resume(); waiter = nil }
        }
        guard !disposed else { return }; previous = request
    }
    func dispose() async {
        guard !disposed else { return }; disposed = true
        waiter?.resume(); waiter = nil
        let task = renderer?.retire(); renderer = nil
        await task?.value
        if let animationLease {resources.releaseHD(animationLease)};animationLease=nil
        if let lease { resources.releaseHD(lease) }; lease = nil; reservedBytes = 0; maps = nil; image = nil
    }
}
