import AppKit

/// Static M11.44 Earth and Mercury pictures, plus 12 pt bare moons in the shared sprite ledger.
@MainActor final class BrowserBodyImages {
    static let companions: [(String, Double, CGPoint)] = [("venus", 44, CGPoint(x: 757.5, y: 78)), ("neptune", 44, CGPoint(x: 1086, y: 78)),
        ("mars", 32, CGPoint(x: 1122, y: 764)), ("jupiter", 32, CGPoint(x: 1178, y: 764)), ("saturn", 32, CGPoint(x: 1234, y: 764))]
    let resources: BodyResources
    var hostLL: CGPoint?
    private var pins: [String: BodySpriteLayer] = [:]
    private(set) var preparedMoonFrames = 0
    init(resources: BodyResources = .shared) { self.resources = resources }
    func prepare() async throws {
        guard pins.isEmpty else { return }
        for scale in [1, 2] {
            for (id, outer, center) in Self.companions {
                let input = BodyPresentationInput(bodyID: id, outer: outer, scale: scale, ll: CGPoint(x: 48, y: 764), center: center)
                guard let key = resources.load(input), let pin = resources.sprites.makeLayer(key: key, at: 0) else { throw BodyError.invalid("Browser companion sprite unavailable") }
                pins[key] = pin
            }
            for id in ["earth", "mercury"] {
                for outer in [32, 56] {
                    for bin in 0..<32 {
                        let angle = Double(bin) * 2 * Double.pi / 32
                        let input = BodyPresentationInput(bodyID: id, outer: CGFloat(outer), scale: scale,
                            ll: CGPoint(x: cos(angle), y: -sin(angle)), center: .zero)
                        guard let key = resources.load(input), let pin = resources.sprites.makeLayer(key: key, at: 0) else { throw BodyError.invalid("Browser body sprite unavailable") }
                        pins[key] = pin
                    }
                }
            }
        }
        guard let queue = resources.queue else { throw BodyError.invalid("Browser body resource queue unavailable") }
        let maps = try await queue.prepare("moon", maximumWidth: 256)
        for scale in [1, 2] {
            for bin in 0..<32 {
                let key = "browser-bare-moon-d12-s\(scale)-l\(bin)"
                let admitted = try resources.sprites.loadPhase(bodyID: "moon", outer: 12, scale: scale, framing: .bare, key: key) {
                    self.preparedMoonFrames += 1
                    return BodyRasterizer.render(body: maps.body, map: maps.map,
                        request: .init(outer: 12, scale: scale, framing: .bare, lightDegrees: Float(bin) * 360 / 32, phase: nil))
                }
                guard admitted, let pin = resources.sprites.makeLayer(key: key, at: 0) else { throw BodyError.invalid("Browser bare moon budget exhausted") }
                pins[key] = pin
            }
        }
    }
    func image(_ body: String, outer: Double, scale: Int, center: CGPoint) -> CGImage? {
        let ll = hostLL ?? CGPoint(x: 48, y: 764)
        let degrees = Float(atan2(center.y - ll.y, ll.x - center.x) * 180 / .pi)
        let bin = BodyProfile.current.quantizedDirection(degrees).index
        let tier = body == "earth" || body == "mercury" ? (outer > 32 ? 56 : 32) : Int(outer)
        let key = body == "moon" ? "browser-bare-moon-d12-s\(scale)-l\(bin)" : "\(body)-d\(tier)-s\(scale)-l\(bin)-u0"
        return resources.sprites.value(key)?.image
    }
    func dispose() { for pin in pins.values { pin.dispose() }; pins = [:] }
}
