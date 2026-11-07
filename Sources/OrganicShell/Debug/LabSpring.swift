import Foundation
import SwiftUI

/// Independent port of SpringLab/FittedCurve and TruncatedSpring; System uses SwiftUI's public Spring evaluator.
/// This is experiment-only and never replaces a production animation's full tail.
struct LabSpring {
    var response:Double,damping:Double
    private var spring:SwiftUI.Spring{SwiftUI.Spring(response:max(0.01,response),dampingRatio:max(0.01,damping))}
    func value(_ time:Double,velocity:Double=0)->Double{spring.value(target:1,initialVelocity:velocity,time:max(0,time))}
    func velocity(_ time:Double,initial:Double=0)->Double{spring.velocity(target:1,initialVelocity:initial,time:max(0,time))}
    var settlingTime:Double{min(8,max(response,spring.settlingDuration(target:1,epsilon:0.00001)))}
    func truncatedEnd(distance:Double,scale:Double=2)->Double {
        let threshold=min(0.002,0.5/max(1,scale)/max(0.001,abs(distance)))
        var last=0.0,t=0.0
        while t<settlingTime {if abs(1-value(t))>=threshold || abs(velocity(t))*response/(2 * .pi)>=threshold{last=t};t+=0.001}
        return last+0.001
    }
}
struct LabFittedCurve {
    var c1=CGPoint(x:0.2,y:0.8),c2=CGPoint(x:0.3,y:1)
    var duration:Double
    func value(_ time:Double)->Double {
        guard duration>0 else{return 1};let fraction=min(1,max(0,time/duration))
        return UnitCurve.bezier(startControlPoint:UnitPoint(x:c1.x,y:c1.y),endControlPoint:UnitPoint(x:c2.x,y:c2.y)).value(at:fraction)
    }
    static func fit(_ spring:LabSpring,distance:Double,scale:Double=2)->Self {
        let duration=spring.truncatedEnd(distance:distance,scale:scale)
        let ts=(0...80).map{Double($0)/80},ys=(0...80).map{spring.value(Double($0)/80*duration)}
        func cost(_ p:[Double])->Double{let curve=Self(c1:CGPoint(x:p[0],y:p[1]),c2:CGPoint(x:p[2],y:p[3]),duration:duration);return zip(ts,ys).reduce(0){$0+pow(curve.value($1.0*duration)-$1.1,2)}}
        var p=[0.2,0.8,0.3,1.0],step=0.2,best=Double.infinity,iterations=0
        while step>0.0005,iterations<10000 {iterations+=1;var improved=false
            for i in 0..<4{for direction in [-1.0,1.0]{var q=p;q[i]+=direction*step;if i%2 == 0{q[i]=min(1,max(0,q[i]))};let c=cost(q);if c<best{best=c;p=q;improved=true}}}
            if !improved{step/=2}
        }
        return Self(c1:CGPoint(x:p[0],y:p[1]),c2:CGPoint(x:p[2],y:p[3]),duration:duration)
    }
}
struct LabSpringPreset {
    var name:String,response:Double,damping:Double,distance:Double
    static let all:[Self]=[
        .init(name:"Auto columns",response:0.42,damping:0.86,distance:370),.init(name:"Focused / Split",response:0.4,damping:0.82,distance:400),
        .init(name:"Normie ↔ Organic",response:0.45,damping:0.82,distance:600),.init(name:"New Chat",response:0.48,damping:0.88,distance:400),
        .init(name:"Collapse restore",response:0.42,damping:0.86,distance:400),.init(name:"Collapse arrival",response:0.38,damping:0.82,distance:300),
        .init(name:"Peek",response:0.3,damping:0.86,distance:200),.init(name:"Island open",response:0.34,damping:0.80,distance:200),
        .init(name:"Island close",response:0.28,damping:0.90,distance:200),.init(name:"Rename",response:0.24,damping:0.72,distance:40),
        .init(name:"Dock bloom",response:0.38,damping:0.78,distance:60),.init(name:"Dock rise",response:0.26,damping:0.86,distance:30),
        .init(name:"Dock fall",response:0.30,damping:0.90,distance:30),.init(name:"Queue",response:0.3,damping:0.8,distance:60)]
}
