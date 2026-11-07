extension CoreSubmission {
    /// The composer's snapshot as Core's, field by field, with its UUID.
    init(_ s: NativeComposerSubmission) {
        let action: CoreSubmissionAction
        switch s.action { case .send: action = .send; case .steer: action = .steer; case .queue: action = .queue }
        self.init(id: s.id, identity: s.identity, action: action, text: s.text, attachments: s.attachments,
                  settings: s.settings, access: s.access, waitingForTurnID: s.waitingForTurnID)
    }
}

extension NativeComposerCompletion {
    init(_ r: CoreSubmissionResult) {
        switch r {
        case .accepted: self = .accepted
        case .failed(let m): self = .failed(m)
        case .outcomeUnknown(let m): self = .outcomeUnknown(m)
        }
    }
}
