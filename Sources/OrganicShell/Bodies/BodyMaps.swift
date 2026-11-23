import Foundation
import CoreGraphics
import ImageIO
import simd

struct BodyMap: Sendable {
    let identity = UUID()
    let width, height: Int
    let pixels: [UInt8]
    var byteCount: Int { pixels.count }
    func sample(u: Float, v: Float) -> SIMD4<Float> {
        let fx = (u-floor(u))*Float(width)-0.5, fy = min(Float(height-1),max(0,v*Float(height)-0.5))
        let x = Int(floor(fx)), y = Int(floor(fy)), tx = fx-floor(fx), ty = fy-Float(y)
        func pixel(_ xx: Int,_ yy: Int) -> SIMD4<Float> {
            let ix = (xx % width + width) % width, iy = min(height-1,max(0,yy)), o = (iy*width+ix)*4
            return SIMD4(Float(pixels[o]),Float(pixels[o+1]),Float(pixels[o+2]),Float(pixels[o+3])/255)
        }
        return (pixel(x,y)*(1-tx)+pixel(x+1,y)*tx)*(1-ty)+(pixel(x,y+1)*(1-tx)+pixel(x+1,y+1)*tx)*ty
    }
    static func load(_ url: URL, maximumWidth: Int = 2048) throws -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw BodyError.invalid("Cannot decode \(url.lastPathComponent)") }
        let w = min(maximumWidth,image.width), h = max(1,Int((Double(image.height)*Double(w)/Double(image.width)).rounded()))
        var bytes = [UInt8](repeating:0,count:w*h*4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let c = CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.interpolationQuality = .high; c.draw(image,in:CGRect(x:0,y:0,width:w,height:h));return true
        }
        guard ok else { throw BodyError.invalid("Cannot allocate map context") }
        for o in stride(from:0,to:bytes.count,by:4) where bytes[o+3] > 0 && bytes[o+3] < 255 {
            let a = Float(bytes[o+3])/255
            for k in 0..<3 { bytes[o+k] = UInt8(min(255,(Float(bytes[o+k])/a).rounded())) }
        }
        return Self(width:w,height:h,pixels:bytes)
    }
    func cgImage() throws -> CGImage {
        guard let provider = CGDataProvider(data:Data(pixels) as CFData), let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { throw BodyError.invalid("Cannot create image") }
        return image
    }
    func fillingPlutoGaps() -> Self {
        var d = pixels, boundary = [Int](repeating:0,count:width), average = [SIMD3<Float>](repeating:.zero,count:width)
        func lum(_ x: Int,_ y: Int) -> Float { let o=(y*width+x)*4;return Float(d[o])*0.3+Float(d[o+1])*0.59+Float(d[o+2])*0.11 }
        for x in 0..<width {
            var y=height-1
            while y > Int(Float(height)*0.3) && lum(x,y)<16 { y-=1 }
            boundary[x]=y+1
            var yy=Int(Float(height)*0.3)
            while yy<boundary[x] {
                if lum(x,yy)>=16 { yy+=1;continue }
                var end=yy
                while end<boundary[x] && lum(x,end)<16 { end+=1 }
                if end-yy<=10 && end<boundary[x] && yy>0 {
                    for k in yy..<end { let f=Float(k-yy+1)/Float(end-yy+1),o=(k*width+x)*4,a=((yy-1)*width+x)*4,b=(end*width+x)*4
                        for c in 0..<3 { d[o+c]=UInt8((Float(d[a+c])*(1-f)+Float(d[b+c])*f).rounded()) }
                    }
                }
                yy=max(yy+1,end)
            }
            var sum=SIMD3<Float>.zero,n:Float=0
            for row in max(0,boundary[x]-60)..<max(0,boundary[x]-8) {let o=(row*width+x)*4;sum+=SIMD3(Float(d[o]),Float(d[o+1]),Float(d[o+2]));n+=1}
            average[x]=sum/max(1,n)
        }
        let radius=max(1,width>>5)
        for x in 0..<width {
            var color=SIMD3<Float>.zero
            for k in -radius...radius {color+=average[(x+k+width)%width]}
            color/=Float(2*radius+1)
            let gray=simd_dot(color,SIMD3(0.3,0.59,0.11)),start=max(0,boundary[x]-3)
            for y in start..<height {
                let k=Float(y-start)/Float(max(1,height-start)),f:Float=0.86-0.36*k,w=min(1,Float(y-start)/6),o=(y*width+x)*4
                let value=(color*0.75+SIMD3(repeating:gray*0.25))*f
                for c in 0..<3 {d[o+c]=UInt8(min(255,max(0,Float(d[o+c])*(1-w)+value[c]*w)).rounded())}
            }
        }
        return Self(width:width,height:height,pixels:d)
    }
}

/// Bounded decoded-map LRU. Images are loaded only on explicit semantic preparation, never by a timer.
final class BodyMapStore {
    let textureDirectory: URL
    let budget: Int
    private var maps: [String:BodyMap] = [:]
    private var order: [String] = []
    private(set) var residentBytes = 0
    private(set) var decodes = 0
    convenience init(repository: URL,budget:Int = BodyProfile.current.highDefinitionBudget / 2) {self.init(textureDirectory:repository.appendingPathComponent("design/orrery/project/tex"),budget:budget)}
    init(textureDirectory:URL,budget:Int = BodyProfile.current.highDefinitionBudget / 2) {self.textureDirectory=textureDirectory;self.budget=budget}
    func map(for body: BodyDefinition, maximumWidth: Int = 1024, clampPluto: Bool = false) throws -> BodyMap {
        let key=body.id+"@\(maximumWidth)"
        if let map=maps[key] {touch(key);return map}
        let map: BodyMap
        if let texture=body.texture {
            let source=try BodyMap.load(textureDirectory.appendingPathComponent("\(texture).jpg"),maximumWidth:body.id == "pluto" && !clampPluto ? 2048:maximumWidth)
            map=body.id == "pluto" ? source.fillingPlutoGaps():source
        } else if let p=body.procedure {map=BodyProcedural.make(p)}
        else {throw BodyError.invalid("Missing map: \(body.id)")}
        try insert(map,key:key);decodes+=1;return map
    }
    func named(_ name: String, maximumWidth: Int = 2048) throws -> BodyMap {
        let key=name+"@\(maximumWidth)"
        if let map=maps[key] {touch(key);return map}
        let ext=name == "saturn_ring" ? "png":"jpg"
        let map=try BodyMap.load(textureDirectory.appendingPathComponent("\(name).\(ext)"),maximumWidth:maximumWidth)
        try insert(map,key:key);decodes+=1;return map
    }
    private func touch(_ key: String) {order.removeAll{$0 == key};order.append(key)}
    private func insert(_ map: BodyMap,key: String) throws {
        guard map.byteCount<=budget else {throw BodyError.invalid("Map exceeds decoded budget")}
        while residentBytes+map.byteCount>budget,let oldest=order.first {residentBytes-=maps.removeValue(forKey:oldest)!.byteCount;order.removeFirst()}
        maps[key]=map;residentBytes+=map.byteCount;touch(key)
    }
    func removeAll() {maps.removeAll();order.removeAll();residentBytes=0}
}

enum BodyProcedural {
    static func hash(_ x: Int,_ y: Int,_ z: Int,_ seed: Int) -> Float {
        var h=UInt32(truncatingIfNeeded:x)&*374761393 ^ UInt32(truncatingIfNeeded:y)&*668265263 ^ UInt32(truncatingIfNeeded:z)&*1440662683 ^ UInt32(truncatingIfNeeded:seed)&*1274126177
        h=(h ^ (h>>13))&*1274126177;h ^= h>>16
        return Float(Double(h)/4294967296)
    }
    static func noise(_ p: SIMD3<Float>,_ seed: Int) -> Float {
        let x=Int(floor(p.x)),y=Int(floor(p.y)),z=Int(floor(p.z)),f=p-SIMD3(Float(x),Float(y),Float(z)),w=f*f*(SIMD3(repeating:3)-2*f)
        func mix(_ a: Float,_ b: Float,_ t: Float)->Float {a+(b-a)*t}
        return mix(mix(mix(hash(x,y,z,seed),hash(x+1,y,z,seed),w.x),mix(hash(x,y+1,z,seed),hash(x+1,y+1,z,seed),w.x),w.y),mix(mix(hash(x,y,z+1,seed),hash(x+1,y,z+1,seed),w.x),mix(hash(x,y+1,z+1,seed),hash(x+1,y+1,z+1,seed),w.x),w.y),w.z)
    }
    static func fbm(_ p: SIMD3<Float>,_ seed: Int,_ octaves: Int)->Float {
        var amplitude:Float=0.5,frequency:Float=1,value:Float=0,total:Float=0
        for i in 0..<octaves {value+=amplitude*noise(p*frequency,seed+i);total+=amplitude;amplitude*=0.5;frequency*=2.03}
        return value/total
    }
    static func make(_ p: BodyProcedure, width: Int = 512) -> BodyMap {
        let height=width/2
        var bytes=[UInt8](repeating:255,count:width*height*4),state=Double(p.seed*9301+49297)
        func random()->Float {state=(state*9301+49297).truncatingRemainder(dividingBy:233280);return Float(state/233280)}
        var craters:[(SIMD3<Float>,Float,Float)]=[]
        for _ in 0..<p.craters {let z=random()*2-1,a=random()*2 * .pi,r=sqrt(1-z*z),radius=p.craterSizes[0]+(p.craterSizes[1]-p.craterSizes[0])*pow(random(),2.2);craters.append((SIMD3(r*sin(a),z,r*cos(a)),radius,cos(radius*1.35)))}
        let c0=SIMD3(p.c0[0],p.c0[1],p.c0[2]),c1=SIMD3(p.c1[0],p.c1[1],p.c1[2])
        for y in 0..<height {let lat=(0.5-(Float(y)+0.5)/Float(height)) * .pi
            for x in 0..<width {
                let lon=((Float(x)+0.5)/Float(width)-0.5)*2 * .pi,q=SIMD3(cos(lat)*sin(lon),sin(lat),cos(lat)*cos(lon))
                let t=min(1,max(0,0.5+(fbm(q*p.scale+SIMD3(11,7,3),p.seed,5)-0.5)*p.contrast*4))
                var color=c0+(c1-c0)*t
                if let pc=p.patchColor {let m=fbm(q*p.patchScale+SIMD3(5,9,1),p.seed+7,4),w=p.patchAlpha*min(1,max(0,(m-p.patchThreshold+0.05)/0.1));color+=(SIMD3(pc[0],pc[1],pc[2])-color)*w}
                var f:Float=1
                for (center,radius,limit) in craters {let dp=simd_dot(q,center);if dp<limit {continue};let k=acos(min(1,dp))/radius;if k<1 {f*=0.86+0.14*k*k};f*=1+0.14*exp(-pow((k-1)/0.13,2))}
                if p.basin {let k=acos(min(1,max(-1,-q.y)))/0.95;if k<1 {f*=0.93+0.1*k*k+0.12*exp(-k*k/0.02)};f*=1+0.1*exp(-pow((k-1)/0.08,2))}
                if p.grooves {f*=1-0.08*pow(abs(sin(lat*40)),6)*exp(-lat*lat/0.05)}
                let o=(y*width+x)*4
                for c in 0..<3 {bytes[o+c]=UInt8(min(255,max(0,(color[c]*f).rounded())))}
            }
        }
        return BodyMap(width:width,height:height,pixels:bytes)
    }
}
