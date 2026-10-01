import AppKit
import Testing
@testable import MDViewer

@MainActor
struct MarkdownRendererTests {
    let directory = TemporaryDirectory()

    private func render(_ source: String, documentURL: URL? = nil) -> RenderedMarkdown {
        MarkdownRenderer(style: .default, documentURL: documentURL).render(MarkdownParser.parse(source))
    }

    @Test func headingLocationsPointAtHeadingText() {
        let rendered = render("# Title\n\nIntro text.\n\n## Details\n\nMore.")
        let string = rendered.attributedString.string as NSString
        #expect(rendered.outlineLocations.count == 2)
        #expect(string.substring(from: rendered.outlineLocations[0]!).hasPrefix("Title"))
        #expect(string.substring(from: rendered.outlineLocations[1]!).hasPrefix("Details"))
        #expect(rendered.anchorLocations["details"] == rendered.outlineLocations[1]!)
    }

    @Test func linksCarryTheirDestination() {
        let rendered = render("Read [the docs](./docs/README.md).")
        let string = rendered.attributedString.string as NSString
        let location = string.range(of: "the docs").location
        #expect(rendered.attributedString.attribute(.link, at: location, effectiveRange: nil) as? String == "./docs/README.md")
    }

    @Test func codeBlocksAreMonospacedAndColored() throws {
        let rendered = render("```swift\nlet x = 1\n```")
        let attachment = rendered.attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        let cell = try #require(attachment?.attachmentCell as? CodeBlockAttachmentCell)
        let code = cell.highlightedCode
        #expect(code.string == "let x = 1")
        let font = code.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        let color = code.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == ReaderPalette.syntax(.keyword))
    }

    @Test func relativeImagesLoadFromTheDocumentDirectory() throws {
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("images"), withIntermediateDirectories: true)
        try png.write(to: directory.url.appendingPathComponent("images/pic.png"))
        let document = directory.write("doc.md", "")

        let rendered = render("![pic](./images/pic.png) ![missing](./images/none.png)", documentURL: document)
        var cells: [ImageAttachmentCell] = []
        rendered.attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.attributedString.length)) { value, _, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? ImageAttachmentCell {
                cells.append(cell)
            }
        }
        #expect(cells.count == 2)
        #expect(cells[0].displayImage != nil)
        #expect(cells[1].displayImage == nil)
    }

    @Test func tablesUseTextTableBlocks() {
        let rendered = render("| a | b |\n|---|---|\n| 1 | 2 |")
        let style = rendered.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.textBlocks.first is NSTextTableBlock)
        #expect(rendered.attributedString.string.contains("a"))
        #expect(rendered.attributedString.string.contains("2"))
    }

    @Test func everyBlockTypeRendersWithoutCrashing() {
        let source = """
        # H1
        ## H2
        ###### H6

        Text with **bold**, *italic*, ~~strike~~, `code`, and a https://example.com link.
        Line break here\\
        next line.

        > Quote with a list:
        > - one
        >   ```
        >   nested code
        >   ```

        > [!TIP]
        > Useful.

        1. First
           - nested **item**
             - deeper
        2. Second

        - [ ] open
        - [x] done

        | Left | Center | Right |
        |:-----|:------:|------:|
        | a | b | c |
        | longer cell | | x |

        ---

        ```diff
        - old
        + new
        ```
        """
        let rendered = render(source)
        #expect(rendered.attributedString.length > 100)
        #expect(rendered.outlineLocations.count == 3)
    }
}

@MainActor
struct DiagramAndMathTests {
    @Test func mathRendersWithBaselineMetrics() throws {
        let inline = try #require(MathRenderer.render(#"\frac{a}{b} + x_i^2"#, fontSize: 16, display: false))
        #expect(inline.image.size.width > 20)
        #expect(inline.descent > 0)
        let display = try #require(MathRenderer.render(#"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}"#, fontSize: 16, display: true))
        #expect(display.image.size.height > inline.image.size.height)
        #expect(MathRenderer.render(#"\frac{a}{"#, fontSize: 16, display: false) == nil)
    }

    @Test func mermaidRendersToAVectorImage() async throws {
        let result = await MermaidRenderer.shared.renderAndWait("graph TD\n  A[Start] --> B{Choice}\n  B -->|yes| C[Done]", dark: false)
        guard case .image(let image)? = result else {
            Issue.record("Expected an image, got \(String(describing: result))")
            return
        }
        #expect(image.size.width > 50 && image.size.height > 50)
    }

    @Test func invalidMermaidReportsAnError() async {
        let result = await MermaidRenderer.shared.renderAndWait("graph TD\n  A -->", dark: true)
        guard case .failure(let message)? = result else {
            Issue.record("Expected a failure, got \(String(describing: result))")
            return
        }
        #expect(!message.isEmpty)
    }
}

struct TableSizingTests {
    @Test func tablesThatFitUseTheirNaturalProportions() {
        let shares = MarkdownRenderer.columnShares(minimum: [20, 30], natural: [40, 60], available: 800, cellChrome: 0)
        #expect(shares.map { $0.rounded() } == [40, 60])
    }

    @Test func squeezedColumnsKeepTheirLongestWord() {
        // Column 0 is short; column 1 wants far more than there is room for.
        let shares = MarkdownRenderer.columnShares(minimum: [50, 80], natural: [50, 900], available: 300, cellChrome: 0)
        #expect(abs(shares[0] - 50.0 / 300 * 100) < 0.5)
        #expect(abs(shares.reduce(0, +) - 100) < 0.01)
    }

    @Test func tooNarrowForEvenTheMinimumFallsBackToMinimumProportions() {
        let shares = MarkdownRenderer.columnShares(minimum: [100, 300], natural: [200, 600], available: 200, cellChrome: 0)
        #expect(shares.map { $0.rounded() } == [25, 75])
    }
}
