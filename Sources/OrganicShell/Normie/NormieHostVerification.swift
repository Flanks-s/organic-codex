#if NORMIE_SELFTEST
import AppKit

@MainActor enum NormieHostVerification {
    static func run(_ check:(Bool,String)->Void) {
        let c=Conversation(id:"host-inspector",title:"Host inspector")
        c.changes=[FileChange(path:"Sources/View.swift",added:2,removed:1,lines:[])]
        let store=ConversationStore(conversations:[c],devices:MockSeed.devices)
        let workbench=NormieWorkbench(store:store,sessions:NativeComposerSessions(),current:c.id)
        _ = workbench.select(c.id)
        var requests:[Bool]=[],stateAtRequest:[Bool]=[],tabAtRequest:[NormieInspectorController.Tab]=[]
        workbench.onInspectorRequest={shown in
            requests.append(shown);stateAtRequest.append(workbench.inspectorVisible);tabAtRequest.append(workbench.inspector.tab)
        }
        workbench.reviewChanges()
        check(!workbench.isViewLoaded,"host inspector does not load a second split")
        check(requests == [true] && stateAtRequest == [true],"Review requests host show with committed state")
        check(tabAtRequest == [.changes],"Review selects Changes before host request")
        workbench.detail.composer?.onContext?()
        check(requests == [true,true] && tabAtRequest == [.changes,.status],"ordinary composer context requests host Status")
        workbench.perform(.inspector)
        check(requests.last == false && !workbench.inspectorVisible,"standalone command uses host hide callback")
        workbench.requestInspector(shown:true)
        check(requests.last == true && workbench.menuContext.inspectorVisible,"explicit host show synchronizes menu state")
        _ = workbench.select(c.id);workbench.detail.composer?.refresh()
        check(requests.count == 4,"selection and refresh do not request another inspector toggle")
        workbench.onInspectorRequest=nil
        _ = workbench.view
        let split=workbench.children.first as! NSSplitViewController
        workbench.requestInspector(shown:false)
        check(split.splitViewItems.last!.isCollapsed && !workbench.inspectorVisible,"no hook falls back to standalone split hide")
        workbench.reviewChanges()
        check(!split.splitViewItems.last!.isCollapsed && workbench.inspectorVisible,"no hook Review opens standalone inspector")
        workbench.detail.composer?.onContext?()
        check(!split.splitViewItems.last!.isCollapsed && workbench.inspector.tab == .status,"no hook context opens standalone Status")

        // Host-owned composer handlers stay in place on retained sessions.
        let owned=NativeComposerSessions(),composer=owned.composer(for:c,store:store)
        var ownedContext=0;composer.onContext={ownedContext+=1}
        let second=NormieWorkbench(store:store,sessions:owned,current:c.id)
        _ = second.select(c.id)
        composer.onContext?()
        check(ownedContext == 1,"workbench preserves an existing host context handler")

        // An externally restored chat invalidates the native Undo token too; an older valid entry still works.
        let a=Conversation(id:"host-undo-a",title:"Older archive"),b=Conversation(id:"host-undo-b",title:"Restored elsewhere")
        let archiveStore=ConversationStore(conversations:[a,b],devices:MockSeed.devices)
        let undo=NormieWorkbench(store:archiveStore,sessions:NativeComposerSessions(),current:a.id)
        undo.sidebarModel.archive(a.id);undo.sidebarModel.archive(b.id)
        b.archived=false;b.archivedAt=nil;archiveStore.changed(b)
        check(undo.sidebarModel.canUndoArchive && undo.archiveUndoManager.canUndo,"external restore keeps older valid archive Undo")
        check(undo.undoArchive() && !a.archived && !b.archived,"Undo after external restore targets older archive")
        check(!undo.archiveUndoManager.canUndo,"successful Undo removes its own native token")
        undo.sidebarModel.archive(a.id);undo.sidebarModel.archive(b.id)
        check(undo.undoArchive() && undo.archiveUndoManager.canUndo,"synchronous refresh during Undo preserves next native token")
        check(undo.undoArchive() && !undo.archiveUndoManager.canUndo,"multiple archive Undo entries remain LIFO")
        undo.sidebarModel.archive(a.id);undo.notice("Keep this newer notice")
        a.archived=false;archiveStore.changed(a)
        func containsNotice(_ view:NSView)->Bool {
            ((view as? NormieLabel)?.stringValue == "Keep this newer notice" && !view.isHiddenOrHasHiddenAncestor) || view.subviews.contains(where:containsNotice)
        }
        check(containsNotice(undo.detail.view),"invalidating archive Undo preserves a newer unrelated notice")
        undo.dispose();second.dispose();workbench.dispose()
        check(workbench.onInspectorRequest == nil,"dispose withdraws inspector host callback")
    }
}
#endif
