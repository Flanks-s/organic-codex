import Foundation

/// SunHover02-only tuning. Existing Dock, Tuning and mode-flight springs are not changed.
enum SunHoverParameters {
    struct Spring: Equatable { let response: Double; let damping: Double; init(_ r: Double, _ d: Double) { response = r; damping = d } }
    static let sun = Spring(0.32, 0.74), ring = Spring(0.62, 0.95), number = Spring(0.2, 1)
    static let deal = Spring(0.52, 0.82), fold = Spring(0.34, 1), satelliteHover = Spring(0.22, 0.8)
    static let label = Spring(0.3, 0.78), labelOut = Spring(0.16, 1)
    static let panel = Spring(0.42, 0.84), panelOut = Spring(0.3, 1)
    static let pickerTop = Spring(0.44, 0.84), pickerBottom = Spring(0.5, 0.9), pickerWidth = Spring(0.5, 0.84), search = Spring(0.42, 0.78)
    static let row = Spring(0.36, 0.8), requisition = Spring(0.42, 0.84), glyph = Spring(0.14, 1)
    static let grace = 0.260, numberDwell = 0.550, badgeDwell = 0.140, sunBack = 0.350, labelGrace = 0.120
    static let rowDelay = 0.070, rowStagger = 0.030, rowIn = 0.130, rowOut = 0.070, closeHold = 0.050
    static let labelGone = 0.1, labelPass = 0.6, labelSettle = 2.0, labelClearance = 12.0
    static let arcRadius = 160.0, arcLengths = [84.0, 130, 176, 222, 268, 314]
    static let labelWidths = [78.0, 94, 66, 106, 88, 74]
    static let labelDistances = [41.0, 41, 41, 52.75, 50, 41], labelLeftShares = [0.0, 0, 0, 0.4, 0.5, 0]
    static let satelliteDiameter = 34.0, dockDiameter = 32.0, margin = 10.0
    static let llIdleDiameter = 36.0, llOpenDiameter = 42.0
    static let minimumPickerHeight = 3.0 * 32 + 44 + 24
    struct Color: Equatable { let red: Double, green: Double, blue: Double, alpha: Double }
    static let goo = Color(red: 51/255, green: 53/255, blue: 51/255, alpha: 1)
    static let ll = Color(red: 50/255, green: 111/255, blue: 94/255, alpha: 1)
    static let panelGlass = Color(red: 48/255, green: 50/255, blue: 48/255, alpha: 0.82)
    static let pickerGlass = Color(red: 46/255, green: 48/255, blue: 46/255, alpha: 0.92)
    static let error = Color(red: 1, green: 69/255, blue: 58/255, alpha: 1)
    static let question = Color(red: 1, green: 214/255, blue: 10/255, alpha: 1)
    static let accent = Color(red: 52/255, green: 120/255, blue: 246/255, alpha: 1)
    static let ringTrackAlpha = 0.14, ringUsedAlpha = 0.85, scrimAlpha = 0.24
    static let strokeAlpha = 0.2, searchAlpha = 0.08, placeholderAlpha = 0.42, rowHoverAlpha = 0.08
    static let textAlpha = 0.92, secondaryTextAlpha = 0.55, noteAlpha = 0.45, shadowAlpha = 0.45
}

/// Analytic spring segment: arbitrary sampling does not change the trajectory or the semantic clock.
struct SunHoverMotion {
    private var initial: Double, velocity = 0.0, start = 0.0
    private var spring = SunHoverParameters.Spring(0.3, 1)
    private var fadeDuration: Double?
    private(set) var target: Double
    init(_ value: Double) { initial = value; target = value }
    mutating func aim(_ goal: Double, at time: Double, delay: Double = 0,
                      spring: SunHoverParameters.Spring, instant: Bool = false, fadeDuration: Double? = nil) {
        guard target != goal else { return }
        let sample = sample(at: time)
        initial = instant ? goal : sample.0; velocity = instant ? 0 : sample.1
        target = goal; start = time + delay; self.spring = spring; self.fadeDuration = fadeDuration
    }
    func value(at time: Double) -> Double { sample(at: time).0 }
    func isMoving(at time: Double) -> Bool {
        let (value, velocity) = sample(at: time)
        return abs(value - target) > 0.0001 || abs(velocity) > 0.001
    }
    private func sample(at time: Double) -> (Double, Double) {
        let t = max(0, time - start)
        if let fadeDuration {
            let q = min(1, t / fadeDuration)
            return (initial + (target - initial) * SunHoverGeometry.smooth(q), 0)
        }
        let w = 2 * Double.pi / spring.response, z = spring.damping, a = initial - target
        if z >= 1 {
            let b = velocity + w * a, e = exp(-w * t)
            return (target + (a + b * t) * e, (b - w * (a + b * t)) * e)
        }
        let wd = w * sqrt(1 - z * z), b = (velocity + z * w * a) / wd
        let c = cos(wd * t), s = sin(wd * t), e = exp(-z * w * t)
        return (target + e * (a * c + b * s), e * (-z * w * (a * c + b * s) + wd * (-a * s + b * c)))
    }
}

/// Independent shape channels preserve the live rectangle when one open panel changes kind.
/// The semantic state above never owns a view; B keeps one shape sampler alongside it.
struct SunHoverPanelMotion {
    struct Pose { let rect: CGRect; let radius: Double; let opacity: Double }
    private var x: SunHoverMotion, y: SunHoverMotion, width: SunHoverMotion, height: SunHoverMotion
    private var source: CGPoint
    private var isOpen = false
    init(source: CGPoint) {
        self.source = source
        x = .init(source.x - 7); y = .init(source.y - 7); width = .init(14); height = .init(14)
    }
    mutating func show(_ kind: SunHoverPanel, source: CGPoint, geometry: SunHoverGeometry,
                       attentionCount: Int = 4, accountHeight: Double = 142, at time: Double) {
        if !isOpen, abs(width.value(at: time) - 14) <= 0.5, abs(height.value(at: time) - 14) <= 0.5 {
            x = .init(source.x - 7); y = .init(source.y - 7); width = .init(14); height = .init(14)
        }
        isOpen = true
        self.source = source
        let goal = geometry.panelTarget(kind, attentionCount: attentionCount, accountHeight: accountHeight)
        aim(goal, at: time, spring: SunHoverParameters.panel)
    }
    mutating func close(at time: Double) {
        isOpen = false
        aim(.init(x: source.x - 7, y: source.y - 7, width: 14, height: 14), at: time, spring: SunHoverParameters.panelOut)
    }
    private mutating func aim(_ rect: CGRect, at time: Double, spring: SunHoverParameters.Spring) {
        x.aim(rect.minX, at: time, spring: spring); y.aim(rect.minY, at: time, spring: spring)
        width.aim(rect.width, at: time, spring: spring); height.aim(rect.height, at: time, spring: spring)
    }
    func pose(at time: Double, geometry: SunHoverGeometry) -> Pose {
        let w = max(14, width.value(at: time)), h = max(14, height.value(at: time))
        let rect = geometry.fitted(.init(x: x.value(at: time), y: y.value(at: time), width: w, height: h))
        return .init(rect: rect, radius: min(20, rect.height / 2), opacity: SunHoverGeometry.smooth((w - 14) / 40))
    }
    func needsFrames(at time: Double) -> Bool { [x, y, width, height].contains { $0.isMoving(at: time) } }
}

/// Top-left window points, like the design board. B passes the actual raised LL centre and Dock baseline.
struct SunHoverGeometry {
    let llCenter: CGPoint
    let dockBaseline: Double
    let bounds: CGRect
    let backingScale: Double
    static func smooth(_ x: Double) -> Double { let x = min(1, max(0, x)); return x * x * (3 - 2 * x) }
    static func mix(_ a: Double, _ b: Double, _ q: Double) -> Double { a + (b - a) * q }
    func arc(_ distance: Double) -> (center: CGPoint, normal: CGPoint) {
        let a = distance / SunHoverParameters.arcRadius, r = SunHoverParameters.arcRadius
        return (.init(x: llCenter.x + r * (1 - cos(a)), y: llCenter.y - r * sin(a)), .init(x: cos(a), y: sin(a)))
    }
    func satelliteCenter(_ key: SunHoverSatellite) -> CGPoint { arc(SunHoverParameters.arcLengths[key.rawValue]).center }
    func satellite(_ key: SunHoverSatellite, progress: Double, hover: Double = 0, reduceMotion: Bool = false) -> CGRect {
        let s = SunHoverParameters.arcLengths[key.rawValue] * max(0, progress)
        let p = arc(reduceMotion ? SunHoverParameters.arcLengths[key.rawValue] : s).center
        let d = reduceMotion ? 34 : 10 + 24 * Self.smooth(s / 56) + 3 * hover
        return fitted(.init(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
    }
    func satelliteHitRect(_ key: SunHoverSatellite, progress: Double, reduceMotion: Bool = false) -> CGRect {
        let s = SunHoverParameters.arcLengths[key.rawValue]
        let p = arc(reduceMotion ? s : s * max(0, progress)).center
        return fitted(.init(x: p.x - 17, y: p.y - 17, width: 34, height: 34))
    }
    func label(_ key: SunHoverSatellite, progress: Double = 1, aligned: Bool = false) -> CGRect {
        let i = key.rawValue, p = arc(SunHoverParameters.arcLengths[i]), c = min(1, max(0, progress))
        let h = Self.mix(10, 28, c), width = Self.mix(10, SunHoverParameters.labelWidths[i], pow(c, 1.5))
        let distance = SunHoverParameters.labelDistances[i] * c
        let rect = CGRect(x: p.center.x + p.normal.x * distance - h / 2 - SunHoverParameters.labelLeftShares[i] * (width - h),
                          y: p.center.y + p.normal.y * distance - h / 2, width: width, height: h)
        return aligned ? fitted(rect) : clamp(rect)
    }
    var zone: CGRect { fitted(.init(x: llCenter.x - 26, y: llCenter.y - 180, width: 276, height: 158)) }
    func panelTarget(_ kind: SunHoverPanel, attentionCount: Int = 4, accountHeight: Double = 142) -> CGRect {
        let width: Double, height: Double
        switch kind {
        case .attention: width = 316; height = 40 + 46 * Double(min(6, max(1, attentionCount)))
        case .usage: width = 288; height = 178
        // Preserve the board value. B must pass the approved height for Advisor's extra Sign Out row/divider.
        case .account: width = 240; height = accountHeight
        }
        let bottom = min(bounds.maxY - 10, dockBaseline - 28)
        let fittedHeight = min(height, max(0, bottom - bounds.minY - 10))
        return fitted(.init(x: llCenter.x - 26, y: bottom - fittedHeight, width: width, height: fittedHeight))
    }
    func panelRect(_ kind: SunHoverPanel, source: CGPoint, progress: Double, attentionCount: Int = 4, accountHeight: Double = 142) -> CGRect {
        let q = min(1, max(0, progress)), goal = panelTarget(kind, attentionCount: attentionCount, accountHeight: accountHeight)
        return fitted(.init(x: Self.mix(source.x - 7, goal.minX, q), y: Self.mix(source.y - 7, goal.minY, q),
                            width: Self.mix(14, goal.width, q), height: Self.mix(14, goal.height, q)))
    }
    var pickerTarget: CGRect {
        pickerTarget(minimumHeight: SunHoverParameters.minimumPickerHeight)
    }
    /// B may pass the measured height of three native lyric rows plus its search field/padding.
    func pickerTarget(minimumHeight: Double) -> CGRect {
        let bottom = min(bounds.maxY - 10, dockBaseline - 34)
        let above = max(0, bottom - bounds.minY - 10)
        let h = min(560.0, min(max(0, bounds.height - 20), max(minimumHeight, above)))
        return fitted(.init(x: llCenter.x - 26, y: bottom - h, width: 408, height: h))
    }
    func pickerRect(source: CGPoint, top: Double, bottom: Double, width: Double,
                    minimumHeight: Double = SunHoverParameters.minimumPickerHeight) -> CGRect {
        let goal = pickerTarget(minimumHeight: minimumHeight), w = max(0, width), h = max(0, top), b = max(0, bottom)
        let left = Self.mix(source.x - 17, goal.minX, w), y = Self.mix(source.y - 17, goal.minY, h)
        let end = Self.mix(source.y + 17, goal.maxY, b)
        return fitted(.init(x: left, y: y, width: Self.mix(34, goal.width, w), height: max(34, end - y)))
    }
    struct Ring { let center: CGPoint; let radius: Double; let stroke: Double; let used: Double?; let sweep: Double }
    func ring(diameter: Double, number: Double, progress: Double, usage: AccountUsage, reduceMotion: Bool) -> Ring {
        .init(center: llCenter, radius: diameter / 2 + 3.5, stroke: Self.mix(2, 3, number),
              used: usage.tightest?.used, sweep: (reduceMotion ? 1 : min(1, max(0, progress))) * (usage.tightest?.used ?? 0))
    }
    func clamp(_ rect: CGRect) -> CGRect {
        let available = bounds.insetBy(dx: min(10, bounds.width / 2), dy: min(10, bounds.height / 2))
        let w = min(rect.width, available.width), h = min(rect.height, available.height)
        return .init(x: min(max(rect.minX, available.minX), available.maxX - w),
                     y: min(max(rect.minY, available.minY), available.maxY - h), width: w, height: h)
    }
    func fitted(_ rect: CGRect) -> CGRect {
        let rect = clamp(rect), scale = max(1, backingScale)
        let available = clamp(bounds)
        let left = (available.minX * scale).rounded(.up) / scale, top = (available.minY * scale).rounded(.up) / scale
        let right = (available.maxX * scale).rounded(.down) / scale, bottom = (available.maxY * scale).rounded(.down) / scale
        let w = min((rect.width * scale).rounded() / scale, max(0, right - left))
        let h = min((rect.height * scale).rounded() / scale, max(0, bottom - top))
        return .init(x: min(max((rect.minX * scale).rounded() / scale, left), right - w),
                     y: min(max((rect.minY * scale).rounded() / scale, top), bottom - h), width: w, height: h)
    }
}
