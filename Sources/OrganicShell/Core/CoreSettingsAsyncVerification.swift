#if CORE_SELFTEST
import Foundation

@MainActor enum CoreSettingsAsyncVerification {
    static func run(check:(Bool,String)->Void) async throws {
        let f=CoreControllerFixture(),c=CoreSettingsController(),scope=SettingsScope(endpoint:"s1-fixture",device:"mac")
        c.configure(client:f.transport,endpoint:scope.endpoint)
        let observable:any SettingsObservableDataSource=c
        var changes:[SettingsReadResult]=[],foreign=0
        let token=observable.observeChanges(scope:scope){changes.append($0)}
        let other=observable.observeChanges(scope:.init(endpoint:"another",device:"mac")){_ in foreign+=1}
        let device=observable.observeChanges(scope:.init(endpoint:scope.endpoint,device:"remote")){_ in foreign+=1}
        _ = try await c.read(.init(pane:"usage",scope:scope))
        check(changes.last?.snapshots["account"] != nil,"S1 acknowledged readbacks reach observable subscribers")
        check(foreign == 0,"S1 observers are isolated by endpoint and device")
        let before=f.requests.count
        c.receive(.init(id:10,time:nil,method:"account/updated",params:[:]))
        check(f.requests.count == before,"S1 invalidation itself never starts a network read")
        check(changes.last?.invalidatedPanes == ["account","profile","usage"],"S1 account events invalidate all dependent panes")
        check(c["account"] == .null && c["limits"] == .null,"S1 invalidation withdraws old identity and quota immediately")
        let count=changes.count;observable.removeChangeObserver(token)
        c.receive(.init(id:11,time:nil,method:"account/updated",params:[:]))
        check(changes.count == count && foreign == 0,"S1 removed/foreign observers receive no late event")
        observable.removeChangeObserver(other);observable.removeChangeObserver(device)
        check(c.changeObserverCount == 0,"S1 removing the last observer releases the source subscription")

        var release:CheckedContinuation<JSONValue,Never>?
        f.before={request in
            if request.key == "account/read" {return await withCheckedContinuation{release=$0}}
            return nil
        }
        let reading=Task{try await c.read(.init(pane:"usage",scope:scope))}
        await wait({release != nil},check:check,"S1 suspended account read reached fixture")
        c.receive(.init(id:12,time:nil,method:"account/updated",params:[:]))
        release?.resume(returning:["account":["email":"stale@example.invalid"]]);f.before=nil
        do {_ = try await reading.value;check(false,"S1 invalidated read must not return old quota/account")}
        catch {check(error as? SettingsDataError != nil && c["account"] == .null,"S1 event arriving during read fences stale HTTP readback")}
        f.failures["account/rateLimits/read"]=CoreWire.failure("recorded limits unavailable")
        let unavailable=try await c.read(.init(pane:"usage",scope:scope))
        check(unavailable.notice?.contains("limits unavailable") == true && c["limits"] == .null,"S1 failed limits reload remains unknown with an explicit error")
        f.failures=[:]

        _ = try await c.perform(.init(kind:.login,scope:scope))
        c.receive(.init(id:13,time:nil,method:"account/login/completed",params:["loginId":"other-login","success":true]))
        check(c.pendingLoginID == "login-1","S1 unrelated login completion cannot cancel the pending request")
        c.receive(.init(id:14,time:nil,method:"account/login/completed",params:["loginId":"login-1","success":false,"error":"recorded login failure"]))
        check(c.pendingLoginID == nil && c["login"] == .null && c.errors["login"] == "recorded login failure","S1 matching failed login clears pending state and preserves the error")
        let restoredLogin=try await c.read(.init(pane:"account",scope:scope))
        check(restoredLogin.snapshots["login"] == .null && restoredLogin.errors["login"] == "recorded login failure","S1 readback recovers login completion and errors missed while Settings was closed")
        f.before={request in
            if request.key == "account/login/start" {
                c.receive(.init(id:15,time:nil,method:"account/login/completed",params:["loginId":"early","success":true]))
                return ["loginId":"early","authUrl":"https://auth.example.invalid/early"]
            };return nil
        }
        let early=try await c.perform(.init(kind:.login,scope:scope));f.before=nil
        check(c.pendingLoginID == nil && early.snapshots["login"] == .null && early.browserURL == nil,"S1 early SSE completion cannot be overwritten by late login HTTP response")
        var event:SettingsReadResult?
        let mcpToken=c.observeChanges(scope:scope){event=$0}
        c.receive(.init(id:16,time:nil,method:"mcpServer/oauth/login/completed",params:["success":false,"error":"recorded oauth failure"]))
        check(event?.invalidatedPanes == ["plugins","plugins/mcp"] && event?.errors["oauth"] == "recorded oauth failure","S1 OAuth failure invalidates both plugins routes and publishes its actual error")
        c.receive(.init(id:17,time:nil,method:"mcpServer/oauth/login/completed",params:["success":true]))
        check(event?.clearedErrors.contains("oauth") == true && c.errors["oauth"] == nil,"S1 successful OAuth completion clears a previous error")
        c.removeChangeObserver(mcpToken)

        var permissionReads=0,permissionPrompts=0
        c.onPermissionStatus={permissionReads+=1;return "Not allowed"}
        c.onPermissionRequest={permissionPrompts+=1;return true}
        let permission=try await c.read(.init(pane:"notifications",scope:scope))
        check(permissionReads == 1 && permissionPrompts == 0 && permission.snapshots["permission"] == "Not allowed","S1 permission read reports OS state without prompting")
        let allowed=try await c.perform(.init(kind:.notificationPermission,scope:scope))
        check(permissionPrompts == 1 && allowed.snapshots["permission"] == "Allowed" && c["permission"] == "Allowed","S1 explicit permission request returns an acknowledged UI snapshot")
        c.updateNotificationPermission("Not allowed")
        check(c["permission"] == "Not allowed","S1 host can publish an external OS authorization change")
        var statusRelease:CheckedContinuation<String,Never>?
        c.onPermissionStatus={await withCheckedContinuation{statusRelease=$0}}
        let statusRead=Task{try await c.read(.init(pane:"notifications",scope:scope))}
        await wait({statusRelease != nil},check:check,"S1 OS status read suspended in fixture")
        c.updateNotificationPermission("Not allowed");statusRelease?.resume(returning:"Allowed")
        let latestStatus=try await statusRead.value
        check(latestStatus.snapshots["permission"] == "Not allowed","S1 late OS status read cannot overwrite a newer external denial")
        c.onPermissionStatus=nil
        var permissionRelease:CheckedContinuation<Bool,Never>?
        c.onPermissionRequest={await withCheckedContinuation{permissionRelease=$0}}
        let prompt=Task{try await c.perform(.init(kind:.notificationPermission,scope:scope))}
        await wait({permissionRelease != nil},check:check,"S1 suspended permission request reached fixture")
        c.updateNotificationPermission("Not allowed");permissionRelease?.resume(returning:true)
        let latestPrompt=try await prompt.value
        check(latestPrompt.snapshots["permission"] == "Not allowed","S1 late prompt acknowledgement cannot overwrite a newer OS status")
        permissionRelease=nil
        let oldPrompt=Task{try await c.perform(.init(kind:.notificationPermission,scope:scope))}
        await wait({permissionRelease != nil},check:check,"S1 second suspended permission request reached fixture")
        c.configure(client:f.transport,endpoint:"new-scope")
        permissionRelease?.resume(returning:true)
        do {_ = try await oldPrompt.value;check(false,"S1 old permission result must not enter new endpoint")}
        catch {check(c.notificationPermission == "Not checked" && c["permission"] == .null,"S1 endpoint switch fences delayed permission result")}

        c.configure(client:f.transport,endpoint:scope.endpoint)
        for (status,attention) in [("completed",false),("failed",true),("submissionFailed",true),("submissionUnknown",true),("submissionUnconfirmed",true),("interrupted",true),("running",false)] {
            check(SettingsNotificationPolicy(enabled:true,jobs:["job":"failed"]).allows(jobID:"job",status:status) == attention,"S1 failure-only policy: "+status)
            check(!SettingsNotificationPolicy(enabled:false).allows(jobID:"job",status:status),"S1 global Off: "+status)
            check(!SettingsNotificationPolicy(enabled:true,jobs:["job":"off"]).allows(jobID:"job",status:status),"S1 per-job Off: "+status)
        }
        var calls=0
        c.onDeliverNotification={_ in calls+=1;return .delivered}
        func notification(_ id:Int,_ status:String="completed")->CoreEvent {.init(id:id,time:nil,method:"core/notification",params:["id":.string("note-\(id)"),"jobId":"job","status":.string(status)])}
        c.setNotificationPolicy(.init(enabled:true));c.receive(notification(30));c.receive(notification(30))
        await wait({calls == 1},check:check,"S1 duplicate SSE notification reaches injected sink once")
        for _ in 0..<8 {await Task.yield()}
        c.receive(notification(30));check(calls == 1,"S1 acknowledged notification ID is not delivered again")
        c.receive(notification(31));c.setNotificationPolicy(.init(enabled:false))
        for _ in 0..<8 {await Task.yield()}
        check(calls == 1,"S1 queued notification rechecks global Off before calling the OS sink")
        c.setNotificationPolicy(.init(enabled:true));c.notificationPolicyProvider={.init(enabled:false)}
        c.receive(notification(32));check(calls == 1,"S1 injected dynamic host policy can suppress delivery")
        c.notificationPolicyProvider=nil
        c.onDeliverNotification={_ in calls+=1;return .notAuthorized("OS denied notifications")}
        c.receive(notification(33))
        await wait({c.errors["notifications"] != nil},check:check,"S1 OS delivery denial is observable")
        check(c.notificationPermission == "Not allowed" && c.errors["notifications"] == "OS denied notifications","S1 delivery denial never fabricates an authorized state")
        c.onDeliverNotification={_ in throw CoreWire.failure("recorded delivery failed")};c.receive(notification(34))
        await wait({c.errors["notifications"]?.contains("recorded delivery failed") == true},check:check,"S1 OS delivery errors are published")
        c.onDeliverNotification={_ in .suppressed};c.receive(notification(35))
        await wait({c.errors["notifications"] == nil},check:check,"S1 explicit host suppression clears old delivery failure without changing permission")
        check(c.notificationPermission == "Not allowed","S1 suppression does not masquerade as OS authorization")
        var deliveryRelease:CheckedContinuation<CoreNotificationDeliveryResult,Never>?
        c.onDeliverNotification={_ in await withCheckedContinuation{deliveryRelease=$0}}
        c.receive(notification(36))
        await wait({deliveryRelease != nil},check:check,"S1 suspended OS delivery reached fixture")
        c.configure(client:f.transport,endpoint:"different-core")
        deliveryRelease?.resume(returning:.notAuthorized("stale OS reply"))
        for _ in 0..<8 {await Task.yield()}
        check(c.errors["notifications"] == nil && c.notificationPermission == "Not checked","S1 cancelled old delivery cannot publish into reconfigured controller")
        var fallbackID:String?
        c.onDeliverNotification={value in fallbackID=value["id"]?.stringValue;return .delivered}
        c.receive(.init(id:80,time:nil,method:"core/notification",params:["status":"completed"]))
        await wait({fallbackID != nil},check:check,"S1 event without inbox ID reaches delivery bridge")
        check(fallbackID == "core-event-80","S1 OS bridge receives a stable event-derived fallback identifier")
    }
    private static func wait(_ predicate:()->Bool,check:(Bool,String)->Void,_ label:String) async {
        for _ in 0..<250 {if predicate(){check(true,label);return};try? await Task.sleep(for:.milliseconds(1))}
        check(false,label)
    }
}
#endif
