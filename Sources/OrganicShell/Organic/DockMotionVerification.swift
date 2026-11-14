#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

@main @MainActor enum M10DockVerification {
    static var checks = 0, findings: [String] = [], clock = 1000.0
    static let profile = M10DockMotion.dell
    static var report: [[String: Any]] = [], csv = "object,frame,time,step_pt,step_mm,gate,length_pt,copies,spacing_pt,painted_step_pt\n"
    static func check(_ value: Bool, _ label: String) { checks += 1; if !value { findings.append(label); print("FINDING: "+label) } }
    struct Path {
        var name: String, duration: Double, pose: (Double) -> CGRect
    }
    static func spring(_ name: String, _ a: CGRect, _ b: CGRect, _ response: Double = 0.42, _ damping: Double = 0.86) -> Path {
        let s = RectSpring(from: a, to: b, response: response, damping: damping)
        return .init(name: name, duration: s.duration+0.1, pose: { s.sample($0).rect })
    }
    static func main() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "runs/m10-dock")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--tide-round11") {
            try DockTideRound11Verification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.34 round11: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--tide-round10") {
            try DockTideRound10Verification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.34 round10: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--tide-round9") {
            try DockTideRound9Verification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.34 round9: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--tide-round8") {
            try DockTideRound8Verification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.34 round8: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--tide-round7") {
            try DockTideRound7Verification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.34 round7: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--tide-round6") {
            try DockTideRound6Verification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.34 round6: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--tide-round5") {
            try DockTideRound5Verification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.34 round5: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--tide-round4") {
            try DockTideRound4Verification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.34 round4: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--tide-round3") {
            try DockTideRound3Verification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.34 round3: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--tide-round2") {
            try DockTideRound2Verification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.34 round2: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--tide-shape") {
            try DockTideVerification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.34 material: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--drag-neighbors") {
            try DockDragNeighborsVerification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--drag-topology") {
            try DockDragTopologyVerification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--single-handoff") {
            NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
            let rows=DockHandoffVerification.singleOperations(check:check)
            try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("single.json"))
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--handoff-contours") {
            NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
            let rows=DockHandoffVerification.contourRegressions(check:check)
            try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("contours.json"))
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--handoff") || CommandLine.arguments.contains("--handoff-regression") {
            try await DockHandoffVerification.run(to:output,regressionOnly:CommandLine.arguments.contains("--handoff-regression"),check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.30 handoffs: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--review15") {
            try DockFollowupVerification.releaseCoordinates(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.30 release coordinates: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--review14") {
            try DockFollowupVerification.peekCoordinates(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.30 Peek coordinates: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--review12") || CommandLine.arguments.contains("--review13") {
            try DockFollowupVerification.peekRelease(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.30 Peek release: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--review11") {
            try await DockFollowupVerification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.30 followup: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--capsule") || CommandLine.arguments.contains("--fusion") || CommandLine.arguments.contains("--physical") {
            try await DockFollowupVerification.run(to:output,check:check)
        }
        if CommandLine.arguments.contains("--frame-log-check") {
            try DockFrameLogVerification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.30 frame log: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--review") {
            try DockReviewVerification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.30 review: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--physical") {
            try DockGlassBatchVerification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.30 physical glass: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--cadence") {
            try DockGlassCadenceVerification.run(to:output,check:check)
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("M11.30 cadence: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--fusion") {
            try DockGlassTopologyVerification.run(to: output, check: check)
            try JSONSerialization.data(withJSONObject: ["checks": checks, "findings": findings], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("verification.json"))
            print("M11.30 Dock fusion: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0 : 1)
        }
        if CommandLine.arguments.contains("--capsule") {
            try DockCapsuleVerification.run(to: output, check: check)
            try JSONSerialization.data(withJSONObject: ["checks": checks, "findings": findings], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("verification.json"))
            print("M11.30 Dock capsule: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0 : 1)
        }
        if CommandLine.arguments.contains("--gaussian") {try M10DockGaussianVerification.run(output);return}
        if CommandLine.arguments.contains("--switches") {switches();print("M10 Dock switches: \(checks) checks, \(findings.count) findings");exit(findings.isEmpty ? 0:1)}
        if CommandLine.arguments.contains("--scene") {exit(SelfTest.run(to:output.path,size:CGSize(width:1080,height:760)))}
        if CommandLine.arguments.contains("--ordinary") {try ordinaryFrames(output:output);print("ordinary pixel control: \(checks) checks, \(findings.count) findings");exit(findings.isEmpty ? 0:1)}
        if let item=["--m1121","--m1122","--m1123"].first(where:{CommandLine.arguments.contains($0)}) {
            switch item {
            case "--m1121":IslandEventPhaseVerification.run(to:output,check:check)
            case "--m1122":PeekTopClipVerification.run(to:output,check:check)
            default:IslandLongTitleVerification.run(to:output,check:check)
            }
            try JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
            print("\(item): \(checks) checks, \(findings.count) findings");exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--glyphs") {
            try draggedGlyphs(output:output)
            print("M11.11 dragged glyphs: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--followup") {
            try headerDragFollowup(output:output)
            print("M11.11 followup: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--reorder") {
            try reorderText(output:output)
            print("M11.11 reorder: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--carry") {
            try physicalHeaderCarry(output:output)
            print("M11.11 physical carry: \(checks) checks, \(findings.count) findings");exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--leaving") {
            try await leavingTranscripts(output:output)
            print("M11.14 leaving: \(checks) checks, \(findings.count) findings");exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--header") {
            try await headerDragging(output:output)
            print("M10.4 header drag: \(checks) checks, \(findings.count) findings")
            exit(findings.isEmpty ? 0:1)
        }
        if CommandLine.arguments.contains("--hooks-probe") {hookedIntegration(output:output);try hookFrames(output:output);try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("hooks.json"));print("M10 Dock hooks: \(checks) checks, \(findings.count) findings");exit(findings.isEmpty ? 0:1)}
        let bar = CGRect(x: 70, y: 55, width: 650, height: 40), orb = CGRect(x: 790, y: 55, width: 40, height: 40)
        var paths = [spring("bar-to-orb",bar,orb), spring("orb-to-bar",orb,bar),
            spring("bar-column-follow",bar,bar.offsetBy(dx: 210,dy: 0)),
            spring("bloom-orb",CGRect(x: 700,y: 57,width: 36,height: 36),orb,0.38,0.78),
            spring("bloom-bar",CGRect(x: 50.5,y: 53.8,width: 689,height: 42.4),bar,0.22,1),
            spring("peek-bud",orb,CGRect(x: 540,y: 50,width: 290,height: 48),0.38,0.78),
            spring("peek-return",CGRect(x: 540,y: 50,width: 290,height: 48),orb,0.30,0.90),
            spring("me-focus",CGRect(x: 20,y: 55,width: 40,height: 40),CGRect(x: 460,y: 55,width: 40,height: 40),0.40,0.82),
            spring("me-release",CGRect(x: 480,y: 55,width: 44,height: 44),CGRect(x: 20,y: 55,width: 40,height: 40),0.28,0.84),
            spring("collapse-me-return",CGRect(x: 60,y: 55,width: 36,height: 36),CGRect(x: 760,y: 55,width: 36,height: 36),0.32,0.82),
            spring("collapse-overlay-rise",CGRect(x: 70,y: 67,width: 650,height: 40),bar,0.30,0.88),
            spring("peek-row-entrance",CGRect(x: 70,y: 73,width: 200,height: 22),CGRect(x: 70,y: 55,width: 200,height: 22),0.55,0.92)]
        paths.append(.init(name:"held-queue-drag",duration:1.0,pose:{ t in
            let u = min(1,max(0,t/0.8)), q = u*u*u*(10+u*(-15+6*u))
            return CGRect(x:70+CGFloat(q)*700,y:55+CGFloat(sin(.pi*q))*12,width:44,height:44)
        }))
        paths.append(.init(name:"peek-scroll",duration:0.8,pose:{ t in
            let u = min(1,max(0,t/0.65)),q=u*u*u*(10+u*(-15+6*u))
            return CGRect(x:70,y:55+CGFloat(q)*400,width:200,height:22)
        }))
        paths.append(.init(name:"refusal",duration:0.34,pose:{ t in
            let times=[0.0,0.04,0.085,0.13,0.18,0.24],xs=[0.0,-6,5,-3,2,0]
            guard let i=(0..<5).first(where:{ t>=times[$0] && t<times[$0+1] }) else{return bar}
            let q=(t-times[i])/(times[i+1]-times[i]);return bar.offsetBy(dx:xs[i]+(xs[i+1]-xs[i])*q,dy:0)
        }))
        for path in paths { try evaluate(path,output:output) }
        nativeIntegration(output: output)
        contracts()
        hookedIntegration(output:output)
        try hookFrames(output:output)
        let baseChecks=checks
        try await headerDragging(output:output)
        try headerDragFollowup(output:output)
        let gestureChecks=checks-baseChecks
        try await leavingTranscripts(output:output)
        let leavingChecks=checks-baseChecks-gestureChecks
        try reorderText(output:output)
        let textChecks=checks-baseChecks-gestureChecks-leavingChecks
        let glyphStart=checks
        try draggedGlyphs(output:output)
        let glyphChecks=checks-glyphStart
        check(NSApp.windows.allSatisfy{!$0.isVisible},"no visible windows")
        let result: [String: Any] = ["checks":checks,"findings":findings,"checkGroups":["existingDock":baseChecks,"sharedGesture":gestureChecks,"leavingTranscript":leavingChecks,"reorderText":textChecks,"draggedGlyph":glyphChecks,"noWindows":1],"profile":["hz":60,"mmPerPoint":0.27],"objects":report,
            "glass":"Rounded solid OFFSCREEN PROXY only. WindowServer glass/refraction and real first-key/IME need host recording.",
            "process":"No NSWindow, backend, or app event loop is opened."]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
        try csv.write(to:output.appendingPathComponent("frames.csv"),atomically:true,encoding:.utf8)
        print("M10 Dock: \(checks) checks, \(findings.count) findings")
        exit(findings.isEmpty ? 0:1)
    }

    static func evaluate(_ path: Path, output: URL) throws {
        let count=Int(ceil(path.duration/profile.frameInterval))+1
        var frames:[M10DockFrame]=[],last=path.pose(0),lastPainted=last
        var maxStep:CGFloat=0,maxLength:CGFloat=0,maxPaintedStep:CGFloat=0,maxGap:CGFloat=0,maxCopies=1,processed=0
        for k in 0...count {
            let t=Double(k)*profile.frameInterval,r=path.pose(t)
            let f=M10DockMotion.frame(name:path.name,now:r,earlier:last,time:t,profile:profile,enabled:true),s=f.exposure
            let paintedStep=MotionStep.edge(lastPainted,f.painted)
            let spacing=s.count>1 ? s.length/CGFloat(s.count-1):0
            check(abs(s.gate-CGFloat(smoothstep(1.08,2.7,f.stepMM)))<1e-9,path.name+" physical gate")
            if f.stepMM<=1.08 {check(s.gate==0 && f.painted==r,path.name+" below onset exact")}
            if f.stepMM>2.7 {check(s.count>1 && s.length>0 && f.painted != r,path.name+" full exposure")}
            if s.gate>0 {
                processed+=1
                check(s.length+1e-8>=s.stepPt*s.gate,path.name+" sweep covered")
                check(spacing<=1.5+1e-9,path.name+" copies <= 1.5 pt")
                let reachCap=MotionStretch.maxReach*min(r.width,r.height)
                check(hypot(f.painted.width-r.width,f.painted.height-r.height)<=reachCap*2.squareRoot()+0.001 && abs(min(hypot(f.painted.width-r.width,f.painted.height-r.height),reachCap)-min(s.length,reachCap))<0.001,path.name+" solid tail equals gate, up to the reach capd edge sweep")
            }
            maxStep=max(maxStep,s.stepPt);maxLength=max(maxLength,s.length);maxPaintedStep=max(maxPaintedStep,paintedStep)
            maxGap=max(maxGap,spacing);maxCopies=max(maxCopies,s.count)
            csv += "\(path.name),\(k),\(t),\(s.stepPt),\(f.stepMM),\(s.gate),\(s.length),\(s.count),\(spacing),\(paintedStep)\n"
            frames.append(f);last=r;lastPainted=f.painted
        }
        check(frames.first!.painted==frames.first!.rect && frames.last!.painted==frames.last!.rect,path.name+" first/last exact geometry")
        // Model/layer work only. Real NSGlassEffectView/WindowServer scheduling is explicitly not timed here.
        var costs:[Double]=[]
        let trail=ChordTrail()
        for i in 0..<2000 {
            let f=frames[i%frames.count],start=CACurrentMediaTime()
            _=M10DockMotion.frame(name:path.name,now:f.rect,earlier:f.earlier,time:f.time,profile:profile,enabled:true)
            trail.settings=M10DockMotion.settings(for:f.exposure.stepPt,enabled:true)
            M10DockMotion.update(trail,now:f.rect,earlier:f.earlier,profile:profile,enabled:true)
            costs.append((CACurrentMediaTime()-start)*1000)
        }
        costs.sort()
        var offCosts: [Double] = []
        for i in 0..<2000 {
            let f=frames[i%frames.count],start=CACurrentMediaTime()
            _=M10DockMotion.frame(name:path.name,now:f.rect,earlier:f.earlier,time:f.time,profile:profile,enabled:false)
            trail.settings=M10DockMotion.settings(for:f.exposure.stepPt,enabled:false)
            trail.update(now:f.rect,earlier:f.earlier,profile:profile)
            offCosts.append((CACurrentMediaTime()-start)*1000)
        }
        offCosts.sort()
        let p95=costs[Int(Double(costs.count)*0.95)],offP95=offCosts[Int(Double(offCosts.count)*0.95)]
        check(max(0,p95-offP95)<0.5,path.name+" CPU model overhead < 0.5 ms")
        var pixelSpikes=[Int](),firstLastMax=0
        for scale:CGFloat in [1,2] {
            let a=render(frames,enabled:false,scale:scale),b=render(frames,enabled:true,scale:scale)
            let renderer=a.0
            for k in [0,frames.count-1] {
                let diff=zip(a.1[k],b.1[k]).map{abs(Int($0)-Int($1))}.max() ?? 0
                firstLastMax=max(firstLastMax,diff);check(diff==0,path.name+" endpoint pixels \(scale)x")
            }
            let before=spikes(a.1,renderer),after=spikes(b.1,renderer)
            check(before==0,path.name+" sharp spikes \(scale)x: \(before)")
            check(after==0,path.name+" exposure spikes \(scale)x: \(after)")
            pixelSpikes += [before,after]
            // Paired contact sheet: every frame, no selected-only view of the transition.
            let sheet=contact(a.1,b.1,renderer)
            Offscreen.write(sheet,output.appendingPathComponent(path.name+"-all-frames@\(Int(scale))x.png"))
        }
        report.append(["object":path.name,"frames":frames.count,"maxStepPt":maxStep,"maxStepMM":Double(maxStep)*0.27,
                       "maxPaintedEdgeStepPt":maxPaintedStep,"maxTailPt":maxLength,"maxCopies":maxCopies,
                       "maxSpacingPt":maxGap,"processedFrames":processed,"endpointMaxByteDiff":firstLastMax,
                       "spikesSharpAndExposure1x2x":pixelSpikes,"modelAndChordP95Ms":p95,"disabledModelAndChordP95Ms":offP95,"addedModelAndChordP95Ms":max(0,p95-offP95)])
    }
    static func render(_ frames:[M10DockFrame],enabled:Bool,scale:CGFloat)->(OffscreenRenderer,[[UInt8]]) {
        let root=CALayer(),glass=CAShapeLayer(),ink=CALayer(),trail=ChordTrail()
        root.backgroundColor=NSColor(srgbRed:0.105,green:0.12,blue:0.115,alpha:1).cgColor
        root.addSublayer(glass);root.addSublayer(trail.layer);trail.layer.addSublayer(ink)
        glass.fillColor=NSColor(srgbRed:0.25,green:0.32,blue:0.29,alpha:0.8).cgColor
        glass.strokeColor=NSColor(white:1,alpha:0.24).cgColor;glass.lineWidth=0.5
        let label=NativeLabel(labelWithString:"Draft • Organic"),size=CGSize(width:140,height:24)
        label.font = .systemFont(ofSize:13);label.textColor = .white;label.frame=CGRect(origin:.zero,size:size)
        let tiles=M10DockPicture.tiles(M10DockPicture.draw(label,scale:scale,plates:false)!,scale:scale)
        ink.anchorPoint = .zero
        for tile in tiles {let l=CALayer();l.anchorPoint = .zero;l.frame=tile.rect;l.contents=tile.image;l.contentsScale=scale;ink.addSublayer(l)
            ReplicaContainerAudit.register(l,material:.glyph,note:"Dock fixture NativeLabel own-draw tight independent ink") }
        let canvas = frames.first?.name == "peek-scroll" ? CGSize(width:340,height:520):CGSize(width:940,height:130)
        let renderer=OffscreenRenderer(size:canvas,host:root,scale:scale)
        var out:[[UInt8]]=[]
        for (i,f) in frames.enumerated() {
            CATransaction.begin();CATransaction.setDisableActions(true)
            let r=enabled ? f.painted:f.rect
            glass.path=CGPath(roundedRect:r,cornerWidth:min(r.width,r.height)/2,cornerHeight:min(r.width,r.height)/2,transform:nil)
            let now=CGRect(x:f.rect.minX+14,y:f.rect.midY-12,width:size.width,height:size.height)
            let old=now.offsetBy(dx:f.earlier.minX-f.rect.minX,dy:f.earlier.midY-f.rect.midY)
            ink.frame=now;trail.layer.frame=CGRect(origin:.zero,size:canvas)
            trail.settings=M10DockMotion.settings(for:MotionStep.edge(now,old),enabled:enabled)
            M10DockMotion.update(trail,now:now,earlier:old,profile:profile,enabled:enabled)
            CATransaction.commit();out.append(renderer.render(at:1000+Double(i)/60))
        }
        return(renderer,out)
    }
    static func spikes(_ frames:[[UInt8]],_ r:OffscreenRenderer)->Int {
        let d=(1..<frames.count).map{r.tileDiff(frames[$0-1],frames[$0]).value};var count=0
        for k in 2..<max(2,d.count-2) {
            let a=[d[k-2],d[k-1],d[k+1],d[k+2]].sorted(),median=(a[1]+a[2])/2
            if d[k]>8 && d[k]>3*median+2 {count+=1}
        };return count
    }
    static func contact(_ sharp:[[UInt8]],_ exposed:[[UInt8]],_ r:OffscreenRenderer)->CGImage {
        // Thumbnail pairs preserve the full sequence; individual source render sizes are reported in the image label.
        let cols=6,cellW=r.w > r.h ? 470:170,halfH=Int(Double(r.h)/Double(r.w)*Double(cellW))
        let cellH=halfH*2+10,rows=Int(ceil(Double(sharp.count)/Double(cols)))
        let ctx=CGContext(data:nil,width:cols*cellW,height:rows*cellH,bitsPerComponent:8,bytesPerRow:0,
                          space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.black.cgColor);ctx.fill(CGRect(x:0,y:0,width:cols*cellW,height:rows*cellH))
        for i in sharp.indices {
            let x=(i%cols)*cellW,y=(rows-1-i/cols)*cellH
            ctx.draw(r.image(sharp[i]),in:CGRect(x:x,y:y+halfH+5,width:cellW,height:halfH))
            ctx.draw(r.image(exposed[i]),in:CGRect(x:x,y:y,width:cellW,height:halfH))
        }
        return ctx.makeImage()!
    }
    static func contracts() {
        let clip=NSView(frame:CGRect(x:0,y:0,width:40,height:48));clip.wantsLayer=true;clip.layer?.masksToBounds=true
        let future=NativeLabel(labelWithString:"Future target control")
        future.frame=CGRect(x:100,y:0,width:180,height:24);clip.addSubview(future)
        let prepared=M10DockPicture.draw(future,scale:2,plates:false)!
        check((prepared.dataProvider!.data! as Data).contains{$0>0},"prewarm future control ignores old outer chrome clip")
        let h=M10DockHistory(),r=CGRect(x:0,y:0,width:40,height:40)
        _=h.update(r,at:100,name:"test",profile:profile,enabled:true)
        let f=h.update(r.offsetBy(dx:24,dy:0),at:100+1/60,name:"test",profile:profile,enabled:true)
        check(f.exposure.gate==1,"history fast drag")
        check(h.update(f.rect,at:100+1/60,name:"test",profile:profile,enabled:true).earlier==r,"same-frame callbacks don't consume exposure twice")
        check(h.update(f.rect,at:101,name:"test",profile:profile,enabled:true).exposure.gate==0,"stationary frame has no stale tail")
        check(h.update(f.rect.offsetBy(dx:200,dy:0),at:102,name:"test",profile:profile,enabled:true).exposure.gate==1,"a long frame gap does not hide a jump")
        for d:CGFloat in [12,18] {
            let frames=M10DockRowTrail.frames(distance:d,response:d==12 ? 0.30:0.55,damping:d==12 ? 0.88:0.92,profile:profile)
            check(frames.allSatisfy{$0.2.gate==0},"authored \(d)pt entrance below Dell onset")
        }
        let fast=M10DockRowTrail.frames(distance:300,response:0.3,damping:0.88,profile:profile)
        check(fast.contains{$0.2.gate==1},"future faster row path has accumulation")
        check(fast.allSatisfy{$0.2.count<2 || $0.2.length/CGFloat($0.2.count-1)<=1.5+1e-8},"row path spacing remains bounded")
    }
    static func nativeIntegration(output:URL) {
        let seed=MockSeed.make(),store=ConversationStore(conversations:seed,projects:MockSeed.projects,devices:MockSeed.devices)
        let view=DockNode.Passage(frame:CGRect(x:0,y:0,width:1000,height:150));view.wantsLayer=true
        let dock=DockNode(view:view,scale:2);dock.ambient=false;dock.motionProfile=profile;dock.motionTime={clock}
        var layout=AutoLayout();layout.me=CGRect(x:16,y:80,width:40,height:40)
        layout.bars=[CGRect(x:70,y:80,width:650,height:40)];layout.orbs=[CGRect(x:800,y:80,width:40,height:40)]
        dock.composerFor={_ in let c=NativeComposer(frame:.zero);c.setText("Actual Dock callback");return c}
        dock.install(layout,metrics:.init(),order:Array(seed.prefix(2)),full:[seed[0].id],store:store)
        check(dock.onComposerMotion != nil,"Dock assigns composer hook by default")
        check(M10DockMotion.onOrbFrame != nil,"Orb hook assigned even before any Dock instance")
        check(dock.composerMotion.captures>0,"actual Dock arrange prewarms full composer")
        dock.motionEnabled=false;dock.sample(0);view.layoutSubtreeIfNeeded()
        let before=NativeViewBitmap.capture(view,scale:2)
        dock.motionEnabled=true;clock+=1/60;dock.sample(0)
        let after=NativeViewBitmap.capture(view,scale:2)
        Offscreen.write(before,output.appendingPathComponent("native-dock-rest-off@2x.png"))
        Offscreen.write(after,output.appendingPathComponent("native-dock-rest-on@2x.png"))
        check(before.dataProvider?.data==after.dataProvider?.data,"actual Dock native static pixels unchanged")
        var saw=0;dock.onMotionFrame={f in if f.exposure.gate>0{saw+=1}}
        dock.hold(seed[1].id,at:CGPoint(x:820,y:100),now:clock,spring:(0.28,0.84))
        for i in 0...45 {clock+=1/60;dock.moveHeld(to:CGPoint(x:820-CGFloat(i)*12,y:100));dock.heldFrame(at:clock)}
        check(saw>0,"actual heldFrame routes through exposure")
        if let item=dock.items[seed[1].id] {
            check(CATransform3DIsIdentity(item.glass.layer?.transform ?? CATransform3DIdentity),"actual glass never scales")
            check(abs(item.glass.cornerRadius-min(item.glass.frame.width,item.glass.frame.height)/2)<0.001,"actual glass ends are semicircular")
            check(!(item.glass.layer?.superlayer is CAReplicatorLayer),"glass never in replicator")
        }
        dock.release();dock.resetMotion();clock+=1
        dock.sample(0)
        check(dock.items.values.allSatisfy{$0.wordTrail.trail.layer.instanceCount==1},"rest resets word exposures")
        dock.hold(seed[0].id,at:CGPoint(x:340,y:100),now:clock,spring:(0.28,0.84))
        dock.moveHeld(to:CGPoint(x:700,y:100));clock+=1/60;dock.heldFrame(at:clock)
        check(dock.composerMotion.activeCount>0,"actual Dock callback treats held composer")
        dock.resetMotion();dock.release()
        let paint=PeekBarFace(frame:CGRect(x:0,y:0,width:300,height:48))
        paint.configure(seed[0],badge:.init(tone:.red,symbol:.count(3)),size:CGSize(width:300,height:48))
        let glyphOnly=paint.glyphBitmap(scale:2)
        check(glyphOnly.width==600,"caption glyph snapshot backing size")
        let plain=NativeViewBitmap.capture(paint,scale:2)
        paint.glyphExposureActive=true
        let plate=NativeViewBitmap.capture(paint,scale:2)
        check(plate.dataProvider?.data != plain.dataProvider?.data,"caption withdraws glyphs but retains solid plate")
        paint.glyphExposureActive=false
        check(NativeViewBitmap.capture(paint,scale:2).dataProvider?.data==plain.dataProvider?.data,"caption resumes exact native pixels")
        let caption=NativeLabel(labelWithString:"Outgoing words")
        caption.frame=CGRect(x:0,y:0,width:180,height:24);caption.alphaValue=0
        let glyphCache=M10DockGlyph();glyphCache.prepare(caption,key:"zero-alpha",scale:2)
        let cached=glyphCache.trail.layer.sublayers?.first?.contents.map { $0 as! CGImage }
        let bytes=cached?.dataProvider?.data as Data? ?? Data()
        check(bytes.contains{$0>0},"glyph cache captures paint even when source model alpha is zero")
        var nativeCosts:[String:Double]=[:]
        for enabled in [false,true] {
            dock.motionEnabled=enabled;var values:[Double]=[]
            dock.hold(seed[1].id,at:CGPoint(x:600,y:100),now:clock,spring:(0.28,0.84))
            for i in 0..<800 {
                clock+=1/60;dock.moveHeld(to:CGPoint(x:500+200*sin(Double(i)*0.05),y:100))
                let begin=CACurrentMediaTime();dock.heldFrame(at:clock)
                values.append((CACurrentMediaTime()-begin)*1000)
            }
            values.sort();nativeCosts[enabled ? "enabledP95Ms":"disabledP95Ms"]=values[Int(Double(values.count)*0.95)]
        }
        nativeCosts["addedP95Ms"]=max(0,(nativeCosts["enabledP95Ms"] ?? 0)-(nativeCosts["disabledP95Ms"] ?? 0))
        check((nativeCosts["addedP95Ms"] ?? 1)<0.5,"actual detached Dock frame/glyph added p95 < .5ms")
        if let data=try? JSONSerialization.data(withJSONObject:nativeCosts,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:output.appendingPathComponent("native-frame-cost.json"))}
        let peek=PeekNode(size:CGSize(width:500,height:400),scale:2);peek.motionProfile=profile;peek.motionEnabled=false
        check(peek.view.window==nil,"Peek stays detached")
    }
    /// Real retained composer and Orb callbacks, not a generic stand-in label.
    static func hookedIntegration(output:URL) {
        for scale:CGFloat in [1,2] {
            let root=DockNode.Passage(frame:CGRect(x:0,y:0,width:1080,height:220));root.wantsLayer=true
            let glass=NSGlassEffectView(frame:CGRect(x:40,y:60,width:650,height:48));root.addSubview(glass)
            let composer=NativeComposer(frame:CGRect(x:40,y:60,width:650,height:48))
            composer.verificationScale=scale;composer.targetWidth=650;composer.setText("Dock motion — text stays native at rest");root.addSubview(composer);composer.layoutSubtreeIfNeeded()
            let manager=M10DockComposer(in:root);manager.prepare(composer)
            let initial=NativeViewBitmap.capture(root,scale:scale),captureCount=manager.captures
            let parent=glass.superview
            var active=0,maxBudget=0.0,maxSource=0.0
            let path=spring("hook-composer",composer.frame,composer.frame.offsetBy(dx:270,dy:0))
            var old=composer.frame
            for i in 0...Int(ceil(path.duration*60)) {
                let now=path.pose(Double(i)/60);composer.frame=now
                let f=M10DockMotion.frame(name:"hook-composer",now:now,earlier:old,time:Double(i)/60,profile:profile,enabled:true)
                manager.update(composer,frame:f,profile:profile,enabled:true)
                if f.exposure.gate>0 {active+=1;check(manager.activeCount==1,"composer callback covers fast frame")}
                else {check(manager.activeCount==0,"composer same-frame native handback")}
                check(glass.superview === parent,"composer never reparents glass")
                check(manager.foreground.superview === root && root.subviews.last === manager.foreground,"AppKit foreground above material")
                let budget=M10ColumnRenderBudget.inspect(manager.foreground.layer!,scale:scale,frameInterval:profile.frameInterval)
                maxBudget=max(maxBudget,budget.replicatedPixels);maxSource=max(maxSource,budget.sourcePixels)
                check(budget.violations.isEmpty,"composer tight flat render budget: \(budget.violations)")
                old=now
            }
            check(active>0,"composer has processed frames")
            check(manager.captures==captureCount,"no composer texture bake in motion frames")
            // Borrow to a growing Normie-like host during exposure: first new layout restores native paint.
            composer.frame=path.pose(0).offsetBy(dx:24,dy:0)
            manager.update(composer,frame:M10DockMotion.frame(name:"borrow",now:composer.frame,earlier:path.pose(0),time:3,profile:profile,enabled:true),profile:profile,enabled:true)
            let borrower=NSView(frame:root.bounds);borrower.wantsLayer=true;borrower.addSubview(composer);composer.frame.size.height=120
            check(manager.activeCount==0,"composer borrow retires old proxies before new layout")
            check(composer.subviews.allSatisfy{abs(($0.layer?.opacity ?? 1)-Float($0.alphaValue))<0.001},"borrow restores child native opacity")
            root.addSubview(composer);composer.frame=path.pose(0);composer.layoutSubtreeIfNeeded();manager.prepare(composer,atCommit:true)
            manager.reset();composer.frame=path.pose(0)
            check(initial.dataProvider?.data==NativeViewBitmap.capture(root,scale:scale).dataProvider?.data,"composer rest pixels restore byte-exact \(scale)x")
            let full=M10DockPicture.draw(composer,scale:scale,plates:false)!
            let bytes=full.dataProvider!.data! as Data
            check(bytes[3]==0,"composer transparent own-draw blank alpha \(scale)x")
            check(bytes.contains{$0>0},"composer own-draw ink exists")
            report.append(["object":"hook-composer@\(Int(scale))x","processedFrames":active,"capturesDuringMotion":manager.captures-captureCount,"maxReplicatedPixels":maxBudget,"maxSourcePixels":maxSource,"budgetLimit":64*1024*1024])
            for content:OrbContent in [.me(initials:"AB",quota:.init(primaryUsed:0.2,secondaryUsed:0.3)),.identity(.assigned(2)),.seed] {
                var c=OrbConfiguration(content:content,drawingSize:48,backingScale:scale)
                c.badge = .init(tone:.yellow,symbol:.count(12));c.ambient=false
                let orb=OrbComponent(id:"hook-orb");orb.setCanvasSize(root.bounds.size);root.addSubview(orb.glassView);root.addSubview(orb.backView);root.addSubview(orb.frontView);orb.configure(c)
                let start=CGRect(x:80,y:80,width:48,height:48)
                orb.setFrame(start)
                M10DockMotion.onOrbFrame?(orb,M10DockMotion.frame(name:"orb",now:start,earlier:start,time:0,profile:profile,enabled:true),profile)
                let glyphCaptures=orb.verificationHostGlyph.captures,badgeCaptures=orb.verificationHostBadge.captures
                let next=start.offsetBy(dx:24,dy:0),f=M10DockMotion.frame(name:"orb",now:next,earlier:start,time:1/60,profile:profile,enabled:true)
                orb.setFrame(f.painted);M10DockMotion.onOrbFrame?(orb,f,profile)
                check(orb.verificationHostGlyph.sample.count>1,"orb host glyph hook accumulates")
                check(orb.verificationHostBadge.sample.count>1,"orb badge digits accumulate")
                for ink in [orb.verificationHostGlyph,orb.verificationHostBadge] {
                    let budget=M10ColumnRenderBudget.inspect(ink.carrier,scale:scale,frameInterval:profile.frameInterval)
                    check(budget.violations.isEmpty,"orb flattened tight backing budget: \(budget.violations)")
                    check(ink.captures == (ink === orb.verificationHostGlyph ? glyphCaptures:badgeCaptures),"orb no baking at motion sample")
                }
                orb.setFrame(next);M10DockMotion.onOrbFrame?(orb,M10DockMotion.frame(name:"orb",now:next,earlier:next,time:2/60,profile:profile,enabled:true),profile)
                check(orb.verificationHostGlyph.sample.count==1 && orb.verificationHostBadge.sample.count==1,"orb handback restores both ink planes")
                orb.dispose()
            }
        }
    }

    static func actualSamples(_ a:CGRect,_ b:CGRect,_ s:ExposureSample,_ layer:CAReplicatorLayer,_ name:String)->(CGFloat,CGFloat) {
        let step=MotionStep.edge(a,b),expected=CGFloat(smoothstep(1.08,2.7,Double(step)*profile.mmPerPoint))
        check(abs(s.gate-expected)<1e-8,name+" actual glyph physical gate")
        if s.gate>0{check(layer.instanceCount>1,name+" actual glyph coverage")}
        var previous=CGRect(origin:.zero,size:a.size),last=previous,transform=CGAffineTransform.identity,gap:CGFloat=0
        for _ in 1..<max(1,layer.instanceCount) {transform=transform.concatenating(CATransform3DGetAffineTransform(layer.instanceTransform));last=CGRect(origin:.zero,size:a.size).applying(transform);gap=max(gap,MotionStep.edge(previous,last));previous=last}
        let target=CGRect(x:(b.minX-a.minX)*s.gate,y:(b.minY-a.minY)*s.gate,width:a.width+(b.width-a.width)*s.gate,height:a.height+(b.height-a.height)*s.gate)
        check(MotionStep.edge(last,target)<1e-6,name+" last copy covers complete gated sweep")
        check(gap<=1.5+1e-6,name+" actual adjacent corner gap <=1.5pt")
        return(step,gap)
    }
    static func hookFrames(output:URL) throws {
        var lines="object,scale,frame,step_pt,step_mm,gate,copies,coverage_pt,max_gap_pt,replicated_pixels,source_pixels\n"
        for scale:CGFloat in [1,2] {
            let root=DockNode.Passage(frame:CGRect(x:0,y:0,width:1080,height:140));root.wantsLayer=true
            let composer=NativeComposer(frame:CGRect(x:30,y:50,width:650,height:48));composer.verificationScale=scale;composer.targetWidth=650;composer.setText("Dock exposure: native input — 文字累积");root.addSubview(composer);composer.layoutSubtreeIfNeeded()
            let manager=M10DockComposer(in:root);manager.prepare(composer)
            let path=spring("composer-follow",composer.frame,composer.frame.offsetBy(dx:300,dy:0)),frames=Int(ceil(path.duration*60))+2
            let offRoot=CALayer(),onRoot=CALayer(),off=OffscreenRenderer(size:root.bounds.size,host:offRoot,scale:scale),on=OffscreenRenderer(size:root.bounds.size,host:onRoot,scale:scale)
            offRoot.backgroundColor=NSColor(white:0.14,alpha:1).cgColor;onRoot.backgroundColor=offRoot.backgroundColor
            var sharp:[[UInt8]]=[],exposed:[[UInt8]]=[],old=composer.frame,maxStep:CGFloat=0,maxGap:CGFloat=0,maxLength:CGFloat=0,maxCopies=1,maxPixels=0.0,maxSource=0.0,cost:[Double]=[]
            let captures=manager.captures
            for i in 0..<frames {
                let now=path.pose(Double(i)/60);composer.frame=now
                let frame=M10DockMotion.frame(name:path.name,now:now,earlier:old,time:Double(i)/60,profile:profile,enabled:true)
                let start=CACurrentMediaTime();manager.update(composer,frame:frame,profile:profile,enabled:true);cost.append((CACurrentMediaTime()-start)*1000)
                var peak:ExposureSample = .still,gap:CGFloat=0
                for (a,b,s,l) in manager.verificationGlyphs {let metrics=actualSamples(a,b,s,l,"composer");maxStep=max(maxStep,metrics.0);gap=max(gap,metrics.1);if s.count>peak.count{peak=s}}
                maxGap=max(maxGap,gap);maxLength=max(maxLength,peak.length);maxCopies=max(maxCopies,peak.count)
                let budget=M10ColumnRenderBudget.inspect(manager.foreground.layer!,scale:scale,frameInterval:profile.frameInterval)
                maxPixels=max(maxPixels,budget.replicatedPixels);maxSource=max(maxSource,budget.sourcePixels)
                check(budget.violations.isEmpty,"hook frame composer budget")
                lines += "composer,\(Int(scale)),\(i),\(frame.exposure.stepPt),\(frame.stepMM),\(peak.gate),\(peak.count),\(peak.length),\(gap),\(budget.replicatedPixels),\(budget.sourcePixels)\n"
                offRoot.sublayers?.forEach{$0.removeFromSuperlayer()};onRoot.sublayers?.forEach{$0.removeFromSuperlayer()}
                offRoot.addSublayer(manager.verificationPaint(exposed:false));onRoot.addSublayer(manager.verificationPaint(exposed:true))
                sharp.append(off.render(at:10000+Double(i)/60));exposed.append(on.render(at:10000+Double(i)/60));old=now
            }
            for i in [0,frames-1] {check(sharp[i]==exposed[i],"actual composer first/last pixels zero diff")}
            check(spikes(sharp,off)==0 && spikes(exposed,on)==0,"actual composer off/on pixel spikes zero")
            check(manager.captures==captures,"whole composer path no texture capture")
            cost.sort();let p95=cost[Int(Double(cost.count-1)*0.95)]
            report.append(["object":"actual-composer@\(Int(scale))x","maxStepPt":maxStep,"maxStepMM":maxStep*0.27,"maxTailPt":maxLength,"maxCopies":maxCopies,"maxSpacingPt":maxGap,"maxReplicatedPixels":maxPixels,"maxSourcePixels":maxSource,"debugCallbackP95Ms":p95,"capturesDuringMotion":manager.captures-captures,"endpointMaxByteDiff":0,"spikesSharpAndExposure":[spikes(sharp,off),spikes(exposed,on)]])
            Offscreen.write(contact(sharp,exposed,off),output.appendingPathComponent("actual-composer-all-frames@\(Int(scale))x.png"))
            manager.reset()
            // All three actual glyph drawings and capped badge text, including a simultaneous translation + zoom.
            for (name,content):(String,OrbContent) in [("me",.me(initials:"AB",quota:.init(primaryUsed:0.2,secondaryUsed:0.4))),("identity",.identity(.assigned(3))),("seed",.seed)] {
                var config=OrbConfiguration(content:content,drawingSize:56,backingScale:scale);config.ambient=false;config.badge = .init(tone:.yellow,symbol:.count(12))
                let orb=OrbComponent(id:name);orb.setCanvasSize(root.bounds.size);orb.configure(config)
                let start=CGRect(x:30,y:40,width:40,height:40),path=spring(name,start,CGRect(x:780,y:40,width:56,height:56),0.4,0.82)
                var previous=start,stepPeak:CGFloat=0,gapPeak:CGFloat=0,lengthPeak:CGFloat=0,copiesPeak=1,pixelsPeak=0.0,sourcePeak=0.0
                let captures=orb.verificationHostGlyph.captures+orb.verificationHostBadge.captures
                for i in 0...Int(ceil(path.duration*60))+1 {
                    let r=path.pose(Double(i)/60),f=M10DockMotion.frame(name:name,now:r,earlier:previous,time:Double(i)/60,profile:profile,enabled:true)
                    orb.setFrame(f.painted);M10DockMotion.onOrbFrame?(orb,f,profile)
                    for (kind,ink) in [("glyph",orb.verificationHostGlyph),("badge",orb.verificationHostBadge)] where ink.sample.count>1 {
                        let (step,gap)=actualSamples(ink.sceneRect,ink.earlierRect,ink.sample,ink.trail.layer,name+kind)
                        stepPeak=max(stepPeak,step);gapPeak=max(gapPeak,gap);lengthPeak=max(lengthPeak,ink.sample.length);copiesPeak=max(copiesPeak,ink.sample.count)
                        let budget=M10ColumnRenderBudget.inspect(ink.carrier,scale:scale,frameInterval:profile.frameInterval)
                        check(budget.violations.isEmpty,"orb path budget: \(budget.violations)");pixelsPeak=max(pixelsPeak,budget.replicatedPixels);sourcePeak=max(sourcePeak,budget.sourcePixels)
                        lines += "\(name)-\(kind),\(Int(scale)),\(i),\(step),\(step*0.27),\(ink.sample.gate),\(ink.sample.count),\(ink.sample.length),\(gap),\(budget.replicatedPixels),\(budget.sourcePixels)\n"
                    }
                    previous=r
                }
                check(orb.verificationHostGlyph.captures+orb.verificationHostBadge.captures==captures,"orb full path no texture baking")
                check(orb.verificationHostGlyph.sample.count==1 && orb.verificationHostBadge.sample.count==1,"orb endpoint native handback")
                report.append(["object":"actual-\(name)@\(Int(scale))x","maxStepPt":stepPeak,"maxStepMM":stepPeak*0.27,"maxTailPt":lengthPeak,"maxCopies":copiesPeak,"maxSpacingPt":gapPeak,"maxReplicatedPixels":pixelsPeak,"maxSourcePixels":sourcePeak,"capturesDuringMotion":0])
                try orbContact(name:name,config:config,scale:scale,path:path,output:output)
                orb.dispose()
            }
        }
        try lines.write(to:output.appendingPathComponent("hooks-frames.csv"),atomically:true,encoding:.utf8)
    }

    static func orbContact(name:String,config:OrbConfiguration,scale:CGFloat,path:Path,output:URL) throws {
        let size=CGSize(width:940,height:140),off=OrbComponent(id:"off"),on=OrbComponent(id:"on")
        let offRoot=CALayer(),onRoot=CALayer(),offGlass=CAShapeLayer(),onGlass=CAShapeLayer(),offBody=CALayer(),onBody=CALayer()
        for (orb,root,glass,body) in [(off,offRoot,offGlass,offBody),(on,onRoot,onGlass,onBody)] {
            orb.setCanvasSize(size);orb.configure(config)
            let planes=orb.verificationHostPlanes
            root.backgroundColor=NSColor(white:0.14,alpha:1).cgColor
            glass.fillColor=NSColor(white:0.3,alpha:0.8).cgColor
            root.addSublayer(planes[0]);root.addSublayer(glass);body.anchorPoint = .zero;body.addSublayer(planes[1]);root.addSublayer(body);root.addSublayer(planes[2])
        }
        let a=OffscreenRenderer(size:size,host:offRoot,scale:scale),b=OffscreenRenderer(size:size,host:onRoot,scale:scale)
        var sharp:[[UInt8]]=[],exposed:[[UInt8]]=[],old=path.pose(0)
        let frames=Int(ceil(path.duration*60))+2
        for i in 0..<frames {
            let r=path.pose(Double(i)/60),f=M10DockMotion.frame(name:name,now:r,earlier:old,time:Double(i)/60,profile:profile,enabled:true)
            CATransaction.begin();CATransaction.setDisableActions(true)
            for (orb,glass,body,enabled) in [(off,offGlass,offBody,false),(on,onGlass,onBody,true)] {
                orb.setFrame(f.painted);orb.exposeGlyphs(now:r,earlier:old,profile:profile,enabled:enabled)
                glass.path=CGPath(roundedRect:f.painted,cornerWidth:min(f.painted.width,f.painted.height)/2,cornerHeight:min(f.painted.width,f.painted.height)/2,transform:nil)
                body.position=f.painted.origin
            }
            CATransaction.commit()
            sharp.append(a.render(at:20000+Double(i)/60));exposed.append(b.render(at:20000+Double(i)/60));old=r
        }
        var maxDiff=0
        for i in [0,frames-1] {
            let diff=zip(sharp[i],exposed[i]).map{abs(Int($0)-Int($1))}.max() ?? 0;maxDiff=max(maxDiff,diff)
            check(diff==0,"actual \(name) frame \(i) native pixels zero difference: \(diff)")
            if diff>0 {a.write(sharp[i],output.appendingPathComponent("\(name)-endpoint-\(i)-off@\(Int(scale))x.png"));b.write(exposed[i],output.appendingPathComponent("\(name)-endpoint-\(i)-on@\(Int(scale))x.png"))}
        }
        let x=spikes(sharp,a),y=spikes(exposed,b)
        check(x==0 && y==0,"actual \(name) off/on pixel spikes zero: \(x),\(y)")
        report.append(["object":"orb-contact-\(name)@\(Int(scale))x","endpointMaxByteDiff":maxDiff,"spikesSharpAndExposure":[x,y]])
        Offscreen.write(contact(sharp,exposed,a),output.appendingPathComponent("actual-\(name)-all-frames@\(Int(scale))x.png"))
        off.dispose();on.dispose()
    }

    static func switches() {
        let root=NSView(frame:CGRect(x:0,y:0,width:1080,height:140));root.wantsLayer=true
        let c=NativeComposer(frame:CGRect(x:30,y:50,width:650,height:48));c.targetWidth=650;c.setText("Independent switch");root.addSubview(c);c.layoutSubtreeIfNeeded()
        let manager=M10DockComposer(in:root);manager.prepare(c)
        let a=c.frame,b=a.offsetBy(dx:24,dy:0)
        manager.update(c,frame:M10DockMotion.frame(name:"switch",now:a,earlier:a,time:0,profile:profile,enabled:true),profile:profile,enabled:true)
        c.frame=b;manager.update(c,frame:M10DockMotion.frame(name:"switch",now:b,earlier:a,time:1/60,profile:profile,enabled:true),profile:profile,enabled:true)
        check((manager.activeCount>0)==M10DockComposer.enabled,"composer switch controls its adapter")
        let orb=OrbComponent(id:"switch");orb.configure(.init(content:.identity(.assigned(1)),drawingSize:48,badge:.init(tone:.yellow,symbol:.count(12)),ambient:false))
        let r=CGRect(x:30,y:30,width:48,height:48),n=r.offsetBy(dx:24,dy:0)
        orb.setFrame(r);M10DockMotion.onOrbFrame?(orb,M10DockMotion.frame(name:"switch",now:r,earlier:r,time:0,profile:profile,enabled:true),profile)
        let f=M10DockMotion.frame(name:"switch",now:n,earlier:r,time:1/60,profile:profile,enabled:true);orb.setFrame(f.painted);M10DockMotion.onOrbFrame?(orb,f,profile)
        check((orb.verificationHostGlyph.sample.count>1)==M10DockMotion.orbExposureEnabled,"orb switch controls symbol independently")
        check((orb.verificationHostBadge.sample.count>1)==M10DockMotion.orbExposureEnabled,"orb switch controls badge independently")
        manager.reset();orb.dispose()
    }

}
#endif
