import Foundation

/// Product installSkillFolder's local copy/discovery path. Caller must prove the connected Core is local first.
/// No default backend path: the destination comes exclusively from that Core's writable config layer.
@MainActor enum CoreSkillFolderInstaller {
    static func install(source:URL,configPath:String,refresh:() async throws -> JSONValue) async throws -> JSONValue {
        let manager=FileManager.default
        var directory:ObjCBool=false
        guard source.isFileURL,manager.fileExists(atPath:source.path,isDirectory:&directory),directory.boolValue,
              manager.fileExists(atPath:source.appendingPathComponent("SKILL.md").path) else { throw CoreWire.failure("Choose a skill folder containing SKILL.md.") }
        guard configPath.hasPrefix("/"),!source.lastPathComponent.isEmpty else { throw CoreWire.failure("The connected local Core has no writable config path.") }
        let root=URL(fileURLWithPath:configPath).deletingLastPathComponent().appendingPathComponent("skills",isDirectory:true)
        let destination=root.appendingPathComponent(source.lastPathComponent,isDirectory:true)
        guard !manager.fileExists(atPath:destination.path) else { throw CoreWire.failure("A skill folder with this name already exists. No files were replaced.") }
        try manager.createDirectory(at:root,withIntermediateDirectories:true)
        try manager.copyItem(at:source,to:destination)
        let result=try await refresh()
        let discovered=(result["data"]?.arrayValue ?? []).flatMap { $0["skills"]?.arrayValue ?? [] }
            .contains { $0["path"]?.stringValue == destination.appendingPathComponent("SKILL.md").path }
        guard discovered else { throw CoreWire.failure("The folder was copied, but the backend has not discovered its skill. Check the skill's format and refresh.") }
        return result
    }
}
