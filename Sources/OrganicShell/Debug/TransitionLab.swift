import AppKit
import QuartzCore

@MainActor final class TransitionLabStage:DebugCanvas {
    var frameData=TransitionLabFrame(image:nil,provenance:"Host not connected"){didSet{needsDisplay=true}}
    var outlines=false
    override func draw(_ dirtyRect:NSRect){
        super.draw(dirtyRect);let viewport=bounds.insetBy(dx:20,dy:38)
        if let image=frameData.image{NSImage(cgImage:image,size:viewport.size).draw(in:viewport)}else{DebugPaint.text("Connect TransitionLabHost to render the actual column.",CGRect(x:26,y:90,width:bounds.width-40,height:60),color:.secondaryLabelColor)}
        DebugPaint.text(frameData.provenance,CGRect(x:20,y:12,width:bounds.width-40,height:20),size:11,color:.secondaryLabelColor)
        guard outlines else{return}
        NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:viewport).addClip()
        for anchor in frameData.anchors {
            for (rect,color) in [(anchor.full,NSColor.systemOrange),(anchor.brief,NSColor.systemCyan)]{let r=rect.offsetBy(dx:viewport.minX,dy:viewport.minY);color.setStroke();let p=NSBezierPath(rect:r);p.lineWidth=1;p.stroke();DebugPaint.text(anchor.name,r.insetBy(dx:2,dy:1),size:9,color:color)}
        }
        NSColor.systemYellow.setStroke()
        for path in frameData.paths{let line=NSBezierPath();for (i,point) in path.points.enumerated(){let p=CGPoint(x:point.x+viewport.minX,y:point.y+viewport.minY);if i == 0{line.move(to:p)}else{line.line(to:p)}};line.lineWidth=1;line.stroke()}
        NSGraphicsContext.restoreGraphicsState()
    }
}
@MainActor final class TransitionLabPage:DebugPageController {
    let store:ConversationStore
    weak var host:(any TransitionLabHost)?
    let stage=TransitionLabStage(),form=DebugForm(),controls=NSScrollView()
    private(set) var transport=TransitionLabTransport()
    var parameters=TransitionLabParameters()
    private(set) var conversationID:String
    private var timer:Timer?,lastTime=0.0
    private var formSlider:DebugSlider!,formLabel=DebugPaint.label("",size:11)
    private var loopButton:DebugButton!,outlineButton:DebugButton!
    private(set) var outlines=false
    init(store:ConversationStore,host:(any TransitionLabHost)?){self.store=store;self.host=host;conversationID=store.conversations.first?.id ?? "A";super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    isolated deinit{timer?.invalidate()}
    override func loadView(){
        super.loadView();view.setAccessibilityLabel("Transition Lab");view.addSubview(stage);controls.drawsBackground=false;controls.hasVerticalScroller=true;controls.documentView=form;view.addSubview(controls)
        form.heading("Column")
        form.menu("Conversation",choices:store.conversations.map{$0.id+" · "+$0.title}){[weak self] i in guard let self,store.conversations.indices.contains(i)else{return};conversationID=store.conversations[i].id;render()}
        form.add(formLabel,height:20)
        formSlider=form.slider("Form",value:1,range:0...1){[weak self] in self?.scrub($0)}
        form.button("−0.02"){[weak self] in self?.nudge(-0.02)};form.button("+0.02"){[weak self] in self?.nudge(0.02)}
        form.heading("Play")
        form.button("Full → Brief"){[weak self] in self?.play(toBrief:true)};form.button("Brief → Full"){[weak self] in self?.play(toBrief:false)}
        form.button("Stop"){[weak self] in self?.stop()}
        form.menu("Speed",choices:["1×","½×","¼×","⅒×"]){[weak self] i in self?.transport.slow=[1,2,4,10][i]}
        loopButton=form.toggle("Loop both ways",value:false){[weak self] in guard let self else{return};transport.loop.toggle();loopButton.checked=transport.loop;if transport.loop{play(toBrief:transport.form>0.5)}}
        outlineButton=form.toggle("Outline anchors and paths",value:false){[weak self] in guard let self else{return};outlines.toggle();outlineButton.checked=outlines;render()}
        form.heading("Geometry / motion")
        parameter("Full width",\.fullWidth,480...900);parameter("Brief width",\.briefWidth,200...420);parameter("Height",\.height,420...760)
        parameter("Response",\.response,0.05...1.2);parameter("Damping",\.damping,0.2...1.2);parameter("Burst",\.burst,0...80);parameter("Swirl",\.swirl,-90...90);parameter("Pop",\.pop,0...0.4);parameter("Stagger",\.stagger,0...0.12)
        form.button("Export filmstrip…"){[weak self] in self?.chooseFilmstripDirectory()}
        form.note("Orange: full anchors; cyan: brief; yellow: path. Filmstrip exports 22 exact forms and a manifest. Production / historical provenance comes from the host.",height:86)
        render()
    }
    private func parameter(_ title:String,_ key:WritableKeyPath<TransitionLabParameters,Double>,_ range:ClosedRange<Double>){form.slider(title,value:parameters[keyPath:key],range:range){[weak self] value in guard let self else{return};parameters[keyPath:key]=value;parameters.normalize();render()}}
    override func viewDidLayout(){super.viewDidLayout();let r=view.safeAreaRect;stage.frame=CGRect(x:r.minX,y:r.minY,width:max(1,r.width-320),height:r.height);controls.frame=CGRect(x:r.maxX-320,y:r.minY,width:320,height:r.height);form.frame.size.width=controls.contentSize.width;form.layoutSubtreeIfNeeded();render()}
    override func activate(){super.activate();_ = view;host?.transitionLabAttach();render()}
    override func deactivate(){stop();host?.transitionLabDetach();stage.frameData = .init(image:nil,provenance:"Detached");super.deactivate()}
    func scrub(_ value:Double){transport.scrub(value);stopTimer();render()}
    func nudge(_ amount:Double){transport.nudge(amount);stopTimer();render()}
    func play(toBrief:Bool){transport.play(toBrief:toBrief,fromEndpoint:!transport.playing);render();startTimer()}
    func stop(){transport.stop();stopTimer()}
    func advance(_ dt:Double){transport.advance(dt,parameters:parameters);render();if !transport.playing{stopTimer()}}
    private func startTimer(){guard active,timer == nil else{return};lastTime=CACurrentMediaTime();let timer=Timer(timeInterval:1/60,repeats:true){[weak self] _ in MainActor.assumeIsolated{guard let self else{return};let now=CACurrentMediaTime();self.advance(max(0,now-self.lastTime));self.lastTime=now}};self.timer=timer;RunLoop.main.add(timer,forMode:.common)}
    private func stopTimer(){timer?.invalidate();timer=nil}
    var request:TransitionLabRequest{.init(conversationID:conversationID,form:transport.form,towardBrief:transport.towardBrief,parameters:parameters,outlines:outlines,frozen:transport.playing || (transport.form>0.0005 && transport.form<0.9995))}
    func render(){guard isViewLoaded else{return};formLabel.stringValue=String(format:"%.3f · %@",transport.form,transport.form>0.5 ? "full":"brief");formSlider?.set(transport.form);stage.outlines=outlines
        if let host,active{stage.frameData=host.transitionLabRender(request,size:CGSize(width:max(1,stage.bounds.width-40),height:max(1,stage.bounds.height-76)),scale:view.window?.backingScaleFactor ?? 2)}
    }
    func exportFilmstrip(to directory:URL,scale:CGFloat)throws {
        guard let host,active else{throw LabExportError.hostUnavailable};try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let saved=transport;stop();defer{transport=saved;transport.stop();render()}
        var provenance=Set<String>()
        for (brief,form) in TransitionLabTransport.filmstrip {
            var request=request;request.form=form;request.towardBrief=brief;request.frozen=true
            let data=host.transitionLabRender(request,size:CGSize(width:max(1,stage.bounds.width-40),height:max(1,stage.bounds.height-76)),scale:scale)
            guard let image=data.image else{throw LabExportError.noImage};provenance.insert(data.provenance)
            let filename=String(format:"%@-%03d.png",brief ? "to-brief":"to-full",Int((form*100).rounded()))
            try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(filename),options:.atomic)
        }
        let p=parameters
        let manifest:[String:Any]=["conversationID":conversationID,"scale":scale,"frames":22,"provenance":provenance.sorted(),"parameters":["fullWidth":p.fullWidth,"briefWidth":p.briefWidth,"height":p.height,"response":p.response,"damping":p.damping,"burst":p.burst,"swirl":p.swirl,"pop":p.pop,"stagger":p.stagger],"os":ProcessInfo.processInfo.operatingSystemVersionString]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("manifest.json"),options:.atomic)
    }
    private func chooseFilmstripDirectory(){guard let window=view.window else{return};let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true;panel.prompt="Export filmstrip";panel.beginSheetModal(for:window){[weak self] result in MainActor.assumeIsolated{guard result == .OK,let directory=panel.url,let self else{return};do{try self.exportFilmstrip(to:directory,scale:window.backingScaleFactor)}catch{self.formLabel.stringValue=error.localizedDescription}}}}
}
enum LabExportError:LocalizedError {case hostUnavailable,noImage;var errorDescription:String?{self == .hostUnavailable ? "Connect a scene host before exporting.":"The host did not return an image."}}
