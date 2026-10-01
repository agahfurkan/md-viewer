import Foundation
import Markdown

/// Converts Markdown source text into a `MarkdownDocumentModel`.
///
/// Parsing uses Apple's `swift-markdown` (cmark-gfm) and then maps its AST into the app's own
/// model, so the rest of the app never depends on the parser library. The parser is tolerant:
/// any input string produces a model.
///
/// Everything here is synchronous and free of shared state, so it is safe to call from a
/// background task.
enum MarkdownParser {
    static func parse(_ source: String) -> MarkdownDocumentModel {
        let preprocessed = MarkdownPreprocessor.process(source)
        var converter = Converter(
            math: preprocessed.math,
            footnoteLabels: Set(preprocessed.footnotes.map(\.label))
        )
        var blocks = converter.convertDocument(preprocessed.source)

        // Footnotes: convert definitions in order of first reference. Definitions can reference
        // further footnotes, which then get the next numbers.
        let definitions = Dictionary(preprocessed.footnotes.map { ($0.label, $0.text) }, uniquingKeysWith: { first, _ in first })
        var footnotes: [MarkdownFootnote] = []
        var converted = Set<String>()
        while let (label, number) = converter.footnoteNumbers
            .filter({ !converted.contains($0.key) })
            .min(by: { $0.value < $1.value }) {
            converted.insert(label)
            var content = converter.convertDocument(definitions[label] ?? "")
            let backLink = MarkdownInline.link(
                destination: "#" + MarkdownFootnote.referenceAnchor(for: label),
                title: "Back to reference",
                content: [.text("↩\u{FE0E}")]
            )
            if case .paragraph(let inlines)? = content.last {
                content[content.count - 1] = .paragraph(inlines + [.text(" "), backLink])
            } else {
                content.append(.paragraph([backLink]))
            }
            footnotes.append(MarkdownFootnote(label: label, number: number, blocks: content))
        }
        if !footnotes.isEmpty {
            blocks.append(.footnotes(footnotes))
        }

        var structure = DocumentStructure()
        let finished = structure.finish(blocks)
        return MarkdownDocumentModel(blocks: finished, outline: structure.outline)
    }

    /// Parses on a dedicated thread with a large stack. swift-markdown converts cmark's tree
    /// recursively, so pathological nesting (hundreds of `>` levels) could otherwise overflow the
    /// small stacks of the concurrency thread pool.
    static func parseInBackground(_ source: String) async -> MarkdownDocumentModel {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: parse(source))
            }
            thread.stackSize = 32 << 20
            thread.qualityOfService = .userInitiated
            thread.name = "MDViewer.MarkdownParser"
            thread.start()
        }
    }
}

// MARK: - Document structure

/// Assigns heading anchors, the outline and `<details>` IDs in document order, after all
/// conversion (including HTML folding and footnotes) is done.
private struct DocumentStructure {
    var outline: [OutlineItem] = []
    private var slugger = HeadingSlugger()
    private var detailsCount = 0

    mutating func finish(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        blocks.map { finish($0) }
    }

    private mutating func finish(_ block: MarkdownBlock) -> MarkdownBlock {
        switch block {
        case .heading(let level, let content, _):
            let title = content.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            let anchor = slugger.slug(for: title)
            outline.append(OutlineItem(id: outline.count, level: level, title: title, anchor: anchor))
            return .heading(level: level, content: content, anchor: anchor)
        case .blockQuote(let children):
            return .blockQuote(finish(children))
        case .alert(let kind, let children):
            return .alert(kind, finish(children))
        case .aligned(let alignment, let children):
            return .aligned(alignment, finish(children))
        case .list(var list):
            list.items = list.items.map { item in
                var item = item
                item.blocks = finish(item.blocks)
                return item
            }
            return .list(list)
        case .details(var details):
            details.id = detailsCount
            detailsCount += 1
            details.blocks = finish(details.blocks)
            return .details(details)
        case .footnotes(let notes):
            return .footnotes(notes.map { note in
                var note = note
                note.blocks = finish(note.blocks)
                return note
            })
        case .paragraph, .codeBlock, .table, .thematicBreak, .mathBlock, .mermaid:
            return block
        }
    }
}

// MARK: - AST conversion

private struct Converter {
    /// Deeper container nesting is flattened to plain text. Real documents never come close; the
    /// limit keeps recursion (here and in the renderer) bounded for hostile input.
    static let maximumBlockDepth = 24
    static let maximumInlineDepth = 32

    let math: [String]
    let footnoteLabels: Set<String>
    /// Footnote number per label, assigned on first reference.
    private(set) var footnoteNumbers: [String: Int] = [:]
    private var depth = 0

    init(math: [String], footnoteLabels: Set<String>) {
        self.math = math
        self.footnoteLabels = footnoteLabels
    }

    mutating func convertDocument(_ source: String) -> [MarkdownBlock] {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        return convertBlocks(document.children)
    }

    mutating func convertBlocks(_ children: MarkupChildren) -> [MarkdownBlock] {
        var pieces: [BlockPiece] = []
        for child in children {
            if let html = child as? HTMLBlock {
                pieces.append(.html(HTMLTokenizer.tokenize(html.rawHTML)))
            } else {
                pieces.append(contentsOf: convertBlock(child).map(BlockPiece.block))
            }
        }
        return HTMLBlockFolder.fold(pieces) { finishInlines($0, insideLink: false) }
    }

    private mutating func convertBlock(_ markup: Markup) -> [MarkdownBlock] {
        let isLeaf = markup is Heading || markup is Paragraph || markup is CodeBlock
            || markup is Markdown.Table || markup is ThematicBreak || markup is HTMLBlock
        if !isLeaf {
            if depth >= Self.maximumBlockDepth {
                let text = Self.flattenedText(markup)
                return text.isEmpty ? [] : [.paragraph([.text(text)])]
            }
            depth += 1
        }
        defer { if !isLeaf { depth -= 1 } }

        switch markup {
        case let heading as Heading:
            // Anchors and the outline are assigned once the whole document is converted.
            return [.heading(level: heading.level, content: convertInlines(heading.children), anchor: "")]

        case let paragraph as Paragraph:
            let inlines = convertInlines(paragraph.children)
            if inlines.count == 1, case .math(let latex, true) = inlines[0] {
                return [.mathBlock(latex)]
            }
            return inlines.isEmpty ? [] : [.paragraph(inlines)]

        case let code as CodeBlock:
            var text = code.code
            if text.hasSuffix("\n") { text.removeLast() }
            let language = code.language?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            switch language?.lowercased() {
            case "math", "latex", "tex", "katex":
                return [.mathBlock(text)]
            case "mermaid":
                return [.mermaid(text)]
            default:
                return [.codeBlock(MarkdownCodeBlock(
                    language: language,
                    code: text,
                    tokens: SyntaxHighlighter.tokens(for: text, language: language)
                ))]
            }

        case let quote as BlockQuote:
            let children = convertBlocks(quote.children)
            if let (kind, remaining) = Self.extractAlert(from: children) {
                return [.alert(kind, remaining)]
            }
            return [.blockQuote(children)]

        case let list as OrderedList:
            return [.list(MarkdownList(isOrdered: true, startIndex: Int(list.startIndex), items: convertListItems(list.children)))]

        case let list as UnorderedList:
            return [.list(MarkdownList(isOrdered: false, startIndex: 1, items: convertListItems(list.children)))]

        case let table as Markdown.Table:
            return [.table(convertTable(table))]

        case is ThematicBreak:
            return [.thematicBreak]

        default:
            // Block directives, custom blocks, … are rendered as their plain child content.
            return convertBlocks(markup.children)
        }
    }

    private mutating func convertListItems(_ children: MarkupChildren) -> [MarkdownListItem] {
        children.compactMap { child -> MarkdownListItem? in
            guard let item = child as? ListItem else { return nil }
            let task: MarkdownListItem.TaskState? = switch item.checkbox {
            case .checked: .checked
            case .unchecked: .unchecked
            case nil: nil
            }
            return MarkdownListItem(task: task, blocks: convertBlocks(item.children))
        }
    }

    private mutating func convertTable(_ table: Markdown.Table) -> MarkdownTable {
        let alignments: [MarkdownTable.Alignment] = table.columnAlignments.map {
            switch $0 {
            case .left: .left
            case .center: .center
            case .right: .right
            case nil: .none
            }
        }
        var header: [[MarkdownInline]] = []
        for cell in table.head.cells {
            header.append(convertInlines(cell.children))
        }
        var rows: [[[MarkdownInline]]] = []
        for row in table.body.rows {
            var cells: [[MarkdownInline]] = []
            for cell in row.cells {
                cells.append(convertInlines(cell.children))
            }
            rows.append(cells)
        }
        return MarkdownTable(alignments: alignments, header: header, rows: rows)
    }

    // MARK: Inlines

    private mutating func convertInlines(_ children: MarkupChildren, insideLink: Bool = false, depth: Int = 0) -> [MarkdownInline] {
        var pieces: [InlinePiece] = []
        for child in children {
            convertInline(child, insideLink: insideLink, depth: depth, into: &pieces)
        }
        return finishInlines(pieces, insideLink: insideLink)
    }

    private mutating func convertInline(_ markup: Markup, insideLink: Bool, depth: Int, into result: inout [InlinePiece]) {
        if depth >= Self.maximumInlineDepth {
            result.append(.inline(.text(Self.flattenedText(markup))))
            return
        }
        let depth = depth + 1
        switch markup {
        case let text as Markdown.Text:
            result.append(.inline(.text(text.string)))
        case let emphasis as Emphasis:
            result.append(.inline(.emphasis(convertInlines(emphasis.children, insideLink: insideLink, depth: depth))))
        case let strong as Strong:
            result.append(.inline(.strong(convertInlines(strong.children, insideLink: insideLink, depth: depth))))
        case let strike as Strikethrough:
            result.append(.inline(.strikethrough(convertInlines(strike.children, insideLink: insideLink, depth: depth))))
        case let code as InlineCode:
            result.append(.inline(.code(code.code)))
        case let link as Markdown.Link:
            let content = convertInlines(link.children, insideLink: true, depth: depth)
            let destination = link.destination ?? ""
            result.append(.inline(.link(destination: destination, title: link.title?.nilIfEmpty, content: content.isEmpty ? [.text(destination)] : content)))
        case let image as Markdown.Image:
            result.append(.inline(.image(source: image.source ?? "", title: image.title?.nilIfEmpty, alt: image.plainText)))
        case is SoftBreak:
            result.append(.inline(.softBreak))
        case is LineBreak:
            result.append(.inline(.lineBreak))
        case let html as InlineHTML:
            result.append(contentsOf: HTMLTokenizer.tokenize(html.rawHTML).map(InlinePiece.tag))
        case let symbol as SymbolLink:
            result.append(.inline(.code(symbol.destination ?? "")))
        default:
            for child in markup.children {
                convertInline(child, insideLink: insideLink, depth: depth, into: &result)
            }
        }
    }

    /// Matches inline HTML tags, then resolves math placeholders, footnote references and bare
    /// URLs in text.
    mutating func finishInlines(_ pieces: [InlinePiece], insideLink: Bool) -> [MarkdownInline] {
        postProcess(HTMLInlineFolder.fold(pieces), insideLink: insideLink)
    }

    private mutating func postProcess(_ inlines: [MarkdownInline], insideLink: Bool) -> [MarkdownInline] {
        // cmark splits text around brackets; merge neighbours so patterns like [^1] are whole.
        var merged: [MarkdownInline] = []
        for inline in inlines {
            if case .text(let text) = inline, case .text(let previous)? = merged.last {
                merged[merged.count - 1] = .text(previous + text)
            } else {
                merged.append(inline)
            }
        }

        var result: [MarkdownInline] = []
        for inline in merged {
            switch inline {
            case .text(let text):
                for piece in splitMath(text) {
                    guard case .text(let plain) = piece else {
                        result.append(piece)
                        continue
                    }
                    for part in splitFootnotes(plain) {
                        if case .text(let remaining) = part, !insideLink {
                            result.append(contentsOf: Autolinker.split(remaining))
                        } else {
                            result.append(part)
                        }
                    }
                }
            case .emphasis(let children):
                result.append(.emphasis(postProcess(children, insideLink: insideLink)))
            case .strong(let children):
                result.append(.strong(postProcess(children, insideLink: insideLink)))
            case .strikethrough(let children):
                result.append(.strikethrough(postProcess(children, insideLink: insideLink)))
            case .styled(let style, let children):
                result.append(.styled(style, postProcess(children, insideLink: insideLink)))
            case .link(let destination, let title, let children):
                result.append(.link(destination: destination, title: title, content: postProcess(children, insideLink: true)))
            default:
                result.append(inline)
            }
        }
        return result
    }

    private func splitMath(_ text: String) -> [MarkdownInline] {
        guard text.contains(MarkdownPreprocessor.placeholderStart) else { return [.text(text)] }
        var result: [MarkdownInline] = []
        var buffer = ""
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == MarkdownPreprocessor.placeholderStart,
               let end = text[index...].firstIndex(of: MarkdownPreprocessor.placeholderEnd) {
                let body = text[text.index(after: index)..<end]
                if let kind = body.first, let number = Int(body.dropFirst()), math.indices.contains(number) {
                    if !buffer.isEmpty { result.append(.text(buffer)); buffer = "" }
                    result.append(.math(math[number], display: kind == MarkdownPreprocessor.displayMathKind))
                    index = text.index(after: end)
                    continue
                }
            }
            buffer.append(c)
            index = text.index(after: index)
        }
        if !buffer.isEmpty { result.append(.text(buffer)) }
        return result
    }

    private mutating func splitFootnotes(_ text: String) -> [MarkdownInline] {
        guard !footnoteLabels.isEmpty, text.contains("[^") else { return [.text(text)] }
        var result: [MarkdownInline] = []
        var buffer = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("[^"),
               let close = text[index...].firstIndex(of: "]") {
                let label = String(text[text.index(index, offsetBy: 2)..<close])
                if footnoteLabels.contains(label) {
                    if !buffer.isEmpty { result.append(.text(buffer)); buffer = "" }
                    let number = footnoteNumbers[label] ?? (footnoteNumbers.count + 1)
                    footnoteNumbers[label] = number
                    result.append(.footnoteReference(label: label, number: number))
                    index = text.index(after: close)
                    continue
                }
            }
            buffer.append(text[index])
            index = text.index(after: index)
        }
        if !buffer.isEmpty { result.append(.text(buffer)) }
        return result
    }

    /// Collects the text of a subtree without recursion.
    static func flattenedText(_ root: Markup) -> String {
        var text = ""
        var stack: [Markup] = [root]
        while let node = stack.popLast() {
            switch node {
            case let leaf as Markdown.Text: text += leaf.string
            case let code as InlineCode: text += code.code
            case let code as CodeBlock: text += code.code
            case is SoftBreak, is LineBreak: text += " "
            default:
                if node is BlockMarkup, !text.isEmpty, !text.hasSuffix(" ") { text += " " }
                stack.append(contentsOf: node.children.reversed())
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: GitHub alerts

    /// Detects `> [!NOTE]` style alerts: the first paragraph of the quote starts with the marker.
    private static func extractAlert(from blocks: [MarkdownBlock]) -> (MarkdownAlertKind, [MarkdownBlock])? {
        guard case .paragraph(var inlines)? = blocks.first,
              case .text(let first)? = inlines.first
        else { return nil }

        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), let close = trimmed.firstIndex(of: "]") else { return nil }
        let name = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close].lowercased()
        guard let kind = MarkdownAlertKind(rawValue: name) else { return nil }

        let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
        inlines.removeFirst()
        if !rest.isEmpty {
            inlines.insert(.text(rest), at: 0)
        }
        // Drop the line break that follows the marker line.
        while let head = inlines.first, head == .softBreak || head == .lineBreak {
            inlines.removeFirst()
        }
        var remaining = Array(blocks.dropFirst())
        if !inlines.isEmpty {
            remaining.insert(.paragraph(inlines), at: 0)
        }
        return (kind, remaining)
    }
}

// MARK: - Heading slugs

/// Generates GitHub-compatible heading anchors (`## Getting Started` → `getting-started`).
struct HeadingSlugger {
    private var used: [String: Int] = [:]

    mutating func slug(for title: String) -> String {
        let base = Self.baseSlug(for: title)
        if let count = used[base] {
            used[base] = count + 1
            let candidate = "\(base)-\(count)"
            used[candidate, default: 0] += 1
            return candidate
        }
        used[base] = 1
        return base
    }

    static func baseSlug(for title: String) -> String {
        var slug = ""
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                slug.unicodeScalars.append(scalar)
            } else if scalar == " " {
                slug.append("-")
            }
        }
        return slug
    }
}

// MARK: - Bare URL autolinking

/// cmark-gfm's autolink extension is not enabled by swift-markdown, so bare `https://` URLs in
/// text are turned into links here, matching GitHub's behaviour.
enum Autolinker {
    private static let trailingPunctuation: Set<Character> = [".", ",", ":", ";", "!", "?", "'", "\"", "*", "_", "~"]

    static func split(_ text: String) -> [MarkdownInline] {
        guard text.contains("http://") || text.contains("https://") || text.contains("www.") else {
            return [.text(text)]
        }

        var result: [MarkdownInline] = []
        var buffer = ""
        var index = text.startIndex

        while index < text.endIndex {
            let rest = text[index...]
            let startsURL = rest.hasPrefix("https://") || rest.hasPrefix("http://") || rest.hasPrefix("www.")
            let atBoundary = index == text.startIndex || !(text[text.index(before: index)].isLetter || text[text.index(before: index)].isNumber)
            if startsURL, atBoundary {
                var end = index
                while end < text.endIndex, !text[end].isWhitespace, text[end] != "<", text[end] != ">" {
                    end = text.index(after: end)
                }
                var url = String(text[index..<end])
                // Trim trailing punctuation and unbalanced closing parentheses.
                while let last = url.last {
                    if trailingPunctuation.contains(last) {
                        url.removeLast()
                    } else if last == ")", url.filter({ $0 == ")" }).count > url.filter({ $0 == "(" }).count {
                        url.removeLast()
                    } else {
                        break
                    }
                }
                let minimumLength = url.hasPrefix("www.") ? 5 : 9
                if url.count >= minimumLength {
                    if !buffer.isEmpty {
                        result.append(.text(buffer))
                        buffer = ""
                    }
                    let destination = url.hasPrefix("www.") ? "https://\(url)" : url
                    result.append(.link(destination: destination, title: nil, content: [.text(url)]))
                    index = text.index(index, offsetBy: url.count)
                    continue
                }
            }
            buffer.append(text[index])
            index = text.index(after: index)
        }
        if !buffer.isEmpty {
            result.append(.text(buffer))
        }
        return result
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
