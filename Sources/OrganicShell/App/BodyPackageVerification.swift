import AppKit
import QuartzCore
import CryptoKit

/// A fresh-process resource startup sample; it never orders a window or starts the app controller.
@MainActor enum BodyPackageVerification {
    static func run(to path: String) -> Int32 {
        let out=URL(fileURLWithPath:path)
        do {
            try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
            let start=CACurrentMediaTime(),resources=BodyResources.shared,indexReady=CACurrentMediaTime()
            let before=resources.archive?.framesRead ?? 0,encodedBefore=resources.archive?.encodedBytesRead ?? 0
            let image=resources.image(bodyID:"saturn",outer:48,scale:2),firstReady=CACurrentMediaTime()
            let firstRead=(resources.archive?.framesRead ?? 0)-before
            _=resources.image(bodyID:"saturn",outer:48,scale:2)
            let unchanged=(resources.archive?.framesRead ?? 0)-before == firstRead
            let noWindows=NSApp.windows.allSatisfy { !$0.isVisible }
            let pixels: Data
            if let data=image?.dataProvider?.data { pixels=data as Data } else { pixels=Data() }
            let pixelHash=SHA256.hash(data:pixels).map { String(format:"%02x",$0) }.joined()
            let report:[String:Any]=["layout":resources.archive?.index.layout.rawValue ?? "missing",
                "resourceInitMilliseconds":(indexReady-start)*1000,"firstFrameMilliseconds":(firstReady-indexReady)*1000,
                "firstFrameReads":firstRead,"firstFrameEncodedBytes":(resources.archive?.encodedBytesRead ?? 0)-encodedBefore,
                "decodedBytes":resources.sprites.residentBytes,"imageWidth":image?.width ?? 0,"imageSHA256":pixelHash,
                "unchangedLookupReadsNoFrame":unchanged,"noVisibleWindows":noWindows,
                "scope":"Fresh app process and one independent PNG decode; no visible startup or WindowServer claim"]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("startup.json"))
            print("BODY PACKAGE",report)
            return image?.width == 96 && firstRead == 1 && unchanged && noWindows ? 0:1
        } catch { print("BODY PACKAGE FAILED",error); return 1 }
    }
}
