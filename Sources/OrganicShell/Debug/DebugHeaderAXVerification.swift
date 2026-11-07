#if HEADER_AX_SELFTEST
import AppKit

/// Read-only integration fixture: the real Island source is compiled unchanged, with no window or warm-up.
@main @MainActor enum DebugHeaderAXVerification {
    static func main()throws{
        _ = NSApplication.shared;NSApp.appearance=NativeDisplayOptions.appearance
        let output=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "/tmp/organic-header-ax")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[]
        func check(_ value:Bool,_ name:String){checks+=1;if !value{failures.append(name)}}
        let carrier=NativeInteractionSurface(frame:CGRect(x:0,y:0,width:420,height:300));carrier.verificationAXScreenOrigin=CGPoint(x:100,y:200)
        let header=HeaderIsland();carrier.addSubview(header)
        var config=HeaderIslandConfiguration(id:"cold-header",title:"Cold actual Header Title");config.ambient=false;config.reduceMotion=true
        header.configure(config)
        func tree(_ proxy:NativeInteractionProxy,depth:Int=0)->[NativeInteractionProxy]{guard depth<12 else{return []};return [proxy]+(proxy.accessibilityChildren() ?? []).compactMap{$0 as? NativeInteractionProxy}.flatMap{tree($0,depth:depth+1)}}
        let nodes=(carrier.accessibilityChildren() ?? []).compactMap{$0 as? NativeInteractionProxy}.flatMap{tree($0)}
        let title=nodes.first{$0.source === header.titleButton}
        let planet=nodes.first{$0.source === header.planetButton}
        check(title?.accessibilityLabel()==config.title,"b086 actual cold Header Title is exported on the first public traversal")
        check(title?.accessibilityHelp()?.isEmpty==false && title?.accessibilityRole() == .button,"b086 actual cold title exports help and button semantics")
        check(title != nil && planet != nil && title !== planet,"b086 actual planet is not substituted for Title")
        check(title?.accessibilityCustomActions()?.contains{$0.name=="Rename"}==true,"b087 actual Title custom actions survive the exact proxy getter")
        header.isHidden=true
        check(title?.accessibilityFrame().isEmpty==true,"b086 hidden actual Header Title withdraws its public frame")
        header.dispose()
        check(NSApp.windows.allSatisfy{!$0.isVisible},"read-only Header AX fixture opens no window")
        let report="Header AX verification: \(checks) checks, \(failures.count) findings\n"+failures.joined(separator:"\n")+"\n"
        try report.write(to:output.appendingPathComponent("verification.txt"),atomically:true,encoding:.utf8);print(report);if !failures.isEmpty{exit(1)}
    }
}
#endif
