import Foundation

/// Ordinary Dock springs own position. The tail and delayed diameter have finite outgoing channels.
struct TideAddHandoff {
    var size:RectSpring?
    var began:Double
    let duration:Double,initialTail:Double,lean:Double,reduced:Bool
    func tail(at now:Double)->Double {
        guard !reduced else{return 0}
        let value=Spring(from:initialTail,to:0,response:0.09,damping:1,epsilon:0.004).sample(max(0,now-began)).value
        return value<0.004 ? 0:max(0,value)
    }
}
