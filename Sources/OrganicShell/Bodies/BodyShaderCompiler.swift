import Foundation
import Metal
import CryptoKit

struct BodyCompilationReceipt: Codable, Sendable {
    let sourceSHA256:String
    let device:String
    let sourceMilliseconds:Double
    let pipelineMilliseconds:Double
    let totalMilliseconds:Double
    let ranOnMainThread:Bool
}

/// Metal handles are safe to transfer; the completed immutable pipeline is installed on the main actor.
struct BodyMetalProgram: @unchecked Sendable {
    let device:any MTLDevice
    let pipeline:any MTLComputePipelineState
    let presentation:any MTLRenderPipelineState
    let receipt:BodyCompilationReceipt
    static func compile(sourceURL:URL)throws->Self {
        let main=Thread.isMainThread
        guard !main else {throw BodyError.invalid("Shader source compilation must run off the main thread")}
        let start=ProcessInfo.processInfo.systemUptime
        let source=try String(contentsOf:sourceURL,encoding:.utf8)
        guard let device=MTLCreateSystemDefaultDevice() else {throw BodyError.invalid("Metal unavailable; use CPU")}
        let options=MTLCompileOptions();options.mathMode = .safe
        let sourceStart=ProcessInfo.processInfo.systemUptime
        let library=try device.makeLibrary(source:source,options:options)
        let pipelineStart=ProcessInfo.processInfo.systemUptime
        guard let function=library.makeFunction(name:"bodyRender") else {throw BodyError.invalid("Missing bodyRender kernel; use CPU")}
        let pipeline=try device.makeComputePipelineState(function:function)
        let presentationDescriptor=MTLRenderPipelineDescriptor()
        presentationDescriptor.vertexFunction=library.makeFunction(name:"bodyPresentVertex")
        presentationDescriptor.fragmentFunction=library.makeFunction(name:"bodyPresentFragment")
        presentationDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let presentation=try device.makeRenderPipelineState(descriptor:presentationDescriptor)
        let end=ProcessInfo.processInfo.systemUptime
        let hash=SHA256.hash(data:Data(source.utf8)).map{String(format:"%02x",$0)}.joined()
        return Self(device:device,pipeline:pipeline,presentation:presentation,receipt:.init(sourceSHA256:hash,device:device.name,sourceMilliseconds:(pipelineStart-sourceStart)*1000,pipelineMilliseconds:(end-pipelineStart)*1000,totalMilliseconds:(end-start)*1000,ranOnMainThread:main))
    }
}

protocol BodyProgramLoading: Sendable {
    func program() async throws -> BodyMetalProgram
}

/// One shared loader per shader/profile. Success and failure are both cached; there is no retry loop.
actor BodyShaderCompiler: BodyProgramLoading {
    typealias Operation = @Sendable () async throws -> BodyMetalProgram
    private let operation:Operation
    private var task:Task<BodyMetalProgram,any Error>?
    private(set) var attempts=0
    init(sourceURL:URL) {operation={try BodyMetalProgram.compile(sourceURL:sourceURL)}}
    init(operation:@escaping Operation) {self.operation=operation}
    func program() async throws -> BodyMetalProgram {
        if let task {return try await task.value}
        attempts+=1
        let operation=operation
        let task=Task.detached(priority:.utility) {try await operation()}
        self.task=task
        return try await task.value
    }
}
