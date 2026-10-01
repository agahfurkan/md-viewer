import AppKit
import Testing
@testable import MDViewer

@MainActor
@Suite(.serialized)
struct CodeBlockTests {
    private func makeReader(_ markdown: String) -> (ReaderCoordinator, NSScrollView, ReaderTextView) {
        let model = MarkdownParser.parse(markdown)
        let session = DocumentSession(fileURL: URL(fileURLWithPath: "/tmp/code.md"))
        let coordinator = ReaderCoordinator(isPreview: false)
        let scrollView = coordinator.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        coordinator.display(ReaderContent(id: UUID(), model: model, version: 1, documentURL: session.fileURL, detailsToggles: []), session: session, style: .default)
        return (coordinator, scrollView, scrollView.documentView as! ReaderTextView)
    }

    private let document = """
    Intro paragraph mentions alpha.

    ```swift
    let veryLongLine = "\(String(repeating: "wide ", count: 60))" // UNIQUECODEWORD
    ```

    Closing paragraph mentions alpha again.
    """

    @Test func codeBlocksAreSingleAttachments() throws {
        let (_, _, textView) = makeReader(document)
        var cells: [CodeBlockAttachmentCell] = []
        textView.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textView.textStorage!.length)) { value, _, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? CodeBlockAttachmentCell { cells.append(cell) }
        }
        #expect(cells.count == 1)
        #expect(cells[0].code.contains("UNIQUECODEWORD"))
        #expect(cells[0].language == "swift")
        // Long lines don't wrap: the block's natural width exceeds the reading width.
        #expect(cells[0].cellSize().width > 700)
        #expect(!textView.string.contains("UNIQUECODEWORD"))
    }

    @Test func findSearchesInsideCodeBlocks() throws {
        let (_, _, textView) = makeReader(document)
        let client = try #require(textView.findClient)
        #expect(client.string.contains("UNIQUECODEWORD"))
        #expect(client.string.contains("Intro paragraph"))
        #expect(client.string.contains("Closing paragraph"))

        // Select the match through the client, as NSTextFinder does.
        let location = (client.string as NSString).range(of: "UNIQUECODEWORD")
        client.selectedRanges = [NSValue(range: location)]
        let cell = try #require(findCell(in: textView))
        let codeSelection = cell.textView.selectedRange()
        #expect((cell.code as NSString).substring(with: codeSelection) == "UNIQUECODEWORD")
        #expect(cell.view.superview === textView)
        #expect(client.rects(forCharacterRange: location)?.isEmpty == false)
    }

    // Find Next driven through NSTextFinder itself is verified in the live window
    // (WindowSnapshotTests): NSTextFinder keeps app-wide search state, which makes it
    // order-dependent inside the unit test process.

    @Test func documentTextMatchesMapBackToTheReader() throws {
        let (_, _, textView) = makeReader(document)
        let client = try #require(textView.findClient)
        let range = (client.string as NSString).range(of: "Closing paragraph")
        client.selectedRanges = [NSValue(range: range)]
        let selected = (textView.string as NSString).substring(with: textView.selectedRange())
        #expect(selected == "Closing paragraph")
        #expect(client.firstSelectedRange == range)
    }

    @Test func copyingASelectionIncludesCode() throws {
        let (_, _, textView) = makeReader(document)
        textView.selectAll(nil)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MDViewerTests-\(UUID().uuidString)"))
        #expect(textView.writeSelection(to: pasteboard, types: [.string]))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains("Intro paragraph"))
        #expect(copied.contains("UNIQUECODEWORD"))
        #expect(copied.contains("Closing paragraph"))
        #expect(!copied.contains("\u{FFFC}"))
    }

    private func findCell(in textView: NSTextView) -> CodeBlockAttachmentCell? {
        var found: CodeBlockAttachmentCell?
        textView.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textView.textStorage!.length)) { value, _, stop in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? CodeBlockAttachmentCell {
                found = cell
                stop.pointee = true
            }
        }
        return found
    }
}
