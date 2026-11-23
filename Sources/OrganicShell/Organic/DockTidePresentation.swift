import AppKit
import QuartzCore

@MainActor private final class DockTideGlyphView:NSView {
    override var isFlipped:Bool {true}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
}

/// Side B's static 14 pt status mark. Only notification content phases animate it.
@MainActor private final class DockTideSideLeadView:NSView {
    override var isFlipped:Bool {true}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    private let shape=CAShapeLayer(),arc=CAShapeLayer(),label=CATextLayer()
    private var lastApprovalCount=0
    private(set) var symbol=""
    init() {
        super.init(frame:CGRect(x:0,y:0,width:14,height:14));wantsLayer=true;isHidden=true
        layer?.addSublayer(shape);layer?.addSublayer(arc);layer?.addSublayer(label)
        label.alignmentMode = .center;shape.lineCap = .round;shape.lineJoin = .round;arc.lineCap = .round
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
    func render(kind:ConversationNotice.Kind,count:Int,context:Double?,color:NSColor,scale:CGFloat) {
        shape.frame=bounds;arc.frame=bounds;arc.path=nil;shape.strokeColor=nil;shape.fillColor=nil
        label.string="";label.foregroundColor=NSColor.black.withAlphaComponent(0.85).cgColor
        let path=CGMutablePath()
        switch kind {
        case .approval,.question,.stoppedError,.retryingError:
            if count>0 {lastApprovalCount=count}
            symbol=kind == .approval ? (lastApprovalCount>0 ? (lastApprovalCount>99 ? "99+":String(lastApprovalCount)):"?") : kind == .question ? "?":"!"
            path.addEllipse(in:bounds);shape.fillColor=(kind == .stoppedError || kind == .retryingError ? NSColor.systemRed:NSColor.systemYellow).cgColor
            label.foregroundColor=(kind == .stoppedError || kind == .retryingError ? NSColor.white:NSColor.black.withAlphaComponent(0.85)).cgColor
            label.string=symbol
        case .done,.finish:
            symbol="✓";path.move(to:CGPoint(x:3,y:7.4));path.addLine(to:CGPoint(x:5.9,y:10.2));path.addLine(to:CGPoint(x:11,y:4.2))
            shape.strokeColor=NSColor(srgbRed:74/255,green:230/255,blue:115/255,alpha:1).cgColor;shape.lineWidth=1.8
        case .context:
            symbol="context";path.addEllipse(in:bounds.insetBy(dx:1.5,dy:1.5));shape.strokeColor=NSColor.white.withAlphaComponent(0.16).cgColor;shape.lineWidth=2
            if let context {
                let p=CGMutablePath();p.addArc(center:CGPoint(x:7,y:7),radius:5.5,startAngle:-.pi/2,endAngle:-.pi/2+min(1,max(0,context))*2 * .pi,clockwise:false)
                arc.path=p;arc.strokeColor=color.cgColor;arc.fillColor=nil;arc.lineWidth=2
            }
        case .compacted:
            symbol="↻";label.string=symbol;label.foregroundColor=NSColor.white.withAlphaComponent(0.75).cgColor
        default:
            symbol="•••";for x in [0.5,5.5,10.5] {path.addEllipse(in:CGRect(x:x,y:5.5,width:3,height:3))}
            shape.fillColor=NSColor.white.withAlphaComponent(0.75).cgColor
        }
        shape.path=path
        let font=NSFont.systemFont(ofSize:symbol.count>2 && symbol != "•••" ? 8:10,weight:.bold)
        label.font=font;label.fontSize=font.pointSize;label.contentsScale=max(1,scale)*2
        label.frame=CGRect(x:0,y:(14-font.ascender+font.descender)/2,width:14,height:font.ascender-font.descender)
    }
}

/// Measurement-only ablation of retained hidden filter surfaces, read once per process.
enum TideCompositePolicy {
    static let legacy=ProcessInfo.processInfo.environment["M11_TIDE_FILTERS"] == "legacy"
    static let control=ProcessInfo.processInfo.environment["M11_TIDE_CONTROL"] == "1"
}

/// Native hit target shared by the Dock passage and the retained notice contents.
@MainActor final class DockTideHitView:NSView {
    var onPress:(()->Void)?,onPointer:((NSEvent)->Void)?
    var orbID:String?
    var interactive=true
    private var press:NSPoint?
    private var dragged=false
    var hasPress:Bool {press != nil}
    func cancelPress() {press=nil;dragged=false}
    override var isFlipped:Bool {true}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func hitTest(_ point:NSPoint)->NSView? {
        guard interactive,let hit=super.hitTest(point) else{return nil}
        var node:NSView?=hit
        while let current=node,current !== self {
            if current is NSButton {return hit};node=current.superview
        }
        return self
    }
    private func routeOrbInput(_ event:NSEvent)->Bool {
        guard let orbID else{return false}
        var ancestor=superview
        while let view=ancestor {
            if let passage=view as? DockNode.Passage {return passage.routeTideOrbInput?(orbID,event) ?? false}
            ancestor=view.superview
        }
        return false
    }
    override func mouseDown(with event:NSEvent) {
        cancelPress()
        if OrbGesturePolicy.action(event) != .ordinary {
            _=routeOrbInput(event)
            return
        }
        press=event.locationInWindow;onPointer?(event)
    }
    override func rightMouseDown(with event:NSEvent) {
        cancelPress()
        if !routeOrbInput(event) {super.rightMouseDown(with:event)}
    }
    override func mouseDragged(with event:NSEvent) {
        guard press != nil else {_=routeOrbInput(event);return}
        if let press,hypot(press.x-event.locationInWindow.x,press.y-event.locationInWindow.y)>8 {dragged=true}
        onPointer?(event)
    }
    override func mouseUp(with event:NSEvent) {
        guard press != nil else {_=routeOrbInput(event);return}
        let invoke=press != nil && !dragged && interactive && !isHiddenOrHasHiddenAncestor
        cancelPress();onPointer?(event)
        if invoke {onPress?()}
    }
}

/// Ink and hit targets live above glass. No clock, filter or repeating animation is installed at rest.
@MainActor final class DockTidePresentation:NSObject {
    let view=DockTideHitView()
    private let liquid=CALayer(),liquidClip=CALayer()
    private let tideBand=CAShapeLayer()
    private let liquidMask=CAShapeLayer()
    private let lyricClip=DockTideHitView()
    private let labels=(0..<3).map{_ in NativeLabel(labelWithString:"")}
    private let title=NativeLabel(labelWithString:"")
    private let percentage=NativeLabel(labelWithString:"")
    private var percentageFilter:NSObject?
    private let subtitle=NativeLabel(labelWithString:"")
    private let actionHost=DockTideHitView(),detailHost=DockTideHitView()
    private let detailTitle=NativeLabel(labelWithString:""),detailSubtitle=NativeLabel(labelWithString:"")
    private let buttons=(0..<2).map{_ in NSButton(title:"",target:nil,action:nil)}
    private var filters:[NSObject?]=[nil,nil,nil,nil,nil]
    private let haloHost=NSView(),halo=CAGradientLayer()
    private let sideLead=DockTideSideLeadView()
    private let autoLead=DockTideGlyphView(),autoGlyph=CAShapeLayer()
    private var autoLeadFilter:NSObject?
    private var sideLeadFilter:NSObject?
    var sideCard=false {didSet {view.layer?.masksToBounds=sideCard}}
    var sideTwoRows=false
    var onAction:((ConversationNoticeAction)->Void)?
    var onPin:(()->Void)?
    var onPointer:((NSEvent)->Void)? {
        didSet {for target in [view,lyricClip,actionHost,detailHost] {target.onPointer=onPointer}}
    }
    private struct Sample:Equatable {
        var rect:CGRect,tail:CGRect?,title:String,lyric:String,previous:String
        var phases:[Double],progress:Double?,action:ConversationNotice?,halo:ConversationNotice?
        var glyph:OrbCelestialBody,kind:ConversationNotice.Kind,pendingCount:Int,twoRows:Bool,inside:Bool,hovering:Bool,pinned:Bool,enabled:Bool,rolling:Bool
    }
    private var sample:Sample?
    private var paintCount=0
    private var offered:[ConversationNotice.Button]=[]
    private(set) var probe:[String:Any]=[:]
    init(parent:NSView,below:NSView) {
        super.init()
        view.wantsLayer=true;view.layer?.masksToBounds=true;view.isHidden=true;haloHost.isHidden=true;view.onPress={ [weak self] in self?.onPin?() }
        actionHost.wantsLayer=true;actionHost.onPress={ [weak self] in self?.onPin?() }
        detailHost.wantsLayer=true;detailHost.onPress={ [weak self] in self?.onPin?() }
        lyricClip.wantsLayer=true;lyricClip.layer?.masksToBounds=true;lyricClip.onPress={ [weak self] in self?.onPin?() }
        haloHost.identifier = .init("tide.halo");haloHost.wantsLayer=true;haloHost.layer?.addSublayer(halo)
        halo.type = .radial;halo.startPoint=CGPoint(x:0.5,y:0.25);halo.endPoint=CGPoint(x:1,y:1);halo.locations=[0,1]
        parent.addSubview(haloHost,positioned:.below,relativeTo:below);parent.addSubview(view)
        Self.ink(sideLead.layer!,opacity:0,blur:0,scale:1,filter:&sideLeadFilter,prepare:true)
        liquidClip.addSublayer(tideBand);liquidClip.addSublayer(liquid);liquidClip.mask=liquidMask
        liquid.backgroundColor=NSColor(white:1,alpha:1).cgColor;view.layer?.addSublayer(liquidClip)
        view.addSubview(sideLead)
        autoLead.wantsLayer=true;autoLead.layer?.addSublayer(autoGlyph);view.addSubview(autoLead)
        autoGlyph.fillColor=nil;autoGlyph.strokeColor=NSColor.white.withAlphaComponent(0.8).cgColor
        autoGlyph.lineWidth=1.2;autoGlyph.lineCap = .round;autoGlyph.lineJoin = .round
        Self.ink(autoLead.layer!,opacity:0,blur:6,scale:1,filter:&autoLeadFilter,prepare:true)
        view.addSubview(lyricClip);view.addSubview(detailHost);view.addSubview(actionHost);view.addSubview(percentage)
        percentage.wantsLayer=true;percentage.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium)
        percentage.textColor=NSColor(white:1,alpha:0.55)
        Self.ink(percentage.layer!,opacity:0,blur:6,scale:1,filter:&percentageFilter,prepare:true)
        for label in labels+[title,subtitle,detailTitle,detailSubtitle] {
            label.wantsLayer=true;label.font = .systemFont(ofSize:12,weight:.semibold)
            label.textColor=NSColor(white:1,alpha:0.92);label.lineBreakMode = .byTruncatingTail
        }
        for label in labels {lyricClip.addSubview(label)}
        actionHost.addSubview(title);actionHost.addSubview(subtitle)
        detailHost.addSubview(detailTitle);detailHost.addSubview(detailSubtitle)
        detailSubtitle.font = .systemFont(ofSize:11,weight:.medium);detailSubtitle.textColor=NSColor(white:1,alpha:0.55)
        subtitle.font = .systemFont(ofSize:11,weight:.medium);subtitle.textColor=NSColor(white:1,alpha:0.55)
        for (index,button) in buttons.enumerated() {
            button.tag=index;button.target=self;button.action=#selector(pressed(_:));button.isBordered=false
            button.wantsLayer=true;button.layer?.cornerRadius=11;button.font = .systemFont(ofSize:12,weight:.semibold)
            button.contentTintColor = .white;button.layer?.backgroundColor=(index==1 ? NSColor(srgbRed:0.204,green:0.471,blue:0.965,alpha:1):NSColor(white:1,alpha:0.13)).cgColor
            actionHost.addSubview(button)
        }
        for i in 0..<3 {Self.ink(labels[i].layer!,opacity:0,blur:6,scale:1,filter:&filters[i],prepare:true)}
        Self.ink(actionHost.layer!,opacity:0,blur:6,scale:1,filter:&filters[3],prepare:true)
        Self.ink(detailHost.layer!,opacity:0,blur:6,scale:1,filter:&filters[4],prepare:true)
    }
    @objc private func pressed(_ button:NSButton) {
        guard button.isEnabled,offered.indices.contains(button.tag) else{return}
        onAction?(offered[button.tag].action)
    }
    func render(_ motion:TideMotion,rect:CGRect,tailBounds:CGRect?,title conversationTitle:String,color:NSColor = .white,glyph:OrbCelestialBody = .mars) {
        for target in [view,lyricClip,actionHost,detailHost] {target.orbID=motion.owner}
        let next=Sample(rect:rect,tail:tailBounds,title:conversationTitle,lyric:motion.lyric,previous:motion.previousLyric,
            phases:[motion.liquidWidth.x,motion.liquidOpacity.x,motion.ownerInk.opacity,motion.ink.opacity,motion.actionInk.opacity,motion.haloInk.opacity,motion.detailInk.opacity,motion.lyricOldY.x,motion.lyricCurrentY.x,motion.lyricNewY.x,motion.lyricCurrentAlpha.x,motion.lyricNewAlpha.x,motion.percentageInk.opacity],progress:motion.displayedProgress,
            action:motion.displayedAction,halo:motion.displayedHalo,glyph:glyph,kind:motion.lastKind,pendingCount:motion.pending.filter{$0.owner==motion.owner && $0.notice.kind == .approval}.count,twoRows:sideTwoRows,inside:motion.inside,hovering:motion.hovering,pinned:motion.pinned,
            enabled:motion.action?.submitting == false && motion.actionInk.target>0,rolling:motion.lyricAge<1.2)
        guard sample != next else{return}
        sample=next;paintCount+=1
        if view.frame != rect {view.frame=rect}
        view.layer?.cornerRadius=min(sideCard && sideTwoRows ? 22:rect.height/2,rect.width/2)
        let bandAlpha=0.3*(1-min(1,max(0,motion.liquidOpacity.x/0.24)))*motion.ink.opacity
        // The orb's existing water precedes the lyric entrance; only the text waits for contentInAt.
        let waterInk=motion.progress != nil && !motion.returning ? 1:motion.ink.opacity
        let liquidVisible=rect.width>32 && (bandAlpha+motion.liquidOpacity.x*waterInk)>0.001
        liquidClip.isHidden = !liquidVisible
        liquidClip.mask=motion.liquidOpacity.x*waterInk>0.001 ? liquidMask:nil
        liquidClip.frame=view.bounds
        liquidMask.path=CGPath(roundedRect:view.bounds,cornerWidth:min(sideCard && sideTwoRows ? 22:rect.height/2,rect.width/2),cornerHeight:min(sideCard && sideTwoRows ? 22:rect.height/2,rect.width/2),transform:nil)
        liquid.frame=CGRect(x:0,y:0,width:rect.width*max(0,min(1,motion.liquidWidth.x/100)),height:rect.height)
        liquid.opacity=Float(max(0,motion.liquidOpacity.x)*waterInk)
        tideBand.frame=view.bounds
        tideBand.path=Self.bandPath(size:rect.size,radius:min(sideCard && sideTwoRows ? 22:rect.height/2,rect.width/2))
        tideBand.opacity=Float(bandAlpha);tideBand.fillColor=color.cgColor
        if liquid.backgroundColor != color.cgColor {liquid.backgroundColor=color.cgColor}
        autoLead.isHidden=sideCard
        if !sideCard {
            autoLead.frame=CGRect(x:rect.height/2-7,y:rect.height/2-7,width:14,height:14)
            autoGlyph.frame=autoLead.bounds
            autoGlyph.strokeColor=color.withAlphaComponent(0.88).cgColor
            autoGlyph.path=OrbCelestialGlyph(symbol:glyph).path(in:autoLead.bounds.insetBy(dx:1,dy:1)).cgPath
            let leadAlpha=1-motion.ownerInk.opacity
            Self.ink(autoLead.layer!,opacity:leadAlpha,blur:(1-leadAlpha)*6,scale:0.97+0.03*leadAlpha,filter:&autoLeadFilter)
        }
        let pill=rect.width<=68,action=motion.displayedAction
        let percentageText=motion.displayedProgress.map {"\(Int(($0*100).rounded()))%"} ?? ""
        if percentage.stringValue != percentageText {percentage.stringValue=percentageText}
        let percentageWidth=(percentageText as NSString).size(withAttributes:[.font:percentage.font!]).width
        percentage.frame=CGRect(x:rect.width-10-percentageWidth,y:rect.height/2-7,width:percentageWidth,height:14)
        let percentageAlpha=motion.percentageInk.opacity*motion.ink.opacity*min(1,max(0,(rect.width-68)/32))*(1-motion.actionInk.opacity)*(1-motion.detailInk.opacity)
        Self.ink(percentage.layer!,opacity:percentageAlpha,blur:(1-motion.ink.opacity)*7,scale:0.97+0.03*motion.ink.opacity,filter:&percentageFilter)
        percentage.isHidden=percentageText.isEmpty || percentageAlpha<=0
        lyricClip.frame=sideCard ? CGRect(x:35,y:rect.height/2-9,width:max(0,rect.width-47),height:18)
            :CGRect(x:rect.height,y:rect.height/2-9,width:max(0,rect.width-rect.height-(pill ? 4:10)),height:18)
        if !percentageText.isEmpty {lyricClip.frame.size.width=max(0,lyricClip.frame.width-percentageWidth-6)}
        let rolling=motion.lyricAge<1.2 && !pill
        let pillWord:String
        switch motion.lastKind {
        case .command:pillWord="Run"
        case .step:pillWord="Step"
        case .spawn:pillWord="Agent"
        case .finish,.done:pillWord="Done"
        case .tests:pillWord="Tests"
        case .context:pillWord="Context"
        case .compacted:pillWord="Compacted"
        case .retryingError:pillWord="Retrying"
        case .stoppedError:pillWord="Failed"
        case .reply:pillWord="Replied"
        case .approval,.question:pillWord="Review"
        }
        let texts=pill ? ["","",percentageText.isEmpty ? pillWord:percentageText]:["",motion.previousLyric,motion.lyric]
        let ys=[motion.lyricOldY.x,motion.lyricCurrentY.x,rolling ? motion.lyricNewY.x:0]
        let alphas=[0.0,rolling ? motion.lyricCurrentAlpha.x:0,rolling ? motion.lyricNewAlpha.x:1]
        for i in 0..<3 {
            let font=NSFont.systemFont(ofSize:pill ? 11:12,weight:.semibold)
            if labels[i].font != font {labels[i].font=font}
            labels[i].textColor=[.retryingError,.stoppedError].contains(motion.lastKind) ? NSColor(srgbRed:1,green:0.48,blue:0.44,alpha:1):NSColor(white:1,alpha:0.92)
            if labels[i].stringValue != texts[i] {labels[i].stringValue=texts[i]}
            let frame=CGRect(x:0,y:ys[i],width:lyricClip.bounds.width,height:18)
            if labels[i].frame != frame {labels[i].frame=frame}
            let opacity=motion.ink.opacity*min(1,max(0,alphas[i]))*(action == nil ? 1-motion.actionInk.opacity:pill ? 1:0)*(1-motion.detailInk.opacity)
            Self.ink(labels[i].layer!,opacity:opacity,blur:(1-motion.ink.opacity)*7,scale:0.97+0.03*motion.ink.opacity,filter:&filters[i])
        }
        detailHost.frame=view.bounds
        if detailTitle.stringValue != conversationTitle {detailTitle.stringValue=conversationTitle}
        if detailSubtitle.stringValue != motion.lyric {detailSubtitle.stringValue=motion.lyric}
        detailTitle.frame=CGRect(x:rect.height,y:rect.height/2-16,width:max(0,rect.width-rect.height-10),height:18)
        detailSubtitle.frame=CGRect(x:rect.height,y:rect.height/2+2,width:max(0,rect.width-rect.height-10),height:13)
        Self.ink(detailHost.layer!,opacity:motion.ink.opacity*motion.detailInk.opacity,blur:(1-motion.detailInk.opacity)*7,scale:0.97+0.03*motion.detailInk.opacity,filter:&filters[4])
        detailHost.isHidden=pill || motion.detailInk.opacity==0
        actionHost.frame=view.bounds
        let narrow = !sideCard && (action?.buttons.count ?? 0)<2
        offered=action?.buttons ?? []
        var edge=rect.width-10,buttonRows:[[String:Any]]=[]
        for index in buttons.indices.reversed() {
            let button=buttons[index]
            guard offered.indices.contains(index) else {button.isHidden=true;continue}
            let offer=offered[index]
            let color=(offered.count==1 || index==1 ? NSColor(srgbRed:0.204,green:0.471,blue:0.965,alpha:1):NSColor(white:1,alpha:0.13)).cgColor
            if button.layer?.backgroundColor != color {button.layer?.backgroundColor=color}
            if button.title != offer.title {button.title=offer.title}
            let textWidth=(offer.title as NSString).size(withAttributes:[.font:button.font!]).width
            let width=max(36,min(100,textWidth+(narrow ? 18:24)))
            let frame=CGRect(x:edge-width,y:(rect.height-22)/2,width:width,height:22)
            if button.frame != frame {button.frame=frame};edge=frame.minX-5
            button.isHidden=false;button.isEnabled=motion.action?.submitting == false && motion.actionInk.target>0 && motion.actionInk.opacity>0.01 && rect.width>=150
            button.setAccessibilityLabel(offer.title)
            buttonRows.insert(["title":offer.title,"rect":[rect.minX+frame.minX,rect.minY+frame.minY,frame.width,frame.height],"enabled":button.isEnabled],at:0)
        }
        if sideCard,sideTwoRows {
            edge=rect.width-14
            for index in buttons.indices.reversed() where offered.indices.contains(index) {
                let button=buttons[index],w=button.frame.width
                button.frame=CGRect(x:edge-w,y:rect.height-36,width:w,height:22);edge-=w+5
                buttonRows[index]["rect"]=DockTideShape.rect(button.frame.offsetBy(dx:rect.minX,dy:rect.minY))
            }
        }
        let text=action?.text ?? "",width=max(0,edge-rect.height-5)
        title.textColor=action?.kind == .stoppedError ? NSColor(srgbRed:1,green:0.48,blue:0.44,alpha:1):NSColor(white:1,alpha:0.92)
        if title.stringValue != text {title.stringValue=text}
        if subtitle.stringValue != conversationTitle {subtitle.stringValue=conversationTitle}
        title.frame=CGRect(x:rect.height,y:rect.height/2-(narrow ? 9:16),width:width,height:18)
        subtitle.frame=CGRect(x:rect.height,y:rect.height/2+2,width:width,height:13);subtitle.isHidden=narrow
        if sideCard {
            sideLead.isHidden=false;sideLead.frame=CGRect(x:14,y:sideTwoRows ? 11:(rect.height-14)/2,width:14,height:14)
            sideLead.render(kind:motion.displayedAction?.kind ?? motion.lastKind,count:next.pendingCount,context:motion.event?.context,color:color,scale:view.window?.backingScaleFactor ?? 2)
            Self.ink(sideLead.layer!,opacity:motion.ink.opacity,blur:(1-motion.ink.opacity)*6,scale:0.97+0.03*motion.ink.opacity,filter:&sideLeadFilter)
            detailTitle.frame.origin.x=35;detailTitle.frame.size.width=max(0,rect.width-47)
            detailSubtitle.frame.origin.x=35;detailSubtitle.frame.size.width=max(0,rect.width-47)
            if sideTwoRows {
                subtitle.isHidden=false;subtitle.frame=CGRect(x:34,y:11.5,width:max(0,rect.width-48),height:13)
                title.frame=CGRect(x:14,y:29,width:max(0,rect.width-28),height:18)
            } else {
                title.frame.origin.x=35;title.frame.size.width=max(0,edge-40)
                subtitle.frame.origin.x=35;subtitle.frame.size.width=max(0,edge-40)
            }
        }
        let actionRoom=sideCard ? 1:min(1,max(0,(rect.width-68)/((action?.buttons.count==1 ? 192.0:300.0)-68)))
        let actionAlpha=motion.actionInk.opacity*actionRoom
        Self.ink(actionHost.layer!,opacity:actionAlpha,blur:(1-actionAlpha)*7,scale:0.97+0.03*actionAlpha,filter:&filters[3])
        actionHost.isHidden=actionAlpha==0
        view.isHidden=(rect.width<48 && motion.action == nil) || (motion.ink.opacity<=0 && (sideCard || motion.ownerInk.opacity>=1))
        let (scope,alpha,haloRect)=renderHalo(motion,rect:rect,tailBounds:tailBounds)
        probe=["title":text,"lyric":motion.lyric,"autoLeadRect":sideCard ? []:DockTideShape.rect(autoLead.frame.offsetBy(dx:rect.minX,dy:rect.minY)),"bandAlpha":Double(tideBand.opacity),"bandRect":DockTideShape.rect(tideBand.path?.boundingBoxOfPath ?? .zero),"liquidMaskAttached":liquidClip.mask != nil,"sideLead":sideCard ? sideLead.symbol:"","leadRect":sideCard ? DockTideShape.rect(sideLead.frame.offsetBy(dx:rect.minX,dy:rect.minY)):[],"titleRect":DockTideShape.rect(title.frame.offsetBy(dx:rect.minX,dy:rect.minY)),"subtitleRect":DockTideShape.rect(subtitle.frame.offsetBy(dx:rect.minX,dy:rect.minY)),"liquidProgress":motion.progress as Any? ?? NSNull(),"liquidWidth":motion.liquidWidth.x/100,"liquidAlpha":motion.liquidOpacity.x,"liquidDisplayedAlpha":Double(liquid.opacity),"liquidRect":DockTideShape.rect(liquid.frame),"buttons":buttonRows,"requestID":action?.requestID ?? "","submitting":action?.submitting ?? false,
            "percentage":percentageText,"percentageAlpha":percentageAlpha,"percentageRect":DockTideShape.rect(percentage.frame.offsetBy(dx:rect.minX,dy:rect.minY)),"actionAlpha":actionAlpha,"actionVisible":!actionHost.isHidden,"subtitleVisible":!subtitle.isHidden,"detailAlpha":motion.detailInk.opacity,"halo":scope.rawValue,"haloAlpha":alpha,"haloRect":DockTideShape.rect(haloRect),
            "pinned":motion.pinned,"inside":motion.inside,"hovering":motion.hovering,"contentUpdates":paintCount]
    }
    private struct HaloSample:Equatable {let rect:CGRect,scope:NoticeHalo,kind:ConversationNotice.Kind?,alpha:Double}
    private var haloSample:HaloSample?
    @discardableResult private func renderHalo(_ motion:TideMotion,rect:CGRect,tailBounds:CGRect?)->(NoticeHalo,Double,CGRect) {
        let scope=motion.displayedHalo?.halo ?? .none
        let bounds=tailBounds.map{rect.union($0)} ?? rect
        let spread=scope == .column ? 32.0:0
        let haloRect=CGRect(x:bounds.minX-spread,y:bounds.minY-8,width:bounds.width+spread*2,height:max(90,bounds.height+32))
        haloHost.frame=haloRect;halo.frame=haloHost.bounds
        let color:NSColor=motion.displayedHalo?.kind == .stoppedError ? NSColor(srgbRed:1,green:0.27,blue:0.23,alpha:1)
            : motion.displayedHalo?.kind == .context ? NSColor(srgbRed:1,green:0.62,blue:0.04,alpha:1)
            : motion.displayedHalo?.kind == .done ? NSColor(srgbRed:0.29,green:0.90,blue:0.45,alpha:1):.systemYellow
        let colors=[color.withAlphaComponent(0.17).cgColor,color.withAlphaComponent(0).cgColor]
        if halo.colors as? [CGColor] != colors {halo.colors=colors}
        let alpha=scope == .none || OrbDisplayEnvironment.shared.options.opaqueSurfaces ? 0:motion.haloInk.opacity
        if halo.opacity != Float(alpha) {halo.opacity=Float(alpha)}
        haloHost.isHidden=alpha==0
        haloSample=HaloSample(rect:haloRect,scope:scope,kind:motion.displayedHalo?.kind,alpha:alpha)
        return (scope,alpha,haloRect)
    }
    func renderHaloOnly(_ motion:TideMotion,rect:CGRect) {
        let scope=motion.displayedHalo?.halo ?? .none
        let spread=scope == .column ? 32.0:0
        let bounds=CGRect(x:rect.minX-spread,y:rect.minY-8,width:rect.width+2*spread,height:max(90,rect.height+32))
        let alpha=scope == .none || OrbDisplayEnvironment.shared.options.opaqueSurfaces ? 0:motion.haloInk.opacity
        let next=HaloSample(rect:bounds,scope:scope,kind:motion.displayedHalo?.kind,alpha:alpha)
        guard haloSample != next else{return}
        let (_,a,r)=renderHalo(motion,rect:rect,tailBounds:nil)
        if !view.isHidden {view.isHidden=true}
        probe=["halo":scope.rawValue,"haloAlpha":a,"haloRect":DockTideShape.rect(r),"haloOnly":true,"buttons":[] as [[String:Any]],"requestID":motion.event?.requestID ?? ""]
    }
    /// Draw the rounded capsule's bottom 12% directly. A static band needs no offscreen mask surface.
    private static func bandPath(size:CGSize,radius:CGFloat)->CGPath {
        let r=max(0.001,radius),depth=size.height*0.12,dy=max(-r,min(r,r-depth))
        let angle=asin(dy/r),dx=sqrt(max(0,r*r-dy*dy)),p=CGMutablePath()
        p.move(to:CGPoint(x:r-dx,y:size.height-depth))
        p.addLine(to:CGPoint(x:size.width-r+dx,y:size.height-depth))
        p.addArc(center:CGPoint(x:size.width-r,y:size.height-r),radius:r,startAngle:angle,endAngle:.pi/2,clockwise:false)
        p.addLine(to:CGPoint(x:r,y:size.height))
        p.addArc(center:CGPoint(x:r,y:size.height-r),radius:r,startAngle:.pi/2,endAngle:.pi-angle,clockwise:false)
        p.closeSubpath();return p
    }
    static func ink(_ layer:CALayer,opacity:Double,blur:Double,scale:Double,filter:inout NSObject?,prepare:Bool=false) {
        if layer.opacity != Float(opacity) {layer.opacity=Float(opacity)}
        let transform=CATransform3DMakeScale(scale,scale,1)
        if !CATransform3DEqualToTransform(layer.transform,transform) {layer.transform=transform}
        if filter == nil,(prepare || blur>0.001),let cls=NSClassFromString("CAFilter") as? NSObject.Type,
           let f=cls.perform(NSSelectorFromString("filterWithType:"),with:"gaussianBlur")?.takeUnretainedValue() as? NSObject {
            f.setValue("tideInk",forKey:"name");filter=f
        }
        // A retained filter object is cheap. An attached filter keeps a compositing surface alive.
        let attached=TideCompositePolicy.legacy || (opacity>0.001 && blur>0.001)
        if attached {
            if layer.filters?.isEmpty != false,let filter {layer.filters=[filter]}
            // Publish through the installed layer filter path. Mutating the retained CAFilter alone
            // does not invalidate its render-server copy, which otherwise jumps clear on detach.
            if filter?.value(forKey:"inputRadius") as? Double != blur || layer.value(forKeyPath:"filters.tideInk.inputRadius") as? Double != blur {
                layer.setValue(blur,forKeyPath:"filters.tideInk.inputRadius");filter?.setValue(blur,forKey:"inputRadius")
            }
            if filter?.value(forKey:"enabled") as? Bool != (blur>0.001) || layer.value(forKeyPath:"filters.tideInk.enabled") as? Bool != (blur>0.001) {
                layer.setValue(blur>0.001,forKeyPath:"filters.tideInk.enabled");filter?.setValue(blur>0.001,forKey:"enabled")
            }
        } else {
            if layer.filters?.isEmpty == false {layer.filters=nil}
            if filter?.value(forKey:"enabled") as? Bool != false {filter?.setValue(false,forKey:"enabled")}
        }
    }
    /// Keep AppKit controls and filter objects warm; hidden ink owns no compositing filters.
    func park() {
        liquid.opacity=0;tideBand.opacity=0;liquidClip.isHidden=true;liquidClip.mask=nil
        view.isHidden=true;haloHost.isHidden=true;halo.opacity=0
        for i in 0..<3 {Self.ink(labels[i].layer!,opacity:0,blur:0,scale:1,filter:&filters[i])}
        Self.ink(actionHost.layer!,opacity:0,blur:0,scale:1,filter:&filters[3])
        Self.ink(detailHost.layer!,opacity:0,blur:0,scale:1,filter:&filters[4])
        percentage.isHidden=true;Self.ink(percentage.layer!,opacity:0,blur:0,scale:1,filter:&percentageFilter)
        autoLead.isHidden=true;Self.ink(autoLead.layer!,opacity:0,blur:0,scale:1,filter:&autoLeadFilter)
        sideLead.isHidden=true;Self.ink(sideLead.layer!,opacity:0,blur:0,scale:1,filter:&sideLeadFilter)
        for target in [view,lyricClip,actionHost,detailHost] {target.interactive=true;target.cancelPress()}
        sample=nil;haloSample=nil;offered=[];probe=[:];paintCount=0
    }
    func fadeModeExit(_ fade:TideModeExit) {fade.include([view]);fade.include([haloHost],plane:.behindMaterial)}
    func freezeInput() {for target in [view,lyricClip,actionHost,detailHost] {target.interactive=false;target.cancelPress()}}
    func dispose() {view.removeFromSuperview();haloHost.removeFromSuperview()}
}
