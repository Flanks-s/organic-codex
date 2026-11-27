import AppKit
import QuartzCore
import CryptoKit

/// Same fixed event corpus is compiled against B0 and the candidate. No HD opt-in.
@main @MainActor enum CompactPhaseProbe {
    static func wait(_ predicate: () -> Bool) async -> Bool {
        let end = CACurrentMediaTime() + 8
        while !predicate() && CACurrentMediaTime() < end { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }
    static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let resources = BodyResources()
        var rows: [[String: Any]] = [], failures: [String] = []
        for body in ["mercury", "venus", "earth", "saturn", "pluto"] {
            for state in BodyPhaseState.allCases { for scale in [1, 2] { for size in [12, 32, 56] {
                let id = "compact/\(body)/\(state.rawValue)/\(size)/\(scale)"
                let endpoint = BodyPhasePresentation(resources: resources)
                let event = BodyPhaseEvent(sourceID: id, value: .init(state, fraction: 0.37), serial: 17,
                    animate: false)
                endpoint.configure(event: event, bodyID: body, outer: CGFloat(size), scale: scale,
                                   animate: false, samplingOuter: size == 32 ? 44 : size == 56 ? 64 : nil)
                let admittedHD = resources.hdReservedBytes, admittedSprite = resources.sprites.residentBytes
                let ready = await wait { endpoint.image != nil && endpoint.work["pending"] == 0 }
                let work = endpoint.work
                try? await Task.sleep(for: .milliseconds(20))
                let steady = work == endpoint.work
                let image = endpoint.image, bytes = image?.dataProvider?.data as Data?
                let hash = bytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "missing"
                var row: [String: Any] = ["id": id, "ready": ready, "steady": steady, "width": image?.width ?? -1,
                    "sha256": hash, "work": work, "admittedHD": admittedHD, "admittedSprite": admittedSprite,
                    "residentHD": resources.hdReservedBytes, "residentSprite": resources.sprites.residentBytes,
                    "mapBytes": await resources.queue?.residentBytes ?? -1]
                endpoint.dispose()
                let released = await wait { resources.hdReservedBytes == 0 && BodyPhaseStream.activeJobs == 0 }
                row["released"] = released; row["retiredHD"] = resources.hdReservedBytes
                row["retiredSprite"] = resources.sprites.residentBytes; row["retiredJobs"] = BodyPhaseStream.activeJobs
                if !ready || !steady || !released { failures.append(id) }
                rows.append(row)
            } } }
        }
        var hostRows: [[String: Any]] = []
        for kind in ["small-orb", "dock", "column-header"] { for scale in [1,
                2] { for state in BodyPhaseState.allCases {
            let id = "host/\(kind)/\(scale)/\(state.rawValue)"
            let event = BodyPhaseEvent(sourceID: id, value: .init(state, fraction: 0.37), serial: 17, animate: false)
            let header = kind == "column-header" ? HeaderIsland() : nil
            let orb = header?.orb ?? OrbComponent(id: id)
            if let header {
                var config = HeaderIslandConfiguration(id: id, title: "Compact baseline")
                config.bodyPhase = event
                config.reduceMotion = true
                config.ambient = false
                config.scale = CGFloat(scale)
                header.configure(config)
            } else {
                var config = OrbConfiguration(content: .identity(.assigned(0)), drawingSize: kind == "dock" ? 32 : 12)
                config.bodyPhase = event
                config.reduceMotion = true
                config.ambient = false
                config.backingScale = CGFloat(scale)
                orb.configure(config)
            }
            func picture() -> CGImage? {
                BodyWiringVerification.image(BodyWiringVerification.layers(orb.glassView).first {
                        $0.name == "organic.body.phase" })
            }
            let admittedHD = BodyResources.shared.hdReservedBytes,
                admittedSprite = BodyResources.shared.sprites.residentBytes
            let ready = await wait { picture() != nil && orb.bodyWork["pending"] == 0 }
            let work = orb.bodyWork, image = picture(), data = image?.dataProvider?.data as Data?
            let hash = data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "missing"
            try? await Task.sleep(for: .milliseconds(20))
            let steady = work == orb.bodyWork
            var row: [String: Any] = ["id": id, "ready": ready, "steady": steady, "width": image?.width ?? -1,
                "sha256": hash, "work": work, "admittedHD": admittedHD, "admittedSprite": admittedSprite,
                "residentHD": BodyResources.shared.hdReservedBytes,
                    "residentSprite": BodyResources.shared.sprites.residentBytes,
                "mapBytes": await BodyResources.shared.queue?.residentBytes ?? -1]
            orb.dispose()
            let released = await wait { BodyResources.shared.hdReservedBytes == 0 && BodyPhaseStream.activeJobs == 0 }
            row["released"] = released; row["retiredHD"] = BodyResources.shared.hdReservedBytes
            row["retiredSprite"] = BodyResources.shared.sprites.residentBytes
            row["retiredJobs"] = BodyPhaseStream.activeJobs
            if !ready || !steady || !released { failures.append(id) }
            hostRows.append(row)
        } } }
        let rates = [Float(12), 26, 32, 36, 37, 56].flatMap { outer in
            [1, 4, 5, 8, 9].map { active in
                ["outer": Double(outer), "active": Double(active), "fps": BodyPhaseStream.samplingRate(outer: outer,
                        active: active)]
            }
        }
        let report: [String: Any] = ["seed": 17, "rows": rows, "hostRows": hostRows, "samplingRates": rates,
            "checks": (rows.count + hostRows.count) * 3, "failures": failures,
                "visibleWindows": NSApp.windows.filter(\.isVisible).count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,
                .sortedKeys]).write(to: out.appendingPathComponent("report.json"))
        print("Compact fixed corpus: \((rows.count + hostRows.count) * 3) checks, \(failures.count) failures")
        exit(failures.isEmpty ? 0 : 1)
    }
}
