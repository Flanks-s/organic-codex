import AppKit

extension FunctionPanelView {
    var visibleArtifactIDs: Set<String> {
        guard state.isOpen else { return [] }
        if state.page == .library {
            if let id = state.coverID { return [id] }
            return Set(filteredCovers().dropFirst(state.libraryOffset * 3).prefix(12).map(\.id))
        }
        guard state.page == .outputs, let outputs = input.outputs.value, !outputs.isEmpty else { return [] }
        let index = outputs.firstIndex { $0.id == state.outputID } ?? 0
        return Set(outputs[max(0, index - 1)...min(outputs.count - 1, index + 1)].map(\.id))
    }

    private func paintPreview(_ id: String, in box: CGRect) {
        guard !box.isEmpty else { return }
        let state = input.materials?.previews[id] ?? .unavailable
        switch state {
        case .known(.raster(let image)):
            let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                              width: size.width, height: size.height)
            NSImage(cgImage: image, size: size).draw(in: rect, from: .zero, operation: .sourceOver,
                                                   fraction: 1, respectFlipped: true, hints: nil)
        case .known(.text(let text)):
            FunctionPanelPaint.text(String(text.prefix(1200)), box, size: 11, alpha: 0.85)
        default:
            FunctionPanelPaint.text("Preview · " + state.status, box, size: 10, alpha: 0.55)
        }
    }

    private func materialButton(_ id: String, _ rect: CGRect, allowed: Bool?, _ action: FunctionPanelAction) {
        guard allowed != false else { return }
        let name = id.hasSuffix(".open") ? "Open" : "Copy"
        button(id, name, rect) { [weak self] in self?.onAction(action) }
    }

    func renderPage() {
        switch state.page {
        case .overview: renderOverview()
        case .library: renderLibrary()
        case .files: renderFiles()
        case .background: renderBackground()
        case .outputs: renderOutputs()
        }
    }
    var liveOverviewLayout: FunctionPanelOverviewLayout {
        .init(historyKnown: input.compactHistory.value != nil,
              hasActions: ["compact", "fork", "stop"].contains { input.commands?.available.contains($0) == true })
    }
    private func renderOverview() {
        if input.live != nil { renderLiveOverview(); return }
        if input.live == nil || !input.goal.isEmpty { label("Goal", pageRect(16, 14, 450, 16), size: 11, alpha: 0.5) }
        label(input.goal, pageRect(16, 33, 459, 49), size: 15, weight: .semibold)
        var values = [("State", input.status), ("Model", input.model.text { $0 })]
        if input.live == nil || input.worked.value != nil { values.append(("Worked", input.worked.text { $0 })) }
        for (index, pair) in values.enumerated() {
            let x = 16 + CGFloat(index) * 154
            label(pair.0, pageRect(x, 88, 146, 14), size: 10, alpha: 0.5)
            label(pair.1, pageRect(x, 107, 146, 32), size: 12)
        }
        label(input.compactHistory.text { $0 }, pageRect(16, 149, 350, 34), size: 11, alpha: 0.55)
        button("compact", "Compact", pageRect(381, 149, 94, 27)) { [weak self] in self?.onAction(.compact) }
        for (index, item) in [("fork", "Fork", FunctionPanelAction.fork), ("export", "Export", .export), ("stop",
                "Stop", .stop)].enumerated() {
            button(item.0, item.1, pageRect(16 + CGFloat(index) * 153, 207, 142,
                    28)) { [weak self] in self?.onAction(item.2) }
        }
    }
    private func renderLiveOverview() {
        if !input.goal.isEmpty {
            label("Goal", pageRect(16, 14, 450, 16), size: 11, alpha: 0.5)
            label(input.goal, pageRect(16, 33, 459, 49), size: 15, weight: .semibold)
        }
        var values = [("State", input.status), ("Model", input.model.text { $0 })]
        if let worked = input.worked.value { values.append(("Worked", worked)) }
        for (index, pair) in values.enumerated() {
            let x = 16 + CGFloat(index) * 154
            label(pair.0, pageRect(x, 88, 146, 14), size: 10, alpha: 0.5)
            label(pair.1, pageRect(x, 107, 146, 32), size: 12)
        }
        let layout = liveOverviewLayout
        if let history = input.compactHistory.value, let r = layout.history {
            label(history, pageRect(r.minX, r.minY, r.width, r.height), size: 11, alpha: 0.55)
        }
        if let row = layout.actions {
            let available = [("compact", "Compact", FunctionPanelAction.compact), ("fork", "Fork", .fork), ("stop",
                    "Stop", .stop)]
                .filter { input.commands?.available.contains($0.0) == true }
            for (index, item) in available.enumerated() {
                button(item.0, item.1, pageRect(row.minX + CGFloat(index) * 153, row.minY, 142,
                        row.height)) { [weak self] in self?.onAction(item.2) }
            }
        }
    }
    private func collectionMessage<Value>(_ value: FunctionPanelValue<[Value]>,
        empty: String) -> Bool where Value: Equatable & Sendable {
        if let values = value.value {
            if !values.isEmpty { return false }
            label(empty, pageRect(22, 60, 447, 50), size: 15, alpha: 0.55)
        } else { label(value.status, pageRect(22, 60, 447, 60), size: 15, alpha: 0.65) }
        return true
    }
    private func renderLibrary() {
        if collectionMessage(input.covers, empty: input.live == nil ?
            "No saved materials" : "No materials with a proven conversation source") { return }
        let filters: [(String, FunctionPanelCover.Kind?)] = [("All", nil)] + FunctionPanelCover.Kind.allCases.map {
            ($0.rawValue, $0) }
        for (index, filter) in filters.enumerated() {
            button("filter.\(filter.0)", filter.0, pageRect(12 + CGFloat(index) * 84, 8, 78, 25),
                selected: state.filter == filter.1, filled: false) { [weak self] in
                self?.interact { $0.filter = filter.1; $0.coverID = nil; $0.libraryOffset = 0 }
            }
        }
        let covers = filteredCovers(), selected = covers.first { $0.id == state.coverID }
        let live = input.live != nil
        var tileIndex = 0
        for (index, cover) in covers.enumerated() {
            let chosen = selected?.id == cover.id
            var rect = FunctionPanelGeometry.librarySlot(index: index, selected: chosen,
                tile: selected != nil && !chosen, tileIndex: tileIndex)
            if selected == nil { rect.origin.y -= CGFloat(state.libraryOffset) * 113 }
            if selected != nil && !chosen { tileIndex += 1 }
            let r = pageRect(rect.minX, rect.minY, rect.width, rect.height)
            let b = button("cover.\(cover.id)", cover.name, r, selected: chosen, filled: false) { [weak self] in
                self?.interact { $0.coverID = $0.coverID == cover.id ? nil : cover.id }
            }
            b.customPaint = { [weak self] bounds in
                FunctionPanelPaint.plate(bounds.insetBy(dx: 0.5, dy: 0.5), radius: chosen ? 14 : 10,
                                         fill: FunctionPanelPaint.colour(cover.colour))
                guard bounds.width > 60 else { return }
                if self?.input.materials != nil {
                    self?.paintPreview(cover.id, in: bounds.insetBy(dx: 10, dy: 10))
                } else if live {
                    FunctionPanelPaint.text(cover.name, CGRect(x: 12, y: 16, width: bounds.width - 24, height: 52),
                        size: 12, weight: .semibold)
                    FunctionPanelPaint.text("Preview not provided", CGRect(x: 12, y: bounds.height - 34,
                            width: bounds.width - 24, height: 24), size: 10, alpha: 0.5)
                } else if cover.kind == .image {
                    FunctionPanelPaint.plate(CGRect(x: 12, y: 12, width: bounds.width - 24, height: bounds.height - 24),
                        radius: 5, fill: NSColor(white: 0.08, alpha: 0.7))
                    for row in 0..<4 {
                        FunctionPanelPaint.plate(CGRect(x: 20, y: 23 + CGFloat(row) * 11, width: bounds.width * (row ==
                                    1 ? 0.7 : 0.5), height: 5), radius: 2, fill: NSColor.white.withAlphaComponent(0.22))
                    }
                } else {
                    FunctionPanelPaint.text(cover.kind == .pdf ? "PDF" : "Artifact", CGRect(x: 12, y: 12,
                            width: bounds.width - 24, height: 18), size: chosen ? 13 : 10, alpha: 0.65)
                    FunctionPanelPaint.text(cover.lyric, CGRect(x: 12, y: bounds.height * 0.37, width: bounds.width -
                            24, height: bounds.height * 0.55), size: chosen ? 24 : 16, weight: .bold)
                }
            }
            if selected == nil { label(cover.name, pageRect(rect.minX, rect.maxY + 6, 144, 17), size: 11, alpha: 0.65) }
            else if !chosen { label(cover.step, pageRect(rect.maxX + 9, rect.minY + 1, 182, 19), size: 11) }
        }
        if let selected {
            label(selected.name, pageRect(292, 44, 183, 25), size: 11, alpha: 0.6)
            label(selected.metadata.text { $0 }, pageRect(292, 72, 183, 30), size: 10, alpha: 0.5)
            label(selected.lyric, pageRect(292, 107, 183, 54), size: 18, weight: .bold)
            materialButton("cover.open", pageRect(292, 170, 53, 23),
                           allowed: input.materials?.openIDs.contains(selected.id), .openCover(selected.id))
            materialButton("cover.copy", pageRect(351, 170, 53, 23),
                           allowed: input.materials?.copyIDs.contains(selected.id), .copyCover(selected.id))
            button("cover.wall", "Wall", pageRect(410, 170, 53, 23)) { [weak self] in self?.interact {
                    $0.coverID = nil } }
        }
    }
    private func renderFiles() {
        if collectionMessage(input.files, empty: "No file changes") { return }
        let files = input.files.value ?? [], selected = files.firstIndex { $0.id == state.fileID } ?? max(0,
            files.count - 1)
        for (index, file) in files.enumerated() {
            let (rect, angle) = FunctionPanelGeometry.fileCard(index: index, selected: selected, count: files.count)
            let r = pageRect(rect.minX, rect.minY, rect.width, rect.height), world = geometry.placed(r)
            ink.commands.append {
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: world.midX, yBy: world.maxY); transform.rotate(byDegrees: angle)
                transform.translateX(by: -world.midX, yBy: -world.maxY); transform.concat()
                FunctionPanelPaint.plate(world, radius: 14, fill: NSColor(white: 0.24 + CGFloat(index) * 0.012,
                        alpha: 1))
                FunctionPanelPaint.text(file.path, world.insetBy(dx: 14, dy: 8), size: 11, alpha: 0.85)
                if index == selected {
                    FunctionPanelPaint.text(file.lines.joined(separator: "\n"), CGRect(x: world.minX + 14, y: world
                            .minY + 46, width: world.width - 28, height: 157), size: 11.5, alpha: 0.8, mono: true)
                    FunctionPanelPaint.text(file.provenance, CGRect(x: world.minX + 14, y: world.maxY - 27,
                            width: world.width - 106, height: 19), size: 10, alpha: 0.6)
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            let b = button("file.\(file.id)", file.path, CGRect(x: r.minX, y: r.minY, width: r.width, height: 30),
                filled: false) { [weak self] in self?.interact { $0.fileID = file.id } }
            b.customPaint = { _ in }
            if index == selected {
                label(file.additions.text { "+\($0)" } + "  " + file.removals.text { "−\($0)" },
                      CGRect(x: r.minX + 14, y: r.minY + 28, width: 380, height: 18), size: 10, alpha: 0.65)
                materialButton("file.open", CGRect(x: r.maxX - 76, y: r.maxY - 30, width: 62, height: 23),
                               allowed: input.materials?.fileIDs.contains(file.id), .openFile(file.id))
            }
        }
    }
    private func renderBackground() {
        guard let tasks = input.tasks.value, !tasks.isEmpty else {
            glass("background.empty", FunctionPanelGeometry.panel)
            _ = collectionMessage(input.tasks, empty: "No background tasks"); return
        }
        let running = tasks.filter { $0.status == "Running" }, finished = tasks.filter { $0.status != "Running" }
        var y: CGFloat = 264
        for task in running {
            let expanded = state.taskID == task.id, height: CGFloat = expanded ? 128 : 64
            glass("task.\(task.id)", CGRect(x: 76, y: y, width: 471, height: height), radius: expanded ? 28 : 32)
            if let progress = task.progress.value {
                fill(CGRect(x: 77, y: y + 1, width: 469 * CGFloat(min(1, max(0, progress))), height: height - 2),
                    colour: NSColor.white.withAlphaComponent(0.055), radius: 28)
            }
            button("task.main.\(task.id)", task.command, CGRect(x: 94, y: y + 8, width: 385, height: 24),
                filled: false) { [weak self] in self?.interact { $0.taskID = $0.taskID == task.id ? nil : task.id } }
            label(task.progress.text { "\(Int(($0 * 100).rounded()))%" } + " · " + task.elapsed.text { $0 },
                  CGRect(x: 98, y: y + 37, width: 360, height: 18), size: 10, alpha: 0.55)
            if expanded { label(task.log, CGRect(x: 98, y: y + 67, width: 415, height: 50), size: 10, alpha: 0.6,
                    mono: true) }
            if let action = task.action {
                button("task.action.\(task.id)", action, CGRect(x: 488, y: y + 17, width: 46,
                        height: 25)) { [weak self] in self?.onAction(.task(task.id, action)) }
            }
            y += height + 10
        }
        label((input.live == nil ? "Stopped and finished" : "Other command records") + " · \(finished.count)",
            CGRect(x: 86, y: y + 6, width: 290, height: 18), size: 11, alpha: 0.55)
        button("task.fan", state.fanTasks ? "Stack" : "Show all", CGRect(x: 428, y: y + 3, width: 104, height: 22),
            filled: false) { [weak self] in self?.interact { $0.fanTasks.toggle() } }
        y += 26
        for (index, task) in finished.enumerated() {
            if !state.fanTasks && index > 0 {
                glass("task.\(task.id)", FunctionPanelGeometry.finishedTaskBack(index: index, y: y), radius: 18,
                    alpha: 0.45)
                continue
            }
            glass("task.\(task.id)", CGRect(x: 76, y: y, width: 471, height: 48), radius: 24)
            label(task.command, CGRect(x: 98, y: y + 8, width: 325, height: 17), size: 11)
            label(task.status + " · " + task.elapsed.text { $0 }, CGRect(x: 98, y: y + 27, width: 320, height: 16),
                size: 10, alpha: 0.5)
            if let action = task.action {
                button("task.action.\(task.id)", action, CGRect(x: 447, y: y + 12, width: 86,
                        height: 24)) { [weak self] in self?.onAction(.task(task.id, action)) }
            }
            if state.fanTasks { y += 58 }
        }
    }
    private func renderOutputs() {
        if collectionMessage(input.outputs, empty: "No outputs yet") { return }
        let outputs = input.outputs.value ?? [], index = outputs.firstIndex { $0.id == state.outputID } ?? 0
        for slot in max(0, index - 1)...min(outputs.count - 1, index + 1) {
            let output = outputs[slot]
            let local = FunctionPanelGeometry.outputCard(index: slot, selected: index)
            let scale: CGFloat = slot == index ? 1 : 0.9
            let card = pageRect(local.minX, local.minY, local.width, local.height),
                clipped = card.intersection(pageRect(0, 0, 491, 350))
            fill(clipped, colour: FunctionPanelPaint.colour(output.colour, alpha: slot == index ? 1 : 0.62),
                radius: FunctionPanelGeometry.outputRadius(selected: slot == index))
            label(output.name, CGRect(x: card.minX + 14 * scale, y: card.minY + 15 * scale, width: 188 * scale,
                    height: 42 * scale), size: 13 * scale, weight: .bold)
            let body = CGRect(x: card.minX + 14 * scale, y: card.minY + 68 * scale,
                              width: 188 * scale, height: 180 * scale)
            if input.materials != nil, !output.id.hasPrefix("diff:") {
                ink.commands.append { [weak self] in
                    self?.paintPreview(output.id, in: body.intersection(clipped))
                }
            } else {
                label(output.content, body, size: 14 * scale, alpha: slot == index ? 0.9 : 0.5, weight: .medium)
            }
            if slot != index {
                let b = button("output.card.\(output.id)", output.name, clipped,
                    filled: false) { [weak self] in self?.interact { $0.outputID = output.id } }
                b.customPaint = { _ in }
            }
        }
        let output = outputs[index]
        label(output.metadata.text { $0 }, pageRect(16, 303, 279, 32), size: 10, alpha: 0.55)
        materialButton("output.open", pageRect(308, 309, 72, 25),
                       allowed: input.materials?.openIDs.contains(output.id), .openOutput(output.id))
        materialButton("output.copy", pageRect(388, 309, 72, 25),
                       allowed: input.materials?.copyIDs.contains(output.id), .copyOutput(output.id))
        for (name, direction) in [("Previous", -1), ("Next", 1)] {
            button("output.\(name)", name, pageRect(direction < 0 ? 12 : 453, 130, 26, 28),
                symbol: direction < 0 ? "chevron.left" : "chevron.right") { [weak self] in
                self?.interact { $0.outputID = outputs[(index + direction + outputs.count) % outputs.count].id }
            }
        }
    }
}
