import AppKit
import Testing
@testable import MDViewer

/// Renders `Samples/Showcase.md` through the real reader view into PNGs for visual review.
/// Opt-in: run with `TEST_RUNNER_SNAPSHOT_DIR=/some/dir xcodebuild test …`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil))
struct ReaderSnapshotTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func renderShowcase(appearanceName: NSAppearance.Name) async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]!)
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/Showcase.md")
        let session = DocumentSession(fileURL: sample)
        await DocumentManager(watchesFiles: false).reload(session)
        let model = try #require(session.model)
        for case .mermaid(let source) in model.blocks {
            _ = await MermaidRenderer.shared.renderAndWait(source, dark: appearanceName == .darkAqua)
        }

        let coordinator = ReaderCoordinator(isPreview: false)
        let scrollView = coordinator.makeScrollView()
        scrollView.appearance = NSAppearance(named: appearanceName)
        scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        coordinator.display(ReaderContent(id: session.id, model: model, version: session.contentVersion, documentURL: sample, detailsToggles: []), session: session, style: .default)

        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()
        let height = textView.frame.height
        scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: height)
        textView.frame.size.height = height

        // Code blocks place their views right after a draw pass.
        for _ in 0..<2 {
            _ = textView.bitmapImageRepForCachingDisplay(in: textView.bounds).map { textView.cacheDisplay(in: textView.bounds, to: $0) }
            try await Task.sleep(for: .milliseconds(150))
        }

        var png: Data?
        NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
            let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds)!
            textView.cacheDisplay(in: textView.bounds, to: rep)
            png = rep.representation(using: .png, properties: [:])
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(png).write(to: output.appendingPathComponent("showcase-\(appearanceName == .aqua ? "light" : "dark").png"))
    }
}

/// Captures the real main window (tabs, sidebar, toolbar) with the sample documents open.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil))
struct WindowSnapshotTests {
    @Test func captureMainWindow() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]!)
        let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Samples")
        let windowState = try #require(AppDelegate.current?.model.windows.first)
        let showcase = windowState.open(samples.appendingPathComponent("Showcase.md"))
        windowState.open(samples.appendingPathComponent("Linked.md"))
        windowState.activate(showcase.id)
        _ = await waitUntil { showcase.state == .ready }
        try await Task.sleep(for: .seconds(1))
        showcase.navigate(to: .outlineItem(2))
        try await Task.sleep(for: .seconds(1))

        let window = try #require(NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.title != "" })
        let frameView = try #require(window.contentView?.superview)
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("window.png"))

        // Dump the menu bar so shortcuts can be reviewed for duplicates.
        var lines: [String] = []
        func dump(_ menu: NSMenu, depth: Int) {
            for item in menu.items where !item.isSeparatorItem {
                let key = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.rawValue >> 17):\(item.keyEquivalent)]"
                lines.append(String(repeating: "  ", count: depth) + item.title + key)
                if let submenu = item.submenu, depth < 2 { dump(submenu, depth: depth + 1) }
            }
        }
        if let main = NSApp.mainMenu { dump(main, depth: 0) }
        try lines.joined(separator: "\n").write(to: output.appendingPathComponent("menus.txt"), atomically: true, encoding: .utf8)

        // Find: the command must reach the reader's find bar.
        UserActions.performFind(.showFindInterface)
        try await Task.sleep(for: .milliseconds(300))
        #expect(ActiveTextView.current(in: nil)?.enclosingScrollView?.isFindBarVisible == true)

        // Find Next reaches text inside a code block, via the same route as the menu.
        UserActions.performFind(.hideFindInterface)
        let findPasteboard = NSPasteboard(name: .find)
        findPasteboard.clearContents()
        findPasteboard.setString("watchDebounce", forType: .string)
        UserActions.performFind(.showFindInterface)
        try await Task.sleep(for: .milliseconds(200))
        UserActions.performFind(.nextMatch)
        try await Task.sleep(for: .milliseconds(300))
        // With the find bar open, Find Next moves the find indicator; closing the bar selects.
        let findFrameView = try #require(window.contentView?.superview)
        let findRep = try #require(findFrameView.bitmapImageRepForCachingDisplay(in: findFrameView.bounds))
        findFrameView.cacheDisplay(in: findFrameView.bounds, to: findRep)
        try #require(findRep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("window-find.png"))
        UserActions.performFind(.hideFindInterface)
        try await Task.sleep(for: .milliseconds(200))
        let reader = try #require(ActiveTextView.current(in: nil))
        var codeSelection: String?
        for case let view as CodeBlockView in reader.subviews {
            let range = view.textView.selectedRange()
            if range.length > 0 { codeSelection = (view.textView.string as NSString).substring(with: range) }
        }
        #expect(codeSelection == "watchDebounce")

        // Scroll restoration: a freshly opened tab with a stored position lands there.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Restored-\(UUID().uuidString).md")
        try FileManager.default.copyItem(at: samples.appendingPathComponent("Showcase.md"), to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let rendered = MarkdownRenderer(style: .default, documentURL: copy).render(try #require(showcase.model))
        let tableHeading = try #require(showcase.model?.outline.firstIndex { $0.title == "Table" })
        let restored = DocumentSession(fileURL: copy, scrollPosition: rendered.outlineLocations[tableHeading]!)
        windowState.restore(from: SessionSnapshot(
            documents: [.init(path: copy.path, bookmark: nil, scrollPosition: restored.scrollPosition)],
            activeIndex: 0
        ))
        let session = try #require(windowState.activeDocument)
        #expect(session.fileURL.lastPathComponent == copy.lastPathComponent)
        #expect(await waitUntil { session.currentOutlineIndex == tableHeading })
    }
}

/// Renders tables at a wide and a narrow width.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil))
struct TableSnapshotTests {
    @Test(arguments: [900.0, 460.0])
    func renderTables(width: Double) throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]!)
        let source = """
        Narrow table:

        | Key | Value |
        |-----|------:|
        | a   | 1     |
        | bb  | 22    |

        Wide table:

        | Column | Description | Notes |
        |--------|-------------|-------|
        | alpha  | A fairly long description that will need to wrap when the window is narrow enough | short |
        | beta   | Another cell | This one also has quite a bit of text in it to force wrapping |

        After the tables.
        """
        let model = MarkdownParser.parse(source)
        let session = DocumentSession(fileURL: URL(fileURLWithPath: "/tmp/tables.md"))
        let coordinator = ReaderCoordinator(isPreview: false)
        let scrollView = coordinator.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        coordinator.display(ReaderContent(id: UUID(), model: model, version: 1, documentURL: session.fileURL, detailsToggles: []), session: session, style: .default)
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()
        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("tables-\(Int(width)).png"))
    }
}
