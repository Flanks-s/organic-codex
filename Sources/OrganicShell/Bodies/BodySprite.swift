import Foundation
import QuartzCore
import CoreGraphics
import ImageIO

struct BodySpriteDescriptor: Codable, Equatable, Sendable {
    let profile: String
    let bodyID: String
    let outer: Float
    let scale: Int
    let frameCount: Int
    let columns: Int
    let cellPixels: Int
    let gutter: Int
    var lightBin: Int
    let framing: BodyProfile.Framing
    let cycleSeconds: Double
    var albedo = false
    var unknown:Bool? = nil
    var rows: Int {(frameCount+columns-1)/columns}
    var imageWidth: Int {columns*(cellPixels+gutter*2)}
    var imageHeight: Int {rows*(cellPixels+gutter*2)}
    var decodedBytes: Int {imageWidth*imageHeight*4}
    func pixelRect(_ frame: Int) -> CGRect {
        let i=(frame%frameCount+frameCount)%frameCount,stride=cellPixels+gutter*2
        return CGRect(x:i%columns*stride+gutter,y:i/columns*stride+gutter,width:cellPixels,height:cellPixels)
    }
    func contentsRect(_ frame: Int)->CGRect {
        let r=pixelRect(frame)
        return CGRect(x:r.minX/CGFloat(imageWidth),y:r.minY/CGFloat(imageHeight),width:r.width/CGFloat(imageWidth),height:r.height/CGFloat(imageHeight))
    }
    /// Static sprites have no playback clock. The sole frame is selected by lighting direction.
    func frame(activeSeconds: Double)->Int {0}

}
struct BodySprite {
    let descriptor: BodySpriteDescriptor
    let image: CGImage
    func frozenFrame(activeSeconds: Double) throws -> CGImage {
        guard let image=image.cropping(to:descriptor.pixelRect(descriptor.frame(activeSeconds:activeSeconds))) else {throw BodyError.invalid("Invalid sprite crop")}
        let side=descriptor.cellPixels
        guard let context=CGContext(data:nil,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw BodyError.invalid("Cannot allocate tight frozen frame")}
        context.draw(image,in:CGRect(x:0,y:0,width:side,height:side))
        guard let tight=context.makeImage() else {throw BodyError.invalid("Cannot export tight frozen frame")}
        return tight
    }
    static func descriptor(at metadata:URL,budget:Int)->BodySpriteDescriptor? {
        guard let data=try? Data(contentsOf:metadata),let d=try? JSONDecoder().decode(BodySpriteDescriptor.self,from:data),valid(d,budget:budget) else {return nil}
        return d
    }
    static func valid(_ d: BodySpriteDescriptor, budget: Int) -> Bool {
        d.profile == BodyProfile.current.version && d.frameCount==1 && d.columns==1 && d.cellPixels>0 && d.cellPixels<=512 && d.gutter==0 && d.cycleSeconds==0 && d.decodedBytes<=budget
    }
    static func load(png: URL, metadata: URL, budget: Int = BodyProfile.current.atlasBudget)->Self? {
        guard let d=descriptor(at:metadata,budget:budget),let source=CGImageSourceCreateWithURL(png as CFURL,nil) else { return nil }
        return load(source:source,descriptor:d)
    }
    static func load(data: Data, descriptor: BodySpriteDescriptor, budget: Int)->Self? {
        guard valid(descriptor,budget:budget),let source=CGImageSourceCreateWithData(data as CFData,nil) else { return nil }
        return load(source:source,descriptor:descriptor)
    }
    private static func load(source: CGImageSource, descriptor d: BodySpriteDescriptor)->Self? {
        guard
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              properties[kCGImagePropertyPixelWidth] as? Int == d.imageWidth,properties[kCGImagePropertyPixelHeight] as? Int == d.imageHeight,
              let decoded=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),decoded.bitsPerComponent==8,
              let context=CGContext(data:nil,width:d.imageWidth,height:d.imageHeight,bitsPerComponent:8,bytesPerRow:d.imageWidth*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return nil}
        context.draw(decoded,in:CGRect(x:0,y:0,width:d.imageWidth,height:d.imageHeight))
        guard let image=context.makeImage() else{return nil}
        return Self(descriptor:d,image:image)
    }
}

/// One atlas is shared by every instance of a matching body/size/direction. Reject oversized entries.
@MainActor final class BodySpriteCache {
    let budget: Int
    private var entries:[String:BodySprite]=[:],order:[String]=[]
    private var pins:[String:Int]=[:]
    private var workReservations:[UUID:Int]=[:]
    private(set) var residentBytes=0
    private(set) var peakBytes=0
    init(budget: Int = BodyProfile.current.atlasBudget) {self.budget=budget}
    @discardableResult func insert(_ sprite: BodySprite,key: String)->Bool {
        let cost=sprite.descriptor.decodedBytes
        guard cost<=budget else {return false}
        if pins[key,default:0]>0 {return false}
        if let old=entries.removeValue(forKey:key) {residentBytes-=old.descriptor.decodedBytes;order.removeAll{$0==key}}
        let victims=order.filter{pins[$0,default:0]==0}
        guard residentBytes+cost-victims.reduce(0,{$0+(entries[$1]?.descriptor.decodedBytes ?? 0)})<=budget else {return false}
        for victim in victims where residentBytes+cost>budget {residentBytes-=entries.removeValue(forKey:victim)!.descriptor.decodedBytes;order.removeAll{$0==victim}}
        entries[key]=sprite;order.append(key);residentBytes+=cost;peakBytes=max(peakBytes,residentBytes);return true
    }
    /// Reserve capacity before decoding, so replacement does not first hold both old and new atlases.
    @discardableResult func load(png:URL,metadata:URL,key:String)->Bool {
        guard let d=BodySprite.descriptor(at:metadata,budget:budget),pins[key,default:0]==0 else{return false}
        let victims=order.filter{pins[$0,default:0]==0}
        guard residentBytes+d.decodedBytes-victims.reduce(0,{$0+(entries[$1]?.descriptor.decodedBytes ?? 0)})<=budget else{return false}
        if let old=entries.removeValue(forKey:key) {residentBytes-=old.descriptor.decodedBytes;order.removeAll{$0==key}}
        for victim in victims where residentBytes+d.decodedBytes>budget {
            if let old=entries.removeValue(forKey:victim){residentBytes-=old.descriptor.decodedBytes};order.removeAll{$0==victim}
        }
        guard let sprite=BodySprite.load(png:png,metadata:metadata,budget:budget) else{return false}
        return insert(sprite,key:key)
    }
    /// Reserve decoded capacity before reading even the single encoded frame.
    @discardableResult func load(descriptor d: BodySpriteDescriptor, key: String, png: () throws -> Data)->Bool {
        guard BodySprite.valid(d,budget:budget),pins[key,default:0]==0 else { return false }
        let victims=order.filter { pins[$0,default:0]==0 }
        guard residentBytes+d.decodedBytes-victims.reduce(0,{$0+(entries[$1]?.descriptor.decodedBytes ?? 0)})<=budget else { return false }
        if let old=entries.removeValue(forKey:key) { residentBytes-=old.descriptor.decodedBytes; order.removeAll { $0==key } }
        for victim in victims where residentBytes+d.decodedBytes>budget {
            if let old=entries.removeValue(forKey:victim) { residentBytes-=old.descriptor.decodedBytes }
            order.removeAll { $0==victim }
        }
        guard let data=try? png(),let sprite=BodySprite.load(data:data,descriptor:d,budget:budget) else { return false }
        return insert(sprite,key:key)
    }
    func value(_ key: String)->BodySprite? {guard let s=entries[key] else{return nil};order.removeAll{$0==key};order.append(key);return s}
    func makeLayer(key:String,at now:Double)->BodySpriteLayer? {
        guard let sprite=value(key) else {return nil}
        pins[key,default:0]+=1
        return BodySpriteLayer(sprite:sprite,now:now,onDispose:{[weak self] in
            guard let self else{return};self.pins[key]=max(0,self.pins[key,default:0]-1)
        })
    }
    func removeAll() {
        for key in order.filter({pins[$0,default:0]==0}) {residentBytes-=entries.removeValue(forKey:key)!.descriptor.decodedBytes;order.removeAll{$0==key}}
    }
    /// Phase fallback work uses this same ledger, before map preparation or image allocation.
    func reserveWorkingBytes(_ bytes:Int)->UUID? {
        guard bytes>0,bytes<=budget else {return nil}
        let victims=order.filter{pins[$0,default:0]==0}
        guard residentBytes+bytes-victims.reduce(0,{$0+(entries[$1]?.descriptor.decodedBytes ?? 0)})<=budget else {return nil}
        for victim in victims where residentBytes+bytes>budget {
            residentBytes-=entries.removeValue(forKey:victim)!.descriptor.decodedBytes;order.removeAll{$0==victim}
        }
        let id=UUID();workReservations[id]=bytes;residentBytes+=bytes;peakBytes=max(peakBytes,residentBytes);return id
    }
    func releaseWorkingBytes(_ id:UUID) {residentBytes-=workReservations.removeValue(forKey:id) ?? 0}
    var count:Int {entries.count}

    /// Phase frames share the existing atlas LRU and pins. Admission includes raster/image staging and precedes rendering/allocation.
    @discardableResult func loadPhase(bodyID: String, outer: Float, scale: Int, framing: BodyProfile.Framing = .orb, key: String, render: () throws -> BodyRaster) throws -> Bool {
        if value(key) != nil {return true}
        guard outer.isFinite,outer>0,outer<=BodyProfile.current.bakeMax,(1...3).contains(scale) else{return false}
        let side=Int((outer*Float(scale)).rounded())
        let d=BodySpriteDescriptor(profile:BodyProfile.current.version,bodyID:bodyID,outer:outer,scale:scale,frameCount:1,columns:1,cellPixels:side,gutter:0,lightBin:0,framing:framing,cycleSeconds:0)
        let victims=order.filter{pins[$0,default:0]==0}
        guard d.decodedBytes*2<=budget,residentBytes+d.decodedBytes*2-victims.reduce(0,{$0+(entries[$1]?.descriptor.decodedBytes ?? 0)})<=budget else{return false}
        for victim in victims where residentBytes+d.decodedBytes*2>budget {residentBytes-=entries.removeValue(forKey:victim)!.descriptor.decodedBytes;order.removeAll{$0==victim}}
        let raster=try render()
        guard raster.width==side,raster.byteCount==d.decodedBytes else{throw BodyError.invalid("Invalid phase raster dimensions")}
        return insert(BodySprite(descriptor:d,image:try raster.image()),key:key)
    }
}

struct BodyActivity: Equatable, Sendable {
    var visible=true,keyWindow=true,ambient=true,reduceMotion=false
    var runs:Bool {visible && keyWindow && ambient && !reduceMotion}
}

/// A static contents layer. Layout/light changes are explicit; there is no animation or clock.
@MainActor final class BodySpriteLayer {
    let layer=CALayer()
    private var sprite:BodySprite?
    let descriptor:BodySpriteDescriptor
    private var shade:BodyLightLayer?
    private var lightDegrees:Float=0
    private var unknown=false
    private var onDispose:(()->Void)?
    init(sprite:BodySprite,now:Double=0,onDispose:(()->Void)?=nil) {
        self.onDispose=onDispose;self.sprite=sprite;descriptor=sprite.descriptor
        layer.actions=["contents":NSNull(),"contentsRect":NSNull(),"hidden":NSNull(),"transform":NSNull()]
        layer.isHidden=true;layer.contents=sprite.image;layer.contentsRect=sprite.descriptor.contentsRect(0)
        layer.bounds=CGRect(x:0,y:0,width:CGFloat(descriptor.outer),height:CGFloat(descriptor.outer))
        layer.contentsScale=CGFloat(descriptor.scale);layer.magnificationFilter = .linear;layer.minificationFilter = .linear
        if descriptor.albedo,let shade=try? BodyLightLayer(descriptor:descriptor) {self.shade=shade;layer.addSublayer(shade.layer)}
    }
    func activeSeconds(at now:Double)->Double {0}
    func setActivity(_ next:BodyActivity,at now:Double=0) {
        CATransaction.begin();CATransaction.setDisableActions(true);layer.isHidden = !next.visible;CATransaction.commit()
    }
    /// Direction-lit sprites require a host-selected replacement. An albedo shade changes only on layout/state input.
    @discardableResult func setLight(degrees:Float,unknown:Bool=false)throws->Bool {
        guard degrees.isFinite else {throw BodyError.invalid("Invalid light direction")}
        if let shade {try shade.setLight(degrees:degrees,unknown:unknown);lightDegrees=degrees;self.unknown=unknown;return true}
        return BodyProfile.current.quantizedDirection(degrees).index == descriptor.lightBin && unknown == (descriptor.unknown ?? false)
    }
    func frozenFrame(at now:Double=0)throws->CGImage {
        guard let sprite else {throw BodyError.invalid("Sprite layer is disposed")}
        let frame=try sprite.frozenFrame(activeSeconds:0)
        return descriptor.albedo ? try BodyLighting.applying(to:frame,descriptor:descriptor,degrees:lightDegrees,unknown:unknown):frame
    }
    isolated deinit {onDispose?()}
    func dispose(){layer.removeAllAnimations();layer.removeFromSuperlayer();layer.contents=nil;shade?.layer.removeFromSuperlayer();shade=nil;sprite=nil;onDispose?();onDispose=nil}
}

enum BodyBaker {
    static func bake(body:BodyDefinition,map:BodyMap,ring:BodyMap?=nil,clouds:BodyMap?=nil,outer:Float,scale:Int,frames:Int=1,lightDegrees:Float,framing:BodyProfile.Framing = .orb,profile:BodyProfile = .current,unlit:Bool=false,unknown:Bool=false,firstFrame:((Double)->Void)?=nil)throws->BodySprite {
        guard outer.isFinite,outer>0,outer<=profile.bakeMax,(1...3).contains(scale),frames==1 else {throw BodyError.invalid("Static bodies require exactly one frame per direction")}
        guard !unlit || !body.ellipsoid && !body.ring && !body.emits && body.atmosphere == nil else {throw BodyError.invalid("Albedo shade supports ordinary airless spheres only")}
        let cell=Int((outer*Float(scale)).rounded()),bin=profile.quantizedDirection(lightDegrees)
        var d=BodySpriteDescriptor(profile:profile.version,bodyID:body.id,outer:outer,scale:scale,frameCount:1,columns:1,cellPixels:cell,gutter:0,lightBin:bin.index,framing:framing,cycleSeconds:0)
        d.albedo=unlit;d.unknown=unknown
        guard d.decodedBytes<=profile.atlasBudget else {throw BodyError.invalid("Sprite exceeds budget")}
        let start=CFAbsoluteTimeGetCurrent()
        let r=BodyRasterizer.render(body:body,map:map,ring:ring,clouds:clouds,request:.init(outer:outer,scale:scale,framing:framing,lightDegrees:bin.degrees,unknown:unknown,unlit:unlit),profile:profile)
        firstFrame?((CFAbsoluteTimeGetCurrent()-start)*1000)
        return BodySprite(descriptor:d,image:try r.image())
    }
    static func write(_ sprite:BodySprite,prefix:URL)throws {
        guard let destination=CGImageDestinationCreateWithURL(prefix.appendingPathExtension("png") as CFURL,"public.png" as CFString,1,nil) else {throw BodyError.invalid("Cannot write atlas")}
        CGImageDestinationAddImage(destination,sprite.image,nil)
        guard CGImageDestinationFinalize(destination) else {throw BodyError.invalid("Cannot finish atlas")}
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(sprite.descriptor).write(to:prefix.appendingPathExtension("json"))
    }
}
