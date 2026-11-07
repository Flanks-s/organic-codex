import Foundation

/// Machine-local instance proof, not authentication. Loopback addresses and remote paths are not proof.
struct CoreLocalIdentity: Equatable, Sendable {
    let verified: Bool
    init(health envelope: JSONValue, localMarker: JSONValue?, dataDirectory: URL) {
        let health = envelope["result"] ?? envelope
        let instance = localMarker?["instanceId"]?.stringValue, pid = localMarker?["pid"]?.intValue
        verified = health["name"]?.stringValue == "Organic Codex Core" && health["backendConnected"]?.boolValue == true
            && instance?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && pid.map { $0 > 0 } == true
            && localMarker?["instanceId"] == health["instanceId"] && localMarker?["pid"] == health["pid"]
            && health["dataDir"]?.stringValue == dataDirectory.path
    }
    /// Authorized production bootstrap only. Tests use the value-only initializer.
    init(health: JSONValue, dataDirectory: URL) {
        let marker = (try? Data(contentsOf: dataDirectory.appendingPathComponent("runtime-instance.json"))).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        self.init(health: health, localMarker: marker, dataDirectory: dataDirectory)
    }
}
