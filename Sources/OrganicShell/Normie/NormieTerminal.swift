import AppKit
import SwiftUI

/// Product TerminalPane history, retained per conversation. This model has no process/transport API.
@MainActor final class NormieMockTerminal {
    struct Entry:Equatable {var command:String,output:String}
    private(set) var entries:[Entry]=[]
    private var source:[TranscriptItem]=[],suppressed:Set<String>=[]
    var input=""
    private(set) var revision=0
    func refresh(_ conversation:Conversation){let next=conversation.items.filter{$0.rowKind == .tool(.command)};if source != next{source=next;revision+=1}}
    var history:[Entry]{Array(source.filter{!suppressed.contains($0.id)}.suffix(8)).map{item in let lines=item.text.split(separator:"\n",maxSplits:1,omittingEmptySubsequences:false);return Entry(command:String(lines.first ?? ""),output:lines.count>1 ? String(lines[1]):"")}+entries}
    @discardableResult func submit(_ value:String)->Bool {
        let command=value.trimmingCharacters(in:.whitespacesAndNewlines);input="";guard !command.isEmpty else{return false}
        if command == "clear"{clear();return true}
        entries.append(.init(command:command,output:"zsh: the prototype runs nothing; ask Codex in the chat instead."));revision+=1;return true
    }
    func clear(){suppressed.formUnion(source.map(\.id));entries=[];revision+=1}
    static func folder(_ name:String?)->String{(name ?? "chats").lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber}).joined(separator:"-")}
    static func visible(_ text:String)->String{String(text.unicodeScalars.filter{$0.value>=32 || $0 == "\n" || $0 == "\t"})}
    func text(folder:String,branch:String)->String{history.map{"\(folder) (\(branch)) $ "+Self.visible($0.command)+( $0.output.isEmpty ? "":"\r\n"+Self.visible($0.output).replacingOccurrences(of:"\n",with:"\r\n"))}.joined(separator:"\r\n")}
}

struct NormieTerminalMotion {
    static let response=0.32,damping=0.88
    var start=0.0,target=0.0,velocity=0.0
    var duration:Double=0
    init(start:Double=0,target:Double=0,velocity:Double=0){self.start=start;self.target=target;self.velocity=velocity;duration=Spring(from:start,to:target,velocity:velocity,response:Self.response,damping:Self.damping,epsilon:0.025/220).duration}
    func value(at time:Double)->Double{if time>=duration{return target};return start+(target-start)*SwiftUI.Spring(response:Self.response,dampingRatio:Self.damping).value(target:1,initialVelocity:abs(target-start)>1e-9 ? velocity/(target-start):0,time:max(0,time))}
    func speed(at time:Double)->Double{(target-start)*SwiftUI.Spring(response:Self.response,dampingRatio:Self.damping).velocity(target:1,initialVelocity:abs(target-start)>1e-9 ? velocity/(target-start):0,time:max(0,time))}
    static func height(available:CGFloat)->CGFloat{min(220,max(0,available-240))}
}

/// Owns only the pane. Hiding never closes a CoreTerminalSession or steals another responder's focus.
@MainActor final class NormieTerminalPane:NativeInteractionSurface,NSTextFieldDelegate {
    let shell=NormieDrawing.label("zsh",size:12,weight:.semibold),location=NormieDrawing.label(size:11)
    let add=NormieButton(),closeButton=NormieButton(),prompt=NormieDrawing.label(size:12),inputField=NormieField()
    let sessionPicker=NativeComposerMenuButton(frame:.zero),endButton=NormieButton(),reconnectButton=NormieButton()
    private(set) var mock:NormieMockTerminal?
    private(set) var terminal:ToolsTerminalView?
    private var mocks:[String:NormieMockTerminal]=[:],renderers:[String:ToolsTerminalView]=[:]
    private var surfaces:[UUID:ToolsTerminalSurface]=[:],surface:ToolsTerminalSurface?
    private var renderedRevision:[String:Int]=[:]
    private var conversation:Conversation?,store:ConversationStore?
    private weak var controller:CoreTerminalController?
    private var controllerObservation:UUID?,openTask:Task<Void,Never>?,epoch=0
    private var sessionTask:Task<Void,Never>?
    var onMotionContentChange:(()->Void)?
    var motionContentKey:String{
        if let c=conversation,let s=controller?.active(for:c.id){return "\(c.id)/\(s.backendID ?? "")/\(s.sequence)/\(s.title)/\(s.cwd)"}
        return "\(conversation?.id ?? "")/\(mock?.revision ?? 0)/\(mock?.input ?? "")"
    }
    private weak var motionSession:CoreTerminalSession?
    private var motionOutputObservation:UUID?
    func watchMotionOutput(_ active:Bool){
        if let motionOutputObservation{motionSession?.removeOutputObserver(motionOutputObservation)};motionOutputObservation=nil;motionSession=nil
        if active,let c=conversation,let session=controller?.active(for:c.id){motionSession=session;motionOutputObservation=session.observeOutput{[weak self] _ in self?.onMotionContentChange?()}}
    }
    private let status=NormieDrawing.label(size:11),openButton=NormieButton()
    var onClose:(()->Void)?
    override init(frame:NSRect){
        super.init(frame:frame);setAccessibilityLabel("Terminal panel");setAccessibilityRole(.group)
        for v in [shell,location,add,closeButton,prompt,inputField,status,openButton,sessionPicker,endButton,reconnectButton]{addSubview(v)}
        sessionPicker.setAccessibilityLabel("Terminal session");sessionPicker.font = .systemFont(ofSize:12,weight:.semibold)
        endButton.image=NSImage(systemSymbolName:"stop.circle",accessibilityDescription:"End this terminal session");endButton.toolTip="End this terminal session";endButton.setAccessibilityLabel("End this terminal session");endButton.run={[weak self] in self?.endActiveSession()}
        reconnectButton.title="Reconnect";reconnectButton.setAccessibilityLabel("Reconnect terminal");reconnectButton.run={[weak self] in self?.reconnectActiveSession()}
        location.font = .monospacedSystemFont(ofSize:11,weight:.regular);location.textColor = NativePalette.secondaryLabel;location.lineBreakMode = .byTruncatingMiddle
        add.image=NSImage(systemSymbolName:"plus",accessibilityDescription:"New Terminal");add.toolTip="New Terminal (prototype)";add.isEnabled=false
        closeButton.image=NSImage(systemSymbolName:"xmark",accessibilityDescription:"Close Terminal");closeButton.toolTip="Close Terminal (⌘J)";closeButton.setAccessibilityLabel("Close Terminal");closeButton.run={[weak self] in self?.onClose?()}
        inputField.font = .monospacedSystemFont(ofSize:12,weight:.regular);inputField.delegate=self;inputField.target=self;inputField.action=#selector(submitInput);inputField.setAccessibilityLabel("Terminal input (prototype)")
        prompt.font=inputField.font;openButton.title="Open Terminal";openButton.run={[weak self] in self?.openLiveTerminal()};add.run={[weak self] in self?.openLiveTerminal()}
        status.maximumNumberOfLines=0;status.lineBreakMode = .byWordWrapping
        presentationActive=false
    }
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    isolated deinit{openTask?.cancel();sessionTask?.cancel();if let controllerObservation{controller?.removeObserver(controllerObservation)};if let motionOutputObservation{motionSession?.removeOutputObserver(motionOutputObservation)}}
    func setController(_ next:CoreTerminalController?){if let controllerObservation{controller?.removeObserver(controllerObservation)};controllerObservation=nil;controller=next
        if let next{controllerObservation=next.observe{[weak self] in self?.refresh()}};refresh()
    }
    func configure(_ c:Conversation?,store:ConversationStore){
        self.store=store
        if conversation?.id != c?.id{epoch+=1;openTask?.cancel();openTask=nil;sessionTask?.cancel();sessionTask=nil;invalidateAccessibilityLease();window?.endEditing(for:inputField);conversation=c;presentationContext=c?.id}
        else{conversation=c};refresh()
    }
    func refresh(){
        sessionPicker.isHidden=true;endButton.isHidden=true;reconnectButton.isHidden=true;shell.isHidden=false
        guard let c=conversation,let store else{renderers.values.forEach{$0.isHidden=true};surfaces.values.forEach{$0.isHidden=true};mock=nil;inputField.isHidden=true;prompt.isHidden=true;status.stringValue="Select a conversation to use its terminal.";status.isHidden=false;openButton.isHidden=true;return}
        let live=store.usesLiveCore || c.isLiveConversation
        let folder=NormieMockTerminal.folder(store.project(c.projectID)?.name)
        shell.stringValue="zsh";location.stringValue="~/\(folder) · \(c.branch)"
        prompt.stringValue="\(folder) (\(c.branch)) $";prompt.textColor = NativePalette.secondaryLabel
        inputField.isHidden=live;prompt.isHidden=live;openButton.isHidden=true;status.isHidden=true
        add.isEnabled=live && controller?.isConfigured == true;add.toolTip=live ? "New Terminal":"New Terminal (prototype)"
        if live {
            renderers.values.forEach{$0.isHidden=true};mock=nil;terminal=nil
            guard let controller,controller.isConfigured else{surfaces.values.forEach{$0.isHidden=true};surface=nil;status.stringValue="Live terminal is not connected. Provide CoreTerminalController; no prototype commands are executed.";status.isHidden=false;return}
            let sessions=controller.sessions(for:c.id)
            if let session=controller.active(for:c.id),sessions.contains(where:{$0.id == session.id}) {
                shell.isHidden=true;sessionPicker.isHidden=false;sessionPicker.removeAllItems();sessionPicker.addItem(withTitle:session.title)
                let menuEpoch=presentationEpoch,conversationID=c.id
                for (index,item) in sessions.enumerated(){let choice=NormieMenuItem("\(index+1). \(item.title)"){[weak self] in guard let self,self.presentationEpoch == menuEpoch,self.conversation?.id == conversationID else{return};_ = self.selectSession(item.id)};choice.state=item.id == session.id ? .on:.off;sessionPicker.menu?.addItem(choice)}
                endButton.isHidden = !session.running;endButton.isEnabled=sessionTask == nil
                for (id,view) in surfaces where id != session.id{view.isHidden=true}
                let next=surfaces[session.id] ?? ToolsTerminalSurface(frame:.zero);surfaces[session.id]=next;surface=next
                if next.superview == nil{addSubview(next,positioned:.below,relativeTo:shell)};next.bind(session);next.isHidden=false
                shell.stringValue=session.title;location.stringValue=session.cwd
                if let error=session.error{status.stringValue=error;status.isHidden=false;reconnectButton.isHidden=false;reconnectButton.title="Reconnect";reconnectButton.isEnabled=sessionTask == nil}
            } else{surfaces.values.forEach{$0.isHidden=true};surface=nil;status.stringValue=controller.restorationError ?? "No terminal session. Open one explicitly to use Live terminal.";status.isHidden=false;openButton.isHidden=false
                if controller.restorationError != nil{reconnectButton.isHidden=false;reconnectButton.title="Retry";reconnectButton.isEnabled=sessionTask == nil}
            }
        } else {
            surfaces.values.forEach{$0.isHidden=true};for (id,view) in renderers where id != c.id{view.isHidden=true}
            let next=mocks[c.id] ?? NormieMockTerminal();mocks[c.id]=next;mock=next;next.refresh(c)
            let renderer=renderers[c.id] ?? ToolsTerminalView(frame:CGRect(x:0,y:0,width:720,height:160));renderers[c.id]=renderer;terminal=renderer
            if renderer.superview == nil{addSubview(renderer,positioned:.below,relativeTo:shell)};renderer.isHidden=false;renderer.setAccessibilityLabel("Mock terminal command history");renderer.setAccessibilityHelp("Prototype only. No commands are executed. Use Terminal input below.")
            renderer.onInput={[weak self] text in self?.receiveMockInput(text)}
            if inputField.currentEditor() == nil{inputField.stringValue=next.input}
            if renderedRevision[c.id] != next.revision{renderer.feed(next.text(folder:folder,branch:c.branch),reset:true);renderedRevision[c.id]=next.revision}
        }
        needsLayout=true;needsDisplay=true;onMotionContentChange?()
    }
    @discardableResult func selectSession(_ id:UUID)->Bool {
        guard isPresentationVisible,let c=conversation,let controller,store?.usesLiveCore == true || c.isLiveConversation else{return false}
        guard controller.sessions(for:c.id).contains(where:{$0.id == id})else{return false}
        controller.selected[c.id]=id;refresh();return true
    }
    func endActiveSession(){
        guard isPresentationVisible,let c=conversation,store?.usesLiveCore == true || c.isLiveConversation,let session=controller?.active(for:c.id),session.running,sessionTask == nil else{return}
        let epoch=epoch;sessionTask=Task{[weak self] in await session.close();guard let self,self.epoch == epoch else{return};sessionTask=nil;refresh()};refresh()
    }
    func reconnectActiveSession(){
        guard isPresentationVisible,let c=conversation,store?.usesLiveCore == true || c.isLiveConversation,let controller,sessionTask == nil else{return}
        let session=controller.active(for:c.id),epoch=epoch
        sessionTask=Task{[weak self,weak controller] in if let session,session.backendID != nil{await session.catchUp()}else{_ = await controller?.restore()};guard let self,self.epoch == epoch else{return};sessionTask=nil;refresh()};refresh()
    }
    var isComposing:Bool{(inputField.currentEditor() as? NSTextView)?.hasMarkedText() ?? false}
    func controlTextDidChange(_ obj:Notification){mock?.input=inputField.stringValue}
    @objc private func submitInput(){guard presentationActive,!isHiddenOrHasHiddenAncestor,let mock else{return};_ = mock.submit(inputField.stringValue);inputField.stringValue="";refresh()}
    @discardableResult func runMock(_ command:String)->Bool{guard presentationActive,let mock else{return false};let result=mock.submit(command);inputField.stringValue="";refresh();return result}
    private func receiveMockInput(_ text:String){guard presentationActive,!isHiddenOrHasHiddenAncestor,let mock else{return}
        switch text{case "\r","\n":_ = runMock(mock.input);case "\u{7f}":if !mock.input.isEmpty{mock.input.removeLast()};case "\u{3}","\u{15}":mock.input="";case "\u{c}":mock.clear();refresh();default:if !text.contains("\u{1b}"){mock.input+=text}}
        inputField.stringValue=mock.input
        onMotionContentChange?()
    }
    /// User action only. configure/show never starts a backend request.
    func openLiveTerminal(){guard presentationActive,let controller,controller.isConfigured,let c=conversation,store?.usesLiveCore == true || c.isLiveConversation,openTask == nil else{return};let epoch=epoch
        openTask=Task{[weak self,weak controller] in guard let self,let controller else{return};_ = await controller.open(for:c,cwd:c.cwd ?? store?.project(c.projectID)?.path);guard self.epoch == epoch else{return};openTask=nil;refresh()}
    }
    func dispose(){watchMotionOutput(false);onMotionContentChange=nil;epoch+=1;openTask?.cancel();openTask=nil;sessionTask?.cancel();sessionTask=nil;setController(nil);presentationActive=false;renderers.values.forEach{$0.onInput=nil};surface=nil;terminal=nil;mock=nil;conversation=nil;store=nil;surfaces=[:];renderers=[:];mocks=[:];renderedRevision=[:];subviews.filter{$0 is ToolsTerminalView || $0 is ToolsTerminalSurface}.forEach{$0.removeFromSuperview()}}
    override func layout(){super.layout();let s=window?.backingScaleFactor ?? 2;func place(_ v:NSView,_ r:CGRect){v.frame=NormieDrawing.rect(r,scale:s)}
        place(shell,CGRect(x:14,y:8,width:80,height:18));place(location,CGRect(x:95,y:9,width:max(1,bounds.width-175),height:17));place(add,CGRect(x:bounds.width-65,y:3,width:26,height:26));place(closeButton,CGRect(x:bounds.width-34,y:3,width:26,height:26))
        place(sessionPicker,CGRect(x:14,y:3,width:min(180,max(80,bounds.width*0.28)),height:26));place(endButton,CGRect(x:bounds.width-96,y:3,width:26,height:26))
        if !sessionPicker.isHidden{place(location,CGRect(x:sessionPicker.frame.maxX+8,y:9,width:max(1,bounds.width-104-sessionPicker.frame.maxX-8),height:17))}
        let bottom:CGFloat=mock == nil ? 0:30
        if let terminal{place(terminal,CGRect(x:0,y:33,width:bounds.width,height:max(1,bounds.height-33-bottom)))}
        if let surface{place(surface,CGRect(x:0,y:status.isHidden ? 33:62,width:bounds.width,height:max(1,bounds.height-(status.isHidden ? 33:62))))}
        let p=ceil((prompt.stringValue as NSString).size(withAttributes:[.font:prompt.font!]).width)+7
        place(prompt,CGRect(x:14,y:bounds.height-24,width:min(p,bounds.width/2),height:20));place(inputField,CGRect(x:min(p,bounds.width/2)+14,y:bounds.height-24,width:max(1,bounds.width-min(p,bounds.width/2)-28),height:20))
        place(status,CGRect(x:14,y:surface?.isHidden == false ? 34:45,width:max(1,bounds.width-(reconnectButton.isHidden ? 28:132)),height:surface?.isHidden == false ? 28:62));place(openButton,CGRect(x:14,y:112,width:150,height:28));place(reconnectButton,CGRect(x:bounds.width-112,y:surface?.isHidden == false ? 34:48,width:98,height:26))
    }
    override func draw(_ dirtyRect:NSRect){NSColor(white:0.055,alpha:1).setFill();bounds.fill();NSColor.separatorColor.setFill();CGRect(x:0,y:0,width:bounds.width,height:1).fill();CGRect(x:0,y:32,width:bounds.width,height:1).fill()}
}
