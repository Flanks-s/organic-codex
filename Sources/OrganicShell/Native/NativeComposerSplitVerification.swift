#if M9_SPLIT_SELFTEST
import AppKit
import QuartzCore

/// Windowless product-contract checks, including the native Dock which App/SelfTest's scene-only renderer omits.
@main @MainActor enum NativeComposerSplitVerification {
    static var checks = 0, failures: [String] = [], rows: [[String: Any]] = []
    static func check(_ pass: Bool, _ label: String) {
        checks += 1
        if !pass { failures.append(label); print("FAIL: " + label) }
    }
    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a-b) <= 0.001 }
    static func rect(_ r: CGRect) -> [CGFloat] { [r.minX,r.minY,r.width,r.height] }
    static func main() throws {
        _ = NSApplication.shared
        OrbDisplayEnvironment.shared.setOverride(.init())
        NativeDisplayOptions.shared.setVerificationState(.init(increaseContrast: false, reduceTransparency: false))
        ModelCatalog.models = ModelCatalog.mockModels
        NativeAppearance.apply(.init())
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        #if !M9_SPLIT_BASELINE
        try OrbMountedVerification.run(out: out, check: check)
        try NativeComposerModelSizingVerification.run(out:out,check:check)
        #endif
        if ProcessInfo.processInfo.environment["M9_ORBS_ONLY"] != "1" {
            for scale: CGFloat in [1,2] { try run(scale: scale, out: out) }
        }
        check(NSApp.windows.allSatisfy{ !$0.isVisible }, "no visible window is opened")
        let report: [String:Any] = ["checks":checks,"failures":failures,"measurements":rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: out.appendingPathComponent("report.json"))
        print("Split Dock: \(checks) checks, \(failures.count) failures")
        exit(failures.isEmpty ? 0 : 1)
    }
    static func run(scale: CGFloat, out: URL) throws {
        let size = CGSize(width:1280,height:820), metrics = AutoLayout.Metrics.tuned(for:CGSize(width:1280,height:820))
        let all = Array(MockSeed.make(now: VerificationRaster.date).prefix(6)), a = all[0], b = all[1]
        let store = ConversationStore(conversations:all,projects:MockSeed.projects,devices:MockSeed.devices)
        let host = DockNode.Passage(frame:CGRect(origin:.zero,size:size));host.wantsLayer = true
        let dock = DockNode(view:host,scale:scale)
        // Keep the 240 Hz / same-frame boundary rounding independent of machine uptime.
        var now = VerificationRaster.epoch
        dock.motionTime = { now };dock.ambient = false;dock.still = true
        dock.motionProfile = DisplayProfile(name:"split-check",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0)
        var composers: [String:NativeComposer] = [:]
        dock.composerFor = { c in
            let composer = composers[c.id] ?? NativeComposer(frame:CGRect(x:0,y:0,width:400,height:48))
            _ = composer.bind(to:c,store:store);composer.verificationScale = scale
            composers[c.id] = composer;return composer
        }
        func layout(_ count: Int, members:Int = all.count) -> AutoLayout {
            let f = FocusLayout(size:size,segments:count,leftOrbs:0,rightOrbs:members-count,satellites:count>1,metrics:metrics)
            var result = AutoLayout();result.focused = true;result.bars = f.segments;result.columns = f.columns
            result.me = f.me;result.orbs = f.rightOrbs;return result
        }
        var current = layout(2)
#if !M9_SPLIT_BASELINE
        dock.focusTarget = b.id
#endif
        dock.install(current,metrics:metrics,order:all,full:Set([a.id,b.id]),store:store)
        now += 1;dock.hoverFrame(at:now);dock.sample(.infinity)
        for (i,c) in [a,b].enumerated() {
            let item = dock.items[c.id]!, composer = composers[c.id]!, f = current.bars[i], h = f.height
            composer.layoutSubtreeIfNeeded()
            let forbidden = [composer.accessButton,composer.stopButton,composer.dictationButton,composer.voiceButton].filter{ !$0.isHidden }.count
            let attach = composer.convert(composer.attachButton.frame,to:host), send = composer.convert(composer.sendButton.frame,to:host)
            let editor = composer.convert(composer.scrollView.frame,to:host)
            let expectedAttach = f.minX + (i == 0 ? h : 8) + 4
            let expectedSendRight = f.maxX - (i > 0 ? h : 10) - 4
            check(forbidden == 0,"\(scale)x segment \(i) has only attach/editor/model/send")
            check(item.grip.isHidden || item.grip.opacity == 0,"\(scale)x segment \(i) has no grip")
            check(near(attach.minX,expectedAttach),"\(scale)x segment \(i) leading spacer + HStack gap")
            check(near(send.maxX,expectedSendRight),"\(scale)x segment \(i) trailing spacer + HStack gap")
            check(near(editor.minX,attach.maxX+4),"\(scale)x segment \(i) editor follows attach by 4pt")
            var row:[String:Any] = ["scale":scale,"segment":i,"forbiddenControls":forbidden,"attachError":attach.minX-expectedAttach,
                                   "sendError":send.maxX-expectedSendRight,"editor":rect(editor)]
#if !M9_SPLIT_BASELINE
            check(near(item.chromeHost.alphaValue,i == 0 ? 0.62 : 1),"\(scale)x focused controls1 / unfocused0.62")
            check(item.emphasis.value(at:now) == (i == 0 ? 0 : 1),"\(scale)x selected segment alone has 8% accent")
            if i == 1 {
                check(item.identity != nil,"\(scale)x second segment identity exists")
                check(near(item.identityFrame.width,current.me.width) && near(item.identityFrame.midX,f.maxX-h/2),"\(scale)x identity diameter/centre matches product")
                check(item.identityOpacity.value(at:now) == 1,"\(scale)x identity stays opaque")
                check(dock.draggable(at:CGPoint(x:item.identityFrame.midX,y:item.identityFrame.midY)) == c.id,"\(scale)x identity hit target")
                row["identity"] = rect(item.identityFrame)
            } else { check(item.identity == nil,"\(scale)x first segment has me only") }
            row["controlsOpacity"] = item.chromeHost.alphaValue
#else
            row["controlsOpacity"] = 1;row["missingIdentity"] = i>0
#endif
            rows.append(row)
        }
        // Real AppKit captures, without a backdrop substitution being counted as pixel parity.
        try save(VerificationRaster.capture(host,scale:scale),out.appendingPathComponent("split-native-\(Int(scale))x.png"))
#if !M9_SPLIT_BASELINE
        try save(raster(dock,host:host,scale:scale,now:now),out.appendingPathComponent("split-flat-\(Int(scale))x.png"))
        // Focus changes and an interruption must start exactly at the already painted opacity.
        let left = dock.items[a.id]!, right = dock.items[b.id]!
        let old = left.chromeHost.alphaValue
        let focusBefore = raster(dock,host:host,scale:scale,now:now)
        dock.focusTarget = a.id;dock.sample(.infinity)
        check(tileDifference(focusBefore,raster(dock,host:host,scale:scale,now:now)) == 0,"\(scale)x focus native raster first frame is identical")
        check(near(left.chromeHost.alphaValue,old),"\(scale)x focus switch has no first-frame pop")
        now += 0.073;dock.sample(.infinity)
        let middle = left.chromeHost.alphaValue
        check(middle > 0.62 && middle < 1,"\(scale)x focus switch has intermediate opacity")
        let focusMiddle = raster(dock,host:host,scale:scale,now:now)
        dock.focusTarget = b.id;dock.sample(.infinity)
        check(tileDifference(focusMiddle,raster(dock,host:host,scale:scale,now:now)) == 0,"\(scale)x focus native raster reversal is identical")
        check(near(left.chromeHost.alphaValue,middle),"\(scale)x focus reversal is continuous")
        now += 0.25;dock.sample(.infinity)
        check(near(left.chromeHost.alphaValue,0.62) && near(right.chromeHost.alphaValue,1),"\(scale)x focus reversal reaches product endpoint")

        var transitionIndex = 0
        func transition(_ count: Int, order: [Conversation] = all) {
            transitionIndex += 1
            let next = layout(count,members:order.count), ids = order.map(\.id), full = Set(ids.prefix(count))
            let springs = dock.springs(to:next,order:ids,at:.infinity,spring:(0.4,0.82))
            let imageBefore = raster(dock,host:host,scale:scale,now:now)
            let sourceEditorState = editorState(dock,host:host)
            let before = order.compactMap{dock.items[$0.id]?.ownComposer}.flatMap { c in [c.convert(c.attachButton.frame,to:host),c.convert(c.sendButton.frame,to:host)] }
            dock.transition(to:next,order:ids,full:full,springs:springs,duration:0.7)
            dock.sample(0)
            let first = order.compactMap{dock.items[$0.id]?.ownComposer}.flatMap { c in [c.convert(c.attachButton.frame,to:host),c.convert(c.sendButton.frame,to:host)] }
            // Retained composers keep the current world geometry even though the endpoint layout changes immediately.
            check(zip(before,first).allSatisfy{near($0.minX,$1.minX)&&near($0.minY,$1.minY)},"\(scale)x \(current.bars.count)→\(count) native first-frame geometry")
            let imageFirst = raster(dock,host:host,scale:scale,now:now)
            try? save(imageBefore,out.appendingPathComponent("\(Int(scale))x-\(current.bars.count)to\(count)-start-before.png"))
            try? save(imageFirst,out.appendingPathComponent("\(Int(scale))x-\(current.bars.count)to\(count)-start-first.png"))
            let startPop = tileDifference(imageBefore,imageFirst)
            if startPop > 2 {
                let state:[String:Any] = ["before":sourceEditorState,"first":editorState(dock,host:host)]
                try? JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("\(Int(scale))x-\(current.bars.count)to\(count)-state.json"))
            }
            check(startPop < 2,"\(scale)x native raster has no start pop \(current.bars.count)→\(count), \(startPop)")
            let began = now
            var priorImage = imageFirst, pixelSteps:[Double] = [], sampleCosts:[Double] = []
            var previous: [String:CGFloat] = [:], maxOpacityStep:CGFloat = 0
            for k in 1...240 {
                now = began + Double(k)/240;dock.hoverFrame(at:now)
                let costBegan = CACurrentMediaTime();dock.sample(Double(k)/240)
                sampleCosts.append((CACurrentMediaTime()-costBegan)*1000)
                if k % 4 == 0 {
                    let nextImage = raster(dock,host:host,scale:scale,now:now)
                    pixelSteps.append(tileDifference(priorImage,nextImage));priorImage = nextImage
                    if ProcessInfo.processInfo.environment["SPLIT_DUMP"] == "1" {
                        try? save(nextImage,out.appendingPathComponent("\(Int(scale))x-transition\(transitionIndex)-\(current.bars.count)to\(count)-frame\(k).png"))
                    }
                }
                for c in order {
                    guard let item = dock.items[c.id] else { continue }
                    let value = item.chromeHost.alphaValue
                    if let p = previous[c.id] {maxOpacityStep = max(maxOpacityStep,abs(value-p))};previous[c.id] = value
                }
            }
            check(maxOpacityStep < 0.013,"\(scale)x opacity follows a finite continuous curve")
            let ends = dock.items.mapValues(\.identityFrame)
            dock.dropItems(keeping:Set(ids))
            dock.settleContent(full:full);dock.sample(.infinity)
            let handoffPop = tileDifference(priorImage,raster(dock,host:host,scale:scale,now:now))
            check(handoffPop < 2,"\(scale)x native raster has no handoff pop \(handoffPop)")
            var spikes = 0
            for k in 2..<max(2,pixelSteps.count-2) {
                let neighbours = [pixelSteps[k-2],pixelSteps[k-1],pixelSteps[k+1],pixelSteps[k+2]].sorted()
                if pixelSteps[k]>8 && pixelSteps[k] > 3*(neighbours[1]+neighbours[2])/2+2 {spikes += 1}
            }
            check(spikes == 0,"\(scale)x native raster has no step spike (\(spikes))")
            check(ends.allSatisfy{ id,frame in dock.items[id].map{abs($0.identityFrame.minX-frame.minX)<0.1} ?? true },"\(scale)x identity settle has no snap")
            rows.append(["scale":scale,"transition":"\(current.bars.count)→\(count)","maxOpacityStep240Hz":maxOpacityStep,"startPop":startPop,"handoffPop":handoffPop,"spikes60Hz":spikes,"pixelSteps60Hz":pixelSteps,"dockSampleP95Ms":sampleCosts.sorted()[Int(Double(sampleCosts.count)*0.95)]])
            current = next
        }
        let beforeDragBar = right.glass.frame
        let pointer = CGPoint(x:right.identityFrame.midX,y:right.identityFrame.midY)
        dock.hold(b.id,at:pointer,now:now,spring:(0.3,0.8));dock.heldFrame(at:now)
        check(right.role == .bar && right.glass.frame == beforeDragBar && !composers[b.id]!.isHidden,
              "\(scale)x dragging an identity leaves its segment/composer in place")
        now += 0.05;dock.moveHeld(to:CGPoint(x:pointer.x+60,y:pointer.y-30));dock.heldFrame(at:now)
        check(near(right.identityFrame.midX,pointer.x+60) && right.identityFrame.width <= max(metrics.orb,metrics.orbMagnified) && near(right.identityFrame.width,right.identityFrame.height),
              "\(scale)x identity drag carries the planet, not a bar-sized capsule")
        dock.release()
        dock.focusTargetProvider = { a.id }
        transition(1)
        check(dock.focusTarget == a.id,"\(scale)x semantic commit samples focus even without another onTarget callback")
        dock.focusTargetProvider = nil
        check(right.identityOpacity.to == 1,"\(scale)x ungrafted identity retains its planet as a focused side orb")
        transition(2);transition(3);transition(2)
        transition(2,order:[b,a]+Array(all.dropFirst(2)))
        check(dock.items[a.id]!.identityOpacity.value(at:now) == 1 && dock.items[b.id]!.identityOpacity.value(at:now) == 0,"\(scale)x identities follow indices after first-segment removal/reorder")
        dock.focusTarget = b.id;now += 0.25;dock.sample(.infinity)
        transition(2,order:[a]+Array(all.dropFirst(2)))
        check(dock.items[b.id] == nil && dock.items[a.id]!.identityOpacity.to == 0 && dock.items[all[2].id]!.identityOpacity.to == 1,
              "\(scale)x removing the first segment retires its node and moves identities to the new indices")
        check(dock.items[a.id]!.emphasis.to == 1,"\(scale)x stale removed focus falls back to first valid segment")
        // Retained editor enters Normie and returns; do not leave Split's hidden access/voice policy behind.
        let composer = composers[a.id]!, editorIdentity = ObjectIdentifier(composers[a.id]!.textView)
        composer.layoutMode = .growing;composer.targetWidth = nil;composer.frame = CGRect(x:0,y:0,width:768,height:120)
        composer.needsLayout = true;composer.layoutSubtreeIfNeeded()
        check(!composer.accessButton.isHidden,"\(scale)x Normie restores access")
        check(ObjectIdentifier(composer.textView) == editorIdentity,"\(scale)x retained editor survives mode/segment changes")
        // Hidden-only states: empty, running, voice, queued, attachments and recovery never add a fifth control.
        composer.targetWidth = 360;composer.frame = CGRect(x:0,y:0,width:360,height:48)
        for state in [NativeComposerState(),NativeComposerState(running:true),NativeComposerState(voice:"hello"),NativeComposerState(usesLiveCore:true,operationError:"offline")] {
            composer.state = state;composer.needsLayout = true;composer.layoutSubtreeIfNeeded()
            check([composer.accessButton,composer.stopButton,composer.voiceButton,composer.dictationButton,composer.historyRefreshButton].allSatisfy(\.isHidden),"\(scale)x segment keeps its control contract in \(state)")
        }
        check(dock.draggable(at:CGPoint(x:current.bars[0].midX,y:current.bars[0].minY)) == nil,"\(scale)x hidden grip has no stale hit target")
#endif
    }
#if !M9_SPLIT_BASELINE
    /// Actual native controls + selection paths on a flat glass proxy. WindowServer's glass backdrop is absent
    /// offscreen; this is used for discontinuity checks, never claimed as whole-window screenshot parity.
    static func raster(_ dock: DockNode, host: NSView, scale: CGFloat, now: Double) -> CGImage {
        let size = CGSize(width:1280,height:100)
        let ctx = CGContext(data:nil,width:Int(size.width*scale),height:Int(size.height*scale),bitsPerComponent:8,bytesPerRow:0,
                            space:VerificationRaster.colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x:scale,y:scale)
        ctx.setFillColor(NSColor(srgbRed:0.13,green:0.155,blue:0.15,alpha:1).cgColor);ctx.fill(CGRect(origin:.zero,size:size))
        ctx.translateBy(x:0,y:100);ctx.scaleBy(x:1,y:-1);ctx.translateBy(x:0,y:-720)
        func opacity(_ view: NSView) -> CGFloat {
            guard let layer = view.layer, let fade = layer.animation(forKey:"shell.fade") as? CABasicAnimation,
                  let from = fade.fromValue as? NSNumber, let to = fade.toValue as? NSNumber else { return view.alphaValue }
            let k = smoothstep(0,1,(layer.convertTime(now,from:nil)-fade.beginTime)/max(0.001,fade.duration))
            return from.doubleValue+(to.doubleValue-from.doubleValue)*k
        }
        func image(_ image: CGImage, at rect: CGRect, alpha: CGFloat) {
            ctx.saveGState();ctx.setAlpha(alpha);ctx.translateBy(x:rect.minX,y:rect.maxY);ctx.scaleBy(x:1,y:-1)
            ctx.draw(image,in:CGRect(origin:.zero,size:rect.size));ctx.restoreGState()
        }
        // Overlapping proxies must have a stable paint order across process hash seeds.
        let items = dock.items.values.sorted { $0.conversation.id < $1.conversation.id }
        func plate(_ r:CGRect,_ alpha:CGFloat) {
            ctx.saveGState();ctx.setAlpha(alpha)
            ctx.setFillColor(NSColor(srgbRed:0.22,green:0.245,blue:0.24,alpha:1).cgColor)
            ctx.addPath(CGPath(roundedRect:r,cornerWidth:min(r.width,r.height)/2,cornerHeight:min(r.width,r.height)/2,transform:nil));ctx.fillPath()
            ctx.restoreGState()
        }
        plate(dock.focusedGlassFrame,dock.focusedGlassOpacity)
        for item in items {plate(item.glass.frame,item.glass.alphaValue)}
        let dividers = dock.dividerLayers.sorted { a, b in
            let x = a.path?.boundingBox.minX ?? 0, y = b.path?.boundingBox.minX ?? 0
            return x == y ? a.opacity < b.opacity : x < y
        }
        for divider in dividers {
            if let path = divider.path,let color = divider.strokeColor {
                ctx.saveGState();ctx.setAlpha(CGFloat(divider.opacity));ctx.setStrokeColor(color)
                ctx.setLineWidth(divider.lineWidth);ctx.addPath(path);ctx.strokePath();ctx.restoreGState()
            }
        }
        for item in items {
            ctx.saveGState();ctx.setAlpha(CGFloat(item.selection.opacity)*item.chromeHost.alphaValue)
            ctx.translateBy(x:item.chromeHost.frame.minX,y:item.chromeHost.frame.minY)
            if let path = item.selection.path, let color = item.selection.fillColor {ctx.addPath(path);ctx.setFillColor(color);ctx.fillPath()}
            ctx.restoreGState()
            if let c = item.ownComposer, !c.isHidden {
                let alpha = opacity(c)*opacity(item.barFace)*item.chromeHost.alphaValue
                ctx.saveGState();ctx.clip(to:item.chromeHost.convert(item.chromeHost.bounds,to:host));ctx.clip(to:c.convert(c.bounds,to:host))
                let controls:[NSView] = [c.attachButton,c.accessButton,c.sendButton,c.stopButton,c.voiceButton,c.dictationButton,c.modelButton,c.scrollView,
                                         c.queueButton,c.historyRefreshButton,c.attachmentScrollView]
                for v in controls where !v.isHidden && v.alphaValue > 0 {
                    if v === c.scrollView {
                        // cacheDisplay(NSScrollView) mutates the unattached clip's backing-aligned scroll origin.
                        // Draw the live TextKit view in the fixed-density context instead of resizing a viewport bitmap.
                        let text = c.textView, frame = text.convert(text.bounds,to:host)
                        ctx.saveGState();ctx.clip(to:c.scrollView.convert(c.scrollView.bounds,to:host))
                        ctx.setAlpha(alpha*v.alphaValue);ctx.translateBy(x:frame.minX-text.bounds.minX,y:frame.minY-text.bounds.minY)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(cgContext:ctx,flipped:true)
                        text.effectiveAppearance.performAsCurrentDrawingAppearance { text.draw(text.bounds) }
                        NSGraphicsContext.restoreGraphicsState();ctx.restoreGState()
                        continue
                    }
                    let texture = exactCapture(v,scale:scale)
                    var frame = v.convert(v.bounds,to:host)
                    frame.size = CGSize(width:CGFloat(texture.width)/scale,height:CGFloat(texture.height)/scale)
                    image(texture,at:frame,alpha:alpha*v.alphaValue)
                }
                ctx.restoreGState()
            }
            if let identity = item.identity, item.identityOpacity.value(at:now)>0 {
                ctx.saveGState();ctx.setAlpha(CGFloat(item.identityOpacity.value(at:now)))
                identity.renderOffscreenDecorations(in:ctx,planet:item.identityFrame);ctx.restoreGState()
            }
        }
        return ctx.makeImage()!
    }
    static func editorState(_ dock:DockNode,host:NSView)->[String:Any] {
        var result:[String:Any] = [:]
        for (id,item) in dock.items {
            guard let c = item.ownComposer else {continue}
            let t = c.textView,clip = c.scrollView.contentView
            result[id] = ["composer":rect(c.frame),"composerBounds":rect(c.bounds),"viewport":rect(c.scrollView.frame),
                          "viewportBounds":rect(c.scrollView.bounds),"clip":rect(clip.bounds),"clipFrame":rect(clip.frame),"textFrame":rect(t.frame),"textBounds":rect(t.bounds),
                          "textWorld":rect(t.convert(t.bounds,to:host)),"textOrigin":[t.textContainerOrigin.x,t.textContainerOrigin.y],
                          "container":[t.textContainer!.containerSize.width,t.textContainer!.containerSize.height],
                          "placeholder":t.placeholder,"alpha":t.alphaValue]
        }
        return result
    }
    static func exactCapture(_ view:NSView, scale:CGFloat) -> CGImage {
        // A fractional viewport clips glyphs instead of resampling a rounded viewport texture.
        VerificationRaster.capture(view, scale: scale, alignCanvas: true)
    }
    static func tileDifference(_ a:CGImage,_ b:CGImage) -> Double {
        func bytes(_ image:CGImage)->[UInt8] {
            let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                            space:VerificationRaster.colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))
        }
        let x=bytes(a),y=bytes(b),w=a.width,h=a.height
        var best=0.0
        for ty in stride(from:0,to:h,by:16) {for tx in stride(from:0,to:w,by:16) {
            var sum=0,n=0
            for py in ty..<min(ty+16,h) {for px in tx..<min(tx+16,w) {let p=(py*w+px)*4
                for c in 0..<3 {sum += abs(Int(x[p+c])-Int(y[p+c]));n += 1}
            }}
            best=max(best,Double(sum)/Double(n))
        }}
        return best
    }
#endif
    static func save(_ image:CGImage,_ path:URL) throws {
        try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:path)
    }
}
#endif
