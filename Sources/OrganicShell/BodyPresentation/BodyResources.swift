import AppKit
import ObjectiveC
#if SWIFT_PACKAGE
import OrganicBodyResources
#endif

struct BodyPreparedMaps: Sendable {
    let body: BodyDefinition
    let map: BodyMap
    let ring: BodyMap?
    let clouds: BodyMap?
    let cacheBytes: Int
}

/// All map decoding/procedural preparation is serialized away from the main actor.
actor BodyResourceQueue {
    private let catalogue: BodyCatalogue
    private let store: BodyMapStore
    init(root: URL, catalogue: BodyCatalogue) {
        self.catalogue=catalogue
        store=BodyMapStore(textureDirectory:root.appendingPathComponent("Textures"),budget:8*1024*1024)
    }
    func prepare(_ id: String, maximumWidth: Int) throws -> BodyPreparedMaps {
        try Task.checkCancellation()
        let body=try catalogue.body(id)
        let map=try store.map(for:body,maximumWidth:maximumWidth,clampPluto:true)
        let ring=body.ring ? try store.named("saturn_ring",maximumWidth:maximumWidth) : nil
        let clouds=try body.clouds.map { try store.named($0,maximumWidth:maximumWidth) }
        try Task.checkCancellation()
        return .init(body:body,map:map,ring:ring,clouds:clouds,cacheBytes:store.residentBytes)
    }
    var residentBytes: Int { store.residentBytes }
    var decodes: Int { store.decodes }
}

/// The app owns one sprite cache, one compiler and one map queue across all windows and hosts.
@MainActor final class BodyResources {
    private static var menuPinKey: UInt8=0
    static let shared = BodyResources()
    let root: URL
    let catalogue: BodyCatalogue?
    let sprites=BodySpriteCache()
    let compiler: BodyShaderCompiler
    let queue: BodyResourceQueue?
    let archive: BodySpriteArchive?
    private(set) var spriteDecodes=0
    private(set) var hdReservedBytes=0
    private var leases: [UUID:Int] = [:]
    init(root: URL? = nil) {
        let bundled=Bundle.main.resourceURL?.appendingPathComponent("Bodies")
        let selected: URL
        if let root { selected=root }
        else if let override=ProcessInfo.processInfo.environment["ORGANIC_BODY_RESOURCES"] { selected=URL(fileURLWithPath:override) }
        else if let bundled,FileManager.default.fileExists(atPath:bundled.appendingPathComponent("catalogue.json").path) { selected=bundled }
        else {
#if SWIFT_PACKAGE
            selected=OrganicBodyResourceBundle.url
#else
            selected=URL(fileURLWithPath:"Resources/Bodies",relativeTo:URL(fileURLWithPath:FileManager.default.currentDirectoryPath))
#endif
        }
        self.root=selected
        archive=try? BodySpriteArchive(root:selected.appendingPathComponent("Sprites"))
        let catalogue=try? BodyCatalogue.load(url:selected.appendingPathComponent("catalogue.json"))
        self.catalogue=catalogue
        compiler=BodyShaderCompiler(sourceURL:selected.appendingPathComponent("BodyShaders.metal"))
        queue=catalogue.map { BodyResourceQueue(root:selected,catalogue:$0) }
    }
    func load(_ input: BodyPresentationInput) -> String? {
        let key=input.spriteKey
        if sprites.value(key) != nil { return key }
        guard let archive,let descriptor=archive.descriptor(group:input.groupKey,bin:input.bin),
              sprites.load(descriptor:descriptor,key:key,png:{ try archive.read(group:input.groupKey,frameKey:key,bin:input.bin) }) else { return nil }
        spriteDecodes += 1
        return key
    }
    func image(bodyID: String, outer: CGFloat = 16, scale: Int = 2, degrees: Float = 135) -> CGImage? {
        let a=CGFloat(degrees) * .pi/180
        let input=BodyPresentationInput(bodyID:bodyID,outer:outer,scale:scale,ll:CGPoint(x:cos(a),y:-sin(a)),center:.zero)
        guard let key=load(input) else { return nil }
        return sprites.value(key)?.image
    }
    func menuImage(_ bodyID: String) -> NSImage? {
        guard let cg=image(bodyID:bodyID) else { return nil }
        let key="\(bodyID)-d16-s2-l12-u0"
        guard let pin=sprites.makeLayer(key:key,at:0) else { return nil }
        let image=NSImage(cgImage:cg,size:CGSize(width:16,height:16))
        objc_setAssociatedObject(image,&Self.menuPinKey,BodyMenuPin(pin),.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return image
    }
    func reserveHD(bytes: Int) -> UUID? {
        guard bytes>0,hdReservedBytes+bytes<=16*1024*1024 else { return nil }
        let id=UUID(); leases[id]=bytes; hdReservedBytes+=bytes; return id
    }
    func releaseHD(_ id: UUID) { hdReservedBytes-=leases.removeValue(forKey:id) ?? 0 }
}

/// A retained menu keeps its decoded picture in the shared sprite ledger until AppKit releases the image.
@MainActor private final class BodyMenuPin: NSObject {
    private let pin: BodySpriteLayer
    init(_ pin: BodySpriteLayer) {
        self.pin=pin
        super.init()
    }
    isolated deinit { pin.dispose() }
}
