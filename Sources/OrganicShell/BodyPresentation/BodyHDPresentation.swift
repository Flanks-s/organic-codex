import AppKit
import Metal
import QuartzCore

/// On-demand CAMetalLayer presentation; CPU content retires only after drawable presentation is acknowledged.
@MainActor final class BodyHDPresentation {
    private let resources: BodyResources
    private let parent: CALayer
    private weak var hostView: NSView?
    let cpu=CALayer(), metal=CAMetalLayer()
    private var renderer: BodyRenderer?
    private var preparation: Task<Void,Never>?
    private var maps: BodyPreparedMaps?
    private var lease: UUID?
    private var latest: BodyPresentationInput?
    private var key=""
    private var generation=0
    private var disposed=false
    private var presentedKey: String?
    private var presentationFence: BodyWorkFence?
    private(set) var presentedFrames=0
    var cpuJobs: Int { renderer?.cpuJobs ?? 0 }
    var metalSubmissions: Int { renderer?.metalSubmissions ?? 0 }
    init(resources: BodyResources, parent: CALayer, hostView: NSView?) {
        self.resources=resources; self.parent=parent; self.hostView=hostView
        cpu.name="organic.body.cpu"; metal.name="organic.body.drawable"
        cpu.actions=["contents":NSNull(),"hidden":NSNull()]
        metal.actions=["hidden":NSNull(),"bounds":NSNull(),"position":NSNull()]
        metal.pixelFormat = .bgra8Unorm; metal.colorspace=CGColorSpace(name:CGColorSpace.sRGB)
        metal.isOpaque=false; metal.framebufferOnly=true; metal.maximumDrawableCount=2
        metal.presentsWithTransaction=false; metal.allowsNextDrawableTimeout=true
        parent.addSublayer(cpu); parent.addSublayer(metal)
    }
    func update(_ input: BodyPresentationInput) {
        guard !disposed,input.visible,input.keyWindow,input.outer>56 else { return }
        let next="\(input.bodyID)|\(input.outer)|\(input.scale)|\(input.bin)|\(input.unknown)"
        latest=input
        cpu.frame=parent.bounds; metal.frame=parent.bounds
        guard next != key else { return }
        key=next; generation+=1
        if renderer == nil {
            let pixels=Int(ceil(input.outer*CGFloat(input.scale)))
            let imageBytes=pixels*pixels*4
            // Two drawable surfaces, CPU raster/image, and one transient image are reserved together.
            let metalBudget=(input.outer*CGFloat(input.scale)>180 ? 6:2)*1024*1024
            let reservation=imageBytes*5+metalBudget
            guard let lease=resources.reserveHD(bytes:reservation) else { return }
            self.lease=lease
            parent.setValue(resources.hdReservedBytes,forKey:"sharedHDReservedBytes")
            let renderer=BodyRenderer(compiler:resources.compiler,metalBudget:metalBudget)
            renderer.requiresPresentationAcknowledgement=true
            renderer.onFrame={ [weak self] frame in self?.receive(frame) }
            renderer.workSubmitted={ [weak parent] counter in
                guard let parent else { return }
                parent.setValue((parent.value(forKey:counter) as? Int ?? 0)+1,forKey:counter)
            }
            self.renderer=renderer
        }
        if maps?.body.id == input.bodyID { renderPrepared(); return }
        preparation?.cancel()
        guard let queue=resources.queue else { return }
        let generation=generation
        preparation=Task { [weak self] in
            do {
                let maps=try await queue.prepare(input.bodyID,maximumWidth:input.outer*CGFloat(input.scale)>180 ? 1024:512)
                try Task.checkCancellation()
                guard let self,!self.disposed,self.generation == generation else { return }
                self.maps=maps; self.preparation=nil; self.renderPrepared()
            } catch { self?.preparation=nil }
        }
    }
    private func renderPrepared() {
        guard let input=latest,let maps,!disposed,input.visible,input.keyWindow else { return }
        parent.setValue(maps.cacheBytes,forKey:"sharedMapCacheBytes")
        parent.setValue(maps.map.byteCount+(maps.ring?.byteCount ?? 0)+(maps.clouds?.byteCount ?? 0),forKey:"preparedMapBytes")
        let request=BodyRenderRequest(outer:Float(input.outer),scale:input.scale,lightDegrees:BodyProfile.current.quantizedDirection(input.degrees).degrees,unknown:input.unknown)
        try? renderer?.update(body:maps.body,map:maps.map,ring:maps.ring,clouds:maps.clouds,request:request,activity:.init(visible:true,keyWindow:true))
    }
    private func receive(_ frame: BodyRenderedFrame) {
        guard !disposed,let renderer,let input=latest,frame.bodyID == input.bodyID else { return }
        switch frame.storage {
        case .cpu(let raster):
            guard presentedKey != frame.key else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            cpu.contents=try? raster.image(); cpu.contentsScale=CGFloat(input.scale); cpu.isHidden=false
            if renderer.shaderStatus == .failed { metal.isHidden=true }
            CATransaction.commit()
        case .metal(let texture):
            parent.setValue(renderer.metalResidentBytes,forKey:"metalResidentBytes")
            guard let window=hostView?.window,window.isVisible,!window.isMiniaturized,window.occlusionState.contains(.visible) else { return }
            guard let program=renderer.presentationProgram else { return }
            metal.device=program.device
            metal.isHidden=false
            metal.contentsScale=CGFloat(input.scale)
            metal.drawableSize=CGSize(width:texture.width,height:texture.height)
            // A detached, hidden or occluded layer can have no drawable. Its CPU picture remains installed.
            guard let drawable=metal.nextDrawable(),let command=renderer.makePresentationCommandBuffer() else { return }
            do { try BodyMetalPresentation.encode(source:texture,target:drawable.texture,program:program,command:command) } catch { return }
            let fence=BodyWorkFence(); presentationFence=fence
            command.addCompletedHandler { _ in fence.finish() }
            let generation=generation, key=frame.key
            drawable.addPresentedHandler { [weak self] presented in
                guard presented.presentedTime>0 else { return }
                Task { @MainActor in
                    guard let self,!self.disposed,self.generation == generation else { return }
                    self.presentedKey=key; self.presentedFrames+=1; self.renderer?.didPresent(key:key)
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.cpu.contents=nil; self.cpu.isHidden=true
                    self.parent.setValue(self.presentedFrames,forKey:"presentedFrames")
                    CATransaction.commit()
                }
            }
            command.present(drawable); command.commit()
        }
    }
    func suspend() {
        generation+=1; key=""; preparation?.cancel(); preparation=nil
        renderer?.setActivity(.init(visible:false,keyWindow:false))
    }
    func dispose() {
        guard !disposed else { return }; disposed=true; generation+=1
        preparation?.cancel(); preparation=nil
        let retired=renderer?.retire(),presented=presentationFence,resources=resources
        renderer=nil; maps=nil
        if let lease {
            Task { @MainActor in await retired?.value; await presented?.wait(); resources.releaseHD(lease) }
        }
        lease=nil
        cpu.contents=nil; cpu.removeFromSuperlayer(); metal.removeFromSuperlayer()
    }
    isolated deinit { dispose() }
}
