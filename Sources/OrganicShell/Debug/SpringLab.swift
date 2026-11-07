import AppKit
import QuartzCore

struct LabSpringSample {var time:Double,value:Double,busyMilliseconds:Double}
struct LabSpringTrace {
    var samples:[LabSpringSample]=[]
    mutating func append(time:Double,value:Double,busyMilliseconds:Double){if let last=samples.last,time-last.time<0.004{samples[samples.count-1] = .init(time:time,value:value,busyMilliseconds:busyMilliseconds)}else{samples.append(.init(time:time,value:value,busyMilliseconds:busyMilliseconds))}}
    func result(variant:LabSpringVariant,target:Double,scale:Double)->SpringLabMeasurement {
        let visible=samples.last(where:{abs(target-$0.value)>=0.5/max(1,scale)})?.time ?? 0
        let settled=samples.first(where:{$0.time>visible})?.time ?? samples.last?.time ?? 0
        return .init(variant:variant,frames:samples.count,tailFrames:samples.filter{$0.time>settled}.count,duration:samples.last?.time ?? 0,visibleEnd:visible,busyMilliseconds:samples.reduce(0){$0+$1.busyMilliseconds},tailBusyMilliseconds:samples.filter{$0.time>settled}.reduce(0){$0+$1.busyMilliseconds},provenance:"Lab draw CPU · sampled System Spring")
    }
    static func median(_ values:[SpringLabMeasurement])->SpringLabMeasurement? {
        guard let first=values.first else{return nil};func m(_ key:KeyPath<SpringLabMeasurement,Double>)->Double{let sorted=values.map{$0[keyPath:key]}.sorted();let n=sorted.count;return n%2 == 1 ? sorted[n/2]:(sorted[n/2-1]+sorted[n/2])/2}
        func count(_ key:KeyPath<SpringLabMeasurement,Int>)->Int{let a=values.map{$0[keyPath:key]}.sorted();return a[a.count/2]}
        return .init(variant:first.variant,frames:count(\.frames),tailFrames:count(\.tailFrames),duration:m(\.duration),visibleEnd:m(\.visibleEnd),busyMilliseconds:m(\.busyMilliseconds),tailBusyMilliseconds:m(\.tailBusyMilliseconds),provenance:first.provenance,preset:first.preset,subject:first.subject)
    }
}
struct SpringLabSimulation {
    var request=SpringLabRequest()
    private(set) var elapsed=0.0,playing=false
    private(set) var values=[0.0,0,0]
    private var starts=[0.0,0,0],velocities=[0.0,0,0],target=1.0
    var fit=LabFittedCurve.fit(LabSpring(response:0.42,damping:0.86),distance:370)
    mutating func play(_ request:SpringLabRequest){self.request=request;self.request.normalize();starts=values;velocities=[0,0,0];target=request.target;elapsed=0;playing=true;fit = .fit(LabSpring(response:self.request.response,damping:self.request.damping),distance:self.request.distance)}
    mutating func interrupt(){
        let spring=LabSpring(response:request.response,damping:request.damping)
        velocities=starts.indices.map{let distance=target-starts[$0];return distance*spring.velocity(elapsed,initial:abs(distance)>1e-9 ? velocities[$0]/distance:0)};starts=values;target=1-target;request.target=target;elapsed=0;playing=true
    }
    mutating func stop(){playing=false}
    mutating func advance(_ dt:Double){guard playing,dt.isFinite,dt>=0 else{return};elapsed+=dt/request.slow
        let spring=LabSpring(response:request.response,damping:request.damping),cut=fit.duration
        for i in 0..<3 {
            let distance=target-starts[i]
            switch i {
            case 2:values[i]=starts[i]+distance*fit.value(elapsed)
            case 1:values[i]=elapsed>=cut ? target:starts[i]+distance*spring.value(elapsed,velocity:abs(distance)>1e-9 ? velocities[i]/distance:0)
            default:values[i]=starts[i]+distance*spring.value(elapsed,velocity:abs(distance)>1e-9 ? velocities[i]/distance:0)
            }
        }
        if elapsed>=spring.settlingTime{values=[target,target,target];playing=false}
    }
}
@MainActor final class SpringLabStage:DebugCanvas {
    var simulation=SpringLabSimulation(){didSet{needsDisplay=true}}
    var columnImage:CGImage?{didSet{needsDisplay=true}}
    var overlay=false
    var onDraw:((Double)->Void)?
    override func draw(_ dirtyRect:NSRect){
        let start=CACurrentMediaTime();super.draw(dirtyRect)
        if simulation.request.realColumn {
            if let columnImage{NSImage(cgImage:columnImage,size:bounds.insetBy(dx:24,dy:40).size).draw(in:bounds.insetBy(dx:24,dy:40))}else{DebugPaint.text("Connect SpringLabHost for the real column.",CGRect(x:24,y:90,width:bounds.width-48,height:35),color:.secondaryLabelColor)}
        }else{
            let colors:[NSColor]=[.systemOrange,.systemMint,.systemPurple],distance=min(CGFloat(simulation.request.distance),max(10,bounds.width-120))
            for (i,variant) in LabSpringVariant.allCases.enumerated(){let y:CGFloat=overlay ? 130:90+CGFloat(i)*94;DebugPaint.text(variant.rawValue,CGRect(x:24,y:y-28,width:bounds.width-48,height:20),color:colors[i]);NSColor.white.withAlphaComponent(0.10).setFill();CGRect(x:40,y:y+10,width:distance,height:1).fill();colors[i].setFill();NSBezierPath(roundedRect:CGRect(x:40+CGFloat(simulation.values[i])*distance,y:y,width:24,height:24),xRadius:7,yRadius:7).fill()}
            let spring=LabSpring(response:simulation.request.response,damping:simulation.request.damping),rect=CGRect(x:40,y:400,width:max(40,bounds.width-80),height:max(80,bounds.height-490))
            for (i,color) in colors.enumerated(){color.setStroke();let path=NSBezierPath();for j in 0...160{let t=Double(j)/160*spring.settlingTime,v=i == 2 ? simulation.fit.value(t):i == 1 && t>=simulation.fit.duration ? 1:spring.value(t);let p=CGPoint(x:rect.minX+CGFloat(j)/160*rect.width,y:rect.maxY-CGFloat(v)*rect.height);if j == 0{path.move(to:p)}else{path.line(to:p)}};path.lineWidth=1.5;path.stroke()}
        }
        DebugPaint.text("System evaluator / truncated experiment / fitted Bézier",CGRect(x:24,y:16,width:bounds.width-48,height:24),size:11,color:.secondaryLabelColor)
        onDraw?((CACurrentMediaTime()-start)*1000)
    }
}
@MainActor final class SpringLabPage:DebugPageController {
    let store:ConversationStore
    weak var host:(any SpringLabHost)?
    let stage=SpringLabStage(),spotlight=SpotlightLabStage(),form=DebugForm(),controls=NSScrollView()
    private(set) var simulation=SpringLabSimulation()
    var request=SpringLabRequest()
    private(set) var results:[SpringLabMeasurement]=[]
    private(set) var spotlightMode=false,loop=false
    private var timer:Timer?,lastTime=0.0,spotlightTime=0.0
    private var measureTask:Task<Void,Never>?,generation=0
    private var traces=[LabSpringTrace(),LabSpringTrace(),LabSpringTrace()]
    private var measuringLanes=false
    private var resultLabel=DebugPaint.label("No measurements yet.",size:11)
    init(store:ConversationStore,host:(any SpringLabHost)?){self.store=store;self.host=host;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    isolated deinit{timer?.invalidate();measureTask?.cancel()}
    override func loadView(){
        super.loadView();view.setAccessibilityLabel("Spring and Spotlight Lab");view.addSubview(stage);view.addSubview(spotlight);spotlight.isHidden=true;controls.drawsBackground=false;controls.hasVerticalScroller=true;controls.documentView=form;view.addSubview(controls)
        stage.onDraw={[weak self] cpu in guard let self,measuringLanes else{return};for i in 0..<3{traces[i].append(time:simulation.elapsed,value:simulation.values[i]*request.distance,busyMilliseconds:cpu/3)}}
        form.menu("Lab",choices:["Spring comparison","Spotlight glass"]){[weak self] i in self?.setSpotlight(i == 1)}
        form.heading("Spring")
        form.menu("Preset",choices:LabSpringPreset.all.map(\.name)){[weak self] i in self?.applyPreset(i)}
        parameter("Response",\.response,0.1...1);parameter("Damping",\.damping,0.4...1);parameter("Distance",\.distance,10...600)
        form.heading("Play")
        form.button("Play / Space"){[weak self] in self?.play()}
        form.button("Interrupt midway"){[weak self] in self?.playAndInterrupt()}
        form.button("Stop / Esc"){[weak self] in self?.stop()}
        form.menu("Speed",choices:["1×","½×","¼×","⅒×"]){[weak self] i in self?.request.slow=[1,2,4,10][i]}
        let loopButton=form.toggle("Loop",value:false){};loopButton.onPress={[weak self,weak loopButton] in guard let self else{return};loop.toggle();loopButton?.checked=loop;if loop{play()}}
        let overlayButton=form.toggle("Lanes on top of each other",value:false){};overlayButton.onPress={[weak self,weak overlayButton] in guard let self else{return};stage.overlay.toggle();overlayButton?.checked=stage.overlay;stage.needsDisplay=true}
        form.heading("Subject")
        form.menu("Subject",choices:["Lanes","Real column"]){[weak self] i in self?.request.realColumn=i == 1;self?.stage.simulation.request.realColumn=i == 1}
        form.menu("Drive",choices:LabSpringVariant.allCases.map(\.rawValue)){[weak self] i in self?.request.variant=LabSpringVariant.allCases[i]}
        form.menu("Conversation",choices:store.conversations.map{$0.id+" · "+$0.title}){[weak self] i in guard let self,store.conversations.indices.contains(i)else{return};request.conversationID=store.conversations[i].id}
        form.heading("Measure")
        form.slider("Runs per variant",value:4,range:2...12){[weak self] in self?.request.runs=Int($0.rounded())}
        form.button("This spring"){[weak self] in self?.startMeasuring(all:false)}
        form.button("Every preset, both subjects"){[weak self] in self?.startMeasuring(all:true)}
        form.button("Clear results"){[weak self] in self?.results=[];self?.showResults()}
        resultLabel.maximumNumberOfLines=0;resultLabel.lineBreakMode = .byWordWrapping;form.add(resultLabel,height:160)
        form.note("Lanes report actual draw samples and draw CPU, not SwiftUI evaluations or full run-loop cost. Real-column measurement is supplied by the scene host. Truncation is an experiment, not a production policy.",height:100)
    }
    private func parameter(_ name:String,_ key:WritableKeyPath<SpringLabRequest,Double>,_ range:ClosedRange<Double>){form.slider(name,value:request[keyPath:key],range:range){[weak self] value in guard let self else{return};request[keyPath:key]=value;request.normalize();simulation.request=request;simulation.fit = .fit(LabSpring(response:request.response,damping:request.damping),distance:request.distance);stage.simulation=simulation}}
    override func viewDidLayout(){super.viewDidLayout();let r=view.safeAreaRect;stage.frame=CGRect(x:r.minX,y:r.minY,width:max(1,r.width-320),height:r.height);spotlight.frame=stage.frame;controls.frame=CGRect(x:r.maxX-320,y:r.minY,width:320,height:r.height);form.frame.size.width=controls.contentSize.width;form.layoutSubtreeIfNeeded()}
    override func activate(){super.activate();_ = view;host?.springLabAttach()}
    override func deactivate(){stop();host?.springLabDetach();stage.columnImage=nil;stage.onDraw=nil;spotlight.releaseGlass();super.deactivate()}
    func setSpotlight(_ value:Bool){stop();spotlightTime=0;spotlightMode=value;if let menu=form.rows.compactMap({$0.0 as? DebugButton}).first(where:{$0.title == "Lab"}){menu.selection=value ? 1:0;menu.valueText=value ? "Spotlight glass":"Spring comparison"};stage.isHidden=value;spotlight.isHidden = !value;if value{spotlight.installGlass();spotlight.needsLayout=true}}
    func applyPreset(_ index:Int){guard LabSpringPreset.all.indices.contains(index)else{return};let p=LabSpringPreset.all[index];request.response=p.response;request.damping=p.damping;request.distance=p.distance;request.normalize();simulation.request=request;simulation.fit = .fit(LabSpring(response:request.response,damping:request.damping),distance:request.distance);stage.simulation=simulation
        for case let slider as DebugSlider in form.subviews{switch slider.name{case "Response":slider.set(request.response);case "Damping":slider.set(request.damping);case "Distance":slider.set(request.distance);default:break}}
    }
    func play(){guard active else{return};if spotlightMode{spotlight.out.toggle();spotlight.needsLayout=true;startTimer();return}
        let drive=LabSpringVariant.allCases.firstIndex(of:request.variant) ?? 0;request.from=simulation.values[drive];request.target=simulation.playing ? (request.target>0.5 ? 0:1):(request.from>0.5 ? 0:1);request.normalize();simulation.play(request);stage.simulation=simulation
        if request.realColumn{host?.springLabPlay(request)};startTimer()
    }
    private var interruptAt:Double?
    func playAndInterrupt(){play();interruptAt=simulation.fit.duration*0.3}
    func interrupt(){simulation.interrupt();request.target=simulation.request.target;if request.realColumn{host?.springLabInterrupt(request)};stage.simulation=simulation}
    func advance(_ dt:Double){
        if spotlightMode{spotlight.advance(dt);spotlightTime+=dt;if spotlightTime>=1.6{spotlightTime=0;spotlight.out.toggle();spotlight.needsLayout=true};return}
        simulation.advance(dt)
        if let interruptAt,simulation.elapsed>=interruptAt{self.interruptAt=nil;interrupt()}
        stage.simulation=simulation
        if request.realColumn{stage.columnImage=host?.springLabFrame(size:stage.bounds.insetBy(dx:24,dy:40).size,scale:view.window?.backingScaleFactor ?? 2)}
        if !simulation.playing{if measuringLanes{measuringLanes=false};if loop{play()}else{stopTimer()}}
    }
    private func startTimer(){guard timer == nil,active else{return};lastTime=CACurrentMediaTime();let timer=Timer(timeInterval:1/60,repeats:true){[weak self] _ in MainActor.assumeIsolated{guard let self else{return};let now=CACurrentMediaTime();self.advance(max(0,now-self.lastTime));self.lastTime=now}};self.timer=timer;RunLoop.main.add(timer,forMode:.common)}
    private func stopTimer(){timer?.invalidate();timer=nil}
    func stop(){generation+=1;measureTask?.cancel();measureTask=nil;measuringLanes=false;simulation.stop();interruptAt=nil;stopTimer();host?.springLabStop()}
    @discardableResult func measureHost() async throws->[SpringLabMeasurement]{guard active,let host else{throw LabExportError.hostUnavailable};var request=request;request.normalize();return try await host.springLabMeasure(request)}
    func startMeasuring(all:Bool){stop();loop=false;let token=generation;let presets=all ? LabSpringPreset.all:[LabSpringPreset(name:"Current",response:request.response,damping:request.damping,distance:request.distance)]
        measureTask=Task{[weak self] in guard let self else{return};let original=request;defer{if generation == token{request=original;showResults()}}
            for preset in presets {for real in (all ? [false,true]:[original.realColumn]){guard !Task.isCancelled,active,generation == token else{return};request.response=preset.response;request.damping=preset.damping;request.distance=preset.distance;request.slow=1;request.realColumn=real
                do{if real{let measured=try await measureHost();guard !Task.isCancelled,active,generation == token else{return};results+=measured.map{var value=$0;value.preset=preset.name;value.subject="Real column";return value}}else{
                    var runs:[[SpringLabMeasurement]]=[[],[],[]]
                    for _ in 0..<request.runs{traces=[LabSpringTrace(),LabSpringTrace(),LabSpringTrace()];measuringLanes=true;play();while simulation.playing,!Task.isCancelled{try await Task.sleep(for:.milliseconds(25))};try Task.checkCancellation();for (i,v) in LabSpringVariant.allCases.enumerated(){runs[i].append(traces[i].result(variant:v,target:request.target*request.distance,scale:Double(view.window?.backingScaleFactor ?? 2)))}}
                    for values in runs{if var median=LabSpringTrace.median(values){median.preset=preset.name;median.subject="Lanes";results.append(median)}}
                };guard generation == token else{return};showResults()}catch{guard generation == token else{return};resultLabel.stringValue=error.localizedDescription;return}
            }}
        }
    }
    private func showResults(){
        resultLabel.stringValue=results.isEmpty ? "No measurements yet.":results.map{"\($0.preset) · \($0.subject) · \($0.variant.rawValue)\n\($0.frames) frames / \($0.tailFrames) tail · "+String(format:"%.1f ms draw CPU · %.3f s\n",$0.busyMilliseconds,$0.duration)+$0.provenance}.joined(separator:"\n\n")
        form.setHeight(resultLabel,max(160,CGFloat(results.count)*64));form.layoutSubtreeIfNeeded()
    }
    override func keyDown(with event:NSEvent){if event.keyCode == 49{play()}else if event.keyCode == 53{stop()}else{super.keyDown(with:event)}}
}
