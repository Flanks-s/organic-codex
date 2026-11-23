import Foundation
import simd

/// The shared, versioned contract for M11.44 and M11.45. No product host is registered here.
struct BodyProfile: Codable, Equatable, Sendable {
    static let current = Self()
    var version = "org.organic.bodies.v2"
    var restZ: Float = 0.8
    var night: Float = 0.28
    var soft: Float = 0.30
    var haze: Float = 0.70
    var limb: Float = 0.22
    var rim: Float = 0.075
    var ringInner: Float = 1.18
    var ringOuter: Float = 2.33
    var supersampling = 2
    var bakeMax: Float = 56
    var bodyMotion = "static"
    var framesPerDirection = 1
    var eventRotation = false
    var ambientAnimation = false
    var phase = BodyPhaseProfile()
    var directionBins = 32
    var atlasBudget = 64 * 1024 * 1024
    var highDefinitionBudget = 32 * 1024 * 1024

    enum Framing: String, Codable, Sendable { case orb, bare }

    func bodyDiameter(outer: Float, framing: Framing) -> Float {
        guard framing == .orb else { return outer }
        let anchors: [(Float, Float)] = [(22,19),(26,22),(32,28),(36,31.5),(44,39),(48,48*50/56),(56,50),(150,140)]
        if outer <= anchors[0].0 { return outer * 19 / 22 }
        for i in 1..<anchors.count where outer <= anchors[i].0 {
            let a = anchors[i-1], b = anchors[i]
            return a.1 + (b.1-a.1) * (outer-a.0) / (b.0-a.0)
        }
        return outer * 140 / 150
    }
    func fixedTurn(body: BodyDefinition) -> Float {body.initialTurn}
    /// Compatibility only. Neither elapsed time nor events may change the body's longitude.
    func turn(body: BodyDefinition, diameter: Float, activeSeconds: Double) -> Float {fixedTurn(body:body)}
    func direction(degrees: Float) -> SIMD3<Float> {
        let a = degrees * .pi / 180
        return simd_normalize(SIMD3(cos(a),sin(a),restZ))
    }
    func light(ll: SIMD2<Float>, center: SIMD2<Float>) -> SIMD3<Float> {
        let delta = SIMD2(ll.x-center.x,center.y-ll.y)
        let d = simd_length(delta)
        return simd_normalize(SIMD3(d > 0 ? delta.x/d:0,d > 0 ? delta.y/d:0,restZ))
    }
    func quantizedDirection(_ degrees: Float) -> (index: Int, degrees: Float, error: Float) {
        let step = 360 / Float(directionBins), angle = (degrees.truncatingRemainder(dividingBy:360)+360).truncatingRemainder(dividingBy:360)
        let i = Int((angle/step).rounded()) % directionBins
        let raw = abs(Float(i)*step-angle)
        return (i,Float(i)*step,min(raw,360-raw))
    }
    func day(_ ndl: Float, unknown: Bool = false) -> Float {
        let width = unknown ? haze:soft
        let k = min(1,max(0,(ndl+width/2)/width))
        return k*k*(3-2*k)
    }
    func brightness(ndl: Float, nz: Float, unknown: Bool = false) -> Float {
        (night+(1-night)*day(ndl,unknown:unknown)*(0.62+0.38*max(0,ndl))) * (1-limb*pow(1-max(0,nz),2))
    }
}

struct BodyCatalogue: Codable, Sendable {
    let version: Int
    let boardSHA256: String
    let conversationChoices: [String]
    let bodies: [BodyDefinition]
    static func load(repository: URL) throws -> Self {
        try load(url:repository.appendingPathComponent("Resources/Bodies/catalogue.json"))
    }
    static func load(url:URL)throws->Self {try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))}
    func body(_ id: String) throws -> BodyDefinition {
        guard let body = bodies.first(where:{$0.id == id}) else { throw BodyError.invalid("Unknown body: \(id)") }
        return body
    }
}
struct BodyDefinition: Codable, Sendable {
    let id, name, tone, colorHex, glyph: String
    let glyphPath, texture, clouds, role: String?
    let tilt, elevation, rotation, initialTurn, rockDegrees: Float
    let axes: [Float]
    let atmosphere: [Float]?
    let emits, ring: Bool
    let procedure: BodyProcedure?
    var axis: SIMD3<Float> { SIMD3(axes[0],axes[1],axes[2]) }
    var ellipsoid: Bool { axes != [1,1,1] }
    var basis: (pole: SIMD3<Float>, meridian: SIMD3<Float>, east: SIMD3<Float>) {
        let t = tilt * .pi/180, e = elevation * .pi/180
        return (SIMD3(cos(e)*sin(t),cos(e)*cos(t),sin(e)),SIMD3(-sin(e)*sin(t),-sin(e)*cos(t),cos(e)),SIMD3(cos(t),-sin(t),0))
    }
}
struct BodyProcedure: Codable, Sendable {
    let c0, c1: [Float]
    let scale, contrast: Float
    let craters: Int
    let craterSizes: [Float]
    let seed: Int
    let basin, grooves: Bool
    let patchColor: [Float]?
    let patchScale, patchThreshold, patchAlpha: Float
}
enum BodyError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let message):message } }
}

/// Versioned phase recipe; the rest-light profile remains v2 and byte compatible.
struct BodyPhaseProfile: Codable, Equatable, Sendable {
    var version = "org.organic.body-phase.v1"
    var unknownEventGain: Float = 0.14
    var unknownEventDuration: Float = 0.90
    var diffuseBase: Float = 0.74
    var diffuseGain: Float = 0.26
    var floor:Float=0.14
    var umbra:Float=2.6
    var umbraSoft:Float=0.10
    var unknownLitRange:[Float]=[0.45,0.80]
    var unknownPeriod:Float=4
    var hazeFade:Float=0.4
    var waitRGB:[Float]=[0.62,0.48,0.10]
    var waitLow:Float=0.70
    var waitPeriod:Float=2.4
    var waitFade:Float=0.35
    var doneRise:Float=0.28
    var doneFall:Float=0.62
    var doneGain:Float=0.18
    var failRGB:[Float]=[0.80,0.19,0.09]
    var failSweep:Float=0.8
    var failEdge:Float=0.22
    var cancelLevel:Float=0.36
    var cancelFloor:Float=16
    var cancelFade:Float=0.5
    var fractionResponse:Float=0.5
}
