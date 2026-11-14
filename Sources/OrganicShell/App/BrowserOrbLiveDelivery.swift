import AppKit

/// The destination is fixed at invocation, exactly like Tools' screenshot-to-draft delivery.
@MainActor enum BrowserLiveDelivery {
    static func attachPage(from window:OrganicWindow,source:LiveBrowserSource) async {
        guard let app=window.browserApp else {return}
        let destinationID=window.shell.mode == .normie ? window.workbench.selectedConversation?.id:window.scene.current
        guard let destinationID,let conversation=app.store.conversation(destinationID),!conversation.archived else {
            source.reportIssue("Choose a foreground conversation before attaching this page.");return
        }
        do {
            let capture=try await source.capture(threadID:conversation.backendThreadID)
            guard !Task.isCancelled,!window.isClosed,source.isCurrent(capture),let input=capture.uploaded["input"] else {return}
            let metadata=String(data:try JSONEncoder().encode(capture.metadata),encoding:.utf8) ?? ""
            let attachments=[Attachment(id:"browser:"+(capture.uploaded["id"]?.stringValue ?? UUID().uuidString),
                name:"Browser screenshot",symbol:"photo",input:input,mimeType:"image/png"),
                Attachment(id:UUID().uuidString,name:"Browser source",symbol:"link",
                    input:["type":"text","text":.string("Browser screenshot source: "+metadata)])]
            app.deliver(.init(destinationID:destinationID,attachments:attachments,send:false)) { result in
                if case .failed(let message)=result {source.reportIssue(message)}
            }
        } catch {
            if !Task.isCancelled {source.reportIssue(error.localizedDescription)}
        }
    }
}
