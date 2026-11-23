import Foundation
import CryptoKit

struct BodyAssetManifest: Codable, Sendable {
    struct Asset: Codable, Sendable {
        let id,repositoryPath,sha256,canvasBlob,author,license,source,licenseURL: String
        let bytes: Int
        let observed: Bool
        let transformations:[String]
    }
    let version:Int
    let profile,sourcePolicy,provenanceNote:String
    let assets:[Asset]
    func validate(repository:URL)throws {
        guard profile == BodyProfile.current.version,assets.count == 16 else {throw BodyError.invalid("Manifest version/count mismatch")}
        for a in assets {
            guard !a.author.isEmpty,!a.transformations.isEmpty,a.license == "CC BY 4.0" || a.id == "pluto" && a.license == "Public domain (US); JPL Image Use Policy" else {throw BodyError.invalid("Unknown asset license")}
            let root=repository.standardizedFileURL,url=repository.appendingPathComponent(a.repositoryPath).standardizedFileURL
            guard url.path.hasPrefix(root.path+"/design/orrery/project/tex/") else {throw BodyError.invalid("Asset path escapes approved directory")}
            let data=try Data(contentsOf:url)
            let hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
            guard data.count == a.bytes,hash == a.sha256 else {throw BodyError.invalid("Asset checksum mismatch: \(a.id)")}
        }
    }
}
