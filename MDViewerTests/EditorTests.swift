import AppKit
import SwiftUI
import Testing
@testable import MDViewer

struct MarkdownSourceHighlighterTests {
    private func kinds(_ text: String) -> [(String, SyntaxToken.Kind)] {
        let ns = text as NSString
        return MarkdownSourceHighlighter.tokens(for: text).map { (ns.substring(with: $0.range), $0.kind) }
    }

    @Test func blockStructure() {
        let tokens = kinds("# Title\n\n> quoted\n\n- item\n1. first\n- [x] done\n\n---")
        #expect(tokens.contains { $0 == ("# Title", .keyword) })
        #expect(tokens.contains { $0 == ("> quoted", .comment) })
        #expect(tokens.contains { $0 == ("- item".prefix(1).description, .attribute) })
        #expect(tokens.contains { $0 == ("1.", .attribute) })
        #expect(tokens.contains { $0 == ("- [x]", .attribute) })
        #expect(tokens.contains { $0 == ("---", .meta) })
    }

    @Test func inlineStructure() {
        let tokens = kinds("Some **bold**, *em*, `code *not em*`, [link](https://x.dev) and ~~gone~~ <br>.")
        #expect(tokens.contains { $0 == ("**bold**", .type) })
        #expect(tokens.contains { $0 == ("*em*", .type) })
        #expect(tokens.contains { $0 == ("`code *not em*`", .string) })
        #expect(!tokens.contains { $0 == ("*not em*", .type) })
        #expect(tokens.contains { $0 == ("link", .function) })
        #expect(tokens.contains { $0 == ("https://x.dev", .variable) })
        #expect(tokens.contains { $0 == ("~~gone~~", .comment) })
        #expect(tokens.contains { $0 == ("<br>", .tag) })
    }

    @Test func fencedCodeIsOneColorAndNotMarkdown() {
        let tokens = kinds("```swift\n# not a heading\n```\n# Heading")
        #expect(tokens.map(\.1) == [.meta, .string, .meta, .keyword])
    }

    @Test func rangesStayInBounds() {
        let text = "é👍 **b** `c`\r\n# h\n"
        let length = (text as NSString).length
        for token in MarkdownSourceHighlighter.tokens(for: text) {
            #expect(NSMaxRange(token.range) <= length)
        }
    }
}

@MainActor
struct LivePreviewTests {
    @Test func previewFollowsEditsAfterAPause() async {
        let editor = EditorState(text: "# One", model: MarkdownParser.parse("# One"))
        editor.previewDelay = .milliseconds(30)
        let before = editor.previewVersion
        editor.userEdited("# One\n\n## Two")
        #expect(await waitUntil { editor.previewModel?.outline.map(\.title) == ["One", "Two"] })
        #expect(editor.previewVersion == before + 1)
    }

    @Test func rapidTypingProducesOneUpdate() async throws {
        let editor = EditorState(text: "a", model: MarkdownParser.parse("a"))
        editor.previewDelay = .milliseconds(80)
        for text in ["ab", "abc", "abcd", "abcde"] {
            editor.userEdited(text)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await waitUntil { editor.previewModel == MarkdownParser.parse("abcde") })
        #expect(editor.previewVersion == 1)
    }
}

/// Renders the source editor for visual review (opt-in, like the reader snapshots).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil))
struct EditorSnapshotTests {
    @Test func renderEditor() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]!)
        let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Samples/Showcase.md")
        let editor = EditorState(text: try String(contentsOf: sample, encoding: .utf8), model: nil)
        let host = NSHostingView(rootView: SourceEditorView(editor: editor, fontSize: 13).frame(width: 800, height: 640))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("editor.png"))
    }
}
