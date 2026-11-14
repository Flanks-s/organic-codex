import Metal

/// Shared by the drawable presenter and the offscreen BGRA regression. Encoded sRGB stays encoded sRGB.
@MainActor enum BodyMetalPresentation {
    static func encode(source: any MTLTexture, target: any MTLTexture, program: BodyMetalProgram, command: any MTLCommandBuffer) throws {
        guard source.pixelFormat == .rgba8Unorm,target.pixelFormat == .bgra8Unorm,
              source.width == target.width,source.height == target.height else { throw BodyError.invalid("Invalid body presentation attachment") }
        let pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else { throw BodyError.invalid("Cannot encode body presentation") }
        encoder.setRenderPipelineState(program.presentation); encoder.setFragmentTexture(source,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); encoder.endEncoding()
    }
}
