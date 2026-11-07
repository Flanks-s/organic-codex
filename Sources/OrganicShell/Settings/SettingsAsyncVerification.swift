#if SETTINGS_SELFTEST
import AppKit

private actor SettingsExportTestClock:CoreRuntimeClock {
    private var continuations:[CheckedContinuation<Void,any Error>]=[]
    private(set) var intervals:[Double]=[]
    func sleep(seconds:TimeInterval) async throws {
        intervals.append(seconds)
        try await withCheckedThrowingContinuation {continuations.append($0)}
    }
    func finishFirst() {if !continuations.isEmpty {continuations.removeFirst().resume()}}
    func failFirst() {if !continuations.isEmpty {continuations.removeFirst().resume(throwing:SettingsDataError.invalid("Recorded preparation failure"))}}
}
@MainActor enum SettingsAsyncVerification {
    static func run(check:(Bool,String)->Void,png:(CGImage,String)->Void) async {
        let suite="organic.settings.s1."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let preferences=SettingsPreferences(defaults:defaults),f=CoreControllerFixture(),c=CoreSettingsController()
        let endpoint="s1-settings-fixture"
        c.configure(client:f.transport,endpoint:endpoint)
        var email="first@example.invalid",used=70.0,authorized=false
        f.before={request in
            switch request.key {
            case "account/read":return ["account":["email":.string(email),"planType":"fixture"]]
            case "account/rateLimits/read":return ["rateLimits":["primary":["usedPercent":.number(used),"resetsAt":2000000000]]]
            case "mcpServerStatus/list":return ["data":[["name":"server","authStatus":.string(authorized ? "authorized":"notLoggedIn")]]]
            default:return nil
            }
        }
        let s=SettingsSession(source:c,preferences:preferences)
        s.go("usage");await s.loadNow()
        check(c.changeObserverCount == 1,"S1 visible SettingsSession subscribes to live controller")
        check(s.snapshots["limits"]?["rateLimits"]?["primary"]?["usedPercent"] == 70,"S1 initial reported usage reaches visible session")
        let reads=f.count("account/rateLimits/read")
        used=0;email="second@example.invalid"
        for id in 0..<12 {c.receive(.init(id:id,time:nil,method:"account/updated",params:[:]))}
        check(s.snapshots["limits"] == .null && s.snapshots["account"] == .null,"S1 event withdraws old visible account and usage before reading")
        await wait({s.snapshots["limits"]?["rateLimits"]?["primary"]?["usedPercent"] == 0},check:check,"S1 burst of invalidations reloads actual current quota")
        check(f.count("account/rateLimits/read") == reads+1,"S1 twelve events coalesce into one visible usage read")
        check(s.snapshots["account"]?["account"]?["email"] == "second@example.invalid","S1 account change updates already-open Usage")
        check(SettingsPanels.make(s).contains{$0.id == "Usageprimary" && $0.value == 1},"S1 genuine reported zero renders full remaining capacity")

        var release:CheckedContinuation<JSONValue,Never>?,hold=true,seen:[Double]=[]
        s.onChange={if let value=s.snapshots["limits"]?["rateLimits"]?["primary"]?["usedPercent"]?.doubleValue {seen.append(value)}}
        f.before={request in
            if request.key == "account/rateLimits/read" {
                if hold {hold=false;return await withCheckedContinuation{release=$0}}
                return ["rateLimits":["primary":["usedPercent":3]]]
            }
            if request.key == "account/read" {return ["account":["email":"third@example.invalid"]]}
            if request.key == "mcpServerStatus/list" {return ["data":[["name":"server","authStatus":.string(authorized ? "authorized":"notLoggedIn")]]]}
            return nil
        }
        let oldRead=Task{await s.loadNow()}
        await wait({release != nil},check:check,"S1 usage HTTP read suspended in fixture")
        c.receive(.init(id:20,time:nil,method:"account/rateLimits/updated",params:[:]))
        release?.resume(returning:["rateLimits":["primary":["usedPercent":91]]])
        await oldRead.value
        await wait({s.snapshots["limits"]?["rateLimits"]?["primary"]?["usedPercent"] == 3},check:check,"S1 invalidation during HTTP read schedules a fresh acknowledged read")
        check(!seen.contains(91),"S1 superseded HTTP quota never reappears in visible session")
        s.onChange=nil

        s.go("account");await s.loadNow()
        _ = await s.execute(s.operation(.login))
        check(SettingsPanels.make(s).contains{$0.id == "cancelLogin"},"S1 pending login exposes Cancel in the visible pane")
        c.receive(.init(id:21,time:nil,method:"account/login/completed",params:["loginId":"login-1","success":false,"error":"Denied fixture login"]))
        check(!SettingsPanels.make(s).contains{$0.id == "cancelLogin"},"S1 login completion removes stale Cancel without manual Refresh")
        check(SettingsPanels.make(s).contains{$0.id == "source.error.login" && $0.detail.contains("Denied fixture")},"S1 asynchronous login failure is readable in the account pane")
        await wait({!s.busy.contains("read:account")},check:check,"S1 account event refresh finishes")
        let closedSource=CoreSettingsController();closedSource.configure(client:f.transport,endpoint:endpoint)
        let closedSession=SettingsSession(source:closedSource,preferences:SettingsPreferences(defaults:defaults))
        closedSession.go("account");await closedSession.loadNow();_ = await closedSession.execute(closedSession.operation(.login))
        closedSession.stopPresentation();let beforeClosedCompletion=f.requests.count
        closedSource.receive(.init(id:210,time:nil,method:"account/login/completed",params:["loginId":"login-1","success":false,"error":"Completion while closed"]))
        check(f.requests.count == beforeClosedCompletion,"S1 login completion while closed performs no background fetch")
        await closedSession.loadNow()
        check(!SettingsPanels.make(closedSession).contains{$0.id == "cancelLogin"},"S1 reopening cannot retain Cancel from a completed login")
        check(SettingsPanels.make(closedSession).contains{$0.id == "source.error.login" && $0.detail == "Completion while closed"},"S1 reopening recovers a login error missed while unsubscribed")
        closedSession.stopPresentation()
        s.go("plugins/mcp");await s.loadNow()
        authorized=true
        c.receive(.init(id:22,time:nil,method:"mcpServer/oauth/login/completed",params:["success":true]))
        await wait({s.snapshots["mcp"]?["data"]?.arrayValue?.first?["authStatus"] == "authorized"},check:check,"S1 open MCP child route refreshes after OAuth event")
        c.receive(.init(id:23,time:nil,method:"mcpServer/oauth/login/completed",params:["success":false,"error":"Denied fixture OAuth"]))
        check(SettingsPanels.make(s).contains{$0.id == "source.error.oauth" && $0.detail.contains("Denied fixture")},"S1 OAuth failure remains visible while data reloads")
        await wait({!s.busy.contains("read:plugins/mcp")},check:check,"S1 OAuth refresh settles")
        let closedReads=f.requests.count;s.stopPresentation()
        check(c.changeObserverCount == 0,"S1 Settings close removes controller observer")
        c.receive(.init(id:24,time:nil,method:"account/updated",params:[:]))
        for _ in 0..<8 {await Task.yield()}
        check(f.requests.count == closedReads,"S1 closed Settings does not fetch after account events")
        s.go("usage");await s.loadNow()
        check(c.changeObserverCount == 1,"S1 reopening re-subscribes once")
        s.setDevice("remote")
        let remoteReads=f.requests.count;c.receive(.init(id:25,time:nil,method:"account/updated",params:[:]))
        for _ in 0..<8 {await Task.yield()}
        check(f.requests.count == remoteReads && s.snapshots["account"] == nil,"S1 event cannot reload another selected device")
        s.setDevice("mac");await s.loadNow()
        preferences.set("coreNotifications",false)
        check(!c.notificationsEnabled,"S1 local global preference reaches controller without an App reload hook")
        preferences.set("jobNotifications.a.b","failed");preferences.set("coreNotifications",true)
        check(c.notificationsEnabled && c.jobNotificationPolicies["a.b"] == "failed","S1 per-job policy preserves full job IDs")
        let restored=SettingsPreferences(defaults:defaults)
        check(restored.notificationPolicy == preferences.notificationPolicy,"S1 global and per-job notification policies survive preference reload")
        s.stopPresentation()
        var weakSession:SettingsSession?
        weak var released:SettingsSession?
        weakSession=SettingsSession(source:c,preferences:SettingsPreferences(defaults:defaults));released=weakSession
        await weakSession?.loadNow();weakSession=nil
        check(released == nil && c.changeObserverCount == 0,"S1 source callbacks do not retain a closed SettingsSession")

        let clock=SettingsExportTestClock(),demo=SettingsDemoDataSource()
        let e=SettingsSession(source:demo,preferences:SettingsPreferences(defaults:defaults),progressClock:clock)
        e.go("data");await e.loadNow()
        check(e.startDemoExport() && !e.startDemoExport(),"S1 demo Export starts once and rejects duplicate submission")
        await waitClock(clock,count:1,check:check)
        check(SettingsPanels.make(e).first{$0.id == "export"}?.enabled == false && SettingsPanels.make(e).contains{$0.id == "export.cancel"},"S1 preparing Export is disabled and exposes Cancel")
        let content=NativeSettingsWorkbench(session:e);content.automaticallyLoads=false;content.loadViewIfNeeded()
        for scale:CGFloat in [1,2] {png(content.snapshot(scale:scale,fullPanel:true),"s1-export-preparing@\(Int(scale))x")}
        e.cancelDemoExport();await clock.finishFirst()
        for _ in 0..<8 {await Task.yield()}
        check(e.exportProgress == .idle && demo.operations.isEmpty,"S1 cancelled Export cannot complete later or write demo/backend data")
        check(e.startDemoExport(),"S1 Export can restart after cancellation")
        await waitClock(clock,count:2,check:check);await clock.finishFirst()
        await wait({e.exportProgress == .complete},check:check,"S1 injected preparation clock completes Export")
        check(SettingsPanels.make(e).first{$0.id == "export"}?.detail.contains("no email was sent") == true,"S1 completed demo Export never claims a real email or file export")
        content.render()
        for scale:CGFloat in [1,2] {png(content.snapshot(scale:scale,fullPanel:true),"s1-export-complete@\(Int(scale))x")}
        check(e.startDemoExport(),"S1 completed Export can start a new preparation")
        await waitClock(clock,count:3,check:check);e.stopPresentation();await clock.finishFirst()
        for _ in 0..<8 {await Task.yield()}
        check(e.exportProgress == .idle,"S1 closing cancels Export and rejects late completion")
        check(!e.startDemoExport(),"S1 retired Export action cannot start work after closing")
        e.go("data");await e.loadNow();_ = e.startDemoExport()
        await waitClock(clock,count:4,check:check);e.go("general");await clock.finishFirst()
        for _ in 0..<8 {await Task.yield()}
        check(e.exportProgress == .idle,"S1 leaving Export pane cancels its progress")
        check(!e.startDemoExport(),"S1 retired Export action cannot start work from a different pane")
        e.go("data");_ = e.startDemoExport();await waitClock(clock,count:5,check:check)
        e.setSource(c);await clock.finishFirst()
        for _ in 0..<8 {await Task.yield()}
        check(e.exportProgress == .idle && !e.startDemoExport(),"S1 switching to Live cancels prototype Export and forbids starting it")
        e.setSource(demo);e.go("data");_ = e.startDemoExport();await waitClock(clock,count:6,check:check)
        await clock.failFirst()
        await wait({if case .failed=e.exportProgress{return true};return false},check:check,"S1 failed preparation displays an error and can retry")
        check(await clock.intervals.allSatisfy{$0 == 1.6},"S1 demo preparation uses product 1.6 second contract")
        e.stopPresentation()
    }
    private static func wait(_ predicate:()->Bool,check:(Bool,String)->Void,_ label:String) async {
        for _ in 0..<250 {if predicate(){check(true,label);return};try? await Task.sleep(for:.milliseconds(1))};check(false,label)
    }
    private static func waitClock(_ clock:SettingsExportTestClock,count:Int,check:(Bool,String)->Void) async {
        for _ in 0..<250 {if await clock.intervals.count == count {check(true,"S1 Export clock wait \(count)");return};await Task.yield()}
        check(false,"S1 Export clock wait \(count)")
    }
}
#endif
