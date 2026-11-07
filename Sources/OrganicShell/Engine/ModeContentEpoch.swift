import AppKit

@MainActor enum ModeContentEpoch {
    static func copy(_ source:Conversation)->Conversation {
        let result=Conversation(id:source.id,title:source.title)
        result.isLiveConversation=source.isLiveConversation
        result.backendThreadID=source.backendThreadID
        result.activeTurnID=source.activeTurnID
        result.notices=source.notices
        result.cwd=source.cwd
        result.historyLoaded=source.historyLoaded
        result.loading=source.loading
        result.operationError=source.operationError
        result.sendOutcomeUnknown=source.sendOutcomeUnknown
        result.userInput=source.userInput
        result.exactTokensUsed=source.exactTokensUsed
        result.contextLimit=source.contextLimit
        result.identityIndex=source.identityIndex
        result.identitySymbol=source.identitySymbol
        result.identityTint=source.identityTint
        result.projectID=source.projectID
        result.deviceID=source.deviceID
        result.updated=source.updated
        result.pinned=source.pinned
        result.archived=source.archived
        result.archivedAt=source.archivedAt
        result.changes=source.changes
        result.branch=source.branch
        result.gitRoot=source.gitRoot
        result.gitDiffHash=source.gitDiffHash
        result.gitPaths=source.gitPaths
        result.gitBusy=source.gitBusy
        result.gitError=source.gitError
        result.lastCommit=source.lastCommit
        result.plan=source.plan
        result.summaryIndex=source.summaryIndex
        result.items=source.items
        result.draft=source.draft
        result.access=source.access
        result.settings=source.settings
        result.next=source.next
        result.attachments=source.attachments
        result.queued=source.queued
        result.dictating=source.dictating
        result.voice=source.voice
        result.running=source.running
        result.sending=source.sending
        result.stopping=source.stopping
        result.stops=source.stops
        result.lastTurnInterrupted=source.lastTurnInterrupted
        result.approvals=source.approvals
        result.question=source.question
        result.error=source.error
        result.completions=source.completions
        result.unread=source.unread
        result.contextUsed=source.contextUsed
        result.compactions=source.compactions
        result.satellites=source.satellites
        result.satellitesRetired=source.satellitesRetired
        result.pace=source.pace
        result.redEvents=source.redEvents
        result.redSeen=source.redSeen
        result.revision=source.revision
        return result
    }
}
