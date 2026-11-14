import AppKit
import QuartzCore
import Metal

/// One streamed frame per semantic geometry, shared by all matching endpoints.
/// The task exists only while an event has an unfinished finite envelope.
@MainActor final class BodyPhaseStream {
    struct Geometry: Hashable {
        let bodyID: String
        let outer: Float
        let scale: Int
        let bin: Int
        let bare: Bool
        var terminal=false
        var samplingOuter:Float?=nil
        var rasterOuter:Float {samplingOuter ?? outer}
    }
    private final class WeakStream { weak var value:BodyPhaseStream?; init(_ value:BodyPhaseStream){self.value=value} }
    private static var streams:[String:WeakStream]=[:]
    private static var inFlight=0
    static let maximumConcurrentJobs=4
    static var activeJobs:Int {inFlight}
    nonisolated private static func workerIsOffMainThread()->Bool {!Thread.isMainThread}
    static func samplingRate(outer:Float,active:Int)->Double {
        let base=outer<=36 ? 30.0:60.0
        let pressure=active<=4 ? 1.0:active<=8 ? 1.5:3.0
        return base/pressure
    }
    static func acquire(event:BodyPhaseEvent,geometry:Geometry,resources:BodyResources)->BodyPhaseStream {
        let key="\(ObjectIdentifier(resources))|\(event.sourceID)|\(geometry)"
        streams=streams.filter{$0.value.value != nil}
        let stream=streams[key]?.value ?? BodyPhaseStream(event:event,geometry:geometry,resources:resources)
        streams[key]=WeakStream(stream); return stream
    }
    let geometry:Geometry
    let playback:BodyPhasePlayback
    private let resources:BodyResources
    private var renderer:BodyRenderer?
    private var maps:BodyPreparedMaps?
    private var lease:UUID?
    private var atlasLease=false
    private var forceTerminal=false
    private var retiring=false
    private var deadlineRetirement:Task<Void,Never>?
    private var phaseObservation:UUID?
    private var preparation:Task<Void,Never>?
    private var driver:Task<Void,Never>?
    private var referenceTask:Task<Void,Never>?
    private var terminalRaster:BodyRaster?
    private var terminalImage:CGImage?
    private var imageTask:Task<Void,Never>?
    private var lightingTask:Task<Void,Never>?
    private var terminalBloodLift:Float=0
    private var referenceRenderSeconds=0.0
    private(set) var gpuSubmissions=0
    private var referenceTarget:BodyPhaseSample?
    private var settledEvent:BodyPhaseEvent?
    private var generation=0
    private var listeners:[UUID:(CGImage)->Void]=[:]
    private var active:Set<UUID>=[]
    private var terminalOnly:Set<UUID>=[]
    private var lastSample:BodyPhaseSample?
    private var submittedAt=0.0
    private var submittedEvent:BodyPhaseEvent?
    private var ownsSlot=false
    private(set) var image:CGImage?
    private(set) var cpuJobs=0
    private(set) var imageChanges=0
    private(set) var refused=0
    private(set) var renderSeconds=0.0
    private(set) var lastCPUWasOffMain=false
    var hasPendingWork:Bool { retiring || driver != nil || preparation != nil || referenceTask != nil || imageTask != nil || lightingTask != nil || renderer?.hasPendingWork == true }
    private init(event:BodyPhaseEvent,geometry:Geometry,resources:BodyResources) {
        self.geometry=geometry; self.resources=resources
        playback=BodyPhasePlaybackRegistry.shared.resolve(event)
        phaseObservation=playback.observe { [weak self] in
            guard let self,!self.active.isEmpty else {return}
            self.prepareIfNeeded();self.startIfNeeded()
        }
    }
    func attach(_ receive:@escaping(CGImage)->Void)->UUID {
        let id=UUID();listeners[id]=receive
        if let image {receive(image)}
        return id
    }
    func setActivity(_ id:UUID,visible:Bool,animate:Bool,event:BodyPhaseEvent) {
        playback.update(event,at:CACurrentMediaTime())
        if visible {active.insert(id)} else {active.remove(id)}
        if animate {terminalOnly.remove(id)} else {terminalOnly.insert(id)}
        if active.isEmpty { suspend(); return }
        prepareIfNeeded()
        startIfNeeded()
    }
    func detach(_ id:UUID) {
        listeners[id]=nil;active.remove(id);terminalOnly.remove(id)
        if active.isEmpty {suspend(releaseImage:listeners.isEmpty)}
    }
    private func prepareIfNeeded() {
        guard !retiring,maps == nil,preparation == nil,let queue=resources.queue,
              let body=try? resources.catalogue?.body(geometry.bodyID) else { return }
        let side=Int((geometry.rasterOuter*Float(geometry.scale)).rounded())
        let gpuBudget=geometry.rasterOuter>56 ? 2*1024*1024:0
        let bytes=512*512*4*(1+(body.ring ? 1:0)+(body.clouds == nil ? 0:1))+BodyPhaseLighting.workspaceBytes+side*side*4*7+gpuBudget
        if lease != nil {}
        else if let lease=resources.reserveHD(bytes:bytes) {self.lease=lease;atlasLease=false}
        else {
            refused+=1;forceTerminal=true
            guard let lease=resources.sprites.reserveWorkingBytes(bytes) else {return}
            self.lease=lease;atlasLease=true
        }
        let generation=generation
        preparation=Task { [weak self] in
            do {
                let prepared=try await queue.prepare(body.id,maximumWidth:512)
                try Task.checkCancellation()
                guard let self,self.generation == generation else {return}
                self.maps=prepared;self.preparation=nil
                let renderer=BodyRenderer(compiler:self.resources.compiler,metalBudget:gpuBudget>0 ? gpuBudget:bytes)
                renderer.requiresPresentationAcknowledgement=true
                renderer.onFrame={ [weak self] frame in self?.receive(frame) }
                renderer.workSubmitted={ [weak self] counter in
                    if counter == "gpuSubmissions" {self?.gpuSubmissions += 1} else {self?.cpuJobs += 1}
                }
                self.renderer=renderer;self.startIfNeeded()
            } catch { if let self,self.generation == generation {self.preparation=nil;self.releaseReservation()} }
        }
    }
    private func startIfNeeded() {
        guard driver == nil,maps != nil,!active.isEmpty else {return}
        let terminal=forceTerminal || active.isSubset(of:terminalOnly)
        let now=CACurrentMediaTime(),sample=playback.sample(at:now,reduceMotion:terminal).sample
        if settledEvent == playback.event {return}
        if settledEvent?.value == playback.event.value,playback.event.value.state != .unknown {settledEvent=playback.event;return}
        if lastSample == sample,playback.finished(at:now) || terminal {return}
        let generation=generation
        driver=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.generation == generation,!self.active.isEmpty else {return}
                let now=CACurrentMediaTime(),terminal=self.forceTerminal || self.active.isSubset(of:self.terminalOnly)
                let finished=terminal || self.playback.finished(at:now)
                if now>self.playback.began+self.playback.duration+2 {
                    self.refused+=1;self.stopAtDeadline();return
                }
                let sample=self.playback.sample(at:now,reduceMotion:terminal).sample
                let target=self.playback.event.value.terminal()
                if self.renderer?.hasPendingWork != true,self.referenceTask == nil,self.imageTask == nil,self.lightingTask == nil,Self.inFlight<Self.maximumConcurrentJobs {
                    if self.referenceTarget != target {self.prepareReference(target)}
                    else if finished,let raster=self.terminalRaster,let image=self.terminalImage {
                        self.install(raster:raster,image:image,sample:target,generationSeconds:self.referenceRenderSeconds)
                        self.settledEvent=self.playback.event
                    } else {self.submit(sample)}
                }
                if (finished && self.lastSample == sample || self.settledEvent == self.playback.event),self.renderer?.hasPendingWork != true,self.referenceTask == nil,self.imageTask == nil,self.lightingTask == nil {
                    self.driver=nil;return
                }
                let active=Self.streams.values.compactMap(\.value).filter{$0.driver != nil}.count
                let fps=Self.samplingRate(outer:self.geometry.outer,active:active)
                do { try await Task.sleep(for:.seconds(1/fps)) } catch { return }
            }
        }
    }
    private func prepareReference(_ target:BodyPhaseSample) {
        guard let maps else {return}
        let geometry=geometry,generation=generation
        Self.inFlight+=1;cpuJobs+=1
        referenceTask=Task { [weak self] in
            let worker=Task.detached(priority:.utility) {
                let began=ProcessInfo.processInfo.systemUptime
                var request=BodyRenderRequest(outer:geometry.rasterOuter,scale:geometry.scale,framing:geometry.bare ? .bare:.orb,
                    lightDegrees:Float(geometry.bin)*360/32,phase:target)
                let lighting=BodyPhaseLightingInputs.prepare(body:maps.body,map:maps.map,ring:maps.ring,clouds:maps.clouds,request:request)
                request.phaseLighting=lighting
                let raster=BodyRasterizer.render(body:maps.body,map:maps.map,ring:maps.ring,clouds:maps.clouds,
                    request:request,isCancelled:{Task.isCancelled})
                let image=try? raster.image()
                return (raster,image,Self.workerIsOffMainThread(),lighting.bloodLift,ProcessInfo.processInfo.systemUptime-began)
            }
            let result=await withTaskCancellationHandler {await worker.value} onCancel:{worker.cancel()}
            Self.inFlight=max(0,Self.inFlight-1)
            guard let self,self.generation == generation,!Task.isCancelled else {return}
            self.referenceTask=nil;self.terminalRaster=result.0;self.terminalImage=result.1;self.referenceTarget=target;self.lastCPUWasOffMain=result.2;self.terminalBloodLift=result.3
            self.referenceRenderSeconds=result.4
        }
    }
    private func submit(_ sample:BodyPhaseSample) {
        guard lastSample != sample,renderer != nil,let maps else {return}
        submittedAt=CACurrentMediaTime();submittedEvent=playback.event;Self.inFlight+=1;ownsSlot=true;cpuJobs+=1
        let geometry=geometry,generation=generation,event=playback.event,bloodLift=terminalBloodLift
        let request=BodyRenderRequest(outer:geometry.rasterOuter,scale:geometry.scale,framing:geometry.bare ? .bare:.orb,
            lightDegrees:Float(geometry.bin)*360/32,phase:sample)
        lightingTask=Task { [weak self] in
            let worker=Task.detached(priority:.utility) {
                BodyPhaseLightingInputs(direction:BodyPhaseLighting.direction(body:maps.body,request:request,ring:maps.ring),bloodLift:sample.blood>0 ? bloodLift:0)
            }
            let lighting=await withTaskCancellationHandler {await worker.value} onCancel:{worker.cancel()}
            guard let self else {return}
            guard self.generation == generation else {return}
            self.lightingTask=nil
            guard !Task.isCancelled,self.playback.event == event else {self.finishSlot();return}
            var prepared=request;prepared.phaseLighting=lighting
            do {try self.renderer?.update(body:maps.body,map:maps.map,ring:maps.ring,clouds:maps.clouds,request:prepared,activity:.init())}
            catch {self.finishSlot();self.refused+=1}
        }
    }
    /// Compute completion precedes this callback; the shared texture is not reused until its image is copied.
    private func receive(_ frame:BodyRenderedFrame) {
        guard !active.isEmpty,submittedEvent == playback.event else {finishSlot();return}
        if playback.finished(at:CACurrentMediaTime()),frame.request.phase != playback.event.value.terminal() {finishSlot();return}
        switch frame.storage {
        case .cpu(let raster):
            guard imageTask == nil,let prepared=frame.preparedImage else {return}
            finishSlot();install(raster:raster,image:prepared,sample:frame.request.phase!)
            lastCPUWasOffMain=renderer?.lastCPUWasOffMain == true
            renderer?.didPresent(key:frame.key)
        case .metal(let texture):
            guard imageTask == nil else {return}
            if !ownsSlot {
                guard Self.inFlight<Self.maximumConcurrentJobs else {return}
                Self.inFlight+=1;ownsSlot=true
            }
            let snapshot=PhaseTextureSnapshot(texture:texture),generation=generation,event=playback.event
            imageTask=Task { [weak self] in
                let worker=Task.detached(priority:.utility) {try? snapshot.copyImage()}
                let result=await withTaskCancellationHandler {await worker.value} onCancel:{worker.cancel()}
                guard let self else {return}
                guard self.generation == generation else {return}
                self.imageTask=nil;self.finishSlot()
                guard !Task.isCancelled,self.playback.event == event,
                      !self.active.isEmpty,let result else {return}
                self.lastCPUWasOffMain=result.2
                self.install(raster:result.0,image:result.1,sample:frame.request.phase!)
                self.renderer?.didPresent(key:frame.key)
                // The first acknowledged GPU image ends the CPU fallback for subsequent frames.
                self.renderer?.requiresPresentationAcknowledgement=false
            }
        }
    }
    private func install(raster:BodyRaster,image:CGImage,sample:BodyPhaseSample,generationSeconds:Double?=nil) {
        self.image=image;lastSample=sample;imageChanges+=1
        let elapsed=CACurrentMediaTime()-playback.began
        let canSettle=playback.event.value.state == .completed ? elapsed>=playback.duration:
            playback.event.value.state == .unknown ? elapsed>=playback.duration*0.3:true
        if canSettle,referenceTarget == playback.event.value.terminal(),raster.pixels == terminalRaster?.pixels {settledEvent=playback.event}
        if let generationSeconds {renderSeconds=generationSeconds}
        else if submittedAt>0 {renderSeconds=CACurrentMediaTime()-submittedAt}
        CATransaction.begin();CATransaction.setDisableActions(true)
        for id in active {listeners[id]?(image)}
        CATransaction.commit()
    }
    private func stopAtDeadline() {
        driver=nil;retiring=true
        let reference=referenceTask,copying=imageTask,lighting=lightingTask
        referenceTask?.cancel();imageTask?.cancel();lightingTask?.cancel()
        referenceTask=nil;imageTask=nil;lightingTask=nil
        let retired=renderer?.retire();renderer=nil;maps=nil
        let slot=ownsSlot;ownsSlot=false
        deadlineRetirement=Task { @MainActor [weak self] in
            await retired?.value;await reference?.value;await copying?.value;await lighting?.value
            if slot {Self.inFlight=max(0,Self.inFlight-1)}
            self?.retiring=false
        }
    }
    private func finishSlot() { if ownsSlot {Self.inFlight=max(0,Self.inFlight-1);ownsSlot=false} }
    private func suspend(releaseImage:Bool=false) {
        let preparing=preparation,deadline=deadlineRetirement
        generation+=1;driver?.cancel();driver=nil;preparation?.cancel();preparation=nil
        let slot=ownsSlot;ownsSlot=false
        let reference=referenceTask;referenceTask?.cancel();referenceTask=nil
        let copying=imageTask;imageTask?.cancel();imageTask=nil
        let lighting=lightingTask;lightingTask?.cancel();lightingTask=nil
        terminalRaster=nil;terminalImage=nil;referenceTarget=nil;settledEvent=nil
        let retired=renderer?.retire();renderer=nil;maps=nil;lastSample=nil
        if slot {Task { @MainActor in await retired?.value;await copying?.value;await lighting?.value;Self.inFlight=max(0,Self.inFlight-1)}}
        if releaseImage {image=nil}
        if let lease,image == nil {
            self.lease=nil
            let resources=resources,atlas=atlasLease
            Task { @MainActor in
                await retired?.value;await reference?.value;await copying?.value;await lighting?.value;await preparing?.value;await deadline?.value
                if atlas {resources.sprites.releaseWorkingBytes(lease)} else {resources.releaseHD(lease)}
            }
        }
    }
    private func releaseReservation() {if let lease {if atlasLease {resources.sprites.releaseWorkingBytes(lease)} else {resources.releaseHD(lease)};self.lease=nil}}
    isolated deinit {
        if let phaseObservation {playback.removeObserver(phaseObservation)}
        suspend(releaseImage:true)
    }
}

/// A contents-only endpoint. Its finite scheduler uses monotonic event time, never a layer's local clock.
@MainActor final class BodyPhasePresentation {
    let layer=CALayer()
    private let resources:BodyResources
    private var stream:BodyPhaseStream?
    private var listener:UUID?
    private var geometry:BodyPhaseStream.Geometry?
    private var currentEvent:BodyPhaseEvent?
    var onPictureChange:((CGImage)->Void)?
    var image:CGImage? {stream?.image}
    var playback:BodyPhasePlayback? {stream?.playback}
    var streamIdentity:ObjectIdentifier? {stream.map(ObjectIdentifier.init)}
    var lastCPUWasOffMain:Bool {stream?.lastCPUWasOffMain == true}
    var frameSeconds:Double {stream?.renderSeconds ?? 0}
    var work:[String:Int] {["cpuJobs":stream?.cpuJobs ?? 0,"imageChanges":stream?.imageChanges ?? 0,"gpuSubmissions":stream?.gpuSubmissions ?? 0,"pending":stream?.hasPendingWork == true ? 1:0,"refused":stream?.refused ?? 0]}
    init(resources:BodyResources = .shared) {
        self.resources=resources;layer.name="organic.body.phase"
        layer.actions=["contents":NSNull(),"bounds":NSNull(),"position":NSNull(),"hidden":NSNull(),"transform":NSNull(),"opacity":NSNull()]
        layer.masksToBounds=true
    }
    func configure(event:BodyPhaseEvent?,bodyID:String,outer:CGFloat,scale:Int,bin:Int=12,bare:Bool=false,visible:Bool=true,animate:Bool=true,samplingOuter:CGFloat?=nil) {
        guard let event else {dispose();return}
        let next=BodyPhaseStream.Geometry(bodyID:bodyID,outer:Float(min(56,max(1,outer))),scale:scale,bin:bin,bare:bare,terminal:!animate,samplingOuter:samplingOuter.map{Float(min(64,max(1,$0)))})
        if geometry != next || stream?.playback.event.sourceID != event.sourceID {
            dispose();geometry=next
            stream=BodyPhaseStream.acquire(event:event,geometry:next,resources:resources)
            listener=stream?.attach { [weak self] image in self?.layer.contents=image;self?.onPictureChange?(image) }
        }
        currentEvent=event
        layer.contentsScale=CGFloat(scale);layer.isHidden = !visible;layer.cornerRadius=layer.bounds.width/2
        if let listener {stream?.setActivity(listener,visible:visible,animate:animate,event:event)}
    }
    func setActivity(visible:Bool,animate:Bool) {
        if visible,let geometry,let currentEvent,geometry.terminal == animate {
            configure(event:currentEvent,bodyID:geometry.bodyID,outer:CGFloat(geometry.outer),scale:geometry.scale,
                bin:geometry.bin,bare:geometry.bare,visible:visible,animate:animate,samplingOuter:geometry.samplingOuter.map(CGFloat.init))
            return
        }
        layer.isHidden = !visible
        if let listener,let stream {stream.setActivity(listener,visible:visible,animate:animate,event:stream.playback.event)}
    }
    func dispose() {
        if let listener {stream?.detach(listener)}
        stream=nil;listener=nil;geometry=nil;currentEvent=nil;layer.contents=nil;layer.isHidden=true
    }
    isolated deinit {dispose()}
}

/// The producer holds its slot while the completed shared texture is copied off the main actor.
private struct PhaseTextureSnapshot: @unchecked Sendable {
    let texture:any MTLTexture
    func copyImage()throws->(BodyRaster,CGImage,Bool) {
        let side=texture.width
        var bytes=[UInt8](repeating:0,count:side*side*4)
        bytes.withUnsafeMutableBytes {raw in
            texture.getBytes(raw.baseAddress!,bytesPerRow:side*4,from:MTLRegionMake2D(0,0,side,side),mipmapLevel:0)
        }
        let raster=BodyRaster(width:side,pixels:bytes)
        return (raster,try raster.image(),!Thread.isMainThread)
    }
}
