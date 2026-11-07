#if M1_SELFTEST
import AppKit

@MainActor enum NativeRecoveryVerification {
    static func run(check: (Bool, String) -> Void) {
        let composer = NativeComposer(frame: CGRect(x: 0, y: 0, width: 1080, height: 120))
        composer.state.usesLiveCore = true; composer.state.running = true
        var requests: [UUID] = [], receipts: [(@MainActor (NativeComposerCompletion) -> Void)] = []
        composer.onStopRequest = { id, done in requests.append(id); receipts.append(done) }
        check(composer.requestStop() && composer.hasPendingStop && requests.count == 1, "S2 stop starts one UUID request")
        check(!composer.requestStop(), "S2 repeated stop while pending sends nothing")
        receipts[0](.failed("Fixture interrupt failed"))
        check(!composer.hasPendingStop && composer.canStop && composer.state.running, "S2 failed stop clears pending without fabricating turn completion")
        check(composer.state.operationError == "Fixture interrupt failed" && !composer.state.outcomeUnknown, "S2 stop failure is visible without changing send truth")
        check(composer.requestStop() && requests[0] != requests[1], "S2 retry gets a distinct submission UUID")
        receipts[0](.accepted)
        check(composer.hasPendingStop, "S2 late duplicate receipt cannot clear the new stop")
        receipts[1](.outcomeUnknown("Interrupt outcome is unknown"))
        check(!composer.hasPendingStop && composer.canStop && !composer.state.outcomeUnknown, "S2 unknown stop clears only its pending and remains distinguishable from unknown send")
        _ = composer.requestStop(); composer.state.stopping = true; receipts[2](.accepted)
        check(!composer.hasPendingStop && composer.state.running && composer.state.stopping && !composer.canStop, "S2 accepted interrupt leaves backend running/stopping authoritative")
        composer.state.running = false; composer.state.stopping = false
        receipts[2](.failed("stale"))
        check(composer.state.operationError != "stale", "S2 completed stop rejects a later failure")
        var sends = 0, reads = 0
        composer.onSubmit = { _ in sends += 1 }
        composer.onRefreshHistory = { reads += 1; composer.state.loading = true }
        _ = composer.setText("Keep the newer draft")
        composer.attachments = [.init(id: "local", name: "local.txt", symbol: "doc")]
        composer.state.outcomeUnknown = true
        let text = composer.text, files = composer.attachments, settings = composer.settings
        check(composer.requestHistoryRefresh() && reads == 1 && sends == 0, "S2 recovery invokes only the history reader, never sends")
        check(!composer.canRefreshHistory && !composer.requestHistoryRefresh() && reads == 1, "S2 actual loading disables another refresh")
        check(composer.text == text && composer.attachments == files && composer.settings == settings, "S2 refresh does not clear draft/attachments/settings")
        check(!composer.canSend && composer.state.outcomeUnknown, "S2 refresh click does not optimistically resolve unknown send")
        composer.layoutSubtreeIfNeeded()
        check(!composer.historyRefreshButton.isHidden && !composer.historyRefreshButton.isEnabled, "S2 recovery is visible and disabled while loading")
        check(composer.historyRefreshButton.accessibilityLabel() == "Refresh history" && composer.historyRefreshButton.toolTip?.contains("unknown") == true, "S2 recovery exposes its native AX label and real error help")
        composer.state.loading = false; composer.state.outcomeUnknown = false; composer.state.operationError = nil
        composer.layoutSubtreeIfNeeded()
        check(composer.historyRefreshButton.isHidden && composer.canSend, "S2 acknowledged clean state restores normal controls")
        composer.state.operationError = "Read failed"; composer.onRefreshHistory = nil; composer.layoutSubtreeIfNeeded()
        check(!composer.historyRefreshButton.isHidden && !composer.historyRefreshButton.isEnabled && composer.historyRefreshButton.toolTip!.contains("not connected"), "S2 uninstalled host exposes honest disabled recovery")
        composer.state.operationError = nil; composer.state.running = true; composer.onStopRequest = nil
        var legacy = 0; composer.onStop = { legacy += 1 }
        check(composer.requestStop() && legacy == 1, "S2 legacy stop API remains callable")
        composer.completeStopRequest(); check(!composer.hasPendingStop, "S2 legacy explicit acknowledgement remains callable")
        composer.state.operationError = "Read failed"; composer.onRefreshHistory = {}
        for mode in [NativeComposerLayout.fullBar, .growing] {
            for width: CGFloat in [340, 1080] {
                composer.layoutMode = mode; composer.targetWidth = width
                composer.frame.size = CGSize(width: width, height: mode == .fullBar ? 48 : 120)
                composer.layoutSubtreeIfNeeded()
                let compact = width < 620
                check(composer.historyRefreshButton.imagePosition == (compact ? .imageOnly : .imageLeading), "S2 recovery icon/text do not overlap at \(width) \(mode)")
                check(!composer.historyRefreshButton.isHidden && composer.bounds.contains(composer.historyRefreshButton.frame), "S2 recovery remains inside both narrow/wide layouts at \(width) \(mode)")
            }
        }
        composer.onRefreshHistory = nil
    }
}
#endif
