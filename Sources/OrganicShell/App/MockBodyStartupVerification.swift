import AppKit

/// Run the actual application launch callback with presentation disabled, never a hand-started runtime.
@MainActor enum MockBodyStartupVerification {
    static func run(to path: String) -> Int32 {
        let out=URL(fileURLWithPath:path)
        try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let domain="OrganicShell.MockBodyStartup."+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!
        let originalMenu=NSApp.mainMenu
        var options=Options()
        options.mock=true; options.mockPaused=true; options.live=false; options.ambient=false
        let app=AppController(options,windowDefaults:defaults,presentsWindows:false)
        defer {
            app.runtime.shutdown()
            for owner in app.windows { owner.window.close() }
            NSApp.mainMenu=originalMenu
            NativeSettingsWindowController.uninstall()
            defaults.removePersistentDomain(forName:domain)
        }
        var checks=0,failures:[String]=[]
        func check(_ value: Bool,_ label: String) {
            checks += 1
            if !value { failures.append(label); print("FAIL:",label) }
        }
        func symbol(_ c: Conversation) -> String {
            ConversationIdentity.resolved(index:c.identityIndex,symbol:c.identitySymbol,tint:c.identityTint).symbol
        }
        app.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
        check(!app.store.conversations.isEmpty && app.store.conversations.allSatisfy { symbol($0) != "earth" },
              "actual mock app startup has no Earth conversation")
        check(app.store.bodyIdentitiesReady,"actual mock app startup commits in-memory identity readiness")
        let created=app.runtime.createConversation(title:"Startup allocation",projectID:nil,deviceID:"mac",firstMessage:"Mock startup allocation check",attachments:[])
        check(app.store.conversation(created.id) === created && created.identityIndex>=1_000_000 && symbol(created) != "earth",
              "actual app runtime creates a new non-Earth identity from the new allocation range")
        let source=app.store.conversation("F")!
        let fork=source.items.first.flatMap { app.runtime.fork(source,at:$0.id) }
        check(fork.map { $0.identityIndex>=1_000_000 && symbol($0) != "earth" } == true,
              "actual app runtime forks into the new non-Earth allocation range")
        let before=app.store.conversations.map { [$0.id,$0.title,$0.identitySymbol ?? "",$0.identityTint ?? ""] }
        let emitted=app.mock?.emitted
        let debug=app.debugTools?.session
        _=debug?.startPlayback()
        _=debug?.setPaused(false)
        _=debug?.setPaused(true)
        check(app.store.conversations.map { [$0.id,$0.title,$0.identitySymbol ?? "",$0.identityTint ?? ""] } == before,
              "Debug playback restart preserves migrated identities and titles")
        check(app.mock?.emitted == emitted,"Debug playback restart never seeds the replay twice")
        check(app.store.bodyIdentitiesReady && app.store.conversations.allSatisfy { symbol($0) != "earth" },
              "Debug playback restart preserves readiness and the Earth reservation")
        check(!options.usesLiveCore && app.core == nil && app.live == nil,"actual startup remains mock-only")
        check(NSApp.windows.allSatisfy { !$0.isVisible },"actual startup and Debug restart never order a visible window")
        let report:[String:Any]=["checks":checks,"failures":failures,"bodyIdentitiesReady":app.store.bodyIdentitiesReady,
            "newIdentityIndex":created.identityIndex,"newBodyID":symbol(created),"forkIdentityIndex":fork?.identityIndex ?? -1,
            "earthConversationIDs":app.store.conversations.filter { symbol($0) == "earth" }.map(\.id),
            "scope":"AppController.applicationDidFinishLaunching with mock-paused options and presentsWindows=false"]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("mock-startup.json"))
        print("MOCK STARTUP \(checks) checks, \(failures.count) failures")
        return failures.isEmpty ? 0:1
    }
}
