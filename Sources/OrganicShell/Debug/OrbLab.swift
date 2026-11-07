import AppKit

@MainActor final class DebugOrbTile:DebugCanvas {
    let orb:OrbComponent
    let container=NSGlassEffectContainerView()
    private(set) var configuration:OrbConfiguration
    var caption:String
    private var hover=false
    private var tracking:NSTrackingArea?
    init(id:String,configuration:OrbConfiguration,caption:String){
        self.configuration=configuration;self.caption=caption;orb=OrbComponent(id:id);super.init(frame:.zero)
        container.spacing=8;addSubview(orb.backView);addSubview(container);container.contentView=NativeFlippedView();container.contentView?.addSubview(orb.glassView);addSubview(orb.frontView)
        setAccessibilityRole(.image);setAccessibilityLabel(caption);orb.configure(configuration)
    }
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    func configure(_ next:OrbConfiguration){configuration=next;var c=next;if hover{c.satelliteMode = .rows;c.redUnseen=false};orb.configure(c);needsDisplay=true}
    override func layout(){super.layout();container.frame=bounds;container.contentView?.frame=container.bounds;orb.setCanvasSize(bounds.size);let d=configuration.drawingSize;let planet=CGRect(x:bounds.midX-d/2,y:42,width:d,height:d);orb.glassView.frame=planet;orb.glassView.cornerRadius=d/2;orb.setFrame(planet)}
    override func updateTrackingAreas(){super.updateTrackingAreas();if let tracking{removeTrackingArea(tracking)};let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self);tracking=area;addTrackingArea(area)}
    override func mouseEntered(with event:NSEvent){hover=true;configure(configuration)}
    override func mouseExited(with event:NSEvent){hover=false;configure(configuration)}
    override func draw(_ dirtyRect:NSRect){
        super.draw(dirtyRect)
        for i in 0..<5{DebugPaint.text("Glass over transcript · \(i+1)",CGRect(x:4,y:20+CGFloat(i)*20,width:bounds.width-8,height:16),size:10,color:NativeDisplayOptions.shared.state.increaseContrast ? .secondaryLabelColor:NSColor.white.withAlphaComponent(0.12))}
        if window == nil,let c=NSGraphicsContext.current?.cgContext {orb.renderOffscreenDecorations(in:c,planet:orb.glassView.frame)}
        DebugPaint.text(caption,CGRect(x:4,y:bounds.height-29,width:bounds.width-8,height:26),size:10,color:.secondaryLabelColor)
    }
    func dispose(){orb.setPresentationActive(false);orb.dispose()}
}
@MainActor final class OrbLabPage:DebugPageController {
    let store:ConversationStore
    let form=DebugForm(),controls=NSScrollView(),scroll=NSScrollView(),board=DebugCanvas()
    private(set) var tiles:[DebugOrbTile]=[]
    private var observation:UUID?
    var queueSize:CGFloat=40,context:Double?;var pace=0.5,reduceMotion=false,rows=false,animate=true
    init(store:ConversationStore){self.store=store;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func loadView(){
        super.loadView();view.setAccessibilityLabel("Orb Lab")
        for (s,d) in [(controls,form),(scroll,board)]{s.drawsBackground=false;s.hasVerticalScroller=true;s.autohidesScrollers=true;s.documentView=d;view.addSubview(s)}
        form.heading("Orb Lab")
        form.slider("Queue size",value:40,range:24...64){[weak self] in self?.queueSize=$0;self?.rebuild()}
        form.toggle("Calibrate liquid",value:false){[weak self] in guard let self else{return};context=context == nil ? 0.5:nil;refresh()}
        form.slider("Liquid used",value:0.5,range:0...1){[weak self] value in self?.context=value;self?.refresh()}
        form.slider("Satellite pace",value:0.5,range:0...1){[weak self] value in self?.pace=value;self?.refresh()}
        form.toggle("Reduce Motion",value:false){[weak self] in self?.reduceMotion.toggle();self?.refresh()}
        form.toggle("Satellite rows",value:false){[weak self] in self?.rows.toggle();self?.refresh()}
        form.toggle("Ambient animation",value:true){[weak self] in self?.animate.toggle();self?.refresh()}
        form.note("Queue / 2× / 36 pt; all 13 identities. Hover spreads the same satellites into rows. Events come from Debug.",height:80)
        form.note("Offscreen material is a neutral proxy. Live NSGlassEffectView provides the backdrop refraction.",height:64)
        rebuild()
    }
    override func viewDidLayout(){super.viewDidLayout();let r=view.safeAreaRect;controls.frame=CGRect(x:r.minX,y:r.minY,width:250,height:r.height);form.frame.size.width=controls.contentSize.width;form.layoutSubtreeIfNeeded();scroll.frame=CGRect(x:r.minX+250,y:r.minY,width:max(1,r.width-250),height:r.height);layoutTiles()}
    override func activate(){super.activate();_ = view;observation=store.observe{[weak self] _ in self?.refresh()};refresh()}
    override func deactivate(){super.deactivate();if let observation{store.removeObserver(observation)};observation=nil;for tile in tiles{tile.dispose();tile.removeFromSuperview()};tiles=[]}
    func rebuild(){
        guard isViewLoaded else{return};for tile in tiles{tile.dispose();tile.removeFromSuperview()};tiles=[]
        for (row,size) in [queueSize,queueSize*2,36].enumerated(){for c in store.conversations{let tile=DebugOrbTile(id:"lab-\(row)-\(c.id)",configuration:configuration(c,size:size),caption:"\(c.id) · \(Int(size)) pt · \(OrbIdentity.assigned(c.identityIndex).symbol.name)");tiles.append(tile);board.addSubview(tile)}}
        for body in OrbCelestialBody.allCases{let tile=DebugOrbTile(id:"identity-\(body.rawValue)",configuration:OrbConfiguration(content:.identity(.assigned(body.rawValue)),drawingSize:40,context:context ?? 0.46,reduceMotion:reduceMotion,ambient:false),caption:body.name);tiles.append(tile);board.addSubview(tile)}
        layoutTiles()
    }
    func refresh(){
        guard isViewLoaded else{return};let expected=store.conversations.count*3+13;if tiles.count != expected{rebuild();return}
        var i=0;for size in [queueSize,queueSize*2,36]{for c in store.conversations{tiles[i].configure(configuration(c,size:size));i+=1}}
        for tile in tiles.dropFirst(i){var config=tile.configuration;config.context=context ?? 0.46;config.reduceMotion=reduceMotion;tile.configure(config)}
        let toggles=form.rows.compactMap{$0.0 as? DebugButton}.filter(\.isToggle)
        for (b,value) in zip(toggles,[context != nil,reduceMotion,rows,animate]){b.checked=value}
    }
    private func configuration(_ c:Conversation,size:CGFloat)->OrbConfiguration {
        OrbConfiguration(content:.identity(.assigned(c.identityIndex)),drawingSize:size,context:context ?? c.contextUsed,running:c.running,badge:.resolve(error:c.error.map{$0 == .running ? .running:.stopped},approvals:c.approvals.count,question:c.question != nil,completions:c.completions),satellites:c.satellites.map{.init(id:$0.id,face:$0.face,pace:pace,done:$0.done,finishedOrder:$0.finishedOrder)},satellitesRetired:c.satellitesRetired,satelliteMode:rows ? .rows:.orbit,compactions:c.compactions,completions:c.completions,redEvents:c.redEvents,redUnseen:c.redEvents>0,reduceMotion:reduceMotion,ambient:active && animate,isKeyWindow:view.window?.isKeyWindow ?? true,backingScale:view.window?.backingScaleFactor ?? 2)
    }
    private func layoutTiles(){
        guard isViewLoaded else{return};let count=max(1,store.conversations.count),tileWidth:CGFloat=max(130,queueSize*2.2),rowHeight:CGFloat=max(190,queueSize*3.8)
        board.frame=CGRect(x:0,y:0,width:max(scroll.contentSize.width,max(CGFloat(count)*tileWidth,13*82)),height:rowHeight*3+180)
        for (i,tile) in tiles.enumerated(){let identity=i>=count*3,j=i-count*3;tile.frame=identity ? CGRect(x:CGFloat(j)*82,y:rowHeight*3,width:82,height:165):CGRect(x:CGFloat(i%count)*tileWidth,y:CGFloat(i/count)*rowHeight,width:tileWidth,height:rowHeight);tile.needsLayout=true;tile.layoutSubtreeIfNeeded()}
        scroll.hasHorizontalScroller=true
    }
}
