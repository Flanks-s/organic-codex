import Foundation

/// Independent copy of the product's synthetic activity algorithm and analytics fixtures.
enum SettingsDemoVisuals {
    static let analytics:[(String,[(String,Int)])]=[
        ("By model",[("GPT-6.1 Sol",54),("GPT-6 Sol",21),("GPT-5.6 Terra",12),("GPT-6 Astra",8),("Other models",5)]),
        ("By device",[("This Mac",71),("Preview PC",24),("Preview Server",5)]),
        ("By project",[("Synthetic preview workspace",48),("Render Scripts",19),("Photo Library Tools",9),("Chats without a project",24)])
    ]
    static func profileGrid(_ range:String)->[Double] {
        let cells:[Int]=(0..<52).flatMap { w in (0..<7).map{d in
            let r=abs((sin(Double(w)*12.9898+Double(d)*78.233)*43758.5453).truncatingRemainder(dividingBy:1))
            let ramp=Double(w)/52
            if w == 51 && d>2{return -1}
            return r<0.9-ramp*0.75 ? 0:r<0.94-ramp*0.3 ? 1:r<0.97 ? 2:r<0.99 ? 3:4
        }}
        guard range != "daily" else{return cells.map(Double.init)}
        var totals=(0..<52).map{w in (0..<7).reduce(0){$0+max(0,cells[w*7+$1])}}
        if range == "cumulative"{var acc=0;totals=totals.map{acc+=$0;return acc}}
        let top=max(1,totals.max() ?? 1)
        return totals.flatMap{v in let h=v>0 ? max(1,Int((Double(v)/Double(top)*7).rounded())):0;return (0..<7).map{$0>=7-h ? 4.0:0.0}}
    }
}
