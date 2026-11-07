import Foundation
import QuartzCore
import AppKit

/// Optional offline sink. Production builds do nothing unless the verifier explicitly sets M101_AUDIT_LOG.
@MainActor enum ReplicaAuditRecorder {
    static var scenario = "unlabelled"
    static var frame = 0
    private static var captured=Set<String>()
    static func sample(_ root: CALayer?, at time: Double, file: String = #filePath) {
        guard let path=ProcessInfo.processInfo.environment["M101_AUDIT_LOG"],let root else { return }
        let findings=ReplicaContainerAudit.inspect(root,scenario:scenario,frame:frame,time:time,sourceFile:file) { layer,finding in
            guard finding.active,finding.reason.contains("filled canvas"),let contents=layer.contents,
                  CFGetTypeID(contents as CFTypeRef)==CGImage.typeID else { return }
            let name=URL(fileURLWithPath:finding.file).deletingPathExtension().lastPathComponent
            let image=contents as! CGImage
            let key=name+"-\(image.width)x\(image.height)"
            guard captured.insert(key).inserted else { return }
            let directory=URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("container-textures")
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try? NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent(key+".png"))
        }
        let row: [String:Any] = ["scenario":scenario,"frame":frame,"time":time,"sourceFile":file,"findings":findings.map(\.fields)]
        frame += 1
        guard var data=try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath:path) { FileManager.default.createFile(atPath:path,contents:nil) }
        guard let handle=FileHandle(forWritingAtPath:path) else { return }
        handle.seekToEndOfFile();handle.write(data);try? handle.close()
    }
}
