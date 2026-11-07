import AppKit
import QuartzCore

extension AutoScene {

    var isMoving: Bool { now() < ends }
    var transitionEnd: Double { ends }

    /// A transition computed ahead of its commit: the next working set, springs, content snapshots, flights and every
    /// keyframe track, all keyed by conversation.
    struct Prepared {
        let members: [Conversation], current: String, scheme: Scheme
        let next: AutoLayout, order: [String]
        let rects: [String: RectSpring], forms: [String: Spring], presence: [String: Spring]
        let dock: [String: RectSpring]
        let changing: Set<String>, moving: Set<String>, entering: Set<String>, going: Set<String>
        let snapshots: [String: ColumnNode.Snapshot]
        let reflows: [String: ColumnFullReflow]
        let presenceInk: [String: [M10ColumnInkTile]]
        let gaussian:[String:M10ColumnGaussianAsset]
        let flights: [String: [FlightNode]]
        let tracks: [Track]
        let duration: Double, samples: Int, flightCount: Int, peak: CGFloat, smeared: Int
        /// Content revisions it was made from; a prewarmed switch is used only while they still hold.
        let revisions: [Int]
        let fromRest: Bool
        let columnMotion: [String:M10ColumnPlan]
        let presenceMappings: [String:ColumnNode.PresenceMapping]
        /// The slot index of the new full column, for receipts.
        var index: Int { order.firstIndex(of: current) ?? 0 }
    }

    func prepare(members nextMembers: [Conversation], current nextCurrent: String, scheme nextScheme: Scheme? = nil, at now: Double,
                         spring: (response: Double, damping: Double) = Tuning.shared.autoSpring) -> Prepared {
        let work=M10ColumnWorkTrace.scope("scene.prepare",["target":nextCurrent]);defer{work.end()}
        M10ColumnWorkTrace.count("scene.prepare.entry",["target":nextCurrent,"result":"miss","reason":"synchronous-fallback-or-explicit-fixture"])
        if ModeSignposts.enabled {ModeSignposts.Trace().record("OrganicPrepare",detail:"target=\(nextCurrent) miss synchronous-fallback-or-explicit-fixture")}

        // A window can have moved to another display since its last transition. Offscreen/injected profiles stay put.
        if let screen=sceneView.window?.screen { profile=DisplayProfile.of(screen) }
        let sch = nextScheme ?? scheme
        let contentTop=fullContentTop(for:sch)
        var mark = CACurrentMediaTime(), breakdown: [String: Double] = [:]
        func lap(_ name: String) { let t = CACurrentMediaTime(); breakdown[name, default: 0] += (t - mark) * 1000; mark = t }
        defer { prepareBreakdown = breakdown }
        let t = now - began
        let (next, nextOrder) = arrange(nextMembers, current: nextCurrent, scheme: sch)
        let shown = Array(nextOrder.prefix(next.columns.count))
        var rects: [String: RectSpring] = [:], forms: [String: Spring] = [:], presence: [String: Spring] = [:]
        var changing = Set<String>(), moving = Set<String>(), entering = Set<String>(), going = Set<String>()
        let reach = Double(max(size.width, size.height))
        let involved = columns + leaving.values + shown.filter { id in !columns.contains { $0.conversation.id == id } && leaving[id] == nil }
            .compactMap { id in nodes[id] ?? node(id, slot: shown.firstIndex(of: id)!, in: next) }
        admitUnmountedTranscripts(involved)
        // The springs on screen now, for what was drawn before this transition (the exposure looks one frame back).
        var previous: [String: (rect: RectSpring, form: Spring, presence: Spring)] = [:]
        for column in involved {
            let id = column.conversation.id, slot = shown.firstIndex(of: id)
            let onScreen = columns.contains { $0 === column } || leaving[id] != nil
            if !onScreen {
                // Entering: it starts where it lands in the form it lands in (a graft comes in full), invisible.
                column.rect = .rest(carrier(next.columns[slot!])); column.form = .rest(isFull(id, sch, current: nextCurrent) ? 1 : 0); column.presence = .rest(0)
                entering.insert(id)
            }
            if slot == nil { going.insert(id) }
            previous[id] = (column.rect, column.form, column.presence)
            let r = column.rect.sample(t), f = column.form.sample(t), p = column.presence.sample(t)
            if column.hasContinuedTranscriptFlights {
                // Retarget from the transport actually on screen, including an overshoot after handoff.
                for flight in flights[id] ?? [] {
                    flight.line.nativeScrollForm=f.value
                    if ColumnTranscriptHandoff.edgeClip {flight.line.nativeClip=column.continuedTranscriptClip(at:t)}
                }
            }
            if !column.hasContinuedTranscriptFlights {
                for flight in flights[id] ?? [] where flight.line.nativeClip != nil {flight.line.nativeClip=flight.continuedClip(at:t)}
            }
            let targetForm: Double = slot == nil ? column.form.to : (isFull(id, sch, current: nextCurrent) ? 1 : 0)
            if targetForm != column.form.to { changing.insert(id) }
            if changing.contains(id) || flights[id] != nil { moving.insert(id) }
            let targetRect = slot.map { carrier(next.columns[$0]) } ?? column.rect.target
            rects[id] = RectSpring(from: r.rect, to: targetRect, velocity: r.velocity, response: spring.response, damping: spring.damping)
            // Form drives flights across the whole column, so its rest step is scaled to that distance.
            forms[id] = Spring(from: f.value, to: targetForm, velocity: f.velocity, response: spring.response, damping: spring.damping,
                               epsilon: Spring.restEpsilon / reach)
            presence[id] = Spring(from: p.value, to: slot == nil ? 0 : 1, velocity: p.velocity, response: spring.response, damping: spring.damping,
                                  epsilon: Spring.restEpsilon / 200)
        }
        lap("springs")
        for column in involved {
            let id=column.conversation.id
            column.zoomStyle=columnZoomStyle;column.motionExposure=exposure
            column.motionExposure.enabled = exposure.enabled && columnExposureEnabled
            let showsTranscript=max(forms[id]!.from,forms[id]!.to)>0.4
            column.gaussianCaptureNeeded=column.gaussianEnabled && presence[id]!.duration>0 && showsTranscript
        }
        defer {for column in involved {column.gaussianCaptureNeeded=false}}
        // Content for both ends of each column that changes form, and the entering columns' brief (cached snapshots,
        // nothing applied yet).
        var snapshots: [String: ColumnNode.Snapshot] = [:]
        var reflows: [String: ColumnFullReflow] = [:]
        for column in involved {
            let id = column.conversation.id
            let fullSlot=shown.firstIndex(of:id),fullOldSlot=columns.firstIndex{$0===column} ?? fullSlot ?? 0
            let widthChanges=abs(rects[id]!.w.to-rects[id]!.w.from)>0.5/scale
            // Moved sideways at the same width too: the native view can't follow the card's keyframes, and it stood at the
            // target from the first frame, over the next column (header orb reorder, board 10-31).
            let moves=abs(rects[id]!.target.minX-column.rect.sample(t).rect.minX)>0.5/scale
            if column.form.to>0.5,forms[id]!.to>0.5,(widthChanges || moves || presence[id]!.duration>0) {
                // Full-state presence needs the same native/screenshot exchange as a form flight. It must not
                // leave the actual NSTextView opaque above a shrinking/fading card. On interrupted width reflow
                // retain the CURRENT mixture, rather than jumping to its target layout while leaving.
                let mixture=column.fullMaterials(at:t),hadReflow=column.hasFullReflow
                if column.hasContinuedTranscriptFlights { moving.remove(id) }
                let target=column.snapshot(fullWidth:fullSlot.map{fullWidth($0,next)} ?? column.rect.target.width,
                                           briefWidth:fullSlot.map{briefWidth($0,next)} ?? briefWidth(fullOldSlot,layout), contentTop:fullSlot == nil ? column.fullContentTop:contentTop)
                snapshots[id]=target
                let departure=(widthChanges || hadReflow) ? mixture:(target.withGoal.map{[ColumnFullMaterial(image:$0,size:target.transcriptSize,opacity:1)]} ?? mixture)
                reflows[id]=ColumnFullReflow(from:column.alignFullMaterials(departure,to:target.area.minY),to:target,width:rects[id]!.w,scale:scale)
                continue
            }
            guard changing.contains(id) || entering.contains(id), flights[id] == nil else { continue }
            let toFull = forms[id]!.to > 0.5
            if entering.contains(id),!toFull {
                let slot=shown.firstIndex(of:id) ?? 0
                snapshots[id]=column.prepareModeDisplay(fullWidth:fullWidth(slot,next),briefWidth:briefWidth(slot,next),contentTop:contentTop)
                continue
            }
            // The brief end is the column's brief slot: before, when it grows; after, when it shrinks or enters.
            let nextSlot = shown.firstIndex(of: id) ?? 0, oldSlot = columns.firstIndex { $0 === column } ?? nextSlot
            snapshots[id] = column.snapshot(fullWidth: toFull ? fullWidth(nextSlot, next) : fullWidth(oldSlot, layout),
                                            briefWidth: toFull ? briefWidth(oldSlot, layout) : briefWidth(nextSlot, next), contentTop:toFull ? contentTop:column.fullContentTop)
        }
        lap("snapshots")
        dock.ensureItems(for: nextMembers, layout: next, order: nextOrder)
        let dockSprings = dock.springs(to: next, order: nextOrder, at: t, spring: spring)
        let duration = max(involved.map { c in max(rects[c.conversation.id]!.duration, forms[c.conversation.id]!.duration, presence[c.conversation.id]!.duration) }.max() ?? 0,
                           dockSprings.values.map(\.duration).max() ?? 0)
        let timeline = Timeline(began: 0, duration: duration, rate: Timeline.rate(frameInterval: profile.frameInterval))
        let exposureTime = exposure.shutter * profile.frameInterval

        var tracks: [Track] = [], newFlights: [String: [FlightNode]] = [:]
        var peak: CGFloat = 0, smeared = 0, flightCount = 0
        for column in involved {
            let id = column.conversation.id
            // Constant channels produce no CA animation, but retain a zero-treatment row in the M10 frame audit.
            let sampledRects = timeline.map { rects[id]!.sample($0).rect }, sampledForms = timeline.map { forms[id]!.sample($0).value }
            column.motionProfile = profile; column.motionExposure = exposure
            column.motionExposure.enabled = column.motionExposure.enabled && columnExposureEnabled
            let columnEarlier = timeline.map { tau in tau >= exposureTime ? rects[id]!.sample(tau-exposureTime).rect : previous[id]!.rect.sample(t+tau-exposureTime).rect }
            tracks += column.tracks(timeline, rects: sampledRects, forms: sampledForms, earlierRects: columnEarlier)
            if let reflow = reflows[id] { tracks += column.fullReflowTracks(reflow, timeline: timeline, rects: sampledRects) }
            if presence[id]!.duration > 0 || entering.contains(id) {
                column.entering = presence[id]!.to > 0.5
                tracks += column.presenceTracks(timeline, values: timeline.map { presence[id]!.sample($0).value }, rects: sampledRects,
                    earlierValues: timeline.map { tau in tau >= exposureTime ? presence[id]!.sample(tau-exposureTime).value : previous[id]!.presence.sample(t+tau-exposureTime).value }, forms: sampledForms, earlierForms: timeline.map { tau in tau >= exposureTime ? forms[id]!.sample(tau-exposureTime).value : previous[id]!.form.sample(t+tau-exposureTime).value })
            }
            guard moving.contains(id) else { continue }
            // Flights: a reversing column keeps its plans, so its words retrace the same path.
            let lines = snapshots[id]?.pieces ?? column.pieces
            let lyricSize = snapshots[id]?.lyricSize ?? column.lyricSize
            let plans: [(ColumnNode.FlightPiece, FlightPlan)]
            if let current = flights[id] {
                plans = current.map { ($0.line, $0.plan) }
            } else {
                let towardBrief = forms[id]!.to < 0.5
                let centre = MorphFlightMath.centre(lines.map { towardBrief ? $0.source : $0.destination })
                plans = lines.enumerated().map { k, line in
                    // The look decides the anchor (goal trailing, narration leading, the rest centred); the stagger
                    // counts lyric lines from the bottom.
                    let look: MorphLook = switch line.look {
                    case .goal: .goal("", lyricSize: lyricSize, current: true)
                    case .worked: .worked("")
                    case .activity: .activity([], dots: false)
                    case .segment: .segment(BriefLine(words: [], lyricSize: lyricSize, current: true))
                    }
                    let element = MorphElement(id: "\(id)-\(k)", look: look, target: .fixture, line: line.lyricLines - 1 - line.lyricLine)
                    return (line, MorphFlightMath.makePlan(element: element, from: line.source, to: line.destination, towardBrief: towardBrief,
                                                           style: .tuned, span: rects[id]!.target.width, centre: centre, present: true))
                }
            }
            // One exposure back. Before this transition began that is where the column really was, on the springs it
            // is leaving: extrapolating the new springs backwards made a reversal's first exposure smear a path never
            // drawn, then drop to one copy (self-test spike, reverse at 80 ms).
            func earlier(_ exposure: Double) -> (rects: [CGRect], forms: [Double]) {
                (timeline.map { τ in τ - exposure >= 0 ? rects[id]!.sample(τ - exposure).rect : previous[id]!.rect.sample(t + τ - exposure).rect },
                 timeline.map { τ in τ - exposure >= 0 ? forms[id]!.sample(τ - exposure).value : previous[id]!.form.sample(t + τ - exposure).value })
            }
            let lineEarlier = earlier(exposureTime)
            // A narration is a paragraph, not a line: at a full shutter its smear read as a grey block, and collapsing
            // at a reversal's turnaround it changed most of the brief in one frame (self-test). Half the exposure for it
            // (decision 2026-10-29, to review with the user; the product's flights have no smear at all).
            var paragraph = exposure; paragraph.shutter *= 0.5
            let paragraphEarlier = earlier(exposureTime * 0.5)
            let nodes = plans.map { FlightNode(line: $0.0, plan: $0.1, bounds: scene.bounds, scale: scale) }
            for node in nodes {
                let segment = node.line.look == .segment
                let back = segment ? paragraphEarlier : lineEarlier
                tracks += node.tracks(timeline, rects: sampledRects, forms: sampledForms, earlierRects: back.rects, earlierForms: back.forms,
                                      lyricSize: lyricSize, profile: profile, exposure: segment ? paragraph : exposure)
                peak = max(peak, node.peakStep); smeared = max(smeared, node.smearedSamples)
            }
            flightCount += nodes.count
            newFlights[id] = nodes
        }
        lap("tracks")
        var gaussian:[String:M10ColumnGaussianAsset]=[:]
        for column in involved where column.gaussianEnabled && presence[column.conversation.id]!.duration>0 {
            let id=column.conversation.id
            gaussian[id]=column.prepareGaussian(snapshot:snapshots[id],reflow:reflows[id],timeline:timeline,forms:timeline.map{forms[id]!.sample($0).value},hideGoals:moving.contains(id),tracks:tracks)
        }
        var ink: [String: [M10ColumnInkTile]] = [:]
        for column in involved where !column.gaussianEnabled && column.m10Frames["zoom"]?.contains(where: { $0.sample.count > 1 }) == true {
            let id=column.conversation.id
            if let reflow=reflows[id],let snapshot=snapshots[id] {
                ink[id]=column.prepareReflowInk(reflow,snapshot:snapshot,tracks:tracks)
            } else if forms[id]!.duration>0 {
                ink[id]=[true,false].flatMap { full in
                    let bitmaps=column.preparePresenceInk(snapshot:snapshots[id],width:rects[id]!.target.width,form:full ? 1:0,hideGoals:moving.contains(id))
                    return column.prepareInkTiles(bitmaps,tracks:tracks,plane:full)
                }
            } else {
                let bitmaps=column.preparePresenceInk(snapshot:snapshots[id],width:rects[id]!.target.width,form:forms[id]!.to,hideGoals:moving.contains(id))
                ink[id]=column.prepareInkTiles(bitmaps,tracks:tracks)
            }
        }
        tracks += ink.values.flatMap { $0.flatMap(\.tracks) }
        tracks.removeAll { track in involved.contains { $0.isExposureTemplate(track.layer) } }
        lap("exposureInk")
        return Prepared(members: nextMembers, current: nextCurrent, scheme: sch, next: next, order: nextOrder, rects: rects, forms: forms, presence: presence,
                        dock: dockSprings, changing: changing, moving: moving, entering: entering, going: going,
                        snapshots: snapshots, reflows: reflows, presenceInk: ink, gaussian:gaussian, flights: newFlights, tracks: tracks, duration: duration, samples: timeline.times.count,
                        flightCount: flightCount, peak: peak, smeared: smeared, revisions: revisions, fromRest: !isMoving,
                        columnMotion:Dictionary(uniqueKeysWithValues:involved.map { ($0.conversation.id,M10ColumnPlan(times:timeline.times,materials:$0.m10Frames)) }),
                        presenceMappings:Dictionary(uniqueKeysWithValues:involved.map {($0.conversation.id,$0.presenceMapping)}))
    }

    func prepareInIdle(members nextMembers: [Conversation], current nextCurrent: String, scheme nextScheme: Scheme? = nil, at now: Double,
                         spring: (response: Double, damping: Double) = Tuning.shared.autoSpring, idle:M11IdlePreparation) async throws -> Prepared {
        let sch=nextScheme ?? scheme,contentTop=fullContentTop(for:nextScheme ?? scheme)
        try await idle.step("plan.geometry") {}
        let t = now - began
        let (next, nextOrder) = arrange(nextMembers, current: nextCurrent, scheme: sch)
        let shown = Array(nextOrder.prefix(next.columns.count))
        guard shown.allSatisfy({nodes[$0] != nil}) else {throw M11IdlePreparation.Stop.unsupportedSource("cold-column-node")}
        var rects: [String: RectSpring] = [:], forms: [String: Spring] = [:], presence: [String: Spring] = [:]
        var changing = Set<String>(), moving = Set<String>(), entering = Set<String>(), going = Set<String>()
        let reach = Double(max(size.width, size.height))
        let involved = columns + leaving.values + shown.filter { id in !columns.contains { $0.conversation.id == id } && leaving[id] == nil }
            .compactMap { id in nodes[id] }
        // The springs on screen now, for what was drawn before this transition (the exposure looks one frame back).
        var previous: [String: (rect: RectSpring, form: Spring, presence: Spring)] = [:]
        for column in involved {
            let id = column.conversation.id, slot = shown.firstIndex(of: id)
            let onScreen = columns.contains { $0 === column } || leaving[id] != nil
            if !onScreen {
                // Entering: it starts where it lands in the form it lands in (a graft comes in full), invisible.
                column.rect = .rest(carrier(next.columns[slot!])); column.form = .rest(isFull(id, sch, current: nextCurrent) ? 1 : 0); column.presence = .rest(0)
                entering.insert(id)
            }
            if slot == nil { going.insert(id) }
            previous[id] = (column.rect, column.form, column.presence)
            let r = column.rect.sample(t), f = column.form.sample(t), p = column.presence.sample(t)
            if !column.hasContinuedTranscriptFlights {
                for flight in flights[id] ?? [] where flight.line.nativeClip != nil {flight.line.nativeClip=flight.continuedClip(at:t)}
            }
            let targetForm: Double = slot == nil ? column.form.to : (isFull(id, sch, current: nextCurrent) ? 1 : 0)
            if targetForm != column.form.to { changing.insert(id) }
            if changing.contains(id) || flights[id] != nil { moving.insert(id) }
            let targetRect = slot.map { carrier(next.columns[$0]) } ?? column.rect.target
            rects[id] = RectSpring(from: r.rect, to: targetRect, velocity: r.velocity, response: spring.response, damping: spring.damping)
            // Form drives flights across the whole column, so its rest step is scaled to that distance.
            forms[id] = Spring(from: f.value, to: targetForm, velocity: f.velocity, response: spring.response, damping: spring.damping,
                               epsilon: Spring.restEpsilon / reach)
            presence[id] = Spring(from: p.value, to: slot == nil ? 0 : 1, velocity: p.velocity, response: spring.response, damping: spring.damping,
                                  epsilon: Spring.restEpsilon / 200)
        }

        for column in involved {
            let id=column.conversation.id
            column.zoomStyle=columnZoomStyle;column.motionExposure=exposure
            column.motionExposure.enabled = exposure.enabled && columnExposureEnabled
            column.gaussianCaptureNeeded=false
        }
        defer {for column in involved {column.gaussianCaptureNeeded=false}}
        try await idle.step("plan.snapshots") {}
        // Content for both ends of each column that changes form, and the entering columns' brief (cached snapshots,
        // nothing applied yet).
        var snapshots: [String: ColumnNode.Snapshot] = [:]
        var reflows: [String: ColumnFullReflow] = [:]
        for column in involved {
            let id = column.conversation.id
            let fullSlot=shown.firstIndex(of:id),fullOldSlot=columns.firstIndex{$0===column} ?? fullSlot ?? 0
            let widthChanges=abs(rects[id]!.w.to-rects[id]!.w.from)>0.5/scale
            // Moved sideways at the same width too: the native view can't follow the card's keyframes, and it stood at the
            // target from the first frame, over the next column (header orb reorder, board 10-31).
            let moves=abs(rects[id]!.target.minX-column.rect.sample(t).rect.minX)>0.5/scale
            if column.form.to>0.5,forms[id]!.to>0.5,(widthChanges || moves || presence[id]!.duration>0) {
                // Full-state presence needs the same native/screenshot exchange as a form flight. It must not
                // leave the actual NSTextView opaque above a shrinking/fading card. On interrupted width reflow
                // retain the CURRENT mixture, rather than jumping to its target layout while leaving.
                let mixture=try await column.idleFullMaterials(at:t,idle:idle),hadReflow=column.hasFullReflow
                let target=try await column.idleSnapshot(fullWidth:fullSlot.map{fullWidth($0,next)} ?? column.rect.target.width,
                                           briefWidth:fullSlot.map{briefWidth($0,next)} ?? briefWidth(fullOldSlot,layout), contentTop:fullSlot == nil ? column.fullContentTop:contentTop,idle:idle)
                snapshots[id]=target
                let departure=(widthChanges || hadReflow) ? mixture:(target.withGoal.map{[ColumnFullMaterial(image:$0,size:target.transcriptSize,opacity:1)]} ?? mixture)
                reflows[id]=ColumnFullReflow(from:column.alignFullMaterials(departure,to:target.area.minY),to:target,width:rects[id]!.w,scale:scale)
                continue
            }
            guard changing.contains(id) || entering.contains(id), flights[id] == nil else { continue }
            let toFull = forms[id]!.to > 0.5
            if entering.contains(id),!toFull {
                let slot=shown.firstIndex(of:id) ?? 0
                snapshots[id]=try await idle.step("snapshot.enteringBrief") {column.prepareModeDisplay(fullWidth:self.fullWidth(slot,next),briefWidth:self.briefWidth(slot,next),contentTop:contentTop)}
                continue
            }
            // The brief end is the column's brief slot: before, when it grows; after, when it shrinks or enters.
            let nextSlot = shown.firstIndex(of: id) ?? 0, oldSlot = columns.firstIndex { $0 === column } ?? nextSlot
            snapshots[id] = try await column.idleSnapshot(fullWidth: toFull ? fullWidth(nextSlot, next) : fullWidth(oldSlot, layout),
                                            briefWidth: toFull ? briefWidth(oldSlot, layout) : briefWidth(nextSlot, next), contentTop:toFull ? contentTop:column.fullContentTop,idle:idle)
        }
        try await idle.step("plan.dockBoundary") {}
        dock.ensureItems(for: nextMembers, layout: next, order: nextOrder)
        let dockSprings = dock.springs(to: next, order: nextOrder, at: t, spring: spring)
        let duration = max(involved.map { c in max(rects[c.conversation.id]!.duration, forms[c.conversation.id]!.duration, presence[c.conversation.id]!.duration) }.max() ?? 0,
                           dockSprings.values.map(\.duration).max() ?? 0)
        let timeline = Timeline(began: 0, duration: duration, rate: Timeline.rate(frameInterval: profile.frameInterval))
        let exposureTime = exposure.shutter * profile.frameInterval

        var motions:[String:M10ColumnPlan]=[:],mappings:[String:ColumnNode.PresenceMapping]=[:]
        var tracks: [Track] = [], newFlights: [String: [FlightNode]] = [:]
        var peak: CGFloat = 0, smeared = 0, flightCount = 0
        for column in involved {
            let id = column.conversation.id
            // Constant channels produce no CA animation, but retain a zero-treatment row in the M10 frame audit.
            let sampledRects = timeline.map { rects[id]!.sample($0).rect }, sampledForms = timeline.map { forms[id]!.sample($0).value }
            try await column.prepareRevealMattes(forms:sampledForms,idle:idle)
            let built=try await idle.step("plan.columnTracks") { () -> [Track] in
                let rest=M11RestPresentation([column]);defer{rest.restore()}
                var built:[Track]=[]
                column.motionProfile = profile; column.motionExposure = exposure
                column.motionExposure.enabled = column.motionExposure.enabled && columnExposureEnabled
                let columnEarlier = timeline.map { tau in tau >= exposureTime ? rects[id]!.sample(tau-exposureTime).rect : previous[id]!.rect.sample(t+tau-exposureTime).rect }
                built += column.tracks(timeline, rects: sampledRects, forms: sampledForms, earlierRects: columnEarlier)
                if let reflow = reflows[id] { built += column.fullReflowTracks(reflow, timeline: timeline, rects: sampledRects) }
                if presence[id]!.duration > 0 || entering.contains(id) {
                column.entering = presence[id]!.to > 0.5
                built += column.presenceTracks(timeline, values: timeline.map { presence[id]!.sample($0).value }, rects: sampledRects,
                    earlierValues: timeline.map { tau in tau >= exposureTime ? presence[id]!.sample(tau-exposureTime).value : previous[id]!.presence.sample(t+tau-exposureTime).value }, forms: sampledForms, earlierForms: timeline.map { tau in tau >= exposureTime ? forms[id]!.sample(tau-exposureTime).value : previous[id]!.form.sample(t+tau-exposureTime).value },sharp:true)
                }
                motions[id]=column.preparedMotion;mappings[id]=column.presenceMapping
                return built
            }
            tracks += built
            guard moving.contains(id) else { continue }
            // Flights: a reversing column keeps its plans, so its words retrace the same path.
            let lines = snapshots[id]?.pieces ?? column.pieces
            let lyricSize = snapshots[id]?.lyricSize ?? column.lyricSize
            let plans: [(ColumnNode.FlightPiece, FlightPlan)]
            if let current = flights[id] {
                plans = current.map { ($0.line, $0.plan) }
            } else {
                let towardBrief = forms[id]!.to < 0.5
                let centre = MorphFlightMath.centre(lines.map { towardBrief ? $0.source : $0.destination })
                plans = lines.enumerated().map { k, line in
                    // The look decides the anchor (goal trailing, narration leading, the rest centred); the stagger
                    // counts lyric lines from the bottom.
                    let look: MorphLook = switch line.look {
                    case .goal: .goal("", lyricSize: lyricSize, current: true)
                    case .worked: .worked("")
                    case .activity: .activity([], dots: false)
                    case .segment: .segment(BriefLine(words: [], lyricSize: lyricSize, current: true))
                    }
                    let element = MorphElement(id: "\(id)-\(k)", look: look, target: .fixture, line: line.lyricLines - 1 - line.lyricLine)
                    return (line, MorphFlightMath.makePlan(element: element, from: line.source, to: line.destination, towardBrief: towardBrief,
                                                           style: .tuned, span: rects[id]!.target.width, centre: centre, present: true))
                }
            }
            // One exposure back. Before this transition began that is where the column really was, on the springs it
            // is leaving: extrapolating the new springs backwards made a reversal's first exposure smear a path never
            // drawn, then drop to one copy (self-test spike, reverse at 80 ms).
            func earlier(_ exposure: Double) -> (rects: [CGRect], forms: [Double]) {
                (timeline.map { τ in τ - exposure >= 0 ? rects[id]!.sample(τ - exposure).rect : previous[id]!.rect.sample(t + τ - exposure).rect },
                 timeline.map { τ in τ - exposure >= 0 ? forms[id]!.sample(τ - exposure).value : previous[id]!.form.sample(t + τ - exposure).value })
            }
            let lineEarlier = earlier(exposureTime)
            // A narration is a paragraph, not a line: at a full shutter its smear read as a grey block, and collapsing
            // at a reversal's turnaround it changed most of the brief in one frame (self-test). Half the exposure for it
            // (decision 2026-10-29, to review with the user; the product's flights have no smear at all).
            var lineExposure=exposure;lineExposure.enabled=false
            var paragraph=lineExposure;paragraph.shutter *= 0.5
            let paragraphEarlier = earlier(exposureTime * 0.5)
            let nodes = plans.map { FlightNode(line: $0.0, plan: $0.1, bounds: scene.bounds, scale: scale) }
            for node in nodes {
                let segment = node.line.look == .segment
                let back = segment ? paragraphEarlier : lineEarlier
                tracks += try await idle.step("plan.flightTracks") {
                    node.tracks(timeline, rects:sampledRects, forms:sampledForms, earlierRects:back.rects, earlierForms:back.forms,
                                lyricSize:lyricSize,profile:profile,exposure:segment ? paragraph:lineExposure)
                }
                peak = max(peak, node.peakStep); smeared = max(smeared, node.smearedSamples)
            }
            flightCount += nodes.count
            newFlights[id] = nodes
        }
        // Presence uses the exact original geometry and alpha curves without an extra filtered/baked plane.
        let gaussian:[String:M10ColumnGaussianAsset]=[:],ink:[String:[M10ColumnInkTile]]=[:]
        tracks.removeAll {track in involved.contains{$0.isExposureTemplate(track.layer)}}
        try await idle.step("plan.finishBoundary") {}
        return Prepared(members: nextMembers, current: nextCurrent, scheme: sch, next: next, order: nextOrder, rects: rects, forms: forms, presence: presence,
                        dock: dockSprings, changing: changing, moving: moving, entering: entering, going: going,
                        snapshots: snapshots, reflows: reflows, presenceInk: ink, gaussian:gaussian, flights: newFlights, tracks: tracks, duration: duration, samples: timeline.times.count,
                        flightCount: flightCount, peak: peak, smeared: smeared, revisions: revisions, fromRest: !isMoving,
                        columnMotion:motions,presenceMappings:mappings)
    }

    func transition(to next: [Conversation], current c: String, scheme sch: Scheme, spring: (response: Double, damping: Double), reason: String) {
        M10ColumnWorkTrace.beginWindow("scheme")
        let work=M10ColumnWorkTrace.scope("scene.transition",["reason":reason]);defer{work.end()}
        let start = CACurrentMediaTime()
        let cached=newChatPreparation
        let hit=(reason == "new-chat" || reason == "new-chat-cancel") && !isMoving
            && cached?.key == newChatPreparationKey && cached?.plan.scheme == sch
            && cached?.plan.current == c && cached?.plan.members.map(\.id) == next.map(\.id)
        if ModeSignposts.enabled || M10ColumnWorkTrace.active {
            var reasons:[String]=[]
            if !["new-chat","new-chat-cancel"].contains(reason) {reasons.append("different-transition")}
            if isMoving {reasons.append("moving")}
            if cached == nil {reasons.append(idlePrewarmTask == nil ? (prewarmMissReasons["newchat"] ?? "absent"):"incomplete")}
            else {
                if cached?.key != newChatPreparationKey {reasons.append("newchat-key")}
                if cached?.plan.scheme != sch {reasons.append("target-scheme")}
                if cached?.plan.current != c {reasons.append("target-current")}
                if cached?.plan.members.map(\.id) != next.map(\.id) {reasons.append("target-members")}
            }
            let why=hit ? "hit":reasons.joined(separator:",")
            M10ColumnWorkTrace.count("scene.prewarm.lookup",["target":c,"hit":hit,"reason":why,"transition":reason])
            if ModeSignposts.enabled {ModeSignposts.Trace().record("OrganicPrewarmLookup",detail:"target=\(c) \(why) transition=\(reason)")}
        }
        discardNewChatPreparation()
        for other in prewarmed.values { unstage(other) }
        prewarmed = [:];lastPrewarmClear="transition"
        commit(hit ? cached!.plan:prepare(members: next, current: c, scheme: sch, at: now(), spring: spring), reason: reason, prewarmed: hit, start: start)
    }

    func commit(_ p: Prepared, reason: String, prewarmed hit: Bool, start: Double) {
        let work=M10ColumnWorkTrace.scope("scene.commit",["reason":reason,"hit":hit,"flights":p.flightCount]);defer{work.end()}
        discardNewChatPreparation()
        // A transition ends a peek at once (the bud's glass is taken over where it is); see DECISIONS #7.
        dismissPeek()
        cancelIdlePreparation();prewarmTask?.cancel();prewarmTask=nil;prewarmScheduled=false;prewarmQueue=nil
        let now = self.now(), interrupted = isMoving
        let preparedAt = CACurrentMediaTime()
        let membersChanged = members.map(\.id) != p.members.map(\.id)
        members = p.members; current = p.current; order = p.order; scheme = p.scheme
        if membersChanged { onMembersChange?(members) }
        let shown = Array(p.order.prefix(p.next.columns.count))
        columns = shown.compactMap { nodes[$0] }
        for id in p.going { leaving[id] = nodes[id] }
        for id in shown { leaving[id] = nil }
        let layers=M10ColumnWorkTrace.scope("scene.commit.layers")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for column in columns + leaving.values {
            let id = column.conversation.id
            guard let r = p.rects[id], let f = p.forms[id] else { continue }
            if column.card.superlayer == nil { cards.addSublayer(column.card); cards.addSublayer(column.separator) }
            column.rect = r; column.form = f
            if let mapping=p.presenceMappings[id] {column.presenceMapping=mapping}
            if let motion=p.columnMotion[id] {column.preparedMotion=motion}
            if let pr = p.presence[id] { column.presence = pr }
            column.removeAnimations()
            column.beginTranscriptMotion()
            if let s = p.snapshots[id] {
                if f.to>0.5 {column.usePreparedNativeGeometry(s)}
                column.apply(s)
            }
            column.place(column.rect.target, form: column.form.to)
            // Outgoing native views must stay hidden even when an interrupted presence spring is at rest.
            // showRest also consumes scroll/follow state, so it belongs only to retained columns.
            if shown.contains(id) { column.showRest(full: column.form.to > 0.5) }
            else {
                // Capture departure intent without consuming it through showRest's landing side effects.
                if column.ownsNative,!column.native.isHidden,column.followBeforeMotion == nil {
                    column.atEndBeforeMotion=column.native.shouldFollowEnd && column.native.isAtEnd
                }
                column.suspendNative()
            }
            if p.moving.contains(id) { column.hideGoal() }
            if let reflow = p.reflows[id] { column.beginFullReflow(reflow) }
            column.installPresenceInk(p.presenceInk[id] ?? [])
            column.installGaussian(p.gaussian[id],timeline:Timeline(began:0,duration:p.duration,rate:Timeline.rate(frameInterval:profile.frameInterval)),clock:clock,at:now)
        }
        for (i, column) in columns.enumerated() { column.separator.opacity = i < columns.count - 1 ? 1 : 0 }
        for nodes in flights.values { nodes.forEach { $0.replicator.removeFromSuperlayer() } }
        flights = p.flights
        for nodes in flights.values {
            for node in nodes {
                if node.replicator.superlayer == nil { flightsPlane.addSublayer(node.replicator) }
                node.replicator.isHidden = false
            }
        }
        for track in p.tracks { M10ColumnExposure.start(track,at:now,frameInterval:profile.frameInterval) }
        beginReorderText(p,reason:reason,at:now)
        CATransaction.commit()
        layers.end()
        let flush=M10ColumnWorkTrace.scope("scene.commit.flush")
        // Commit now, so the render server has the whole transition before the main thread does anything else.
        CATransaction.flush()
        let flushedAt = CACurrentMediaTime()
        flush.end()

        layout = p.next
        columnMotionPlans=p.columnMotion
        dock.still = isFocused && fullyFocused
        began = now; ends = now + p.duration
        generation += 1
        let g = generation
        let dockCommit=M10ColumnWorkTrace.scope("scene.commit.dock")
        // One commit origin and the last written Dock snapshot serve every Dock channel.
        dock.transitionEpoch = dock.makeTransitionEpoch(at:now)
        let adopted=committingDraftComposer.map {
            dock.transitionAdoptingStationaryDraft($0.composer,id:$0.id,to:p.next,order:p.order,
                full:fullIDs,springs:p.dock,duration:p.duration)
        } ?? false
        if !adopted {dock.transition(to:p.next,order:p.order,full:fullIDs,springs:p.dock,duration:p.duration)}
        ends=max(ends,dock.glassReleaseSettles)
        dockCommit.end()
        // The headers move with their columns on the main thread (their capsule and planet are glass, P2).
        for column in columns { column.beginIslandMotion(to: islandVariant(for: column.conversation.id), width: column.rect.target.width) }
        for column in leaving.values { column.beginIslandMotion(to: column.islandVariant, width: column.rect.target.width) }
        // Configuring lays a header out for where it is going. Left to the first tick, the frame it is leaving showed that for
        // a frame or two: titles jumped 130 pt the wrong way at the start of most switches (Opus, board 261031i).
        // Not a first send's new column: its header takes the seed's place when it starts to rise, right after this.
        for column in columns + leaving.values where !(reason == "new-chat-send" && p.entering.contains(column.conversation.id)) {
            column.islandFrame(rect: column.rect.sample(0).rect, form: column.form.sample(0).value, presence: column.presence.sample(0).value,
                earlierRect: column.rect.sample(-profile.frameInterval*exposure.shutter).rect, earlierForm: column.form.sample(-profile.frameInterval*exposure.shutter).value)
        }
        bindOverlays(leaving: true)
        runClock(until: max(ends, dock.meSettles, dock.peekSettles, dock.carrySettles))
        switches.append(["at": flushedAt, "reason": reason, "to": p.index, "current": p.current, "order": p.order, "durationSeconds": p.duration,
                         "keyframeSamples": p.samples, "flights": p.flightCount, "peakStepPtPerFrame": Double(p.peak), "smearedSamplesMax": p.smeared,
                         "compileMs": (flushedAt - start) * 1000, "prepareMs": (preparedAt - start) * 1000, "flushMs": (flushedAt - preparedAt) * 1000,
                         "prewarmed": hit, "tracks": p.tracks.count, "interrupted": interrupted, "exposure": exposure.enabled,
                         "entering": Array(p.entering), "going": Array(p.going), "prepareBreakdown": prepareBreakdown,
                         "revealFallbacks":columns.reduce(0){$0+$1.revealMatteFallbacks},
                         "revealReadyHits":columns.reduce(0){$0+$1.revealMatteHits},
                         "revealPrepared":columns.reduce(0){$0+$1.revealMattePrepared},
                         "revealStageFlushes":columns.reduce(0){$0+$1.revealStageFlushes},
                         "revealStageFlushMs":columns.reduce(0.0){$0+$1.revealStageFlushMs},
                         "revealCacheEntries":ColumnRevealMaterial.entryCount,
                         "revealCacheBytes":ColumnRevealMaterial.retainedBytes])
        if switches.count > 400 { switches.removeFirst() }
        updateStatus()
        if blockMain { Thread.sleep(forTimeInterval: p.duration + 0.05) }
        guard !manualSettle else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ends - CACurrentMediaTime()) + 0.02) { [weak self] in
            guard let self, self.generation == g else { return }
            self.settle()
        }
    }

    /// All automatic and hover requests share one cancellable idle job. Activity restarts the quiet period;
    /// no hover callback ever drains a plan synchronously (OrganicWindow.hover calls this on every move).
    func runClock(until time:Double) {
        idleMotionUntil=max(idleMotionUntil,time)
        clock.run(until:time)
    }

    /// Puts a prepared switch's new images in the tree without changing what shows: the growing column's
    /// full-form snapshot (its transcript is invisible while brief) and the flights, hidden.
    func stage(_ p: Prepared) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, s) in p.snapshots where p.forms[id]!.to > 0.5 { nodes[id]?.apply(s) }
        for nodes in p.flights.values {
            for node in nodes { node.replicator.isHidden = true; flightsPlane.addSublayer(node.replicator) }
        }
        CATransaction.commit()
    }

    func unstage(_ p: Prepared) {
        for nodes in p.flights.values { for node in nodes where node.replicator.isHidden { node.replicator.removeFromSuperlayer() } }
    }

    /// The transition is over: drop the flights, show the rest forms, apply content that changed meanwhile.
    func settle() {
        defer {onModeEndpointVisibilityChanged?()}
        clearReorderText()
        dirty.formUnion(pendingMovingRenders);pendingMovingRenders=[]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for nodes in flights.values { nodes.forEach { $0.replicator.removeFromSuperlayer() } }
        flights = [:]
        // Gone to orbs: out of the tree, but kept with their native sessions.
        for column in leaving.values {
            column.finishGaussian()
            column.removeAnimations()
            column.card.removeFromSuperlayer(); column.separator.removeFromSuperlayer()
            column.endTranscriptMotion()
            column.suspendNative()
        }
        leaving = [:]
        // A prepared switch doesn't go through prepare: an orb that came back brief needs this for its own preparation.
        admitUnmountedTranscripts(columns)
        for (i, column) in columns.enumerated() {
            column.removeAnimations()
            column.place(column.rect.target, form: column.form.to)
            column.rect = .rest(column.rect.target)
            column.form = .rest(column.form.to)
            column.presence = .rest(1)
            column.showPresent()
            if dirty.contains(column.conversation.id) || column.needsReanchor {
                column.renderDisplay(fullWidth: fullWidth(i, layout), briefWidth: briefWidth(i, layout), force: true)
            }
            column.showRest(full: isFull(column.conversation.id))
            column.endTranscriptMotion()
            column.separator.opacity = i < columns.count - 1 ? 1 : 0
        }
        dirty = []
        if tuningPending { tuningPending = false; DispatchQueue.main.async { [weak self] in self?.tuningChanged() } }
        CATransaction.commit()
        restIslands()
        dock.sample(.infinity)
        dock.dropItems(keeping: Set(members.map(\.id)))
        dock.settleContent(full: fullIDs)
        bindOverlays()
        settles.append(CACurrentMediaTime())
        updateStatus()
        tellTarget()
        if !manualSettle { DispatchQueue.main.async { [weak self] in self?.requestPrewarm() } }
    }

    func frame(_ target: Double) {
        let work=M10ColumnWorkTrace.scope("scene.frame",["t":target]);defer{work.end()}
        endPressIfButtonReleased()
        handoffTranscripts(at:target)
        if let d = draftColumn {
            let wasMoving=d.isMoving
            d.frame(at: target)
            if wasMoving,!d.isMoving,prewarmRequested {requestPrewarm()}
            if d.isLeaving, target >= d.settles { d.removeFromSuperview() }
        }
        for column in columns where column.isPromoting {
            let x = column.rect.sample(began >= 0 ? target - began : .infinity).rect.minX
            let oldX=column.rect.sample(began >= 0 ? target-began-profile.frameInterval*exposure.shutter:.infinity).rect.minX
            if !column.promotionFrame(at: target, x: x, width: column.rect.target.width, earlierX:oldX), !isMoving {
                column.configureIsland(islandVariant(for: column.conversation.id), width: column.rect.target.width)
                column.placeIsland(column.rect.target, shown: true)
                if prewarmRequested { requestPrewarm() }
            }
        }
        if began >= 0, target <= ends + 0.02 {
            let t = target - began
            for column in columns + leaving.values {
                column.islandFrame(rect: column.rect.sample(t).rect, form: column.form.sample(t).value, presence: column.presence.sample(t).value,
                    earlierRect:column.rect.sample(t-profile.frameInterval*exposure.shutter).rect,earlierForm:column.form.sample(t-profile.frameInterval*exposure.shutter).value)
            }
        }
        // Header destinations are ready before the Dock computes and applies its single glass batch.
        dock.frame(at: target, elapsed: began >= 0 ? target - began : .infinity)
        peekNode.placeCapsuleShadow(dock.peekCapsuleFrame)
    }
}
