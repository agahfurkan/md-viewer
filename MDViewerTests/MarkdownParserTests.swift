import Foundation
import Testing
@testable import MDViewer

struct MarkdownParserTests {
    @Test func headingsProduceOutlineWithHierarchy() {
        let model = MarkdownParser.parse("""
        # Project

        ## Architecture

        ### Networking

        ## Installation
        """)
        #expect(model.outline.map(\.title) == ["Project", "Architecture", "Networking", "Installation"])
        #expect(model.outline.map(\.level) == [1, 2, 3, 2])
        #expect(model.outline.map(\.id) == [0, 1, 2, 3])
        #expect(model.outline.map(\.anchor) == ["project", "architecture", "networking", "installation"])
    }

    @Test func duplicateHeadingsGetUniqueAnchors() {
        let model = MarkdownParser.parse("## Usage\n\n## Usage\n\n## Usage")
        #expect(model.outline.map(\.anchor) == ["usage", "usage-1", "usage-2"])
    }

    @Test func slugsFollowGitHubRules() {
        #expect(HeadingSlugger.baseSlug(for: "Getting Started!") == "getting-started")
        #expect(HeadingSlugger.baseSlug(for: "API v2.0 (beta)") == "api-v20-beta")
        #expect(HeadingSlugger.baseSlug(for: "snake_case & kebab-case") == "snake_case--kebab-case")
        #expect(HeadingSlugger.baseSlug(for: "Überblick") == "überblick")
    }

    @Test func inlineFormatting() {
        let model = MarkdownParser.parse("Some **bold**, *italic*, ~~gone~~ and `code`.")
        guard case .paragraph(let inlines) = model.blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        #expect(inlines.contains(.strong([.text("bold")])))
        #expect(inlines.contains(.emphasis([.text("italic")])))
        #expect(inlines.contains(.strikethrough([.text("gone")])))
        #expect(inlines.contains(.code("code")))
    }

    @Test func fencedCodeBlockKeepsLanguageAndHighlights() {
        let model = MarkdownParser.parse("""
        ```swift
        let value = "hi" // note
        ```
        """)
        guard case .codeBlock(let code) = model.blocks.first else {
            Issue.record("Expected code block")
            return
        }
        #expect(code.language == "swift")
        #expect(code.code == "let value = \"hi\" // note")
        #expect(code.tokens.contains { $0.kind == .keyword && $0.location == 0 && $0.length == 3 })
        #expect(code.tokens.contains { $0.kind == .string })
        #expect(code.tokens.contains { $0.kind == .comment })
    }

    @Test func nestedListsAndTaskItems() {
        let model = MarkdownParser.parse("""
        - [x] done
        - [ ] todo
          1. first
          2. second
        """)
        guard case .list(let list) = model.blocks.first else {
            Issue.record("Expected list")
            return
        }
        #expect(!list.isOrdered)
        #expect(list.items.map(\.task) == [.checked, .unchecked])
        guard case .list(let nested) = list.items[1].blocks.last else {
            Issue.record("Expected nested list")
            return
        }
        #expect(nested.isOrdered)
        #expect(nested.startIndex == 1)
        #expect(nested.items.count == 2)
    }

    @Test func orderedListStartIndex() {
        let model = MarkdownParser.parse("3. three\n4. four")
        guard case .list(let list) = model.blocks.first else {
            Issue.record("Expected list")
            return
        }
        #expect(list.startIndex == 3)
    }

    @Test func tablesWithAlignment() {
        let model = MarkdownParser.parse("""
        | Name | Count |
        |:-----|------:|
        | a    | 1     |
        | b    | 2     |
        """)
        guard case .table(let table) = model.blocks.first else {
            Issue.record("Expected table")
            return
        }
        #expect(table.alignments == [.left, .right])
        #expect(table.header.map(\.plainText) == ["Name", "Count"])
        #expect(table.rows.count == 2)
        #expect(table.rows[1].map(\.plainText) == ["b", "2"])
    }

    @Test func blockquoteRuleLinksAndImages() {
        let model = MarkdownParser.parse("""
        > quoted

        ---

        [Architecture](./ARCHITECTURE.md) ![diagram](./images/a.png "Title")
        """)
        #expect(model.blocks.count == 3)
        guard case .blockQuote = model.blocks[0], case .thematicBreak = model.blocks[1],
              case .paragraph(let inlines) = model.blocks[2]
        else {
            Issue.record("Unexpected block structure: \(model.blocks)")
            return
        }
        #expect(inlines.contains(.link(destination: "./ARCHITECTURE.md", title: nil, content: [.text("Architecture")])))
        #expect(inlines.contains(.image(source: "./images/a.png", title: "Title", alt: "diagram")))
    }

    @Test func bareURLsBecomeLinks() {
        let model = MarkdownParser.parse("See https://example.com/docs. Or www.apple.com")
        guard case .paragraph(let inlines) = model.blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        #expect(inlines.contains(.link(destination: "https://example.com/docs", title: nil, content: [.text("https://example.com/docs")])))
        #expect(inlines.contains(.link(destination: "https://www.apple.com", title: nil, content: [.text("www.apple.com")])))
        #expect(inlines.last == .link(destination: "https://www.apple.com", title: nil, content: [.text("www.apple.com")]))
    }

    @Test func githubAlerts() {
        let model = MarkdownParser.parse("> [!WARNING]\n> Be careful.")
        guard case .alert(let kind, let blocks) = model.blocks.first else {
            Issue.record("Expected alert, got \(model.blocks)")
            return
        }
        #expect(kind == .warning)
        #expect(blocks == [.paragraph([.text("Be careful.")])])
    }

    @Test func alignedHTMLBlocksKeepImagesAndAlignment() {
        let model = MarkdownParser.parse("""
        <p align="center">
          <img src="logo.png" alt="Logo" width="100">
        </p>

        Line one<br>line two
        """)
        guard case .aligned(.center, let inner)? = model.blocks.first, case .paragraph(let first)? = inner.first else {
            Issue.record("Expected centered paragraph, got \(model.blocks)")
            return
        }
        #expect(first.contains(.image(source: "logo.png", title: nil, alt: "Logo", width: 100)))
        guard case .paragraph(let second) = model.blocks.last else {
            Issue.record("Expected paragraph")
            return
        }
        #expect(second.contains(.lineBreak))
    }

    @Test func inlineHTMLFormatting() {
        let model = MarkdownParser.parse("Press <kbd>⌘</kbd>+<kbd>K</kbd>, H<sub>2</sub>O, x<sup>2</sup>, <mark>hot</mark>, <u>under</u>, <b>bold</b> <a href=\"https://x.dev\">link</a> <span>plain</span>")
        guard case .paragraph(let inlines) = model.blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        #expect(inlines.contains(.styled(.keyboard, [.text("⌘")])))
        #expect(inlines.contains(.styled(.keyboard, [.text("K")])))
        #expect(inlines.contains(.styled(.subscript, [.text("2")])))
        #expect(inlines.contains(.styled(.superscript, [.text("2")])))
        #expect(inlines.contains(.styled(.highlight, [.text("hot")])))
        #expect(inlines.contains(.styled(.underline, [.text("under")])))
        #expect(inlines.contains(.strong([.text("bold")])))
        #expect(inlines.contains(.link(destination: "https://x.dev", title: nil, content: [.text("link")])))
        #expect(inlines.plainText.contains("plain"))
        #expect(!inlines.plainText.contains("<"))
    }

    @Test func unmatchedInlineTagsAreDropped() {
        let model = MarkdownParser.parse("a </b> b <i>c")
        guard case .paragraph(let inlines) = model.blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        #expect(inlines.plainText == "a  b c")
    }

    @Test func detailsWithMarkdownContent() {
        let model = MarkdownParser.parse("""
        <details open>
        <summary>More <b>info</b></summary>

        Hidden **markdown**

        ## Inside

        </details>

        <details><summary>Second</summary>

        Text

        </details>
        """)
        guard case .details(let first)? = model.blocks.first, case .details(let second)? = model.blocks.last else {
            Issue.record("Expected two details, got \(model.blocks)")
            return
        }
        #expect(first.id == 0 && second.id == 1)
        #expect(first.isOpenByDefault)
        #expect(!second.isOpenByDefault)
        #expect(first.summary.plainText == "More info")
        #expect(first.blocks.first == .paragraph([.text("Hidden "), .strong([.text("markdown")])]))
        #expect(model.outline.map(\.title) == ["Inside"])
    }

    @Test func htmlHeadingsJoinTheOutline() {
        let model = MarkdownParser.parse("<h1 align=\"center\">Project</h1>\n\n## Usage")
        #expect(model.outline.map(\.title) == ["Project", "Usage"])
        #expect(model.outline.map(\.anchor) == ["project", "usage"])
    }

    @Test func htmlTablesAndLists() {
        let model = MarkdownParser.parse("""
        <table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>

        <ul><li>one</li><li>two</li></ul>
        """)
        guard case .table(let table)? = model.blocks.first, case .list(let list)? = model.blocks.last else {
            Issue.record("Unexpected blocks \(model.blocks)")
            return
        }
        #expect(table.header.map(\.plainText) == ["A", "B"])
        #expect(table.rows.map { $0.map(\.plainText) } == [["1", "2"]])
        #expect(list.items.count == 2)
    }

    @Test func htmlEntities() {
        #expect(HTMLEntities.decode("&copy; &#8212; &#x1F600; &amp;lt; &unknown;") == "© — 😀 &lt; &unknown;")
    }

    @Test func footnotesAreNumberedByFirstReference() {
        let model = MarkdownParser.parse("""
        Second[^b] and first[^a] and again[^b].

        [^a]: Note **A**.
        [^b]: Note B
            continued.
        [^unused]: Never referenced.
        """)
        guard case .paragraph(let inlines)? = model.blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        #expect(inlines.contains(.footnoteReference(label: "b", number: 1)))
        #expect(inlines.contains(.footnoteReference(label: "a", number: 2)))
        guard case .footnotes(let notes)? = model.blocks.last else {
            Issue.record("Expected footnotes, got \(model.blocks)")
            return
        }
        #expect(notes.map(\.label) == ["b", "a"])
        #expect(notes.map(\.number) == [1, 2])
        #expect(notes[0].blocks.map { if case .paragraph(let i) = $0 { i.plainText } else { "" } }.first?.hasPrefix("Note B continued.") == true)
        #expect(model.blocks.count == 2)
    }

    @Test func footnoteSyntaxInCodeIsLeftAlone() {
        let model = MarkdownParser.parse("```\n[^x]: not a note\n```\n\nUse `[^x]` literally.")
        #expect(model.blocks.count == 2)
        guard case .codeBlock(let code) = model.blocks[0] else {
            Issue.record("Expected code block")
            return
        }
        #expect(code.code == "[^x]: not a note")
    }

    @Test func mathIsProtectedFromMarkdown() {
        let model = MarkdownParser.parse("""
        Inline $a_1 + b_1$ costs $5 and $10, and `$not math$`.

        $$
        \\sum_{i=1}^{n} x_i
        $$

        ```math
        E = mc^2
        ```
        """)
        guard case .paragraph(let inlines) = model.blocks[0] else {
            Issue.record("Expected paragraph")
            return
        }
        #expect(inlines.contains(.math("a_1 + b_1", display: false)))
        #expect(inlines.plainText.contains("costs $5 and $10"))
        #expect(inlines.contains(.code("$not math$")))
        #expect(model.blocks[1] == .mathBlock("\\sum_{i=1}^{n} x_i"))
        #expect(model.blocks[2] == .mathBlock("E = mc^2"))
    }

    @Test func mermaidBlocks() {
        let model = MarkdownParser.parse("```mermaid\ngraph TD; A-->B\n```")
        #expect(model.blocks == [.mermaid("graph TD; A-->B")])
    }

    @Test(arguments: [
        "",
        "```",
        "| broken | table\n|---",
        "[unclosed link(",
        "<div><span>",
        String(repeating: "> ", count: 200) + "deep",
        String(repeating: "- ", count: 300) + "deep",
        "\u{0}\u{1}binary-ish",
    ])
    func malformedInputNeverCrashes(_ source: String) {
        _ = MarkdownParser.parse(source)
    }

    @Test func largeDocumentParsesQuickly() {
        let section = """
        ## Section

        Paragraph with **bold** text and a [link](./other.md).

        ```swift
        func f() -> Int { 42 }
        ```

        - item
        - item

        """
        let source = String(repeating: section, count: 2_000)
        let start = ContinuousClock.now
        let model = MarkdownParser.parse(source)
        let elapsed = ContinuousClock.now - start
        #expect(model.outline.count == 2_000)
        #expect(elapsed < .seconds(5))
    }
}

struct MarkdownNestingTests {
    @Test func pathologicalNestingIsFlattened() async {
        let source = String(repeating: "> ", count: 5_000) + "deep"
        let model = await MarkdownParser.parseInBackground(source)
        var depth = 0
        var blocks = model.blocks
        while case .blockQuote(let children)? = blocks.first {
            depth += 1
            blocks = children
        }
        #expect(depth <= 25)
        #expect(blocks.first == .paragraph([.text("deep")]))
    }
}
