import Foundation
import Metal
import CoreGraphics

/// A published frame has the same semantic key and longitude on CPU and Metal.
@MainActor struct BodyRenderedFrame {
    enum Storage {case cpu(BodyRaster),metal(any MTLTexture)}
    let key:String
    let bodyID:String
    let longitude:Float
    let request:BodyRenderRequest
    let storage:Storage
    let preparedImage:CGImage?
    var backend:String {switch storage {case .cpu:"cpu";case .metal:"metal"}}
}

/// Lazy background compilation, one cancellable CPU job, and one explicit Metal job. No animation scheduler.
@MainActor final class BodyRenderer {
    enum ShaderStatus:String {case idle,compiling,ready,failed}
    private struct Snapshot:Sendable {
        let key:String
        let generation:Int
        let body:BodyDefinition
        let map:BodyMap
        let ring,clouds:BodyMap?
        let request:BodyRenderRequest
    }
    let profile:BodyProfile
    private let compiler:any BodyProgramLoading
    let metalBudget:Int
    private var gpu:BodyMetalRenderer?
    private var compilation:Task<Void,Never>?
    private var cpuTask:Task<Void,Never>?
    private var latest:Snapshot?
    private var generation=0
    private var gpuPending=false
    private var disposed=false
    var requiresPresentationAcknowledgement=false
    private var presentedKey:String?
    private var completedMetalKey:String?
    private var cpuPublishedKey:String?
    private var activity=BodyActivity(visible:false)
    private(set) var shaderStatus:ShaderStatus = .idle
    private(set) var failure:String?
    private(set) var compilationReceipt:BodyCompilationReceipt?
    private(set) var presentationProgram:BodyMetalProgram?
    private(set) var lastFrame:BodyRenderedFrame?
    private(set) var lastCPUWasOffMain=false
    private(set) var cpuJobs=0
    private(set) var metalFrames=0
    var onFrame:((BodyRenderedFrame)->Void)?
    var workSubmitted:((String)->Void)?
    var hasPendingWork:Bool {cpuTask != nil || gpuPending || compilation != nil}
    var metalSubmissions:Int {gpu?.submissions ?? 0}
    var metalResidentBytes:Int {gpu?.residentBytes ?? 0}
    init(compiler:any BodyProgramLoading,profile:BodyProfile = .current,metalBudget:Int = BodyProfile.current.highDefinitionBudget/2) {self.compiler=compiler;self.profile=profile;self.metalBudget=metalBudget}
    convenience init(sourceURL:URL,profile:BodyProfile = .current,metalBudget:Int = BodyProfile.current.highDefinitionBudget/2) {self.init(compiler:BodyShaderCompiler(sourceURL:sourceURL),profile:profile,metalBudget:metalBudget)}
    private var drawable:Bool {activity.visible && activity.keyWindow && !disposed}
    func setActivity(_ next:BodyActivity) {
        activity=next;gpu?.setActivity(next)
        if !drawable {generation+=1;latest=nil;lastFrame=nil;cpuTask?.cancel()}
    }
    /// Call only for a body, size, scale, light, or state change. Time and dirty ticks are not inputs.
    func update(body:BodyDefinition,map:BodyMap,ring:BodyMap?=nil,clouds:BodyMap?=nil,request:BodyRenderRequest,activity:BodyActivity)throws {
        setActivity(activity)
        guard drawable else {return}
        guard request.outer.isFinite,request.outer>0,request.outer<=1024,(1...3).contains(request.scale),request.lightDegrees.isFinite,request.outer*Float(request.scale)<=2048 else {throw BodyError.invalid("Invalid static body request")}
        if request.phase != nil {
            let side=Int((request.outer*Float(request.scale)).rounded())
            let workingSet=BodyPhaseLighting.workspaceBytes+side*side*8+map.pixels.count+(ring?.pixels.count ?? 0)+(clouds?.pixels.count ?? 0)
            guard workingSet<=min(profile.highDefinitionBudget/2,metalBudget) else{throw BodyError.invalid("Phase reference workspace exceeds shared HD reservation")}
        }
        let request=request.resolved(for:body,profile:profile)
        let key="\(body.id)|\(map.identity)|\(String(describing:ring?.identity))|\(String(describing:clouds?.identity))|\(request)|\(profile.version)"
        guard latest?.key != key else {return}
        generation+=1
        latest=Snapshot(key:key,generation:generation,body:body,map:map,ring:ring,clouds:clouds,request:request)
        if request.outer>profile.bakeMax {startCompilationIfNeeded()}
        if !submitMetal() || requiresPresentationAcknowledgement {startCPUIfNeeded()}
    }
    private func startCompilationIfNeeded() {
        guard shaderStatus == .idle else{return}
        shaderStatus = .compiling
        let compiler=compiler
        compilation=Task { [weak self] in
            do {
                let program=try await compiler.program()
                guard let self,!self.disposed else{return}
                self.compilationReceipt=program.receipt
                self.presentationProgram=program
                self.gpu=try BodyMetalRenderer(program:program,budget:self.metalBudget);self.gpu?.setActivity(self.activity)
                self.shaderStatus = .ready;self.compilation=nil
                _ = self.submitMetal()
            } catch {
                guard let self,!self.disposed else{return}
                self.shaderStatus = .failed;self.failure=error.localizedDescription;self.compilation=nil
                self.startCPUIfNeeded()
            }
        }
    }
    nonisolated private static func cpuIsOffMainThread() -> Bool { !Thread.isMainThread }
    private func startCPUIfNeeded() {
        guard drawable,cpuTask == nil,let snapshot=latest,cpuPublishedKey != snapshot.key,
              lastFrame?.key != snapshot.key || requiresPresentationAcknowledgement && presentedKey != snapshot.key else{return}
        cpuJobs+=1
        workSubmitted?("cpuJobs")
        let profile=profile
        cpuTask=Task { [weak self] in
            let worker=Task.detached(priority:.utility) {
                let raster=BodyRasterizer.render(body:snapshot.body,map:snapshot.map,ring:snapshot.ring,clouds:snapshot.clouds,request:snapshot.request,profile:profile,isCancelled:{Task.isCancelled})
                return (raster, Self.cpuIsOffMainThread(), snapshot.request.phase == nil ? nil : try? raster.image())
            }
            let result=await withTaskCancellationHandler {await worker.value} onCancel:{worker.cancel()}
            let cancelled=Task.isCancelled
            guard let self else{return}
            let raster=result.0; self.lastCPUWasOffMain=result.1
            self.cpuTask=nil
            if !cancelled,self.drawable,self.latest?.generation == snapshot.generation,
               self.lastFrame?.backend != "metal" && self.presentedKey != snapshot.key || self.lastFrame?.key != snapshot.key || self.requiresPresentationAcknowledgement && self.presentedKey != snapshot.key {
                self.cpuPublishedKey=snapshot.key
                self.publish(snapshot: snapshot,storage:.cpu(raster),image:result.2)
            }
            if self.latest?.generation != snapshot.generation {if !self.submitMetal(){self.startCPUIfNeeded()}}
        }
    }
    @discardableResult private func submitMetal()->Bool {
        guard drawable,!gpuPending,let gpu,let snapshot=latest,snapshot.request.outer>profile.bakeMax else{return false}
        if completedMetalKey == snapshot.key {return true}
        do {
            let texture=try gpu.draw(body:snapshot.body,map:snapshot.map,ring:snapshot.ring,clouds:snapshot.clouds,request:snapshot.request,at:0,profile:profile) { [weak self] result in
                guard let self else{return}
                self.gpuPending=false
                switch result {
                case .success:
                    guard let texture=self.gpu?.lastFrame else{return}
                    if self.drawable,self.latest?.generation == snapshot.generation {self.completedMetalKey=snapshot.key;self.metalFrames+=1;self.publish(snapshot:snapshot,storage:.metal(texture))}
                case .failure(let error):
                    self.gpu=nil;self.shaderStatus = .failed;self.failure=error.localizedDescription;self.startCPUIfNeeded()
                }
                if self.latest?.generation != snapshot.generation {if !self.submitMetal(){self.startCPUIfNeeded()}}
            }
            gpuPending=texture != nil
            if texture != nil { workSubmitted?("gpuSubmissions") }
            return texture != nil
        } catch {
            self.gpu=nil;shaderStatus = .failed;failure=error.localizedDescription
            return false
        }
    }
    private func publish(snapshot:Snapshot,storage:BodyRenderedFrame.Storage,image:CGImage?=nil) {
        let frame=BodyRenderedFrame(key:snapshot.key,bodyID:snapshot.body.id,longitude:snapshot.request.turn,request:snapshot.request,storage:storage,preparedImage:image)
        lastFrame=frame;onFrame?(frame)
    }
    func makePresentationCommandBuffer() -> (any MTLCommandBuffer)? { gpu?.makePresentationCommandBuffer() }
    func didPresent(key: String) { presentedKey=key }
    /// Keep a shared-budget lease until canceled CPU work and already submitted compute have retired.
    func retire() -> Task<Void,Never> {
        let cpu=cpuTask,fence=gpu?.lastWorkFence
        dispose()
        return Task { @MainActor in await cpu?.value; await fence?.wait() }
    }
    /// Explicit test/export boundary. Normal presentation consumes the CPU image or completed texture directly.
    func pixelsForVerification()throws->BodyRaster {
        guard let frame=lastFrame else {throw BodyError.invalid("No completed body frame")}
        switch frame.storage {case .cpu(let raster):return raster;case .metal:guard let gpu else{throw BodyError.invalid("Metal retired")};return try gpu.readbackForVerification()}
    }
    func dispose() {
        disposed=true;generation+=1;latest=nil;lastFrame=nil;onFrame=nil;workSubmitted=nil;cpuTask?.cancel();compilation?.cancel();gpu?.dispose();gpu=nil;presentationProgram=nil
    }
}
