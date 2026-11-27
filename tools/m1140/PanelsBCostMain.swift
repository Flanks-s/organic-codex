import AppKit
import QuartzCore

/// One invocation is one fresh process; no textures/maps/compiler are prewarmed.
@main @MainActor enum FunctionPanelBCost {
    static let coldHDCapMS = 200.0
    static var checks = 0, failures: [String] = []
    static func check(_ value: Bool, _ name: String) {
        checks += 1
        if !value { failures.append(name); print("FAIL: " + name) }
    }
    static func cost(_ row: [String: Any], scale: Int) {
        guard scale == 2, let kind = row["kind"] as? String, let times = row["seconds"] as? [String: Double] else {
            return }
        let iteration = (row["iteration"] as? Int).map(String.init) ?? "cold"
        func capped(_ metric: String, _ limitMS: Double, _ category: String) {
            let value = times[metric]
            check(value.map { $0.isFinite && $0 >= 0 && $0 * 1000 <= limitMS } == true,
                  "cost.cap." + category + "." + iteration)
        }
        if kind == "cold" {
            check(row["ready"] as? Bool == true, "cost.cap.cold-ready")
            capped("firstTexture", 120, "cold-texture")
            capped("firstHD", coldHDCapMS, "cold-HD")
        } else if kind == "warm" {
            check(row["ready"] as? Bool == true, "cost.cap.warm-ready." + iteration)
            capped("firstHD", 150, "warm-HD")
        } else if kind == "cold-close" || kind == "warm-close" {
            capped("released", 20, kind)
            let state = row["releaseState"] as? [String: Int]
            check(["HD", "imageTasks", "phaseJobs", "phasePending"].allSatisfy { state?[$0] == 0 },
                  "cost.cap.release-zero." + kind + "." + iteration)
        }
    }
    static func wait(_ predicate: () -> Bool) async -> Bool {
        let end = CACurrentMediaTime() + 16
        while !predicate() && CACurrentMediaTime() < end { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }
    static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let scale = Int(CommandLine.arguments[1])!, output = URL(fileURLWithPath: CommandLine.arguments[2])
        let requested = CACurrentMediaTime(), resources = BodyResources()
        let host = FunctionPanelTextureMockHost(resources: resources, scale: scale)
        _ = NativeViewBitmap.capture(host, scale: CGFloat(scale))
        let stage = CACurrentMediaTime() - requested
        let textureReady = await wait { host.owner.timings["firstTexture"] != nil || host.owner.currentPicture != nil }
        var firstTextureFrame: Double?
        if textureReady {
            _ = NativeViewBitmap.capture(host, scale: CGFloat(scale))
            firstTextureFrame = CACurrentMediaTime() - requested
        }
        let ready = await wait { host.owner.currentPicture?.quality == .panelHD && !host.owner.hasPendingWork }
        var cold = host.owner.timings.mapValues { $0 + host.owner.requestTime - requested }
        cold["stageFrame"] = stage; cold["firstTextureFrame"] = firstTextureFrame
        if ready {
            _ = NativeViewBitmap.capture(host, scale: CGFloat(scale))
            cold["firstHDFrame"] = CACurrentMediaTime() - requested
        }
        var peakHD = host.owner.peakHD
        let coldMap = host.owner.peakMap
        var samples: [[String: Any]] = [["kind": "cold", "seconds": cold, "ready": ready]]
        cost(samples[0], scale: scale)
        if scale == 2 { check(peakHD <= 16 * 1024 * 1024, "cost.cap.HD-peak.cold") }
        let coldClosing = CACurrentMediaTime()
        host.close()
        _ = await wait {
            resources.hdReservedBytes == 0 && host.owner.pendingImages == 0 && BodyPhaseStream.activeJobs == 0 }
        samples.append(["kind": "cold-close", "seconds": ["released": CACurrentMediaTime() - coldClosing]])
        samples[samples.count - 1]["releaseState"] = ["HD": resources.hdReservedBytes,
            "imageTasks": host.owner.pendingImages,
                                                       "phaseJobs": BodyPhaseStream.activeJobs,
                                                           "phasePending": host.owner.phaseWork["pending"]!]
        cost(samples.last!, scale: scale)
        let coldReleased: [String: Any] = ["HD": resources.hdReservedBytes,
            "spriteRetained": resources.sprites.residentBytes,
            "mapRetained": await resources.queue?.residentBytes ?? -1, "jobs": BodyPhaseStream.activeJobs,
                "imageTasks": host.owner.pendingImages]
        var retiredImageTasks = host.owner.pendingImages
        @MainActor func finish() async throws {
            if scale == 2 {
                check(peakHD <= 16 * 1024 * 1024, "cost.cap.HD-peak")
                check(resources.hdReservedBytes == 0 && retiredImageTasks == 0 && BodyPhaseStream.activeJobs == 0,
                      "cost.cap.final-release")
                // Probe the unchanged real allocator only after measurements and retirement.
                let probe = BodyResources(), bytes = 16 * 1024 * 1024
                let exact = probe.reserveHD(bytes: bytes)
                check(exact != nil, "cost.cap.ledger.accept-exact-16MiB")
                if let exact { probe.releaseHD(exact) }
                let over = probe.reserveHD(bytes: bytes + 1)
                check(over == nil, "cost.cap.ledger.reject-over-16MiB")
                if let over { probe.releaseHD(over) }
            }
            let result: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "scale": scale,
                "samples": samples,
                "coldRelease": coldReleased, "peakHD": peakHD, "peakSprite": resources.sprites.peakBytes,
                "peakMap": max(coldMap, await resources.queue?.residentBytes ?? -1),
                "retiredHD": resources.hdReservedBytes, "retiredSprite": resources.sprites.residentBytes,
                "retiredMap": await resources.queue?.residentBytes ?? -1, "retiredJobs": BodyPhaseStream.activeJobs,
                "retiredImageTasks": retiredImageTasks, "checks": checks, "failures": failures,
                "limits": ["coldTextureMS": 120.0, "coldHDMS": coldHDCapMS, "warmHDMS": 150.0, "releaseMS": 20.0,
                    "HDBytes": 16777216.0],
                "capScale": 2, "visibleWindows": NSApp.windows.filter(\.isVisible).count, "diskCacheFlushed": false]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            print("""
                Cost sample scale \(scale); \(checks) checks; \(failures.count) failures;\
                 HD lease after close \(resources.hdReservedBytes)
                """)
            exit(failures.isEmpty ? 0 : 1)
        }
        if !failures.isEmpty { try await finish(); return }
        // Reuse the same injected resources for warm reopen and reverse before the finite envelope settles.
        for n in 0..<3 {
            let began = CACurrentMediaTime()
            let warm = FunctionPanelTextureMockHost(resources: resources, scale: scale)
            _ = NativeViewBitmap.capture(warm, scale: CGFloat(scale))
            let firstStage = CACurrentMediaTime() - began
            let textured = await wait { warm.owner.timings["firstTexture"] != nil || warm.owner.currentPicture != nil }
            var textureFrame: Double?
            if textured {
                _ = NativeViewBitmap.capture(warm, scale: CGFloat(scale))
                textureFrame = CACurrentMediaTime() - began
            }
            let settled = await wait { warm.owner.currentPicture?.quality == .panelHD && !warm.owner.hasPendingWork }
            var times = warm.owner.timings.mapValues { $0 + warm.owner.requestTime - began }
            times["stageFrame"] = firstStage
            times["firstTextureFrame"] = textureFrame
            if settled {
                _ = NativeViewBitmap.capture(warm, scale: CGFloat(scale))
                times["firstHDFrame"] = CACurrentMediaTime() - began
            }
            samples.append(["kind": "warm", "iteration": n, "seconds": times, "ready": settled])
            cost(samples.last!, scale: scale)
            if !failures.isEmpty {
                peakHD = max(peakHD, warm.owner.peakHD)
                warm.close()
                _ = await wait {
                    resources.hdReservedBytes == 0 && warm.owner.pendingImages == 0 && BodyPhaseStream.activeJobs == 0 }
                retiredImageTasks = warm.owner.pendingImages
                try await finish(); return
            }
            let event = BodyPhaseEvent(sourceID: "m1140/reverse/\(n)", value: .init(.running, fraction: 0.85),
                serial: 2)
            warm.setPhase(.init(bodyID: "mercury", event: event, turnID: "reverse", scale: scale, bin: 12,
                    quality: .panelHD, animate: true))
            try? await Task.sleep(for: .milliseconds(70))
            let reversed = CACurrentMediaTime()
            warm.setPhase(.init(bodyID: "mercury", event: .init(sourceID: event.sourceID, value: .init(.running,
                        fraction: 0.21), serial: 3),
                                turnID: "reverse", scale: scale, bin: 12, quality: .panelHD, animate: true))
            let reversalReady = await wait { warm.owner.currentPicture?.event?.serial == 3 && !warm.owner.hasPendingWork
            }
            var reverseTimes = warm.owner.timings.mapValues { $0 + warm.owner.requestTime - reversed }
            reverseTimes["settled"] = CACurrentMediaTime() - reversed
            samples.append(["kind": "reverse", "iteration": n, "seconds": reverseTimes, "ready": reversalReady,
                            "work": warm.owner.phaseWork])
            peakHD = max(peakHD, warm.owner.peakHD)
            let closing = CACurrentMediaTime()
            warm.close()
            _ = await wait {
                resources.hdReservedBytes == 0 && warm.owner.pendingImages == 0 && BodyPhaseStream.activeJobs == 0 }
            samples.append(["kind": "warm-close", "iteration": n,
                    "seconds": ["released": CACurrentMediaTime() - closing]])
            samples[samples.count - 1]["releaseState"] = ["HD": resources.hdReservedBytes,
                "imageTasks": warm.owner.pendingImages,
                                                           "phaseJobs": BodyPhaseStream.activeJobs,
                                                               "phasePending": warm.owner.phaseWork["pending"]!]
            retiredImageTasks = warm.owner.pendingImages
            cost(samples.last!, scale: scale)
            if scale == 2 { check(peakHD <= 16 * 1024 * 1024, "cost.cap.HD-peak.warm.\(n)") }
            if !failures.isEmpty { try await finish(); return }
        }
        for n in 0..<3 {
            let reversing = FunctionPanelTextureMockHost(resources: resources, scale: scale, reduced: false)
            reversing.stage.advance(to: 0.12)
            let before = reversing.stage.motion.progress
            _ = NativeViewBitmap.capture(reversing, scale: CGFloat(scale))
            reversing.stage.close(at: 0.12)
            reversing.stage.advance(to: 0.18)
            let requested = CACurrentMediaTime()
            reversing.stage.open(at: 0.18); reversing.stage.advance(to: 1.8)
            _ = NativeViewBitmap.capture(reversing, scale: CGFloat(scale))
            let firstFrame = CACurrentMediaTime() - requested
            let reopened = await wait {
                reversing.owner.currentPicture?.quality == .panelHD && !reversing.owner.hasPendingWork }
            var times = reversing.owner.timings.mapValues { $0 + reversing.owner.requestTime - requested }
            times["stageFrame"] = firstFrame
            if reopened {
                _ = NativeViewBitmap.capture(reversing, scale: CGFloat(scale))
                times["firstHDFrame"] = CACurrentMediaTime() - requested
            }
            samples.append(["kind": "open-close-open", "iteration": n, "seconds": times, "ready": reopened,
                            "intermediateProgress": before, "timerActive": reversing.stage.hasTimer])
            peakHD = max(peakHD, reversing.owner.peakHD)
            reversing.close()
            _ = await wait { resources.hdReservedBytes == 0 && reversing.owner.pendingImages == 0 &&
                BodyPhaseStream.activeJobs == 0 }
            retiredImageTasks = reversing.owner.pendingImages
            if scale == 2 { check(peakHD <= 16 * 1024 * 1024, "cost.cap.HD-peak.reopen.\(n)") }
            if !failures.isEmpty { try await finish(); return }
        }
        try await finish()
    }
}
