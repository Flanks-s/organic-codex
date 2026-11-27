import AppKit
import QuartzCore

/// Read-only diagnostics. Includes mask clocks and paused animations; never samples or writes glass geometry.
@MainActor enum DockTideAnimationAudit {
    /// Stored-property reflection is diagnostic only. Control stays with each clock's existing public API.
    /// A retained DispatchWorkItem is not proof that it is pending or executing; its owner supplies that meaning.
    static func clocks(_ owners:[(String,Any)])->[String:Any] {
        var links:[[String:Any]]=[],timers:[[String:Any]]=[],workItems:[[String:Any]]=[],seen=Set<ObjectIdentifier>()
        func unwrapped(_ value:Any)->Any? {
            let m=Mirror(reflecting:value)
            if m.displayStyle == .optional {return m.children.first.flatMap{unwrapped($0.value)}}
            return value
        }
        func visit(_ value:Any,_ path:String) {
            guard let object=unwrapped(value) else{return}
            if let link=object as? CADisplayLink {
                guard seen.insert(ObjectIdentifier(link)).inserted else{return}
                links.append(["path":path,"paused":link.isPaused,"running":!link.isPaused,"timestamp":link.timestamp,"targetTimestamp":link.targetTimestamp]);return
            }
            if let timer=object as? Timer {
                guard seen.insert(ObjectIdentifier(timer)).inserted else{return}
                timers.append(["path":path,"valid":timer.isValid,"interval":timer.timeInterval,"fireAt":timer.fireDate.timeIntervalSince1970]);return
            }
            if let work=object as? DispatchWorkItem {
                guard seen.insert(ObjectIdentifier(work)).inserted else{return}
                workItems.append(["path":path,"cancelled":work.isCancelled]);return
            }
            guard object is SceneClock || object is IslandMotionClock || object is OrbComponent || object is DockTideFace || object is M10DockGaussian || object is HeaderIsland || object is HeaderPulsePresentation || object is OrbMeController || object is CollapseStrip else{return}
            guard seen.insert(ObjectIdentifier(object as AnyObject)).inserted else{return}
            for child in Mirror(reflecting:object).children {visit(child.value,path+"."+(child.label ?? "?"))}
        }
        for (path,owner) in owners {
            visit(owner,path)
            // Inspect only immediate slots of caller-supplied owners. Never walk arbitrary app or Core graphs.
            if let root=unwrapped(owner) {for child in Mirror(reflecting:root).children {visit(child.value,path+"."+(child.label ?? "?"))}}
        }
        return ["displayLinks":links,"timers":timers,"retainedWorkItems":workItems,"activeDisplayLinks":links.filter{$0["running"] as? Bool == true}.count]
    }
    static func snapshot(_ roots:[(String,NSView)]) -> [String:Any] {
        var animations:[[String:Any]]=[],filters:[[String:Any]]=[],seen=Set<ObjectIdentifier>()
        let now=CACurrentMediaTime()
        func animation(_ a:CAAnimation,_ key:String,_ path:String,_ layer:CALayer,_ hidden:Bool,_ plane:String,_ inheritedSpeed:Double=1) {
            let rate=layer.convertTime(now+1,from:nil)-layer.convertTime(now,from:nil)
            let repeated = !a.repeatCount.isFinite || a.repeatCount>1_000_000 || a.repeatDuration>1_000_000
            animations.append(["path":path,"key":key,"keyPath":(a as? CAPropertyAnimation)?.keyPath ?? "group",
                "duration":a.duration,"beginTime":a.beginTime,"preferredFPS":a.preferredFrameRateRange.preferred ?? 0,"maximumFPS":a.preferredFrameRateRange.maximum,"repeatCount":a.repeatCount.isFinite ? Double(a.repeatCount):"infinity",
                "repeatDuration":a.repeatDuration.isFinite ? a.repeatDuration:0,"loop":repeated,
                "clockRate":rate*inheritedSpeed*Double(a.speed),"running":rate != 0 && inheritedSpeed != 0 && a.speed != 0,"hidden":hidden,"plane":plane])
            for (i,child) in ((a as? CAAnimationGroup)?.animations ?? []).enumerated() {
                animation(child,key+".group[\(i)]",path,layer,hidden,plane,inheritedSpeed*Double(a.speed))
            }
        }
        func layers(_ layer:CALayer,_ path:String,_ hidden:Bool,_ plane:String) {
            guard seen.insert(ObjectIdentifier(layer)).inserted else{return}
            let h=hidden || layer.isHidden || layer.opacity<=0
            for key in layer.animationKeys() ?? [] {if let a=layer.animation(forKey:key) {animation(a,key,path,layer,h,plane)}}
            let slots:[(String,[Any])]=[("content",layer.filters ?? []),("background",layer.backgroundFilters ?? []),("compositing",layer.compositingFilter.map{[$0]} ?? [])]
            for (slot,values) in slots {for f in values {
                let object=f as? NSObject,type=String(describing:f)
                let native=NSClassFromString("CAFilter").map{object?.isKind(of:$0) == true} ?? false
                let enabled:Any=native ? (object?.value(forKey:"enabled") as? Bool ?? true):NSNull()
                filters.append(["path":path,"slot":slot,"type":type,"enabled":enabled,
                    "radius":native && type.lowercased().contains("gaussian") ? (object?.value(forKey:"inputRadius") as? Double ?? 0):0,"hidden":h,"plane":plane])
            }}
            if let mask=layer.mask {layers(mask,path+"/mask",h,plane)}
            for (i,child) in (layer.sublayers ?? []).enumerated() {layers(child,path+"/\(i):"+(child.name ?? String(describing:type(of:child))),h,plane)}
        }
        func views(_ v:NSView,_ path:String,_ plane:String) {
            let next=v is NSGlassEffectView ? "glass-content":plane
            // Visit view children first so their readable paths win over AppKit backing-layer indices.
            for (i,child) in v.subviews.enumerated() {
                views(child,path+"/\(i):"+(child.identifier?.rawValue ?? String(describing:type(of:child))),next)
            }
            if let l=v.layer {layers(l,path,v.isHiddenOrHasHiddenAncestor,next)}
        }
        for (label,root) in roots {views(root,label,label.hasSuffix(".back") ? "below-glass-container":label.hasSuffix(".front") ? "above-glass-container":"host")}
        return ["animations":animations,"filters":filters,
            "runningLoops":animations.filter{($0["loop"] as? Bool)==true && ($0["running"] as? Bool)==true}.count,
            "attachedLoops":animations.filter{($0["loop"] as? Bool)==true}.count,
            "animatedFilters":animations.filter{($0["keyPath"] as? String)?.lowercased().contains("filter") == true}.count]
    }
}
