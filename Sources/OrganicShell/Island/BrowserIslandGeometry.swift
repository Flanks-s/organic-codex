import AppKit

enum BrowserIslandMetrics {
    static let center = CGPoint(x: 311.5, y: 80)
    static let dock = CGPoint(x: 1066, y: 764)
    static let islandY = 104.0, islandHeight = 32.0
    static let addressMin = 168.0, addressMax = 300.0, rowIn = 34.0, rowOut = 14.0
    static let siteSize = CGSize(width: 320, height: 296), cardRadius = 20.0
    static let backWidth = 72.0, reloadWidth = 32.0, lobeGap = 10.0
    static let tools = CGRect(x: 369.5, y: 56, width: 124, height: 32)
    static let toolsOrigin = CGPoint(x: 326, y: 74)
    static let rowAt = 0.10, rowStep = 0.035, rowDuration = 0.14, rowBlur = 6.0, rowRise = 6.0
    static let flightDuration = 0.58, flightEnd = 0.82
    static let moonDiameter = 12.0, moonPeriod = 18.0, moonTilt = -18.0, moonRY = 16.0
    static let page = CGRect(x: 14, y: 150, width: 570, height: 578)
}

struct BrowserAddressLayout: Equatable {
    let host: String
    let rest: String
    let placeholder: Bool
    let width: Double
    @MainActor static func live(_ address: String) -> Self {
        let font=NSFont.systemFont(ofSize:13,weight:.semibold)
        func measure(_ text:String)->Double {Double((text as NSString).size(withAttributes:[.font:font]).width)}
        var text=address
        let characters=Array(address);var a=characters.count/2,b=a
        while measure(text)>252,a>2,b<characters.count-2 {
            a-=1;b+=1;text=String(characters.prefix(a))+"…"+String(characters.dropFirst(b))
        }
        return .init(host:text,rest:"",placeholder:false,width:min(300,max(168,48+measure(text))))
    }
    @MainActor static func make(_ page: BrowserMockPage) -> Self {
        let regular = NSFont.systemFont(ofSize: 13), bold = NSFont.systemFont(ofSize: 13, weight: .semibold)
        func measure(_ text: String, _ font: NSFont) -> Double { Double((text as NSString).size(withAttributes: [.font: font]).width) }
        if page.host.isEmpty {
            return .init(host: "", rest: "", placeholder: true, width: min(300, max(168, 48 + measure("Search or enter a URL", regular))))
        }
        let hostWidth = measure(page.host, bold), available = 300 - 48 - hostWidth
        var rest = page.port + page.path, a = Int(ceil(Double(page.path.count) / 2)), b = a
        let path = Array(page.path)
        while a > 2 && measure(rest, regular) > available {
            a -= 1; b += 1
            rest = page.port + String(path.prefix(a)) + "…" + String(path.dropFirst(min(b, path.count)))
        }
        return .init(host: page.host, rest: rest, placeholder: false, width: min(300, max(168, 48 + hostWidth + measure(rest, regular))))
    }
}

struct BrowserLobePose {
    var frame: CGRect
    var neckStart: CGPoint
    var neckEnd: CGPoint
    var neckWidth: Double
    var contentAlpha: Double
    var contentScale: Double
    var contentBlur: Double
}

enum BrowserIslandMath {
    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }
    static func smooth(_ x: Double) -> Double { let k = clamp(x); return k * k * (3 - 2 * k) }
    static func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }
    static func bezier(_ x: Double, _ p: (Double, Double, Double, Double)) -> Double {
        if x <= 0 { return 0 }; if x >= 1 { return 1 }
        func value(_ a: Double, _ b: Double, _ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t }
        var lo = 0.0, hi = 1.0
        for _ in 0..<22 { let mid = (lo + hi) / 2; if value(p.0, p.2, mid) < x { lo = mid } else { hi = mid } }
        return value(p.1, p.3, (lo + hi) / 2)
    }
    static func flight(from a: CGPoint, to b: CGPoint, diameterA: Double, diameterB: Double, sign: Double, time: Double, delay: Double) -> CGRect {
        let u = bezier((time - delay) / 0.58, (0.32, 0, 0.2, 1)), dx = b.x - a.x, dy = b.y - a.y
        let p1 = CGPoint(x: a.x + dx * 0.10 - dy * sign * 0.26, y: a.y + dy * 0.10 + dx * sign * 0.26)
        let p2 = CGPoint(x: a.x + dx * 0.58 - dy * sign * 0.14, y: a.y + dy * 0.58 + dx * sign * 0.14)
        func at(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double { pow(1 - u, 3) * a + 3 * pow(1 - u, 2) * u * b + 3 * (1 - u) * u * u * c + u * u * u * d }
        let d = lerp(diameterA, diameterB, u), x = at(a.x, p1.x, p2.x, b.x), y = at(a.y, p1.y, p2.y, b.y)
        return CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)
    }
}
