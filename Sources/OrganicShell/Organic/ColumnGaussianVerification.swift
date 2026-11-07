import AppKit
import QuartzCore

/// Real AutoScene/NativeTranscript, three material choices, the same virtual scene clock. No window or App.
@MainActor enum M10ColumnGaussianVerification {
    static var checks=0,findings:[String]=[],summaries:[[String:Any]]=[],frames:[[String:Any]]=[]
    static let names=["off","accum","gauss"]
    static func check(_ ok:Bool,_ text:String) {checks+=1;if !ok {findings.append(text);print("FINDING: "+text)}}
    static func run(to path:String,size:CGSize)->Int32 {
        checks=0;findings=[];summaries=[];frames=[]
        let output=URL(fileURLWithPath:path);try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let scales=ProcessInfo.processInfo.environment["SELFTEST_SCALES"]?.split(separator:",").compactMap{Double($0)}.map{CGFloat($0)} ?? [1,2]
        for scale in scales {
            autoreleasepool {matte(scale:scale,output:output);cachedMatte(scale:scale);gaussianFixture(scale:scale,output:output)}
            for name in ["appear","disappear","full-appear","full-disappear","card-disappear","reverse"] {
                if let only=ProcessInfo.processInfo.environment["SELFTEST_ONLY"],!only.split(separator:",").contains(Substring(name)){continue}
                autoreleasepool {scene(name,scale:scale,size:size,output:output)}
            }
        }
        additiveGlyph(output:output)
        check(NSApp.windows.allSatisfy{!$0.isVisible},"no visible windows")
        let report:[String:Any]=["checks":checks,"findings":findings,"profile":M10ColumnVerification.profile.summary,"summaries":summaries,"frames":frames,"boundary":"CARenderer, Native cacheDisplay, virtual 60Hz Dell .27mm/pt; not live FPS or human judgment."]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:output.appendingPathComponent("report.json"))}
        print("M10.1 columns: \(checks) checks, \(findings.count) findings -> \(path)")
        return findings.isEmpty ? 0:1
    }
    static func matte(scale:CGFloat,output:URL) {
        let c=Conversation(id:"matte",title:"Native plates and glyphs")
        c.items=[.init(id:"user",turnID:"t",kind:.user,text:"A blue message plate stays unfiltered."),
                 .init(id:"answer",turnID:"t",kind:.assistant,text:"**Markdown** and `inline code`.\n\n```swift\nlet answer = 42\n```"),
                 .init(id:"error",turnID:"t",kind:.notice(.error),text:"A red error plate stays unfiltered.")]
        let native=NativeTranscript(conversation:c);native.frame=CGRect(x:0,y:0,width:600,height:500);native.appearance=NSAppearance(named:.darkAqua);native.prepareForSnapshot()
        defer {native.dispose()}
        native.setSelectedRange(NSRange(location:1,length:4),itemID:"answer")
        let selection=native.selectedRange(itemID:"answer"),offset=native.scrollOffset
        func texts(_ v:NSView)->[NSTextView] {(v as? NSTextView).map{[$0]} ?? v.subviews.flatMap{texts($0)}}
        let views=texts(native),attributes=views.map{NSAttributedString(attributedString:$0.attributedString())}
        let a=native.snapshot(scale:scale),began=CACurrentMediaTime(),b=M10ColumnMatte.plate(native,scale:scale),pair=M10ColumnMatte.split(a,plates:b)
        let elapsed=(CACurrentMediaTime()-began)*1000,restored=native.snapshot(scale:scale)
        check(M10ColumnMatte.rgba(a)==M10ColumnMatte.rgba(restored),"matte \(scale)x native restored pixel diff 0")
        check(native.scrollOffset==offset && native.selectedRange(itemID:"answer")==selection,"matte \(scale)x selection/scroll unchanged")
        check(zip(views,attributes).allSatisfy{$0.attributedString().isEqual(to:$1)},"matte \(scale)x attributed strings byte-for-byte attributes restored")
        let aa=M10ColumnMatte.rgba(a),bb=M10ColumnMatte.rgba(pair.plates),gg=M10ColumnMatte.rgba(pair.ink)
        var plate=0,ink=0,plateLeaks=0,maxError=0
        for i in stride(from:0,to:aa.count,by:4) {
            if aa[i...i+3].elementsEqual(bb[i...i+3]),bb[i+3]>0 {plate+=1;if gg[i+3]>0 {plateLeaks+=1}}
            if gg[i+3]>0 {ink+=1}
            for k in 0..<4 {let over=Int(gg[i+k])+Int((Double(bb[i+k])*(1-Double(gg[i+3])/255)).rounded());maxError=max(maxError,abs(over-Int(aa[i+k])))}
        }
        check(plate>2000 && ink>100,"matte \(scale)x real plates and glyphs are both present")
        check(plateLeaks==0,"matte \(scale)x identical container pixels never enter foreground")
        check(pair.exceptionalPixels==0,"matte \(scale)x no reverse-alpha fallback/container pixels")
        check(maxError<=1,"matte \(scale)x source-over recomposition error <=1/255; actual \(maxError)")
        let marker=CALayer();marker.frame=CGRect(x:0,y:0,width:8,height:8);marker.backgroundColor=NSColor.black.cgColor
        native.isHidden=true;native.layer?.isHidden=true;native.layer?.mask=marker
        let hiddenPlate=M10ColumnMatte.plate(native,scale:scale)
        check(M10ColumnMatte.rgba(b)==M10ColumnMatte.rgba(hiddenPlate),"matte \(scale)x hidden Native uses the SAME unmasked drawing, never an empty plate")
        check(native.isHidden && native.layer?.isHidden==true && native.layer?.mask === marker,"matte \(scale)x temporary capture admission restores view/layer visibility and exact mask object")
        native.isHidden=false;native.layer?.isHidden=false;native.layer?.mask=nil
        for (name,img) in [("native",a),("ink",pair.ink),("plates",pair.plates)] {Offscreen.write(img,output.appendingPathComponent("matte-\(name)@\(Int(scale))x.png"))}
        summaries.append(["case":"native-matte","scale":scale,"prepareMs":elapsed,"platePixels":plate,"glyphPixels":ink,"plateLeaks":plateLeaks,"exceptionalPixels":pair.exceptionalPixels,"maxRecomposeChannelError":maxError])
    }
    static func cachedMatte(scale:CGFloat) {
        let store=ConversationStore(),mock=MockReplay(store:store);mock.start(live:false)
        let c=store.conversations.first{$0.id=="A"}!
        let node=ColumnNode(c,store:store,identity:Look.identity[3],rect:CGRect(x:0,y:0,width:600,height:520),full:true,scale:scale,logicalBottom:480)
        defer{node.native.dispose()}
        node.ambient=false
        let original=node.snapshot(fullWidth:600,briefWidth:260)
        node.zoomStyle = .gauss;node.gaussianCaptureNeeded=true
        let upgraded=node.snapshot(fullWidth:600,briefWidth:260),captures=node.gaussianPlateCaptures
        check(original.withGoal === upgraded.withGoal && original.transcript === upgraded.transcript,"cached matte \(scale)x keeps BOTH original native image objects, no recapture")
        check(captures==1 && node.gaussianMatteFallbackPixels==0,"cached matte \(scale)x one background for original/hidden-goal images, no reverse-alpha pixels")
        let hit=node.snapshot(fullWidth:600,briefWidth:260)
        check(hit.withGoal === original.withGoal && node.gaussianPlateCaptures==captures,"cached matte \(scale)x second access does no drawing")
        let owner=NativeTranscriptSessions(store:store)
        defer{owner.dispose()}
        let shared=ColumnNode(c,store:store,identity:Look.identity[0],rect:CGRect(x:0,y:0,width:600,height:520),full:true,scale:scale,logicalBottom:480,transcriptSessions:owner)
        let source=NSView(frame:CGRect(x:0,y:0,width:600,height:520)),other=NSView(frame:source.frame)
        _=shared.mountNative(in:source,configuration:.init())
        _=shared.snapshot(fullWidth:600,briefWidth:260)
        let lease=owner.mount(c,in:other)!,before=shared.native.snapshot(scale:scale)
        shared.zoomStyle = .gauss;shared.gaussianCaptureNeeded=true
        _=shared.snapshot(fullWidth:600,briefWidth:260)
        check(!shared.ownsNative && lease.isCurrent && shared.native.superview === other && shared.gaussianPlateCaptures==0,"cached matte \(scale)x never borrows another host's Native drawing lease")
        check(M10ColumnMatte.rgba(before)==M10ColumnMatte.rgba(shared.native.snapshot(scale:scale)),"cached matte \(scale)x other host's viewport stays pixel-identical")
    }
    static func scene(_ name:String,scale:CGFloat,size:CGSize,output:URL) {
        let stores=(0..<4).map{_ in ConversationStore()},mocks=stores.map{MockReplay(store:$0)};mocks.forEach{$0.start(live:false)}
        let scenes=stores.enumerated().map{i,store -> AutoScene in
            let s=AutoScene(size:size,store:store,profile:M10ColumnVerification.profile,scale:scale)
            s.columnExposureEnabled=i==1 || i==2;s.columnZoomStyle=i>=2 ? .gauss:.accum;s.manualSettle=true;s.restOnSnapshot=true;s.ambient=false;return s
        }
        var clock=CACurrentMediaTime()+3600
        for s in scenes {s.now={clock};s.install();s.clock.invalidate()}
        defer{scenes.forEach{$0.disposeTranscriptPresentation()}}
        if name=="card-disappear" {scenes.forEach{$0.columns.forEach{$0.cardBand=52...714}}}
        let renders=scenes.map{OffscreenRenderer(size:size,host:$0.sceneView.layer!,scale:scale)}
        let initial=renders.map{$0.render(at:clock-0.001)}
        check(initial[0]==initial[1] && initial[0]==initial[2],"\(name)/\(scale)x initial all three pixel diff 0")
        let old=scenes[0].columns.last!.conversation.id
        for s in scenes {
            switch name {
            case "disappear","card-disappear":s.columns.last!.conversation.archived=true;s.store.changed(s.columns.last!.conversation)
            case "full-disappear":let c=s.columns.first{$0.conversation.id==s.current}!.conversation;c.archived=true;s.store.changed(c)
            case "full-appear":if let id=s.order.dropFirst(s.columns.count).first {s.enterFocused(id,reason:"m101-full")}
            default:if let id=s.order.dropFirst(s.columns.count).first {s.land(id,reason:"m101")}
            }
        }
        let began=clock
        let focus=scenes[2].columnTransitionNodes.first{c in !c.gaussianFields.isEmpty && (name.contains("disappear") ? c.presence.to<0.5:c.presence.to>0.5)}!
        let x=name.contains("disappear") ? focus.rect.x.from:focus.rect.x.to
        let w=min(480,CGFloat(name.contains("disappear") ? focus.rect.w.from:focus.rect.w.to))
        let full=max(focus.form.from,focus.form.to)>0.5
        let roi=CGRect(x:max(0,min(size.width-w,CGFloat(x))),y:full ? 140:420,width:w,height:300)
        var costs:[[String:Any]]=[]
        func audit(_ phase:String) {
            for i in 0..<3 {
                let budget=scenes[i].columnRenderBudget(),cols=scenes[i].columnTransitionNodes
                let row:[String:Any]=["case":name,"scale":scale,"variant":names[i],"phase":phase,"budget":budget.fields,"prepareMs":scenes[i].lastSwitch?["prepareMs"] ?? 0,"matteMs":cols.reduce(0){$0+$1.gaussianMatteMs},"plateCaptures":cols.reduce(0){$0+$1.gaussianPlateCaptures},"gaussian":cols.map{$0.gaussianFields},"missingMaterials":cols.reduce(0){$0+$1.gaussianMissingMaterials},"matteFallbackPixels":cols.reduce(0){$0+$1.gaussianMatteFallbackPixels},"omittedPlatePixels":cols.reduce(0){$0+$1.gaussianOmittedPlatePixels}]
                costs.append(row)
                check(budget.violations.isEmpty,"\(name)/\(scale)x \(names[i]) budget \(budget.violations)")
                if i==2 {
                    check(cols.allSatisfy{$0.bakedPresence.isEmpty},"\(name)/\(scale)x gauss has zero zoom exposure copies")
                    check(cols.allSatisfy{$0.gaussianMissingMaterials==0 && $0.gaussianMatteFallbackPixels==0},"\(name)/\(scale)x gauss has matte for every native material")
                    check(cols.contains{!$0.gaussianFields.isEmpty},"\(name)/\(scale)x actual Gaussian surface installed")
                    let filtered=cols.reduce(0.0){$0+($1.gaussianFields["filterPixels"] as? Double ?? 0)}
                    check(filtered>0 && filtered*4<=budget.limit,"\(name)/\(scale)x single-filter four-surface storage proxy within 60Hz budget")
                    check(cols.allSatisfy{($0.gaussianFields["contentViolations"] as? [String] ?? []).isEmpty},"\(name)/\(scale)x content-only tree: no containers/native/shadow/filter/vector/copies")
                    check(cols.allSatisfy{($0.gaussianFields["copies"] as? Int ?? 1)==1},"\(name)/\(scale)x at most one foreground sample per column")
                }
            }
        }
        audit("initial")
        var previous=[[UInt8]?](repeating:nil,count:3),changes=Array(repeating:[Double](),count:3),tiles=Array(repeating:[CGImage](),count:3),labels=Array(repeating:[String](),count:3),k=0,interrupted=false,firstExact=false
        let selected=[0,1,2,3,4,5,6,8,12,20,30,42]
        while k<160 {
            clock=began+Double(k)/60
            if name=="reverse",k==8,!interrupted {scenes.forEach{$0.land(old,reason:"m101-reverse")};interrupted=true;audit("reversed")}
            let batch=renders.map{$0.render(at:clock)}
            check(batch[0]==batch[3],"\(name)/\(scale)x frame \(k) M10_COLUMNS=0 cancels Gaussian pixel diff 0")
            if k==0 {firstExact=batch[0]==batch[1] && batch[0]==batch[2];check(firstExact,"\(name)/\(scale)x first all three pixel diff 0")}
            for i in 0..<3 {
                if let p=previous[i] {changes[i].append(renders[i].tileDiff(p,batch[i]).value)}
                previous[i]=batch[i]
                if selected.contains(k) {tiles[i].append(renders[i].image(batch[i]));labels[i].append("\(names[i]) · \(Int(Double(k)*1000/60)) ms")}
            }
            let g=scenes[2].columnTransitionNodes.filter{!$0.gaussianFields.isEmpty}.map{$0.gaussianFrame(at:clock)}
            frames.append(["case":name,"scale":scale,"frame":k,"time":clock-began,"gaussian":g,"changes":(0..<3).map{changes[$0].last ?? 0}])
            k+=1;if clock>scenes.map(\.transitionEnd).max()!+0.04 {break}
        }
        let last=previous.map{$0!}
        for i in 0..<3 {Offscreen.write(renders[i].image(last[i]),output.appendingPathComponent("\(name)-last-\(names[i])@\(Int(scale))x.png"))}
        check(last[0]==last[1] && last[0]==last[2],"\(name)/\(scale)x last all three pixel diff 0")
        clock=scenes.map(\.transitionEnd).max()!+0.05;scenes.forEach{$0.settle()}
        let rest=renders.map{$0.render(at:clock)};check(rest[0]==rest[1] && rest[0]==rest[2],"\(name)/\(scale)x rest all three pixel diff 0")
        for i in 0..<3 {
            check(M10ColumnVerification.spikes(changes[i])==0,"\(name)/\(scale)x \(names[i]) no isolated change spikes")
            check(renders[i].tileDiff(last[i],rest[i]).value<=SelfTest.popThreshold,"\(name)/\(scale)x \(names[i]) no final material handoff pop")
        }
        summaries.append(["case":name,"scale":scale,"frames":k,"costs":costs,"changes":changes,"spikes":changes.map{M10ColumnVerification.spikes($0)},"firstExact":firstExact,"lastExact":last[0]==last[2],"restExact":rest[0]==rest[2]])
        M10ColumnVerification.contact(tiles.flatMap{$0},size:CGSize(width:320,height:205),columns:tiles[0].count,to:output.appendingPathComponent("\(name)@\(Int(scale))x.png"),labels:labels.flatMap{$0})
        let details=tiles.flatMap{$0}.compactMap{$0.cropping(to:CGRect(x:roi.minX*scale,y:roi.minY*scale,width:roi.width*scale,height:roi.height*scale))}
        M10ColumnVerification.contact(details,size:roi.size,columns:tiles[0].count,to:output.appendingPathComponent("\(name)-detail@\(Int(scale))x.png"),labels:labels.flatMap{$0})
        print("M10.1 \(name) \(scale)x: \(k) frames; prepare \(costs.map{$0["prepareMs"] ?? 0})")
    }
    static func gaussianFixture(scale:CGFloat,output:URL) {
        let size=CGSize(width:256,height:128),host=CALayer(),clock=SceneClock(),start=CACurrentMediaTime()+3600
        let text=TextBlock.singleLine("Gaussian · 内容",style:TextStyle(font:.systemFont(ofSize:24),color:.white,lineHeight:32),scale:scale)!
        let asset=M10ColumnGaussianAsset(size:size)
        asset.append([.init(image:text.image,rect:CGRect(origin:CGPoint(x:16,y:40),size:text.size))],to:asset.ink,scale:scale)
        let surface=M10ColumnGaussianSurface(size:size,pivot:CGPoint(x:128,y:64),clock:clock,visible:false,scale:scale)
        host.backgroundColor=Look.canvas.cgColor;host.addSublayer(surface.root)
        let render=OffscreenRenderer(size:size,host:host,scale:scale)
        surface.install(asset,visible:true,at:start)
        var previous: [UInt8]?,changes:[Double]=[],shots:[CGImage]=[],labels:[String]=[]
        for k in 0...6 {
            let t=start+Double(k)/60,bytes=render.render(at:t),pose=surface.effect.pose(at:t)
            if let previous {changes.append(render.tileDiff(previous,bytes).value)};previous=bytes
            check(pose.opacity>=0 && pose.opacity<=1 && pose.radius>=0,"Gaussian kernel \(scale)x frame \(k) bounded channels")
            shots.append(render.image(bytes));labels.append("Gaussian · \(Int(Double(k)*1000/60)) ms")
        }
        check(surface.effect.filterAvailable,"Gaussian kernel \(scale)x actual CA filter available")
        check(surface.effect.pose(at:start+0.1) == .visible,"Gaussian kernel \(scale)x sharp 100ms plateau")
        let filteredSharp=render.render(at:start+0.11)
        _=surface.effect.settle(at:start+0.11)
        check(filteredSharp==render.render(at:start+0.11),"Gaussian kernel \(scale)x filter removal pixel diff 0")
        // New entry; reverse halfway through the actual foreground, at the SAME timestamp, not a new endpoint.
        surface.effect.setVisible(false,at:start+1,animated:false)
        surface.install(asset,visible:true,at:start+2)
        let a=render.render(at:start+2.05),pose=surface.effect.pose(at:start+2.05)
        surface.install(asset,visible:false,at:start+2.05)
        check(surface.effect.pose(at:start+2.05)==pose,"Gaussian reverse \(scale)x preserves radius/opacity/scale")
        check(a==render.render(at:start+2.05),"Gaussian reverse \(scale)x interrupted frame pixel diff 0")
        check(M10ColumnVerification.spikes(changes)==0,"Gaussian kernel \(scale)x no isolated brightness/sharpness spike")
        M10ColumnVerification.contact(shots,size:size,columns:7,to:output.appendingPathComponent("gaussian-detail@\(Int(scale))x.png"),labels:labels)
    }
    /// An additive crossfade inside an isolated transparent group preserves ONE antialiased glyph's coverage.
    /// This is not a background/container; the audit's compositingFilter heuristic cannot distinguish the two.
    static func additiveGlyph(output:URL) {
        let text=TextBlock.singleLine("Glyph edge",style:TextStyle(font:.systemFont(ofSize:18),color:.white,lineHeight:24),scale:2)!
        // The native endpoint and scaled sample carry complementary weights of the same image.
        let a=M10ColumnMatte.rgba(text.image)
        var normalLoss=0,additiveError=0
        for i in stride(from:0,to:a.count,by:4) where a[i+3]>0 && a[i+3]<255 {
            let alpha=Double(a[i+3])/255
            normalLoss=max(normalLoss,Int((255*(alpha-(alpha*0.5+alpha*0.5*(1-alpha*0.5)))).rounded()))
            additiveError=max(additiveError,abs(Int((Double(a[i+3])*0.5+Double(a[i+3])*0.5).rounded())-Int(a[i+3])))
        }
        check(additiveError==0 && normalLoss>0,"isolated plusL is a glyph coverage blend, not a container/filter violation")
        summaries.append(["case":"flight-plusL","additiveMaxCoverageError":additiveError,"sourceOverMaxCoverageLoss":normalLoss,"scope":"isolated sourceMaterial, two samples of the same premultiplied glyph; no background drawing"])
    }
}
