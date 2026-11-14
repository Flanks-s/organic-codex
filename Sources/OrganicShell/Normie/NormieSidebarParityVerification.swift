#if NORMIE_SELFTEST
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Captures only this component. Never creates a window or connects a backend.
@MainActor enum NormieSidebarM9Verification {
    static func run(directory: URL, check: (Bool, String) -> Void) throws {
        let now = Date(), seeds = MockSeed.library(now: now)
        check(seeds.count == 20 && seeds.prefix(6).map(\.id) == MockSeed.windowMembers, "M9 complete product library keeps A–F as the six window members")
        check(seeds.suffix(14).map(\.id) == (1...11).map { "H\($0)" } + (1...3).map { "X\($0)" }, "M9 all product history/archived IDs in their original order")
        check(seeds.suffix(14).map(\.identityIndex) == Array(6...19), "M9 history continues the original assigned identity sequence")
        let replayStore = ConversationStore(), replay = MockReplay(store: replayStore, includeSidebarHistory: true)
        replay.start(live: false)
        check(replayStore.conversations.count == 20 && !replay.isPlaybackActive, "M9 paused replay hydrates all twenty chats without a clock")
        for seed in seeds {
            let c = replayStore.conversation(seed.id)!
            check(c.title == seed.title && c.items.map(\.text) == seed.items.map(\.text) && c.projectID == seed.projectID && c.deviceID == seed.deviceID && c.archived == seed.archived,
                  "M9 replay preserves product text/project/device/archive: " + seed.id)
            check(abs(c.updated.timeIntervalSince(seed.updated)) < 2, "M9 replay preserves relative update time: " + seed.id)
            check((c.archivedAt == nil) == (seed.archivedAt == nil), "M9 archive dates survive initial replay: " + seed.id)
        }
        check(replayStore.conversations.filter(\.archived).count == 3, "M9 archived examples stay out of the live sidebar")
        let store = ConversationStore(conversations: seeds, projects: MockSeed.projects, devices: MockSeed.devices)
        let model = NormieSidebarModel(store: store, current: "A"), sidebar = NormieSidebarController(model: model)
        sidebar.loadViewIfNeeded(); sidebar.account = .prototype
        let root = sidebar.view as! NormieView
        root.frame = CGRect(x: 0, y: 0, width: 240, height: 820)
        root.verificationSafeAreaInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)
        let expected: [(String, CGFloat, CGFloat)] = [
            ("group:Pinned", 96, 20), ("project:spw", 116, 32), ("chat:A", 148, 32), ("chat:B", 180, 32),
            ("chat:F", 212, 32), ("chat:H1", 244, 32), ("chat:H2", 276, 32), ("chat:C", 308, 32),
            ("group:Projects", 340, 32), ("project:fn", 372, 32), ("project:rs", 404, 32), ("chat:D", 436, 32),
            ("project:ai", 468, 32), ("chat:E", 500, 32), ("project:plt", 532, 32), ("group:Recents", 564, 32)]
        check(model.rows.map(\.key) == expected.map(\.0), "M9 paused sidebar has the same visible rows as the product reference")
        func cell(_ key: String) -> NormieSidebarCell {
            let index = model.rows.firstIndex { $0.key == key }!
            return sidebar.table.view(atColumn: 0, row: index, makeIfNecessary: true) as! NormieSidebarCell
        }
        var geometry: [[String: String]] = []
        var referenceMetrics: [[String: Any]] = []
        for scale: CGFloat in [1, 2] {
            NormieVerification.layout(root, scale: scale)
            check(root.fill == nil, "M9 root does not cover system sidebar vibrancy with an opaque canvas")
            check((sidebar.searchField.placeholderAttributedString?.string ?? sidebar.searchField.placeholderString) == "Search", "M9 search placeholder matches the product")
            check(sidebar.searchField.convert(sidebar.searchField.bounds, to: root).minX == 37, "M9 search text field starts after the 13 pt magnifier and 6 pt gap")
            check(sidebar.scrollView.frame == CGRect(x: 0, y: 96, width: 240, height: 670), "M9 search/profile safeAreaBar geometry at 820 pt")
            check(sidebar.accountView.frame == CGRect(x: 10, y: 770, width: 220, height: 40), "M9 profile capsule is one 40 pt row with 10 pt bottom clearance")
            check(sidebar.accountView.plan.isHidden && sidebar.accountView.name.stringValue == "Louis L." && sidebar.accountView.avatar.initials == "LL", "M9 profile uses prototype name/initials and one visible line")
            check(!sidebar.accountView.daybreak.isHidden && sidebar.accountView.daybreak.frame == CGRect(x: 192, y: 16, width: 16, height: 8), "M9 product prototype has a 16 × 8 Daybreak horizon")
            check(sidebar.accountView.avatar.convert(sidebar.accountView.avatar.bounds, to: root) == CGRect(x: 17, y: 777, width: 26, height: 26), "M9 profile avatar matches the product crop")
            for (key, y, height) in expected {
                let index = model.rows.firstIndex { $0.key == key }!, c = cell(key)
                let r = sidebar.table.convert(sidebar.table.rect(ofRow: index), to: root)
                check(r.minY == y && r.height == height, "M9 \(Int(scale))× row \(key) y/height: \(NSStringFromRect(r))")
                let titleX = c.isChat && c.nested ? CGFloat(56) : key.hasPrefix("group:") ? 12 : c.isChat ? 45 : 46.5
                check(c.title.frame.minX == NormieDrawing.pixel(titleX, scale: scale), "M9 \(key) title/disclosure indentation")
                if key.hasPrefix("group:") { check(c.disclosure.isHidden && c.title.font?.pointSize == 11, "M9 resting section has bold 11 pt text and no leading chevron: \(key)") }
                if key.hasPrefix("project:") {
                    check(!c.folder.isHidden && !c.disclosure.isHidden && c.folder.frame == CGRect(x: 26, y: 8, width: 16, height: 16), "M9 project folder/disclosure size and anchor: \(key)")
                }
                if c.isChat {
                    check(!c.planet.isHidden && c.title.font?.pointSize == 13, "M11.19 every chat draws its identity glyph: \(key)")
                    check(c.planet.frame == CGRect(x: c.nested ? 36 : 25, y: 7, width: 16, height: 16), "M11.19 nested/top-level identity slots: \(key)")
                    check(c.flightSourceRect == CGRect(x: c.nested ? 39 : 28, y: 8, width: 16, height: 16), "M11.19 preserves M11.2 flight anchors: \(key)")
                    let titleEnd: CGFloat = NormieSidebarModel.hasStatus(store.conversation(String(key.dropFirst(5)))!) ? 208 : 198
                    check(c.rename.frame.minX == titleX && c.rename.frame.maxX == titleEnd && c.title.frame.maxX <= titleEnd,
                          "M11.19 title keeps its trailing boundary and existing truncation: \(key)")
                    check(c.device.isHidden || !c.nested, "M9 nested chat does not repeat its project device: \(key)")
                } else {
                    check(c.planet.isHidden, "M11.19 non-chat rows have no planet: \(key)")
                }
                if scale == 1 { geometry.append(["row": key, "rowFrame": NSStringFromRect(r), "title": NSStringFromRect(c.title.frame), "folder": NSStringFromRect(c.folder.frame), "status": NSStringFromRect(c.statusMark.frame), "device": NSStringFromRect(c.device.frame), "deviceMark": NSStringFromRect(c.deviceMark.frame)]) }
            }
            check(cell("chat:B").statusMark.symbol == "hand.raised.fill" && cell("chat:C").statusMark.symbol == "questionmark.bubble.fill", "M9 approval/question use SF Symbols, not text/emoji placeholders")
            check(cell("chat:D").statusMark.symbol == "exclamationmark.triangle.fill" && cell("chat:E").statusMark.symbol == "exclamationmark.triangle.fill", "M9 both error kinds use the filled red triangle")
            check(!cell("chat:A").runningIndicator.isHidden && cell("chat:A").runningIndicator.frame.size == CGSize(width: 14, height: 14), "M9 running mini spinner has its own fixed trailing slot")
            check(cell("chat:F").trailing.stringValue == "1h" && cell("chat:H1").trailing.stringValue == "2h" && cell("chat:H2").trailing.stringValue == "1d", "M9 current-date seed gives the product relative ages")
            for key in ["project:rs", "project:ai"] {
                let c = cell(key)
                check(!c.deviceMark.isHidden && c.deviceMark.symbol == "circle.fill" && c.deviceMark.frame.width == 7, "M9 online device uses a green 7 pt circle: \(key)")
                check(c.device.frame.maxX < c.deviceMark.frame.minX && c.deviceMark.frame.maxX == NormieDrawing.pixel(223.5, scale: scale), "M9 device name precedes its right-hand online dot: \(key)")
                check(c.device.frame.minX > c.title.frame.maxX, "M9 project/device attachments do not overlap: \(key)")
            }
            let originalFrame = cell("chat:C").planet.frame, nestedFrame = cell("chat:A").planet.frame
            let nestedTitle = cell("chat:A").title.frame, offset = sidebar.scrollView.contentView.bounds.origin
            sidebar.setFlightSourcesHidden(["C", "A"], avatar: true)
            check(cell("chat:C").planet.isHidden && cell("chat:A").planet.isHidden && !cell("chat:F").planet.isHidden,
                  "M11.19 flight hides nested and top-level sources, leaving other planets visible")
            check(sidebar.hiddenFlightSourceViews.contains { $0 === cell("chat:A").planet }, "M11.19 sliding foreground excludes the nested flight source")
            try NormieVerification.write(NativeViewBitmap.capture(root, scale: scale), to: directory.appendingPathComponent("m1119-sidebar-flight-hidden@\(Int(scale))x.png"))
            cell("chat:A").configure(.conversation("A", project: "spw"), model: model)
            check(cell("chat:A").planet.isHidden, "M11.19 reconfiguration cannot reveal an airborne nested source")
            let newFlightCell = sidebar.tableView(sidebar.table, viewFor: sidebar.table.tableColumns[0], row: model.rows.firstIndex { $0.conversationID == "A" }!) as! NormieSidebarCell
            check(newFlightCell.planet.isHidden, "M11.19 rows created during flight inherit the hidden source state")
            sidebar.setFlightSourcesHidden([], avatar: false)
            check(!cell("chat:C").planet.isHidden && !cell("chat:A").planet.isHidden && cell("chat:C").planet.frame == originalFrame
                  && cell("chat:A").planet.frame == nestedFrame && cell("chat:A").title.frame == nestedTitle && sidebar.scrollView.contentView.bounds.origin == offset,
                  "M11.19 flight restoration preserves both planets, row geometry and scrolling")
            let bitmap = NativeViewBitmap.capture(root, scale: scale)
            try NormieVerification.write(bitmap, to: directory.appendingPathComponent("m9-sidebar-default@\(Int(scale))x.png"))
            check(NormieVerification.gridIssues(root, root: root, scale: scale).isEmpty, "M9 sidebar controls align to the \(Int(scale))× backing grid")
            if scale == 1, let reference = loadReference() {
                try comparison(product: reference, sidebar: bitmap, directory: directory)
                for (name, r) in [("A title", CGRect(x: 35, y: 152, width: 165, height: 25)), ("Pinned", CGRect(x: 12, y: 98, width: 60, height: 16)), ("Account", CGRect(x: 49, y: 780, width: 80, height: 23)), ("Project title", CGRect(x: 48, y: 122, width: 175, height: 23)), ("F title", CGRect(x: 35, y: 216, width: 168, height: 25)), ("H1 title", CGRect(x: 35, y: 248, width: 168, height: 25))] {
                    let p = ink(reference, rect: r), v = ink(bitmap, rect: r)
                    let nestedException = ["A title", "F title", "H1 title"].contains(name)
                    referenceMetrics.append(["name": name, "product": NSStringFromRect(p), "v2": NSStringFromRect(v),
                        "exception": nestedException ? "M11.19: nested planet at 36, title field at 56; intentional product parity exception" : ""])
                    if !nestedException {
                        check(!p.isEmpty && !v.isEmpty && abs(p.minX-v.minX) <= 1 && abs(p.minY-v.minY) <= 1 && abs(p.width-v.width) <= 1 && abs(p.height-v.height) <= 1, "M9 historical 1× foreground \(name), product \(NSStringFromRect(p)), v2 \(NSStringFromRect(v)) (≤1 backing px)")
                    }
                }
            }
            if scale == 1, let reference = loadReference() {
                for (name, r, color) in [("Magnifier", CGRect(x: 15, y: 66, width: 20, height: 21), "secondary"), ("Disclosure", CGRect(x: 12, y: 124, width: 14, height: 18), "secondary"), ("Pinned folder", CGRect(x: 24, y: 122, width: 22, height: 22), "purple"),
                    ("Folder", CGRect(x: 24, y: 378, width: 22, height: 22), "blue"),
                    ("Error", CGRect(x: 205, y: 440, width: 25, height: 24), "red"),
                    ("Approval", CGRect(x: 205, y: 184, width: 25, height: 24), "orange"),
                    ("Question", CGRect(x: 205, y: 312, width: 25, height: 24), "orange")] {
                    let p = ink(reference, rect: r, color: color), v = ink(bitmap, rect: r, color: color)
                    referenceMetrics.append(["name": name, "product": NSStringFromRect(p), "v2": NSStringFromRect(v)])
                    check(!p.isEmpty && !v.isEmpty && abs(p.minX-v.minX) <= 1 && abs(p.minY-v.minY) <= 1 && abs(p.width-v.width) <= 1 && abs(p.height-v.height) <= 1,
                          "M9 reference SF Symbol \(name), product \(NSStringFromRect(p)), v2 \(NSStringFromRect(v)) (≤1 backing px)")
                }
            }
            let hover = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            let approvalRow = cell("chat:B"), heightBeforeHover = approvalRow.frame.height
            approvalRow.mouseEntered(with: hover); NormieVerification.layout(root, scale: scale)
            check(!approvalRow.pin.isHidden && !approvalRow.archive.isHidden && !approvalRow.statusMark.isHidden && approvalRow.trailing.isHidden,
                  "M9 hovered active row keeps its status beside Pin/Archive")
            check(approvalRow.pin.frame == CGRect(x: 182, y: 6, width: 20, height: 20) && approvalRow.archive.frame == CGRect(x: 204, y: 6, width: 20, height: 20)
                && approvalRow.frame.height == heightBeforeHover, "M9 hover actions have the product 20/2/20 geometry without changing row height")
            try NormieVerification.write(NativeViewBitmap.capture(root, scale: scale), to: directory.appendingPathComponent("m9-sidebar-approval-hover@\(Int(scale))x.png"))
            approvalRow.mouseExited(with: hover); NormieVerification.layout(root, scale: scale)
            model.toggleProject("spw"); NormieVerification.layout(root, scale: scale)
            check(!model.rows.contains { $0.conversationID == "H1" }, "M9 collapse removes only the project children")
            try NormieVerification.write(NativeViewBitmap.capture(root, scale: scale), to: directory.appendingPathComponent("m9-sidebar-collapsed@\(Int(scale))x.png"))
            model.toggleProject("spw"); sidebar.search("多语言"); NormieVerification.layout(root, scale: scale)
            check(model.rows.compactMap(\.conversationID) == ["H2"], "M9 Unicode search finds the same history specimen")
            try NormieVerification.write(NativeViewBitmap.capture(root, scale: scale), to: directory.appendingPathComponent("m9-sidebar-unicode-search@\(Int(scale))x.png"))
            sidebar.search("No matching conversation"); NormieVerification.layout(root, scale: scale)
            check(model.rows.isEmpty, "M9 empty search has no phantom section headers")
            try NormieVerification.write(NativeViewBitmap.capture(root, scale: scale), to: directory.appendingPathComponent("m9-sidebar-no-results@\(Int(scale))x.png"))
            sidebar.search(""); model.select("H7"); NormieVerification.layout(root, scale: scale)
            let offline = cell("chat:H7")
            check(!offline.device.isHidden && offline.deviceMark.symbol == "exclamationmark.circle", "M9 top-level offline history keeps the orange device warning")
            try NormieVerification.write(NativeViewBitmap.capture(root, scale: scale), to: directory.appendingPathComponent("m9-sidebar-recents-offline@\(Int(scale))x.png"))
            model.select("A"); model.toggleGroup("Recents"); NormieVerification.layout(root, scale: scale)
        }
        for scale: CGFloat in [1, 2] {
            let more = NormieSidebarCell(frame: CGRect(x: 0, y: 0, width: 240, height: 32))
            more.configure(.more("spw"), model: model); NormieVerification.layout(more, scale: scale)
            check(more.title.frame.minX == 35 && more.disclosure.isHidden && more.planet.isHidden, "M11.19 \(Int(scale))× project Show More stays at 35 with no planet or plus")
            more.configure(.more("recents"), model: model); NormieVerification.layout(more, scale: scale)
            check(more.title.frame.minX == 46 && more.disclosure.isHidden && more.planet.isHidden, "M9 \(Int(scale))× Recents Show More uses the product's 22 pt leading padding")
        }
        let menuIndex = model.rows.firstIndex { $0.conversationID == "B" }!
        let unbound = sidebar.menu(for: menuIndex)!
        check(unbound.items.first { $0.title == "Customize Chat…" }?.isEnabled == false, "M9 unbound Customize does not fake opening a host sheet")
        var customized: [String] = []; sidebar.onCustomize = { customized.append($0.id) }
        let menu = sidebar.menu(for: menuIndex)!
        check(menu.items.map(\.title) == ["Pin", "Rename…", "Customize Chat…", "Symbol", "Color", "", "Archive"], "M9 sidebar context menu matches the product order")
        let symbols = menu.items.first { $0.title == "Symbol" }!.submenu!, colors = menu.items.first { $0.title == "Color" }!.submenu!
        check(symbols.items.count == BodyIdentityAdapter.choices.count && colors.items.count == OrbTint.allCases.count && symbols.items.allSatisfy { $0.image?.size == CGSize(width: 16, height: 16) } && colors.items.allSatisfy { $0.image?.size == CGSize(width: 16, height: 16) }, "M9 identity menus include every available body and tint")
        (menu.items.first { $0.title == "Customize Chat…" } as! NormieMenuItem).fire()
        check(customized == ["B"] && model.current == "A", "M9 row Customize keeps the clicked conversation instead of stealing current")
        let originalSymbol = store.conversation("B")!.identitySymbol, originalTint = store.conversation("B")!.identityTint
        let originalIdentities=Dictionary(uniqueKeysWithValues:store.conversations.map { ($0.id,[$0.identitySymbol,$0.identityTint]) })
        (symbols.items[2] as! NormieMenuItem).fire(); (colors.items[2] as! NormieMenuItem).fire()
        check(store.conversation("B")!.identitySymbol == BodyIdentityAdapter.choices[2] && store.conversation("B")!.identityTint == String(describing:OrbTint.allCases[2]) && store.conversations.filter { $0.id != "B" }.allSatisfy { [$0.identitySymbol,$0.identityTint] == originalIdentities[$0.id] }, "M9 symbol/color mutate only the clicked local identity")
        store.conversation("B")!.identitySymbol = originalSymbol; store.conversation("B")!.identityTint = originalTint
        let renamed = sidebar.menu(for: menuIndex)!
        check(renamed.items.first { $0.title == "Symbol" }!.submenu!.items.filter { $0.state == .on }.count == 1, "M9 current identity has one checked symbol")
        let stale = store.conversation("B")!; try store.remove(ids: [stale.id])
        (menu.items.first { $0.title == "Customize Chat…" } as! NormieMenuItem).fire()
        check(customized == ["B"], "M9 stale sidebar menus cannot customize a permanently deleted chat")
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "M9 verification opened no windows")
        let report: [String: Any] = ["width": 240, "height": 820, "safeAreaTop": 52, "geometry": geometry, "foregroundComparison": referenceMetrics,
            "materialBoundary": "Offscreen proxy only. Real sidebar material belongs to NSSplitViewItem/WindowServer and must be compared by the host on HP."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("m9-sidebar-geometry.json"))
    }
    private static func loadReference() -> CGImage? {
        let path = ProcessInfo.processInfo.environment["M9_SIDEBAR_PRODUCT"] ?? "runs/parity-205445/normie-product.png"
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    private static func comparison(product: CGImage, sidebar: CGImage, directory: URL) throws {
        // The title bar is owned by App. Compare only the component's common y=52...820 region.
        let r = CGRect(x: 0, y: 52, width: 240, height: 768)
        guard let p = product.cropping(to: r), let v = sidebar.cropping(to: r),
              let context = CGContext(data: nil, width: 480, height: 768, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(p, in: CGRect(x: 0, y: 0, width: 240, height: 768))
        context.draw(v, in: CGRect(x: 240, y: 0, width: 240, height: 768))
        try NormieVerification.write(context.makeImage()!, to: directory.appendingPathComponent("m9-sidebar-product-v2.png"))
    }
    private static func ink(_ image: CGImage, rect: CGRect, color: String = "text") -> CGRect {
        guard let crop = image.cropping(to: rect), let context = CGContext(data: nil, width: crop.width, height: crop.height,
            bitsPerComponent: 8, bytesPerRow: crop.width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .zero }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<crop.height { for x in 0..<crop.width {
            let i = (y*crop.width+x)*4
            let red = Int(data[i]), green = Int(data[i+1]), blue = Int(data[i+2])
            let match: Bool
            switch color {
            case "secondary": match = min(red,green,blue) > 75
            case "purple": match = blue > 120 && blue > green+20 && blue > red+20
            case "blue": match = blue > 130 && blue > red+40
            case "red": match = red > 160 && red > green+40 && red > blue+40
            case "orange": match = red > 160 && green > 80 && red > blue+50
            default: match = min(red,green,blue) > 160
            }
            if match { xs.append(x); ys.append(y) }
        } }
        guard let x = xs.min(), let y = ys.min(), let maxX = xs.max(), let maxY = ys.max() else { return .zero }
        return CGRect(x: rect.minX+CGFloat(x), y: rect.minY+CGFloat(y), width: CGFloat(maxX-x+1), height: CGFloat(maxY-y+1))
    }
}
#endif
