import Foundation

/// Prepared bytes/input and annotation provenance only. App owns merging into its retained composer and sending.
struct CoreArtifactDelivery: Sendable {
    let id:UUID
    let destinationID:String
    let attachments:[Attachment]
    let artifact:CoreArtifact?
    let annotations:[JSONValue]
    let send:Bool
    init(id:UUID=UUID(),destinationID:String,attachments:[Attachment],artifact:CoreArtifact?=nil,annotations:[JSONValue]=[],send:Bool) {
        self.id=id; self.destinationID=destinationID; self.attachments=attachments; self.artifact=artifact; self.annotations=annotations; self.send=send
    }
    @MainActor func composeDraft(current:String)->String {
        artifact.map { CoreArtifactsController.envelope(artifact:$0,annotations:annotations,request:current) } ?? current
    }
}
