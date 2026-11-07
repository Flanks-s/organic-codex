import AppKit
import QuartzCore
import CoreText

extension ColumnNode {
    /// Everything the column shows for one revision and pair of widths, computed apart from its layers so a
    /// transition can be prepared ahead (spec §4 prewarm) and applied in one step when it commits.
    struct Snapshot {
        /// The native view's scroll and height are part of it: a capture is only good for the scroll it shows
        /// (a recording showed a stale capture at the top while the view had followed to the end).
        struct Key: Hashable { let revision: Int; let visual: Int; let full: CGFloat; let brief: CGFloat; let offset: CGFloat; let content: CGFloat; var contentTop: CGFloat = 156 }
        let key: Key
        let title: (image: CGImage, size: CGSize)?
        let area: CGRect
        let transcript: CGImage?, transcriptSize: CGSize, offsetY: CGFloat
        /// The native capture with the goal's words in place (tests show it at rest).
        let withGoal: CGImage?
        /// The goal's words, at their place in the transcript before scrolling.
        let goalText: (image: CGImage, frame: CGRect)?
        /// The brief's clip, card-local, and where its content's top-left sits in it.
        let briefFrame: CGRect, briefOrigin: CGPoint
        let briefLayout: BriefLayout
        /// Parts with flights (hidden while moving).
        let flownParts: Set<String>
        let lyricSize: CGFloat
        let pieces: [FlightPiece]
        var flightVisibility:NativeTranscript.FlightVisibility?=nil
        var continuationFlightVisibility:NativeTranscript.FlightVisibility?=nil
    }

    struct ModeBriefKey:Hashable {
        let revision:Int,appearance:Int,display:Int
        let width:CGFloat,column:CGFloat,scale:CGFloat
        let state:Bool,playful:Bool,room:CGFloat
    }
    func boundedSummary(columnWidth:CGFloat)->SummaryLog {
        let size=Look.lyric(columnWidth:columnWidth).font.pointSize, gap=(size*0.62).rounded()
        let limit=Int(((logicalBottom-Look.contentTop.brief+18)/(size+gap)).rounded(.up))+2
        return SummaryLog(conversation,playful:Look.playful,lineLimit:limit)
    }
    func modeBrief(_ log:SummaryLog,width:CGFloat,columnWidth:CGFloat)->BriefLayout {
        let key=ModeBriefKey(revision:0,appearance:NativeAppearance.revision,display:NativeDisplayOptions.shared.revision,width:width,column:columnWidth,scale:scale,state:island == nil,playful:Look.playful,room:logicalBottom-Look.contentTop.brief+18)
        if let cached=modeBriefs[key],cached.log==log {return cached.layout}
        modeBriefs=modeBriefs.filter{$0.key.revision==key.revision && $0.key.appearance==key.appearance && $0.key.display==key.display && $0.key.state==key.state && $0.key.playful==key.playful}
        if modeBriefs.count>=4 {modeBriefs.removeAll(keepingCapacity:true)}
        let value=BriefLayout(product:log,width:width,columnWidth:columnWidth,scale:scale,showsState:key.state,room:key.room)
        modeBriefs[key]=(log,value);return value
    }
    func resolveIdleRowConfiguration() {
        guard ownsNative,idleRowConfigurationDirty else{return}
        native.refresh(preservingOffset:true,allowHidden:true);idleRowConfigurationDirty=false
    }

    func snapshot(fullWidth: CGFloat, briefWidth: CGFloat, contentTop: CGFloat? = nil) -> Snapshot {
        // A new target capture must contain the real glyphs even while the old flight owns their display.
        // Hide the view while borrowing its unmasked visibility; restore the live owner before returning.
        let continued=hasContinuedTranscriptFlights ? native.flightVisibility():nil
        let hidden=native.isHidden,layerHidden=native.layer?.isHidden ?? false
        if continued != nil,let restored=transcriptHandoff.previousFlightVisibility {
            native.isHidden=true;native.layer?.isHidden=true;native.restoreFlightVisibility(restored)
        }
        defer {
            if let continued {
                native.restoreFlightVisibility(continued);native.isHidden=hidden;native.layer?.isHidden=layerHidden
            }
        }
        let work=M10ColumnWorkTrace.scope("column.snapshot",["id":conversation.id]);defer{work.end()}
        resolveIdleRowConfiguration()
        displayWidths=(fullWidth,briefWidth)
        let layout=M10ColumnWorkTrace.scope("column.snapshot.layout")
        layoutNative(fullWidth: fullWidth, contentTop: contentTop)
        layout.end()
        let resolve=M10ColumnWorkTrace.scope("column.snapshot.resolve")
        // Resolve deferred native content before keying: prepareForSnapshot can change height/scroll revision.
        if ownsNative, native.refreshDeferred || native.renderedRevision != conversation.revision {
            if hasSnapshotContent {native.prepareForSnapshot(holdingOffset:catchUpHoldsOffset)}
            else {native.refresh(preservingOffset:catchUpHoldsOffset,allowHidden:true)}
        }
        resolve.end()
        let key = Snapshot.Key(revision: conversation.revision, visual: native.captureRevision, full: fullWidth, brief: briefWidth,
                               offset: native.scrollOffset.y, content: native.contentHeight.rounded(), contentTop: contentTop ?? fullContentTop)
        if let s=snapshots[key] {
            if gaussianCaptureNeeded && ownsNative {
                let images=[s.withGoal,s.transcript].compactMap{$0}.filter{$0.width>1 && gaussianPairs[ObjectIdentifier($0)] == nil}
                if !images.isEmpty {
                    let began=CACurrentMediaTime(),plate=M10ColumnMatte.plate(native,scale:scale);gaussianPlateCaptures+=1
                    for image in images {rememberGaussian(image,plate:plate)}
                    gaussianMatteMs+=(CACurrentMediaTime()-began)*1000
                }
            }
            return s
        }
        snapshots = snapshots.filter { $0.key.revision == key.revision && $0.key.visual == key.visual }
        let s = makeSnapshot(key)
        snapshots[key] = s
        return s
    }

    /// The look changed (Settings ▸ Appearance): every capture shows the old fonts and colours; the next render makes new.
    func invalidateCaptures() { modeBriefs=[:];snapshots = [:]; applied = nil; bakedInkCache = [:] }
    func apply(_ s: Snapshot, holdScroll: Bool = false) {
        transcriptHandoff.preparedFlightVisibility=ColumnTranscriptHandoff.rangedGoals ? (s.continuationFlightVisibility ?? s.flightVisibility):s.flightVisibility
        fullContentTop = s.key.contentTop
        applied = s.key
        needsReanchor = holdScroll
        lyricSize = s.lyricSize
        pieces = s.pieces
        if let t = s.title {
            capsuleTitle.contents = t.image
            capsuleTitle.bounds = CGRect(origin: .zero, size: t.size)
            titleSize = t.size
            apply(header(width: card.bounds.width, form: form.to))
        }
        transcriptClip.frame = s.area
        shapeFade(transcriptClip.mask, s.area.size)
        if ownsNative { shapeFade(native.layer?.mask, s.area.size) }
        nativeArea = s.area
        // The view sits where its capture does (placing it before the first layout left it 138 pt too high).
        positionNative(CGPoint(x: card.position.x + s.area.minX, y: card.position.y + s.area.minY))
        motionBase = s.transcript; restWithGoal = s.withGoal
        transcript.contents = restOnSnapshot && isFull && !holdScroll ? s.withGoal : s.transcript
        transcript.frame = CGRect(origin: .zero, size: s.transcriptSize)
        brief.frame = s.briefFrame
        briefFade.frame = CGRect(origin: .zero, size: s.briefFrame.size)
        // Product: transparent to the header reserve less 18, opaque 16 pt lower (NativeBriefSurface.swift:115-124).
        briefFade.locations = [0, NSNumber(value: Double(16 / max(16, s.briefFrame.height)))]
        briefContent.frame = CGRect(origin: s.briefOrigin, size: CGSize(width: s.briefFrame.width, height: max(1, s.briefLayout.height)))
        applyBrief(s.briefLayout)
        flownParts = s.flownParts
    }

    /// One layer per brief part, reused by id; dots are DotsLayers sharing one phase.
    /// `lift`: how far the brief's content just moved up, for the lines to follow on the lyrics' spring. nil: placed at once.
    private func borrowedSnapshot(_ key: Snapshot.Key) -> Snapshot {
        let top = key.contentTop - 18
        let area = CGRect(x: 0, y: top, width: key.full, height: logicalBottom + 22 - top)
        let bw = max(60, key.brief - 40)
        let layout = modeBrief(boundedSummary(columnWidth:key.brief),width:bw,columnWidth:key.brief)
        let clipTop = Look.contentTop.brief - 18, briefTop = logicalBottom - 22 - layout.height
        let title = TextBlock(conversation.title, style: Look.headerTitle, width: 400, maxLines: 1).image(scale: scale)
        return Snapshot(key: key, title: title.map { ($0.image, $0.size) }, area: area, transcript: nil, transcriptSize: area.size,
                        offsetY: 0, withGoal: nil, goalText: nil,
                        briefFrame: CGRect(x: 20, y: clipTop, width: bw, height: max(1, sceneHeight - clipTop)),
                        briefOrigin: CGPoint(x: 0, y: briefTop - clipTop), briefLayout: layout,
                        flownParts: [], lyricSize: layout.lyricStyle.font.pointSize, pieces: [])
    }

    /// A mode endpoint needs its brief/text/geometry, never a bitmap of Normie's borrowed viewport.
    /// This deliberately does not call layoutNative, snapshot, prepareForSnapshot, or claim a lease.
    func prepareModeDisplay(fullWidth: CGFloat, briefWidth: CGFloat, contentTop: CGFloat? = nil) -> Snapshot {
        M10ColumnModeProbe.measure("OrganicModeColumnPrepare", detail: conversation.id) {
            borrowedSnapshot(.init(revision: conversation.revision, visual: NativeAppearance.revision,
                                   full: fullWidth, brief: briefWidth, offset: 0, content: 0, contentTop: contentTop ?? fullContentTop))
        }
    }

    var hasSnapshotContent: Bool {
        !conversation.items.isEmpty || !conversation.approvals.isEmpty || conversation.question != nil
            || conversation.userInput != nil || !conversation.changes.isEmpty
    }

    private func makeSnapshot(_ key: Snapshot.Key) -> Snapshot {
        gaussianCapturePlate=nil;defer{gaussianCapturePlate=nil}
        let work=M10ColumnWorkTrace.scope("column.makeSnapshot",["id":conversation.id]);defer{work.end()}
        // A hidden scene can still arrange its CA layers. It must never lay out/capture Normie's borrowed view.
        guard ownsNative else { return borrowedSnapshot(key) }
        // No rows/cards => no pixels to transport. Nil materials skip the transparent full-state reflow too.
        if !hasSnapshotContent {
            M10ColumnWorkTrace.count("column.emptySnapshot")
            return borrowedSnapshot(key)
        }
        let fullWidth = key.full, briefWidth = key.brief
        let title = TextBlock(conversation.title, style: Look.headerTitle, width: 400, maxLines: 1).image(scale: scale)

        // Full form: the native transcript at the full width, captured as it draws itself (spec §7). The moving
        // base is the viewport with the goal's words hidden; the words are cut from the view's own text layer.
        let top = key.contentTop - 18, bottom = logicalBottom + 22
        let area = CGRect(x: 0, y: top, width: fullWidth, height: bottom - top)
        // A hidden view, or a view whose layer is hidden, draws nothing into a capture (self-test, 2026-10-28).
        // Show both for the capture and restore them before this transaction commits, so nothing shows on screen.
        // The capture renders through the view's layer, mask included: take the fade off, since the capture's own
        // layer wears the same one (a zero-sized mask before the first layout emptied every capture).
        let wasHidden = native.isHidden, layerWasHidden = native.layer?.isHidden ?? false, mask = native.layer?.mask
        let visibility = native.flightVisibility()
        native.isHidden = false; native.layer?.isHidden = false; native.layer?.mask = nil
        defer {
            native.restoreFlightVisibility(visibility)
            native.isHidden = wasHidden; native.layer?.isHidden = layerWasHidden; native.layer?.mask = mask
        }
        // Brief form, from the summary (reference §D): built first, since its goal parts decide what flies.
        let log = boundedSummary(columnWidth:briefWidth)
        let bw = max(60, briefWidth - 40)
        let layout = modeBrief(log,width:bw,columnWidth:briefWidth)
        let style = layout.lyricStyle
        let goals = layout.parts.compactMap { part -> (part: BriefLayout.Part, itemID: String)? in
            if case .goal(let id) = part.anchor, part.block != nil { return (part, id) }
            return nil
        }
        // Only a row the viewport can reach flies, so one that cannot is not mounted and drawn just to be thrown away:
        // that cost grew with the conversation and was most of a cold switch's 650 ms (user 10-30).
        native.prepareForSnapshot()
        func visibleGoalText(_ id:String)->(image:CGImage,rect:CGRect)? {
            guard native.itemNearViewport(id),let text=native.textSnapshot(itemID:id,scale:scale),native.bounds.contains(text.rect) else {return nil}
            return text
        }
        let goalTexts = Dictionary(goals.map { ($0.itemID, visibleGoalText($0.itemID)) }, uniquingKeysWith: { a, _ in a })
        // Worked notes and the current activity fly from the transcript's own divider and row, when those are in view
        // (a flight needs both ends, reference §C); the rest of the brief reveals in place.
        var others: [(part: BriefLayout.Part, look: FlightPiece.Look, source: NativeFlightSource, native: (NativeFlightPart, String))] = []
        for part in layout.parts {
            let wanted: (FlightPiece.Look, NativeFlightPart, String)? = switch part.anchor {
            case .worked(let answer)?: (.worked, .workedDivider, answer)
            case .activity(let item)?: (.activity, .activityText, item)
            default: nil
            }
            guard let (look, nativePart, item) = wanted, part.image != nil, native.itemNearViewport(item),
                  let source = native.flightSource(nativePart, itemID: item, scale: scale), source.rect.intersects(native.bounds) else { continue }
            others.append((part, look, source, (nativePart, item)))
        }
        // Narrations fly from their answers' leads (reference §C): only the lead's glyphs leave the transcript; the rest
        // of the answer stays in the base (Sol's ranged setTextHidden).
        var segments: [(part: BriefLayout.Part, answer: String, range: NSRange, frames: [(range: NSRange, rect: CGRect)], text: (image: CGImage, rect: CGRect))] = []
        for part in layout.parts {
            guard case .segment? = part.anchor, let answer = part.answerID, let paraphrase = part.paraphrase, !paraphrase.lead.isEmpty,
                  native.itemNearViewport(answer),
                  let item = native.sourceItem(answer),
                  let range = Self.rawRange(of: paraphrase.lead, in: item.text),
                  let text = native.textSnapshot(itemID: answer, scale: scale) else { continue }
            let frames = native.glyphFrames(itemID: answer, range: range).filter { $0.rect.width > 0 && $0.rect.height > 0 }
            guard !frames.isEmpty, frames.contains(where: { $0.rect.intersects(native.bounds) }) else { continue }
            segments.append((part, answer, range, frames, text))
        }
        let withGoal = captureViewport()
        for g in goals where (goalTexts[g.itemID] ?? nil) != nil { native.setTextHidden(true, itemID: g.itemID) }
        for g in segments { native.setTextHidden(true, itemID: g.answer, range: g.range) }
        for o in others { native.setFlightSourceHidden(true, part: o.native.0, itemID: o.native.1) }
        // A goal with no text picture is out of the viewport's reach: hiding it changes no pixel, so one capture is both.
        let hiddenFlightVisibility=native.flightVisibility()
        let base = goals.allSatisfy({ (goalTexts[$0.itemID] ?? nil) == nil }) && segments.isEmpty && others.isEmpty ? withGoal : captureViewport()
        for g in goals { native.setTextHidden(false, itemID: g.itemID) }
        for g in segments { native.setTextHidden(false, itemID: g.answer, range: g.range) }
        for o in others { native.setFlightSourceHidden(false, part: o.native.0, itemID: o.native.1) }

        // The content sits low above the dock; taller than the room, it shows its end, as the product's brief scrolls.
        let clipTop = Look.contentTop.brief - 18
        // Bottom-aligned in the room either way: pushed down when it fits, its top under the fade when it does not.
        let briefTop = logicalBottom - 22 - layout.height

        // Flight ends: each user line cut into pieces that sit on one native line and one lyric line. The transcript
        // look is cut from the native text layer at pixel bounds, the lyric look from its line as drawn, so the
        // first and last frames match the rest exactly.
        var lines: [FlightPiece] = [], flown: Set<String> = []
        var carriedGoalRanges=Dictionary(goals.filter{(goalTexts[$0.itemID] ?? nil) != nil}.map{($0.itemID,IndexSet())},uniquingKeysWith:{$0.union($1)})
        let s = max(1, scale)
        for (part, itemID) in goals {
            guard let block = part.block, let goalText = goalTexts[itemID] ?? nil else { continue }
            let text = block.text as NSString
            // Pieces on one native line share their cut, so they tile it exactly (rounding each outward
            // overlapped neighbours by a pixel, which drew the seam twice).
            var raw: [(lk: Int, range: NSRange, rect: CGRect)] = []
            for (lk, ll) in block.lines.enumerated() {
                for (r, rect) in native.glyphFrames(itemID: itemID, range: ll.range)
                    where r.length > 0 && r.location + r.length <= text.length && !text.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    raw.append((lk, r, rect.offsetBy(dx: -goalText.rect.minX, dy: -goalText.rect.minY)))
                }
            }
            var cuts = raw.map { (x0: ($0.rect.minX * s).rounded(.down), x1: ($0.rect.maxX * s).rounded(.up)) }
            let order = raw.indices.sorted { (raw[$0].rect.minY, raw[$0].rect.minX) < (raw[$1].rect.minY, raw[$1].rect.minX) }
            for (a, b) in zip(order, order.dropFirst()) where abs(raw[a].rect.minY - raw[b].rect.minY) < 0.5 {
                let cut = ((raw[a].rect.maxX + raw[b].rect.minX) / 2 * s).rounded()
                cuts[a].x1 = cut; cuts[b].x0 = cut
            }
            for (k, piece) in raw.enumerated() {
                let y0 = (piece.rect.minY * s).rounded(.down), y1 = (piece.rect.maxY * s).rounded(.up)
                let px = CGRect(x: cuts[k].x0, y: y0, width: cuts[k].x1 - cuts[k].x0, height: y1 - y0)
                guard px.width >= 1, let source = goalText.image.cropping(to: px),
                      let destination = Self.briefPiece(part,line:piece.lk,from:piece.range.location,to:piece.range.location+piece.range.length,scale:scale)
                else { continue }
                let ll = block.lines[piece.lk]
                let sx = area.minX + goalText.rect.minX + px.minX / s, sy = area.minY + goalText.rect.minY + px.minY / s
                let dx = 20 + part.frame.minX + (ll.rect.minX*s).rounded()/s + destination.x, dy = briefTop + part.frame.minY + (ll.rect.minY*s).rounded()/s
                lines.append(FlightPiece(look: .goal, source: CGRect(x: sx, y: sy, width: px.width / s, height: px.height / s), sourceImage: source,
                                      destination: CGRect(x: dx, y: dy, width: destination.width, height: destination.height),
                                      destinationImage: destination.image, lyricLine: piece.lk, lyricLines: block.lines.count,
                                      destinationOpacity: part.current ? 1 : Look.olderLine))
                // glyphFrames returns raw item UTF-16, including its native markup/source mapping.
                // Record only a slice that survived both source and destination image construction.
                carriedGoalRanges[itemID,default:[]].insert(integersIn:piece.range.location..<NSMaxRange(piece.range))
                flown.insert(part.id)
            }
        }
        for o in others {
            guard var image = o.part.image else { continue }
            var frame = o.part.frame
            if o.look == .activity, BriefLayout.activityTextInset(o.part) > 0 {
                // The activity's text only: its dots stay with the part and reveal with the brief.
                let inset = BriefLayout.activityTextInset(o.part)
                guard let cut = image.cropping(to: CGRect(x: (inset * s).rounded(), y: 0, width: CGFloat(image.width) - (inset * s).rounded(), height: CGFloat(image.height))) else { continue }
                image = cut; frame.origin.x += inset; frame.size.width -= inset
            }
            let source = o.source.rect.offsetBy(dx: area.minX, dy: area.minY)
            lines.append(FlightPiece(look: o.look, source: source, sourceImage: o.source.image,
                                     destination: CGRect(x: 20 + frame.minX, y: briefTop + frame.minY, width: frame.width, height: frame.height),
                                     destinationImage: image, lyricLine: o.part.line, lyricLines: layout.lineCount,
                                     destinationOpacity: o.part.current ? 1 : Look.olderLine))
            flown.insert(o.part.id)
        }
        for g in segments {
            guard g.part.paraphrase != nil,
                  let source = Self.composed(g.frames, from: g.text, scale: s) else { continue }
            let rect = source.rect.offsetBy(dx: area.minX, dy: area.minY)
            var piece = FlightPiece(look: .segment, source: rect, sourceImage: source.image,
                                    destination: CGRect(x: 20 + g.part.frame.minX, y: briefTop + g.part.frame.minY, width: g.part.frame.width, height: g.part.frame.height),
                                    destinationImage: nil, lyricLine: g.part.line, lyricLines: layout.lineCount,
                                    destinationOpacity: g.part.current ? 1 : Look.olderLine)
            piece.groups = ColumnBriefTypography.groups(g.part,scale:scale)
            guard !piece.groups.isEmpty else { continue }
            lines.append(piece)
            flown.insert(g.part.id)
        }
        lines = Self.fadedAtClip(lines, clipTop: clipTop)
        let clip = CGRect(x: 20, y: clipTop, width: bw, height: max(1, sceneHeight - clipTop))
        return Snapshot(key: key, title: title.map { ($0.image, $0.size) }, area: area, transcript: base, transcriptSize: area.size,
                        offsetY: 0, withGoal: withGoal, goalText: nil, briefFrame: clip, briefOrigin: CGPoint(x: 0, y: briefTop - clipTop),
                        briefLayout: layout, flownParts: flown, lyricSize: style.font.pointSize, pieces: lines,flightVisibility:hiddenFlightVisibility,
                        continuationFlightVisibility:hiddenFlightVisibility.replacingGoalText(with:carriedGoalRanges,preserving:visibility))
    }
    /// Background preparation never lays out a different native viewport between display frames.
    /// Unmounted/offscreen source rows and cold geometry retain the ordinary synchronous transition fallback.
    func idleSnapshot(fullWidth:CGFloat,briefWidth:CGFloat,contentTop:CGFloat?=nil,idle:M11IdlePreparation) async throws ->Snapshot {
        let top=contentTop ?? fullContentTop
        let expected=CGSize(width:(fullWidth*scale).rounded()/scale,height:((logicalBottom+22-(top-18))*scale).rounded()/scale)
        let gridTolerance=0.5/max(1,native.window?.backingScaleFactor ?? 1)
        let sourceMatches=form.to>0.5 && abs(native.frame.width-expected.width)<=gridTolerance && abs(native.frame.height-expected.height)<=gridTolerance
        if !ownsNative && hasSnapshotContent {throw M11IdlePreparation.Stop.unsupportedSource("borrowed-native")}
        if ownsNative && hasSnapshotContent && (!sourceMatches && native.frame.size != expected || native.refreshDeferred || native.renderedRevision != conversation.revision || idleRowConfigurationDirty) {
            // Never change the native view currently being read. A hidden column can build the target width;
            // text value/layout preparation is already incremental in Native, one item per call.
            guard form.to<0.5 || native.isHidden else {throw M11IdlePreparation.Stop.unsupportedSource("visible-native-reflow")}
            // Only rows prepareModeRow will lay out count: a long conversation always has a large row somewhere in its history.
            guard native.modeRowLargestText<=Self.idleRowTextLimit else {throw M11IdlePreparation.Stop.unsupportedSource("large-native-row")}
            var row=0,ready=false
            while !ready {ready=try await idle.step("snapshot.rowLayout") {native.prepareModeRow(width:expected.width,cursor:&row)}}
            // Native's final refresh otherwise configures every mounted NSTextView in one operation.
            // Configure each hidden mounted row first; the final refresh hits the row's exact configuration key.
            func mounted(_ v:NSView)->[NativeTranscriptRow] {
                if let row=v as? NativeTranscriptRow {return [row]}
                return v.subviews.flatMap(mounted)
            }
            for mountedRow in mounted(native) {
                guard let index=native.sourceItemIndex(mountedRow.item.id) else {continue}
                let item=conversation.items[index]
                try await idle.step("snapshot.rowConfigure") {
                    idleRowConfigurationDirty=true
                    mountedRow.configure(item,sourceItem:item,index:index,items:conversation.items,width:expected.width,
                        expanded:native.isExpanded(itemID:item.id),codeStyle:native.codeStyle,fallbackTimestamp:mountedRow.firstSeen)
                }
            }
            try await idle.step("snapshot.hiddenLayout") {
                native.configurePresentation(allowHidden:true) {
                    layoutNative(fullWidth:fullWidth,contentTop:top)
                    native.refresh(preservingOffset:catchUpHoldsOffset,allowHidden:true) // coalesces with size/configuration refresh
                }
                idleRowConfigurationDirty=false
            }
        }
        let key=Snapshot.Key(revision:conversation.revision,visual:native.captureRevision,full:fullWidth,brief:briefWidth,offset:native.scrollOffset.y,content:native.contentHeight.rounded(),contentTop:top)
        let result:Snapshot
        if let cached=snapshots[key] {result=cached}
        else {result=try await makeIdleSnapshot(key,idle:idle)}
        try await idle.step("snapshot.publish") {
            snapshots=snapshots.filter{$0.key.revision==key.revision && $0.key.visual==key.visual}
            snapshots[key]=result;displayWidths=(fullWidth,briefWidth)
        }
        return result
    }
    func usePreparedNativeGeometry(_ s:Snapshot) {
        guard ownsNative else{return}
        resolveIdleRowConfiguration()
        layoutNative(fullWidth:s.key.full,contentTop:s.key.contentTop)
    }
    func idleFullMaterials(at time:Double,idle:M11IdlePreparation) async throws ->[ColumnFullMaterial] {
        if let fullReflow {return fullReflow.materials(at:time)}
        if (!restOnSnapshot || gaussianCaptureNeeded),followBeforeMotion==nil,let widths=displayWidths {
            restWithGoal=try await idleSnapshot(fullWidth:widths.full,briefWidth:widths.brief,idle:idle).withGoal
        }
        return restWithGoal.map{[ColumnFullMaterial(image:$0,size:nativeArea.size,opacity:1)]} ?? []
    }

    /// The text system's first use of the brief's fonts in a process took up to 12 ms on the main thread, inside a slice.
    private static let idleTextWarm=Task.detached(priority:.utility) {
        guard let c=CGContext(data:nil,width:64,height:32,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return}
        for weight in [NSFont.Weight.regular,.medium,.semibold] {
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:"Worked 工作…",attributes:[.font:NSFont.systemFont(ofSize:15,weight:weight)])),c)
        }
    }
    private func makeIdleSnapshot(_ key: Snapshot.Key, idle:M11IdlePreparation) async throws -> Snapshot {
        gaussianCapturePlate=nil;defer{gaussianCapturePlate=nil}
        let work=M10ColumnWorkTrace.scope("column.makeSnapshot",["id":conversation.id]);defer{work.end()}
        // A hidden scene can still arrange its CA layers. It must never lay out/capture Normie's borrowed view.
        guard ownsNative else { return borrowedSnapshot(key) }
        // No rows/cards => no pixels to transport. Nil materials skip the transparent full-state reflow too.
        if !hasSnapshotContent {
            M10ColumnWorkTrace.count("column.emptySnapshot")
            return borrowedSnapshot(key)
        }
        let fullWidth = key.full, briefWidth = key.brief
        // A slice runs up to the next step: without these the title and brief layout counted as plan.geometry, up to 12.9 ms.
        let title = try await idle.step("snapshot.title") { TextBlock(conversation.title, style: Look.headerTitle, width: 400, maxLines: 1).image(scale: scale) }

        // Full form: the native transcript at the full width, captured as it draws itself (spec §7). The moving
        // base is the viewport with the goal's words hidden; the words are cut from the view's own text layer.
        let top = key.contentTop - 18, bottom = logicalBottom + 22
        let area = CGRect(x: 0, y: top, width: fullWidth, height: bottom - top)
        // A hidden view, or a view whose layer is hidden, draws nothing into a capture (self-test, 2026-10-28).
        // Show both for the capture and restore them before this transaction commits, so nothing shows on screen.
        // The capture renders through the view's layer, mask included: take the fade off, since the capture's own
        // layer wears the same one (a zero-sized mask before the first layout emptied every capture).
        let originalFlightVisibility=native.flightVisibility()
        func admitted(_ body:()->Void) {
            let hidden=native.isHidden,layerHidden=native.layer?.isHidden,mask=native.layer?.mask
            let visibility=native.flightVisibility()
            CATransaction.begin();CATransaction.setDisableActions(true)
            native.isHidden=false;native.layer?.isHidden=false;native.layer?.mask=nil
            body()
            native.restoreFlightVisibility(visibility)
            native.isHidden=hidden;if let layerHidden {native.layer?.isHidden=layerHidden};native.layer?.mask=mask
            CATransaction.commit()
        }
        func row(_ id:String)->NativeTranscriptRow? {
            func find(_ view:NSView)->NativeTranscriptRow? {
                if let r=view as? NativeTranscriptRow,r.item.id==id {return r}
                return view.subviews.lazy.compactMap(find).first
            }
            return find(native)
        }
        // Mounted rows already have a settled layout. The public Native query also calls displayIfNeeded()
        // on the entire transcript, which would reintroduce an unbounded capture-like display operation here.
        func glyphFrames(_ id:String,range:NSRange)->[(range:NSRange,rect:CGRect)] {
            guard let row=row(id) else{return []}
        guard let manager = row.body.layoutManager, let container = row.body.textContainer,
              range.location != NSNotFound, range.location >= 0, range.length > 0 else { return [] }
        let sourceLength = (row.item.text as NSString).length
        guard range.location < sourceLength else { return [] }
        let end = range.location + min(range.length, sourceLength - range.location)
        let offsets = row.sourceOffsets
        guard let start = offsets.firstIndex(where: { $0 >= range.location && $0 < end }),
              let last = offsets.lastIndex(where: { $0 >= range.location && $0 < end }) else { return [] }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: start, length: last - start + 1), actualCharacterRange: nil)
        var output: [(range: NSRange, rect: CGRect)] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, lineGlyphs, _ in
            let cut = NSIntersectionRange(lineGlyphs, glyphs)
            guard cut.length > 0 else { return }
            let chars = manager.characterRange(forGlyphRange: cut, actualGlyphRange: nil)
            guard chars.location < offsets.count else { return }
            let sourceStart = max(range.location, offsets[chars.location])
            let sourceEnd = min(end, offsets[min(offsets.count - 1, NSMaxRange(chars) - 1)] + 1)
            guard sourceEnd > sourceStart else { return }
            var rect = manager.boundingRect(forGlyphRange: cut, in: container)
            rect.origin.y = line.minY; rect.size.height = line.height
            rect.origin.x += row.body.textContainerOrigin.x; rect.origin.y += row.body.textContainerOrigin.y
            output.append((NSRange(location: sourceStart, length: sourceEnd - sourceStart), self.native.convert(rect, from: row.body)))
        }
        return output
        }
        func text(_ id:String) async throws ->(image:CGImage,rect:CGRect)? {
            // As the synchronous path: a row the viewport cannot reach does not fly, so it needs no picture. In a long
            // conversation most of the brief's goals are such rows, and refusing them left every switch unprepared.
            guard native.itemNearViewport(id) else {return nil}
            guard let r=row(id) else {throw M11IdlePreparation.Stop.unsupportedSource("unmounted-source-row")}
            guard !r.body.isHidden else{return nil}
            try await idle.step("snapshot.textLayout") {
                if let container=r.body.textContainer {r.body.layoutManager?.ensureLayout(for:container)}
            }
            let rect=native.convert(r.body.bounds,from:r.body)
            return (try await idle.capture(r.body,scale:scale),rect)
        }
        // Brief form, from the summary (reference §D): built first, since its goal parts decide what flies.
        let bw = max(60, briefWidth - 40)
        let log = try await idle.step("snapshot.summary") { boundedSummary(columnWidth:briefWidth) }
        idle.finish()
        await Self.idleTextWarm.value
        let layout = try await idle.step("snapshot.briefLayout") { modeBrief(log,width:bw,columnWidth:briefWidth) }
        let style = layout.lyricStyle
        let goals = layout.parts.compactMap { part -> (part: BriefLayout.Part, itemID: String)? in
            if case .goal(let id) = part.anchor, part.block != nil { return (part, id) }
            return nil
        }
        var goalTexts:[String:(image:CGImage,rect:CGRect)?]=[:]
        for goal in goals {
            let source=try await text(goal.itemID)
            goalTexts[goal.itemID] = .some(source.flatMap{native.bounds.contains($0.rect) ? $0:nil})
        }
        // Worked notes and the current activity fly from the transcript's own divider and row, when those are in view
        // (a flight needs both ends, reference §C); the rest of the brief reveals in place.
        var others: [(part: BriefLayout.Part, look: FlightPiece.Look, source: NativeFlightSource, native: (NativeFlightPart, String))] = []
        for part in layout.parts {
            let wanted: (FlightPiece.Look, NativeFlightPart, String)? = switch part.anchor {
            case .worked(let answer)?: (.worked, .workedDivider, answer)
            case .activity(let item)?: (.activity, .activityText, item)
            default: nil
            }
            guard let (look,nativePart,item)=wanted,part.image != nil,native.itemNearViewport(item) else {continue}
            guard let r=row(item) else {throw M11IdlePreparation.Stop.unsupportedSource("unmounted-source-row")}
            guard let view=r.flightView(nativePart),!view.isHidden,view.bounds.width>0,view.bounds.height>0 else {continue}
            let rect=native.convert(view.bounds,from:view)
            guard rect.intersects(native.bounds) else {continue}
            let image=try await idle.capture(view,scale:scale)
            others.append((part,look,NativeFlightSource(rect:rect,image:image),(nativePart,item)))
        }
        // Narrations fly from their answers' leads (reference §C): only the lead's glyphs leave the transcript; the rest
        // of the answer stays in the base (Sol's ranged setTextHidden).
        var segments: [(part: BriefLayout.Part, answer: String, range: NSRange, frames: [(range: NSRange, rect: CGRect)], text: (image: CGImage, rect: CGRect))] = []
        for part in layout.parts {
            guard case .segment? = part.anchor, let answer = part.answerID, let paraphrase = part.paraphrase, !paraphrase.lead.isEmpty,
                  let item = native.sourceItem(answer),
                  let range = Self.rawRange(of: paraphrase.lead, in: item.text),
                  let text = try await text(answer) else { continue }
            let frames = try await idle.step("snapshot.glyphs") {glyphFrames(answer,range:range).filter{$0.rect.width>0 && $0.rect.height>0}}
            guard !frames.isEmpty, frames.contains(where: { $0.rect.intersects(native.bounds) }) else { continue }
            segments.append((part, answer, range, frames, text))
        }
        let withGoal=try await idle.capture(native,scale:scale,around:admitted)
        var hiddenFlightVisibility:NativeTranscript.FlightVisibility?
        func hiddenSources(_ body:()->Void) {
            admitted {
                for g in goals where (goalTexts[g.itemID] ?? nil) != nil {native.setTextHidden(true,itemID:g.itemID)}
                for g in segments {native.setTextHidden(true,itemID:g.answer,range:g.range)}
                for o in others {native.setFlightSourceHidden(true,part:o.native.0,itemID:o.native.1)}
                hiddenFlightVisibility=native.flightVisibility()
                body()
            }
        }
        let base = goals.allSatisfy({(goalTexts[$0.itemID] ?? nil) == nil}) && segments.isEmpty && others.isEmpty ? withGoal : try await idle.capture(native,scale:scale,around:hiddenSources)

        // The content sits low above the dock; taller than the room, it shows its end, as the product's brief scrolls.
        let clipTop = Look.contentTop.brief - 18
        // Bottom-aligned in the room either way: pushed down when it fits, its top under the fade when it does not.
        let briefTop = logicalBottom - 22 - layout.height

        // Flight ends: each user line cut into pieces that sit on one native line and one lyric line. The transcript
        // look is cut from the native text layer at pixel bounds, the lyric look from its line as drawn, so the
        // first and last frames match the rest exactly.
        var lines: [FlightPiece] = [], flown: Set<String> = []
        var carriedGoalRanges=Dictionary(goals.filter{(goalTexts[$0.itemID] ?? nil) != nil}.map{($0.itemID,IndexSet())},uniquingKeysWith:{$0.union($1)})
        let s = max(1, scale)
        for (part, itemID) in goals {
            try await idle.step("snapshot.flightBoundary") {}
            guard let block = part.block, let goalText = goalTexts[itemID] ?? nil else { continue }
            let text = block.text as NSString
            // Pieces on one native line share their cut, so they tile it exactly (rounding each outward
            // overlapped neighbours by a pixel, which drew the seam twice).
            var raw: [(lk: Int, range: NSRange, rect: CGRect)] = []
            for (lk, ll) in block.lines.enumerated() {
                let frames=try await idle.step("snapshot.glyphs") {glyphFrames(itemID,range:ll.range)}
                for (r, rect) in frames
                    where r.length > 0 && r.location + r.length <= text.length && !text.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    raw.append((lk, r, rect.offsetBy(dx: -goalText.rect.minX, dy: -goalText.rect.minY)))
                }
            }
            var cuts = raw.map { (x0: ($0.rect.minX * s).rounded(.down), x1: ($0.rect.maxX * s).rounded(.up)) }
            let order = raw.indices.sorted { (raw[$0].rect.minY, raw[$0].rect.minX) < (raw[$1].rect.minY, raw[$1].rect.minX) }
            for (a, b) in zip(order, order.dropFirst()) where abs(raw[a].rect.minY - raw[b].rect.minY) < 0.5 {
                let cut = ((raw[a].rect.maxX + raw[b].rect.minX) / 2 * s).rounded()
                cuts[a].x1 = cut; cuts[b].x0 = cut
            }
            for (k, piece) in raw.enumerated() {
                let y0 = (piece.rect.minY * s).rounded(.down), y1 = (piece.rect.maxY * s).rounded(.up)
                let px = CGRect(x: cuts[k].x0, y: y0, width: cuts[k].x1 - cuts[k].x0, height: y1 - y0)
                guard px.width >= 1, let source = goalText.image.cropping(to: px),
                      let destination = Self.briefPiece(part,line:piece.lk,from:piece.range.location,to:piece.range.location+piece.range.length,scale:scale)
                else { continue }
                let ll = block.lines[piece.lk]
                let sx = area.minX + goalText.rect.minX + px.minX / s, sy = area.minY + goalText.rect.minY + px.minY / s
                let dx = 20 + part.frame.minX + (ll.rect.minX*s).rounded()/s + destination.x, dy = briefTop + part.frame.minY + (ll.rect.minY*s).rounded()/s
                lines.append(FlightPiece(look: .goal, source: CGRect(x: sx, y: sy, width: px.width / s, height: px.height / s), sourceImage: source,
                                      destination: CGRect(x: dx, y: dy, width: destination.width, height: destination.height),
                                      destinationImage: destination.image, lyricLine: piece.lk, lyricLines: block.lines.count,
                                      destinationOpacity: part.current ? 1 : Look.olderLine))
                // glyphFrames returns raw item UTF-16, including its native markup/source mapping.
                // Record only a slice that survived both source and destination image construction.
                carriedGoalRanges[itemID,default:[]].insert(integersIn:piece.range.location..<NSMaxRange(piece.range))
                flown.insert(part.id)
            }
        }
        for o in others {
            guard var image = o.part.image else { continue }
            var frame = o.part.frame
            if o.look == .activity, BriefLayout.activityTextInset(o.part) > 0 {
                // The activity's text only: its dots stay with the part and reveal with the brief.
                let inset = BriefLayout.activityTextInset(o.part)
                guard let cut = image.cropping(to: CGRect(x: (inset * s).rounded(), y: 0, width: CGFloat(image.width) - (inset * s).rounded(), height: CGFloat(image.height))) else { continue }
                image = cut; frame.origin.x += inset; frame.size.width -= inset
            }
            let source = o.source.rect.offsetBy(dx: area.minX, dy: area.minY)
            lines.append(FlightPiece(look: o.look, source: source, sourceImage: o.source.image,
                                     destination: CGRect(x: 20 + frame.minX, y: briefTop + frame.minY, width: frame.width, height: frame.height),
                                     destinationImage: image, lyricLine: o.part.line, lyricLines: layout.lineCount,
                                     destinationOpacity: o.part.current ? 1 : Look.olderLine))
            flown.insert(o.part.id)
        }
        for g in segments {
            try await idle.step("snapshot.segmentBoundary") {}
            guard g.part.paraphrase != nil,
                  let source = Self.composed(g.frames, from: g.text, scale: s) else { continue }
            let rect = source.rect.offsetBy(dx: area.minX, dy: area.minY)
            var piece = FlightPiece(look: .segment, source: rect, sourceImage: source.image,
                                    destination: CGRect(x: 20 + g.part.frame.minX, y: briefTop + g.part.frame.minY, width: g.part.frame.width, height: g.part.frame.height),
                                    destinationImage: nil, lyricLine: g.part.line, lyricLines: layout.lineCount,
                                    destinationOpacity: g.part.current ? 1 : Look.olderLine)
            piece.groups = ColumnBriefTypography.groups(g.part,scale:scale)
            guard !piece.groups.isEmpty else { continue }
            lines.append(piece)
            flown.insert(g.part.id)
        }
        lines = Self.fadedAtClip(lines, clipTop: clipTop)
        let clip = CGRect(x: 20, y: clipTop, width: bw, height: max(1, sceneHeight - clipTop))
        return Snapshot(key: key, title: title.map { ($0.image, $0.size) }, area: area, transcript: base, transcriptSize: area.size,
                        offsetY: 0, withGoal: withGoal, goalText: nil, briefFrame: clip, briefOrigin: CGPoint(x: 0, y: briefTop - clipTop),
                        briefLayout: layout, flownParts: flown, lyricSize: style.font.pointSize, pieces: lines,flightVisibility:hiddenFlightVisibility,
                        continuationFlightVisibility:hiddenFlightVisibility?.replacingGoalText(with:carriedGoalRanges,preserving:originalFlightVisibility))
    }

    private func captureViewport()->CGImage {
        let work=M10ColumnWorkTrace.scope("column.viewport",["id":conversation.id,"width":native.bounds.width*scale,"height":native.bounds.height*scale]);defer{work.end()}
        let image=native.snapshot(scale:scale)
        if gaussianCaptureNeeded {
            let began=CACurrentMediaTime()
            if gaussianCapturePlate == nil {gaussianCapturePlate=M10ColumnMatte.plate(native,scale:scale);gaussianPlateCaptures+=1}
            rememberGaussian(image,plate:gaussianCapturePlate!)
            gaussianMatteMs+=(CACurrentMediaTime()-began)*1000
        }
        return image
    }

}
