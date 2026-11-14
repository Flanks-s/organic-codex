#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Tide's retained surfaces remain independent of the optional ambient-loop policy.
@MainActor enum DockTideRound5Verification {
    static func run(to output:URL,check:(Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
        let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:M10DockMotion.dell,scale:2)
        scene.restOnSnapshot=true;scene.ambient=true;scene.manualSettle=true;scene.install(members:MockSeed.windowMembers)
        scene.dock.prepareTideMaterialNow()
        let warm=DockTideAnimationAudit.snapshot([("dock",scene.dock.view)])
        let warmGaussian=(warm["filters"] as? [[String:Any]] ?? []).filter{($0["type"] as? String)=="gaussianBlur" && ($0["radius"] as? Double ?? 0)>0 && ($0["enabled"] as? Bool)==true}
        check(warmGaussian.isEmpty,"parked Tide ink has no attached enabled Gaussian")
        let report:[String:Any]=["warm":warm]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-round5.json"))
        scene.disposeTranscriptPresentation()
        check(NSApp.windows.allSatisfy{!$0.isVisible},"Tide checks open no visible windows")
    }
}
#endif
