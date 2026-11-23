import Foundation
import simd

/// Presentation values only. Core event interpretation belongs to the future host adapter.
enum BodyPhaseState: String, CaseIterable, Codable, Sendable {
    case running, unknown, waiting, completed, failed, cancelled
}

struct BodyPhaseValue: Equatable, Sendable {
    let state: BodyPhaseState
    let fraction: Float?
    init(_ state: BodyPhaseState, fraction: Double? = nil) {
        let normalized = fraction.flatMap { $0.isFinite ? Float(min(1, max(0, $0))) : nil }
        self.state = state == .running && normalized == nil ? .unknown : state
        self.fraction = normalized
    }
    init(completed: Double, total: Double) {
        let valid = completed.isFinite && total.isFinite && total > 0
        self.init(valid ? .running : .unknown, fraction: valid ? completed / total : nil)
    }
    func terminal(profile: BodyProfile = .current) -> BodyPhaseSample {
        let p = profile.phase
        let k = p.floor + (1-p.floor)*(fraction ?? 0)
        switch state {
        case .running: return fraction == nil ? BodyPhaseValue(.unknown).terminal(profile: profile) : .init(lit: k, minimum:p.floor)
        case .unknown: return .init(lit: (p.unknownLitRange[0]+p.unknownLitRange[1])/2, haze: 1)
        case .waiting: return .init(lit: fraction == nil ? 0.5 : k, amber: 1, minimum:p.floor)
        case .completed: return .init(lit: 1)
        case .failed: return .init(lit: fraction == nil ? 0.5 : k, blood: 1, minimum:p.floor)
        case .cancelled: return .init(lit: 1, ash: 1)
        }
    }
}

/// A fully sampled immutable request. No timestamp, event ID, or playback clock enters its key.
struct BodyPhaseSample: Equatable, Sendable {
    let lit, haze, amber, blood, ash, emphasis: Float
    init(lit: Float, haze: Float = 0, amber: Float = 0, blood: Float = 0, ash: Float = 0, emphasis: Float = 0, minimum: Float = BodyProfile.current.phase.floor) {
        func unit(_ x: Float) -> Float { x.isFinite ? min(1,max(0,x)) : 0 }
        self.lit=max(unit(minimum),unit(lit)); self.haze=unit(haze); self.amber=unit(amber)
        self.blood=unit(blood); self.ash=unit(ash); self.emphasis=unit(emphasis)
    }
    var vector: SIMD8<Double> { SIMD8(Double(lit),Double(haze),Double(amber),Double(blood),Double(ash),Double(emphasis),0,0) }
    init(vector: SIMD8<Double>, emphasis: Float? = nil, minimum: Float = BodyProfile.current.phase.floor) {
        self.init(lit:Float(vector[0]),haze:Float(vector[1]),amber:Float(vector[2]),blood:Float(vector[3]),ash:Float(vector[4]),emphasis:emphasis ?? Float(vector[5]),minimum:minimum)
    }
}
