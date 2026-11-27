import Foundation
import CryptoKit
import ImageIO

@main struct BakePackage {
    static func main() throws {
        guard CommandLine.arguments.count == 4,let layout=BodySpriteIndex.Layout(rawValue:CommandLine.arguments[3]) else { throw BodyError.invalid("Usage: bake-package REPOSITORY OUTPUT direction-pack|direction-files") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let out = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let catalogue = try BodyCatalogue.load(repository: root)
        let maps = BodyMapStore(repository: root)
        let start = ProcessInfo.processInfo.systemUptime
        var count = 0, bytes = 0, decoded = 0, groups: [String:BodySpriteIndex.Group] = [:]
        for body in catalogue.bodies {
            let map = try maps.map(for: body)
            let ring = body.ring ? try maps.named("saturn_ring") : nil
            let clouds = try body.clouds.map { try maps.named($0) }
            for outer in [16,22,26,32,36,44,48,56,64] {
                for scale in [1,2] {
                    for unknown in [false,true] {
                        let group="\(body.id)-d\(outer)-s\(scale)-u\(unknown ? 1:0)",filename=group+".bodyframes"
                        var handle:FileHandle?,offset:UInt64=0,offsets:[UInt64]=[],lengths:[Int]=[],descriptor:BodySpriteDescriptor?
                        if layout == .packed {
                            let url=out.appendingPathComponent(filename)
                            guard FileManager.default.createFile(atPath:url.path,contents:nil) else { throw BodyError.invalid("Cannot create sprite pack") }
                            handle=try FileHandle(forWritingTo:url)
                        }
                        defer { try? handle?.close() }
                        for bin in 0..<32 {
                            let name = "\(body.id)-d\(outer)-s\(scale)-l\(bin)-u\(unknown ? 1:0)"
                            let sprite: BodySprite
                            if Float(outer)<=BodyProfile.current.bakeMax {
                                sprite=try BodyBaker.bake(body:body,map:map,ring:ring,clouds:clouds,outer:Float(outer),scale:scale,lightDegrees:Float(bin)*11.25,unknown:unknown)
                            } else {
                                // This is a larger sampling bank, not a larger logical orb. Keep the small-orb cutoff intact.
                                let request=BodyRenderRequest(outer:Float(outer),scale:scale,lightDegrees:Float(bin)*11.25,unknown:unknown)
                                let raster=BodyRasterizer.render(body:body,map:map,ring:ring,clouds:clouds,request:request)
                                var d=BodySpriteDescriptor(profile:BodyProfile.current.version,bodyID:body.id,outer:Float(outer),scale:scale,frameCount:1,columns:1,cellPixels:outer*scale,gutter:0,lightBin:bin,framing:.orb,cycleSeconds:0)
                                d.unknown=unknown
                                sprite=BodySprite(descriptor:d,image:try raster.image())
                            }
                            if descriptor == nil { descriptor=sprite.descriptor }
                            let data=NSMutableData()
                            guard let destination=CGImageDestinationCreateWithData(data as CFMutableData,"public.png" as CFString,1,nil) else { throw BodyError.invalid("Cannot encode sprite PNG") }
                            CGImageDestinationAddImage(destination,sprite.image,nil)
                            guard CGImageDestinationFinalize(destination) else { throw BodyError.invalid("Cannot finish sprite PNG") }
                            let png=data as Data
                            if let handle { try handle.write(contentsOf:png) }
                            else { try png.write(to:out.appendingPathComponent(name+".png")) }
                            offsets.append(layout == .packed ? offset:0);lengths.append(png.count);offset+=UInt64(png.count)
                            bytes += png.count
                            decoded += sprite.descriptor.decodedBytes; count += 1
                        }
                        groups[group] = .init(descriptor:descriptor!,file:layout == .packed ? filename:nil,offsets:offsets,lengths:lengths)
                    }
                }
            }
            print("Baked \(body.id): \(count) direction images")
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        try encoder.encode(BodySpriteIndex(version:BodySpriteIndex.currentVersion,layout:layout,groups:groups)).write(to:out.appendingPathComponent("index.json"))
        let receipt: [String: Any] = ["profile": BodyProfile.current.version,"layout":layout.rawValue,"groups":groups.count, "images": count, "pngBytes": bytes, "allDirectionsDecodedBytes": decoded, "mapCacheBytes": maps.residentBytes]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted,.sortedKeys]).write(to: out.appendingPathComponent("package.json"))
        let timing=["bakeWallSeconds":ProcessInfo.processInfo.systemUptime-start]
        try JSONSerialization.data(withJSONObject:timing,options:[.sortedKeys]).write(to:out.deletingLastPathComponent().appendingPathComponent("bake-timing.json"))
        print(receipt)
    }
}
