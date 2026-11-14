import Foundation

/// Geographic longitudes in degrees; time and the current UTC offset are explicit inputs.
struct BrowserEarthTrajectory: Equatable, Sendable {
    static let surfaceDuration = 2.2
    static let cloudDuration = 2.464
    let began: Double
    let surfaceFrom: Double, cloudFrom: Double
    let surfaceTo: Double, cloudTo: Double
    init(began: Double, surface: Double, cloud: Double, utcOffsetSeconds: Int) {
        self.began = began; surfaceFrom = surface; cloudFrom = cloud
        let home = Self.homeDegrees(utcOffsetSeconds: utcOffsetSeconds)
        let delta = Self.wrap(surface - home)
        surfaceTo = surface - (360 + delta)
        cloudTo = cloud + (surfaceTo - surface)
    }
    static func homeDegrees(utcOffsetSeconds: Int) -> Double { Double(utcOffsetSeconds) / 3600 * 15 }
    static func wrap(_ degrees: Double) -> Double { (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
    static func ease(_ time: Double) -> Double {
        let x = min(1, max(0, time))
        if x == 0 || x == 1 { return x }
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1-t) * (1-t) * t * a + 3 * (1-t) * t * t * b + t*t*t }
        var lo = 0.0, hi = 1.0
        for _ in 0..<48 { let mid = (lo+hi)/2; if cubic(mid, 0.45, 0.15) < x { lo = mid } else { hi = mid } }
        return cubic((lo+hi)/2, 0, 1)
    }
    func longitudes(at time: Double) -> (surface: Double, cloud: Double) {
        let elapsed = max(0, time-began)
        return (surfaceFrom + (surfaceTo-surfaceFrom)*Self.ease(elapsed/Self.surfaceDuration),
                cloudFrom + (cloudTo-cloudFrom)*Self.ease(elapsed/Self.cloudDuration))
    }
    static func pose(surface: Double, cloud: Double) -> BodyEarthPose {
        func finiteAngle(_ value: Double) -> Float { let f = Float(wrap(value)); return f >= 360 ? 0 : f }
        return .init(surfaceDegrees: finiteAngle(surface), cloudDegrees: finiteAngle(cloud))
    }
}

/// One finite interruptible event response, with no clock or scheduled work.
struct BrowserEarthMotion {
    private(set) var trajectory: BrowserEarthTrajectory?
    private(set) var pose: BodyEarthPose?
    private(set) var surface: Double, cloud: Double
    private var consumedGeneration: UInt64 = 0, consumedEventID: UInt64 = 0
    private(set) var acceptedEvents = 0
    var isActive: Bool { trajectory != nil }
    init(initialTurn: Float) { surface = -Double(initialTurn)*360; cloud = -Double(initialTurn)*360*1.08 }
    mutating func receive(_ event: BrowserHomeEvent, at time: Double, utcOffsetSeconds: Int, reduceMotion: Bool) {
        guard event.name == "browser.homeArrived", event.rotationRequested, time.isFinite,
              event.sessionGeneration > consumedGeneration || event.sessionGeneration == consumedGeneration && event.eventID > consumedEventID else { return }
        consumedGeneration = event.sessionGeneration; consumedEventID = event.eventID; acceptedEvents += 1
        guard !reduceMotion else { return }
        sample(at: time)
        trajectory = .init(began: time, surface: surface, cloud: cloud, utcOffsetSeconds: utcOffsetSeconds)
    }
    mutating func sample(at time: Double) {
        guard let path = trajectory, time.isFinite else { return }
        let next = path.longitudes(at: time); surface = next.surface; cloud = next.cloud
        pose = BrowserEarthTrajectory.pose(surface: surface, cloud: cloud)
        if time >= path.began + BrowserEarthTrajectory.cloudDuration { trajectory = nil }
    }
    mutating func finish() {
        guard let trajectory else { return }; sample(at: trajectory.began + BrowserEarthTrajectory.cloudDuration)
    }
    mutating func freeze(at time: Double) { sample(at: time); trajectory = nil }
}
