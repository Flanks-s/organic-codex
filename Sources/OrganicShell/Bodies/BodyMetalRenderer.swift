import Foundation
import Metal
import simd

/// One explicit static compute frame per changed request. No view, timer, display link, or product registration.
@MainActor final class BodyMetalRenderer {
    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private var textures:[String:any MTLTexture]=[:],order:[String]=[]
    private var output:(any MTLTexture)?
    private var lastKey:String?
    private var pending:(any MTLCommandBuffer)?
    private(set) var lastWorkFence: BodyWorkFence?
    private(set) var activity=BodyActivity(visible:false)
    private(set) var submissions=0
    private(set) var dropped=0
    private(set) var textureBytes=0
    private(set) var lastFrame:(any MTLTexture)?
    let budget:Int
    var residentBytes:Int {textureBytes+(output?.allocatedSize ?? 0)}
    init(program:BodyMetalProgram,budget:Int = BodyProfile.current.highDefinitionBudget / 2)throws {
        guard let queue=program.device.makeCommandQueue() else {throw BodyError.invalid("Missing Metal queue")}
        device=program.device;self.queue=queue;pipeline=program.pipeline;self.budget=budget
    }
    func setActivity(_ next:BodyActivity) {activity=next}
    /// Presentation commits on this queue before another compute can reuse the borrowed output.
    func makePresentationCommandBuffer() -> (any MTLCommandBuffer)? { queue.makeCommandBuffer() }
    private func texture(_ map:BodyMap,key:String,reserve:Int,keeping:Set<String>)throws->any MTLTexture {
        if let texture=textures[key] {order.removeAll{$0==key};order.append(key);return texture}
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:map.width,height:map.height,mipmapped:false)
        d.storageMode = .shared;d.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor:d),texture.allocatedSize+reserve<=budget else {throw BodyError.invalid("Metal map exceeds budget")}
        while textureBytes+texture.allocatedSize+reserve>budget,let victim=order.first(where:{!keeping.contains($0)}) {textureBytes-=textures.removeValue(forKey:victim)!.allocatedSize;order.removeAll{$0==victim}}
        guard textureBytes+texture.allocatedSize+reserve<=budget else {throw BodyError.invalid("Active Metal maps exceed budget")}
        map.pixels.withUnsafeBytes{texture.replace(region:MTLRegionMake2D(0,0,map.width,map.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:map.width*4)}
        textures[key]=texture;order.append(key);textureBytes+=texture.allocatedSize;return texture
    }
    /// Returns nil before allocation/GPU work if hidden, non-key, unchanged, or already rendering.
    func draw(body:BodyDefinition,map:BodyMap,ring:BodyMap?=nil,clouds:BodyMap?=nil,request:BodyRenderRequest,at now:Double,dirty:Bool=false,profile:BodyProfile = .current,completion:(@MainActor @Sendable (Result<Void,BodyError>)->Void)?=nil)throws->(any MTLTexture)? {
        guard activity.visible,activity.keyWindow else{return nil}
        let request=request.resolved(for:body,profile:profile)
        guard request.outer.isFinite,request.outer>0,request.outer<=1024,(1...3).contains(request.scale),request.turn.isFinite,request.lightDegrees.isFinite else {throw BodyError.invalid("Invalid Metal dimensions or phase")}
        let key="\(body.id)|\(map.identity)|\(String(describing:ring?.identity))|\(String(describing:clouds?.identity))|\(request)|\(profile)"
        guard key != lastKey else {return nil}
        if let pending,pending.status != .completed && pending.status != .error {dropped+=1;return nil}
        pending=nil
        let side=max(1,Int((request.outer*Float(request.scale)).rounded()))
        guard side<=2048,side*side*4<=budget else {throw BodyError.invalid("Metal target exceeds budget")}
        let requiredMaps=[map]+(ring.map{[$0]} ?? [])+(clouds.map{[$0]} ?? [])
        let minimumBytes=requiredMaps.reduce(0){$0+$1.pixels.count}+side*side*4+4
        let workspace=request.phase == nil ? 0:BodyPhaseLighting.workspaceBytes*2 + ((request.phase?.blood ?? 0)>0 ? side*side*4:0)
        guard minimumBytes+workspace<=budget else {throw BodyError.invalid("Active Metal frame exceeds budget before allocation")}
        defer {
            // A failed allocation must not leave an oversized target/cache resident.
            if residentBytes>budget {textures.removeAll();order.removeAll();textureBytes=0;output=nil;lastFrame=nil}
        }
        if output?.width != side {
            lastFrame=nil;output=nil
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:side,height:side,mipmapped:false)
            d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite]
            output=device.makeTexture(descriptor:d)
        }
        guard let output else {throw BodyError.invalid("Cannot allocate Metal target")}
        let blank=BodyMap(width:1,height:1,pixels:[0,0,0,0])
        let imageKey=body.id+".\(map.identity)",ringKey=ring == nil ? "blank":"saturn.ring.\(ring!.identity)",cloudKey=clouds == nil ? "blank":"earth.clouds.\(clouds!.identity)"
        let keeping=Set([imageKey,ringKey,cloudKey])
        let image=try texture(map,key:imageKey,reserve:output.allocatedSize+workspace,keeping:keeping)
        let ringImage=try texture(ring ?? blank,key:ringKey,reserve:output.allocatedSize+workspace,keeping:keeping)
        let cloudImage=try texture(clouds ?? blank,key:cloudKey,reserve:output.allocatedSize+workspace,keeping:keeping)
        while residentBytes+workspace>budget,let victim=order.first(where:{!keeping.contains($0)}) {textureBytes-=textures.removeValue(forKey:victim)!.allocatedSize;order.removeAll{$0==victim}}
        guard residentBytes+workspace<=budget else {throw BodyError.invalid("Metal residency exceeds budget")}
        let b=body.basis,L=request.phaseLighting?.direction ?? BodyPhaseLighting.direction(body:body,request:request,ring:ring,profile:profile),a=body.atmosphere ?? [0,0,0]
        var uniforms:[SIMD4<Float>]=[
            SIMD4(Float(side),Float(profile.supersampling),profile.bodyDiameter(outer:request.outer,framing:request.framing)/request.outer,request.turn),
            SIMD4(L.x,L.y,L.z,profile.night),SIMD4(request.unknown ? profile.haze:profile.soft,profile.limb,profile.rim,profile.ringInner),
            SIMD4(profile.ringOuter,body.ring ? 1:0,body.emits ? 1:0,body.ellipsoid ? 1:0),
            SIMD4(body.axis.x,body.axis.y,body.axis.z,request.unlit ? 1:0),SIMD4(b.pole.x,b.pole.y,b.pole.z,0),
            SIMD4(b.meridian.x,b.meridian.y,b.meridian.z,0),SIMD4(b.east.x,b.east.y,b.east.z,0),
            SIMD4(a[0],a[1],a[2],body.atmosphere == nil ? 0:1),SIMD4(clouds == nil ? 0:1,0,0,0)]
        if let pose=request.pose {
            uniforms[9].z=1
            uniforms[9].w=(pose.cloudDegrees-pose.surfaceDegrees)/360
        }
        if let phase=request.phase {
            let f=profile.phase
            uniforms[9].y=1
            uniforms += [SIMD4(1,phase.haze,phase.amber,phase.blood),
                         SIMD4(phase.ash,phase.emphasis,f.diffuseBase,f.diffuseGain),
                         SIMD4(f.waitRGB[0],f.waitRGB[1],f.waitRGB[2],profile.haze),
                         SIMD4(f.failRGB[0],f.failRGB[1],f.failRGB[2],f.failEdge),
                         SIMD4(f.cancelLevel,f.cancelFloor,profile.soft,0),
                         SIMD4(request.phaseLighting?.bloodLift ?? BodyPhaseBlood.lift(body:body,map:map,ring:ring,clouds:clouds,request:request,profile:profile),0,0,0)]
        }
        guard let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else {throw BodyError.invalid("Cannot encode Metal frame")}
        encoder.setComputePipelineState(pipeline)
        uniforms.withUnsafeMutableBytes{encoder.setBytes($0.baseAddress!,length:$0.count,index:0)}
        for (i,t) in [image,ringImage,cloudImage,output].enumerated(){encoder.setTexture(t,index:i)}
        let width=pipeline.threadExecutionWidth,height=max(1,min(8,pipeline.maxTotalThreadsPerThreadgroup/width))
        encoder.dispatchThreads(MTLSize(width:side,height:side,depth:1),threadsPerThreadgroup:MTLSize(width:width,height:height,depth:1));encoder.endEncoding()
        if let completion {
            command.addCompletedHandler {command in
                let error=command.error?.localizedDescription
                let succeeded=command.status == .completed
                Task { @MainActor in
                    completion(succeeded ? .success(()):.failure(.invalid(error ?? "Metal command failed")))
                }
            }
        }
        let fence=BodyWorkFence(); lastWorkFence=fence
        command.addCompletedHandler { _ in fence.finish() }
        command.commit();pending=command;submissions+=1;lastFrame=output;lastKey=key
        return output
    }
    /// Explicit verifier/export boundary; normal rendering never performs a CPU readback or waits on the GPU.
    func readbackForVerification()throws->BodyRaster {
        pending?.waitUntilCompleted()
        guard pending?.status != .error,let output else {throw BodyError.invalid("Metal frame failed: \(pending?.error?.localizedDescription ?? "no output")")}
        var bytes=[UInt8](repeating:0,count:output.width*output.height*4)
        bytes.withUnsafeMutableBytes{output.getBytes($0.baseAddress!,bytesPerRow:output.width*4,from:MTLRegionMake2D(0,0,output.width,output.height),mipmapLevel:0)}
        return BodyRaster(width:output.width,pixels:bytes)
    }
    func dispose(){activity=BodyActivity(visible:false);textures.removeAll();order.removeAll();textureBytes=0;output=nil;lastFrame=nil;pending=nil;lastKey=nil}
}
