import AppKit
import SwiftUI

/// Independent port of Model/Identity.swift, including both appearance palettes.
struct OrbIdentity: Equatable {
    var symbol: OrbCelestialBody
    var tint: OrbTint
    static func assigned(_ index: Int) -> Self {
        let n = max(0, index), bodies = OrbCelestialBody.allCases, colors = OrbTint.allCases
        let body = bodies[n % bodies.count], round = n / bodies.count
        return Self(symbol: body, tint: colors[round == 0 ? body.rawValue : (body.rawValue + round * 5) % colors.count])
    }
}

enum OrbCelestialBody: Int, CaseIterable {
    case mercury, venus, earth, mars, jupiter, saturn, uranus, neptune, pluto, ceres, eris, haumea, makemake
    var name: String { String(describing: self).capitalized }
}

enum OrbTint: Int, CaseIterable {
    case silver, peach, ocean, rust, sand, gold, cyan, indigo, rose, slate, lilac, mint, clay
    var hex: UInt32 {
        switch self {
        case .silver: 0xBDB7B0
        case .peach: 0xF0B98A
        case .ocean: 0x5DB4F0
        case .rust: 0xF2734D
        case .sand: 0xE2A86E
        case .gold: 0xE8C45A
        case .cyan: 0x6ED7DD
        case .indigo: 0x8A97FF
        case .rose: 0xE89DAA
        case .slate: 0xA7B4C2
        case .lilac: 0xC3A6F2
        case .mint: 0x7FD9A8
        case .clay: 0xDB8C6B
        }
    }
    var color: NSColor {
        let dark=hex,light=lightHex
        return NSColor(name:"organic.orb.identity.\(rawValue)") { appearance in
            let value=appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? dark:light
            return NSColor(srgbRed:CGFloat(value >> 16 & 255)/255,green:CGFloat(value >> 8 & 255)/255,blue:CGFloat(value & 255)/255,alpha:1)
        }
    }
    var lightHex:UInt32 {
        [0x6F6A64,0xB46F38,0x1F78B8,0xC2461F,0xA2652A,0x9E7810,0x13868E,0x4351D6,0xB5566A,0x56677A,0x7B55C2,0x2E9461,0x9E5232][rawValue]
    }
}

/// Product's 24-point vector grid, including its continuous Makemake outline.
struct OrbCelestialGlyph: Shape {
    var symbol: OrbCelestialBody

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }
        var path = Path()
        func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
            path.move(to: p(x0, y0)); path.addLine(to: p(x1, y1))
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: origin.x + (x - r) * s, y: origin.y + (y - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
        /// An arc by angle in degrees, y down (90° is straight below the centre), sampled finely.
        func arc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, from a0: CGFloat, to a1: CGFloat) {
            let steps = max(8, Int(abs(a1 - a0) / 6))
            for i in 0...steps {
                let a = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)) * .pi / 180
                let q = p(x + r * cos(a), y + r * sin(a))
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
        }
        /// The cross under Venus, Mercury, Pluto and Ceres.
        func cross(top: CGFloat, bar: CGFloat, half: CGFloat = 3.2) {
            line(12, top, 12, 21.5); line(12 - half, bar, 12 + half, bar)
        }

        switch symbol {
        case .mercury: // ☿ horns over a circle over a cross
            arc(12, 2.6, 3.6, from: 15, to: 165)
            circle(12, 10.6, 3.9)
            cross(top: 14.5, bar: 18.2, half: 2.9)
        case .venus: // ♀
            circle(12, 8.4, 5.2)
            cross(top: 13.6, bar: 17.8)
        case .earth: // 🜨 a circle quartered
            circle(12, 12, 8.2)
            line(12, 3.8, 12, 20.2); line(3.8, 12, 20.2, 12)
        case .mars: // ♂
            circle(10, 14, 5.6)
            line(14, 10, 19.6, 4.4)
            path.move(to: p(14.2, 4.4)); path.addLine(to: p(19.6, 4.4)); path.addLine(to: p(19.6, 9.8))
        case .jupiter: // ♃ a hooked 2 on a baseline, crossed by a stem
            path.move(to: p(5.2, 7.2))
            path.addCurve(to: p(9.6, 9.8), control1: p(6.2, 3.2), control2: p(11.8, 5.4))
            path.addLine(to: p(4.8, 15.2))
            path.addLine(to: p(19.6, 15.2))
            line(15.6, 4.2, 15.6, 20.6)
        case .saturn: // ♄ a cross whose foot turns into an h with a tail
            line(8.6, 3, 8.6, 15.8)
            line(5.4, 6.4, 11.8, 6.4)
            path.move(to: p(8.6, 12.4))
            path.addCurve(to: p(15.6, 12.6), control1: p(10.4, 9.4), control2: p(15.4, 9.2))
            path.addCurve(to: p(17.8, 20.6), control1: p(15.8, 16.4), control2: p(12.6, 20.8))
        case .uranus: // ⛢ a dotted circle under an arrow
            circle(12, 15, 5.4)
            circle(12, 15, 0.35)
            line(12, 9.6, 12, 2.8)
            path.move(to: p(8.8, 6)); path.addLine(to: p(12, 2.8)); path.addLine(to: p(15.2, 6))
        case .neptune: // ♆ a trident
            path.move(to: p(5.4, 4.2))
            path.addQuadCurve(to: p(18.6, 4.2), control: p(12, 19))
            line(12, 3.4, 12, 21.4)
            line(8.6, 16.8, 15.4, 16.8)
        case .pluto: // ⯓ an orb in a cup over a cross
            circle(12, 6.4, 2.5)
            arc(12, 6.6, 5.4, from: 0, to: 180)
            cross(top: 12, bar: 17.4, half: 3)
        case .ceres: // ⚳ a sickle over a cross
            arc(12, 7, 4.6, from: 160, to: 450)
            cross(top: 11.6, bar: 17.2, half: 3)
        case .eris: // a circle over a downward arrow
            circle(12, 7.8, 5)
            line(12, 12.8, 12, 21.2)
            path.move(to: p(8.8, 18)); path.addLine(to: p(12, 21.2)); path.addLine(to: p(15.2, 18))
        case .haumea: // a figure with raised arms, after the petroglyph the dwarf planet's symbol comes from
            circle(12, 5, 2.4)
            line(12, 8.6, 12, 21)
            path.move(to: p(5.2, 8.4)); path.addQuadCurve(to: p(12, 14.2), control: p(6.2, 14.2))
            path.move(to: p(18.8, 8.4)); path.addQuadCurve(to: p(12, 14.2), control: p(17.8, 14.2))
        case .makemake: // a face, after the Rapa Nui petroglyph
            path.addRoundedRect(in: CGRect(x: origin.x + 4.4 * s, y: origin.y + 4 * s, width: 15.2 * s, height: 16.4 * s),
                                cornerSize: CGSize(width: 6.4 * s, height: 7.2 * s), style: .continuous)
            circle(9.2, 10.4, 0.35); circle(14.8, 10.4, 0.35)
            line(9.6, 15.2, 14.4, 15.2)
        }
        return path
    }
}

