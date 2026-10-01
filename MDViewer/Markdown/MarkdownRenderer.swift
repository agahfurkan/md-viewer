import AppKit

/// Output of rendering: the attributed string plus positions needed for navigation.
struct RenderedMarkdown {
    let attributedString: NSAttributedString
    /// Character offset of each outline item, indexed by `OutlineItem.id`; `nil` when the heading
    /// isn't rendered (inside a collapsed `<details>`).
    let outlineLocations: [Int?]
    /// Character offset for each anchor: heading slugs and footnotes.
    let anchorLocations: [String: Int]

    /// Rendered outline items in document order, for finding the heading at a position.
    var sortedOutlineLocations: [(location: Int, index: Int)] {
        outlineLocations.enumerated()
            .compactMap { index, location in location.map { ($0, index) } }
            .sorted { $0.location < $1.location }
    }
}

/// Link destinations the reader handles itself.
enum ReaderLink {
    static let detailsScheme = "x-mdviewer-details"

    static func toggleDetails(_ id: Int) -> String { "\(detailsScheme):\(id)" }

    static func detailsID(from destination: String) -> Int? {
        guard destination.hasPrefix(detailsScheme + ":") else { return nil }
        return Int(destination.dropFirst(detailsScheme.count + 1))
    }
}

/// Turns a `MarkdownDocumentModel` into an `NSAttributedString` for a TextKit 1 `NSTextView`.
///
/// Rendering into a single text view (rather than one view per block) gives continuous text
/// selection, native copy, and the system find bar for free.
@MainActor
final class MarkdownRenderer {
    private let style: ReaderStyle
    private let documentURL: URL?
    private let imageLoader: ImageLoader
    private let detailsToggles: Set<Int>
    private let builder = AttributedBuilder()
    private var anchorLocations: [String: Int] = [:]
    private var footnoteTexts: [String: String] = [:]
    private var fontCache: [FontKey: NSFont] = [:]

    /// - Parameter detailsToggles: `<details>` elements whose open state the user flipped.
    init(style: ReaderStyle, documentURL: URL?, detailsToggles: Set<Int> = [], imageLoader: ImageLoader = .shared) {
        self.style = style
        self.documentURL = documentURL
        self.detailsToggles = detailsToggles
        self.imageLoader = imageLoader
    }

    func render(_ model: MarkdownDocumentModel) -> RenderedMarkdown {
        for case .footnotes(let notes) in model.blocks {
            for note in notes {
                footnoteTexts[note.label] = note.blocks.map(Self.plainText(of:)).joined(separator: " ")
                    .replacingOccurrences(of: "↩\u{FE0E}", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        renderBlocks(model.blocks, context: Context(textColor: ReaderPalette.text))
        let output = builder.finish()
        return RenderedMarkdown(
            attributedString: output,
            outlineLocations: model.outline.map { anchorLocations[$0.anchor] },
            anchorLocations: anchorLocations
        )
    }

    private static func plainText(of block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines, _): inlines.plainText
        case .blockQuote(let blocks), .alert(_, let blocks), .aligned(_, let blocks): blocks.map(plainText(of:)).joined(separator: " ")
        case .codeBlock(let code): code.code
        case .mathBlock(let latex): latex
        default: ""
        }
    }

    // MARK: - Metrics

    private var base: CGFloat { style.baseFontSize }
    private var blockGap: CGFloat { (base * 0.95).rounded() }
    private var listItemGap: CGFloat { (base * 0.3).rounded() }
    private var lineSpacing: CGFloat { (base * 0.32).rounded() }

    private func headingSize(_ level: Int) -> CGFloat {
        let scale: CGFloat = switch level {
        case 1: 2.0
        case 2: 1.55
        case 3: 1.28
        case 4: 1.1
        case 5: 1.0
        default: 0.93
        }
        return (base * scale).rounded()
    }

    private func gap(between previous: MarkdownBlock?, and next: MarkdownBlock) -> CGFloat {
        guard let previous else { return 0 }
        if case .heading(let level, _, _) = next {
            return level <= 2 ? (base * 1.7).rounded() : (base * 1.35).rounded()
        }
        if case .heading = previous {
            return (base * 0.6).rounded()
        }
        return blockGap
    }

    // MARK: - Fonts

    private struct FontKey: Hashable {
        let size: CGFloat
        let weight: CGFloat
        let italic: Bool
        let monospaced: Bool
    }

    private func font(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false, monospaced: Bool = false) -> NSFont {
        let key = FontKey(size: size, weight: weight.rawValue, italic: italic, monospaced: monospaced)
        if let cached = fontCache[key] { return cached }
        var font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        var descriptor = font.fontDescriptor
        if !monospaced, style.fontDesign == .serif, let serif = descriptor.withDesign(.serif) {
            descriptor = serif
        }
        if italic {
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic))
        }
        font = NSFont(descriptor: descriptor, size: size) ?? font
        fontCache[key] = font
        return font
    }

    private var bodyFont: NSFont { font(size: base) }
    private var codeFontSize: CGFloat { (base * 0.86).rounded() }

    // MARK: - Context

    private struct Context {
        var indent: CGFloat = 0
        var blocks: [NSTextBlock] = []
        var textColor: NSColor
        var listDepth = 0
        var alignment: NSTextAlignment = .natural
    }

    private func paragraphStyle(_ context: Context) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = context.indent
        paragraph.headIndent = context.indent
        paragraph.textBlocks = context.blocks
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = context.alignment
        return paragraph
    }

    // MARK: - Blocks

    private func renderBlocks(_ blocks: [MarkdownBlock], context: Context) {
        var previous: MarkdownBlock?
        for block in blocks {
            let gap = gap(between: previous, and: block)
            if gap > 0 { builder.requestGap(gap) }
            renderBlock(block, context: context)
            previous = block
        }
    }

    private func renderBlock(_ block: MarkdownBlock, context: Context) {
        switch block {
        case .heading(let level, let content, let anchor):
            renderHeading(level: level, content: content, anchor: anchor, context: context)
        case .paragraph(let inlines):
            let text = NSMutableAttributedString()
            appendInlines(inlines, state: InlineState(size: base, color: context.textColor), into: text)
            builder.appendParagraph(text, style: paragraphStyle(context))
        case .codeBlock(let code):
            renderCodeBlock(code, context: context)
        case .blockQuote(let children):
            renderQuote(children, context: context)
        case .alert(let kind, let children):
            renderAlert(kind, children: children, context: context)
        case .list(let list):
            renderList(list, context: context)
        case .table(let table):
            renderTable(table, context: context)
        case .thematicBreak:
            let attachment = NSTextAttachment()
            attachment.attachmentCell = HorizontalRuleCell(height: (base * 0.9).rounded())
            let paragraph = paragraphStyle(context)
            paragraph.lineSpacing = 0
            builder.appendParagraph(NSAttributedString(attachment: attachment), style: paragraph)
        case .aligned(let alignment, let children):
            var aligned = context
            aligned.alignment = switch alignment {
            case .left: .left
            case .center: .center
            case .right: .right
            }
            renderBlocks(children, context: aligned)
        case .details(let details):
            renderDetails(details, context: context)
        case .mathBlock(let latex):
            renderMathBlock(latex, context: context)
        case .mermaid(let source):
            let attachment = NSTextAttachment()
            attachment.attachmentCell = DiagramAttachmentCell(source: source, font: font(size: (base * 0.87).rounded()))
            let paragraph = paragraphStyle(context)
            paragraph.alignment = .center
            builder.appendParagraph(NSAttributedString(attachment: attachment), style: paragraph)
        case .footnotes(let notes):
            renderFootnotes(notes, context: context)
        }
    }

    private func renderDetails(_ details: MarkdownDetails, context: Context) {
        let isExpanded = details.isOpenByDefault != detailsToggles.contains(details.id)
        let toggle = ReaderLink.toggleDetails(details.id)
        let title = NSMutableAttributedString()
        if let chevron = symbolAttachment(isExpanded ? "chevron.down" : "chevron.right", colors: [.secondaryLabelColor], size: (base * 0.75).rounded()) {
            title.append(chevron)
            title.append(NSAttributedString(string: "\u{2002}", attributes: [.font: bodyFont]))
        }
        appendInlines(details.summary, state: InlineState(size: base, weight: .semibold, color: context.textColor), into: title)
        // The whole summary toggles the details; keep its own colors (links are not recolored).
        title.addAttribute(.link, value: toggle, range: NSRange(location: 0, length: title.length))
        title.addAttribute(.toolTip, value: isExpanded ? "Collapse" : "Expand", range: NSRange(location: 0, length: title.length))
        builder.appendParagraph(title, style: paragraphStyle(context))

        guard isExpanded, !details.blocks.isEmpty else { return }
        var inner = context
        inner.indent = context.indent + (base * 1.3).rounded()
        builder.requestGap((base * 0.5).rounded())
        renderBlocks(details.blocks, context: inner)
    }

    private func renderMathBlock(_ latex: String, context: Context) {
        guard let rendered = MathRenderer.render(latex, fontSize: (base * 1.15).rounded(), display: true) else {
            renderCodeBlock(MarkdownCodeBlock(language: "latex", code: latex, tokens: []), context: context)
            return
        }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MathAttachmentCell(image: rendered.image, descent: rendered.descent, color: context.textColor, centered: true)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttributes([.font: bodyFont, .toolTip: latex], range: NSRange(location: 0, length: text.length))
        let paragraph = paragraphStyle(context)
        paragraph.alignment = .center
        builder.appendParagraph(text, style: paragraph)
    }

    private func renderFootnotes(_ notes: [MarkdownFootnote], context: Context) {
        let rule = NSTextAttachment()
        rule.attachmentCell = HorizontalRuleCell(height: (base * 0.6).rounded())
        builder.requestGap((base * 1.4).rounded())
        builder.appendParagraph(NSAttributedString(attachment: rule), style: paragraphStyle(context))
        builder.requestGap((base * 0.4).rounded())

        var notesContext = context
        notesContext.textColor = ReaderPalette.secondaryText
        let list = MarkdownList(
            isOrdered: true,
            startIndex: 1,
            items: notes.map { MarkdownListItem(blocks: $0.blocks, anchor: $0.anchor) }
        )
        renderList(list, context: notesContext)
    }

    private func renderHeading(level: Int, content: [MarkdownInline], anchor: String, context: Context) {
        let size = headingSize(level)
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        let color = level == 6 ? ReaderPalette.secondaryText : context.textColor
        let text = NSMutableAttributedString()
        appendInlines(content, state: InlineState(size: size, weight: weight, color: color), into: text)
        if text.length == 0 {
            text.append(NSAttributedString(string: " ", attributes: [.font: font(size: size, weight: weight)]))
        }

        let paragraph = paragraphStyle(context)
        paragraph.lineSpacing = (size * 0.15).rounded()
        if level <= 2 {
            let rule = NSTextBlock()
            rule.setContentWidth(100, type: .percentageValueType)
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            rule.setBorderColor(ReaderPalette.headingRule, for: .maxY)
            rule.setWidth((base * 0.35).rounded(), type: .absoluteValueType, for: .padding, edge: .maxY)
            rule.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            paragraph.textBlocks = context.blocks + [rule]
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = 0
        }

        let location = builder.length
        if anchorLocations[anchor] == nil {
            anchorLocations[anchor] = location
        }
        builder.appendParagraph(text, style: paragraph)
    }

    private func renderCodeBlock(_ code: MarkdownCodeBlock, context: Context) {
        let codeFont = font(size: codeFontSize, monospaced: true)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = (codeFontSize * 0.3).rounded()
        paragraph.tabStops = []
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: codeFont]).width
        paragraph.defaultTabInterval = spaceWidth * 4
        paragraph.lineBreakMode = .byClipping

        let source = code.code.isEmpty ? " " : code.code
        let text = NSMutableAttributedString(string: source, attributes: [
            .font: codeFont,
            .foregroundColor: ReaderPalette.text,
            .paragraphStyle: paragraph,
        ])
        let length = text.length
        for token in code.tokens {
            guard token.location < length else { continue }
            let range = NSRange(location: token.location, length: min(token.length, length - token.location))
            text.addAttribute(.foregroundColor, value: ReaderPalette.syntax(token.kind), range: range)
            if let background = ReaderPalette.syntaxBackground(token.kind) {
                text.addAttribute(.backgroundColor, value: background, range: range)
            }
            if token.kind == .meta, code.language?.lowercased() == "diff" || code.language?.lowercased() == "patch" {
                text.addAttribute(.font, value: font(size: codeFontSize, weight: .semibold, monospaced: true), range: range)
            }
        }

        // The block is its own horizontally scrollable view (long lines don't wrap).
        let attachment = NSTextAttachment()
        attachment.attachmentCell = CodeBlockAttachmentCell(
            code: code.code,
            language: code.language,
            highlighted: text,
            padding: (base * 0.85).rounded()
        )
        let line = NSMutableAttributedString(attachment: attachment)
        line.addAttribute(.font, value: codeFont, range: NSRange(location: 0, length: line.length))
        let blockParagraph = paragraphStyle(context)
        blockParagraph.lineSpacing = 0
        blockParagraph.alignment = .natural
        builder.appendParagraph(line, style: blockParagraph)
    }

    private func renderQuote(_ children: [MarkdownBlock], context: Context) {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(ReaderPalette.quoteBorder, for: .minX)
        block.setWidth((base * 0.9).rounded(), type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)

        let inner = Context(indent: 0, blocks: context.blocks + [block], textColor: ReaderPalette.secondaryText, listDepth: context.listDepth)
        if children.isEmpty {
            builder.appendParagraph(NSAttributedString(string: " ", attributes: [.font: bodyFont]), style: paragraphStyle(inner))
        } else {
            renderBlocks(children, context: inner)
        }
    }

    private func renderAlert(_ kind: MarkdownAlertKind, children: [MarkdownBlock], context: Context) {
        let color = ReaderPalette.alert(kind)
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(color, for: .minX)
        block.setWidth((base * 0.9).rounded(), type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)

        let inner = Context(indent: 0, blocks: context.blocks + [block], textColor: context.textColor, listDepth: context.listDepth)

        let title = NSMutableAttributedString()
        let symbolName = switch kind {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.bubble"
        case .warning: "exclamationmark.triangle"
        case .caution: "exclamationmark.octagon"
        }
        if let icon = symbolAttachment(symbolName, colors: [color], size: base) {
            title.append(icon)
            title.append(NSAttributedString(string: " ", attributes: [.font: bodyFont]))
        }
        title.append(NSAttributedString(string: kind.title, attributes: [
            .font: font(size: base, weight: .semibold),
            .foregroundColor: color,
        ]))
        builder.appendParagraph(title, style: paragraphStyle(inner))

        if !children.isEmpty {
            builder.requestGap((base * 0.4).rounded())
            renderBlocks(children, context: inner)
        }
    }

    private func renderList(_ list: MarkdownList, context: Context) {
        let depth = context.listDepth
        let markerFont = font(size: base)
        let markerWidth: CGFloat
        if list.isOrdered {
            let widest = "\(list.startIndex + max(0, list.items.count - 1))."
            markerWidth = ceil((widest as NSString).size(withAttributes: [.font: markerFont]).width + base * 0.75)
        } else {
            markerWidth = (base * 1.5).rounded()
        }
        let contentIndent = context.indent + max(markerWidth, (base * 1.5).rounded())
        let markerTab = contentIndent - (base * 0.45).rounded()

        for (offset, item) in list.items.enumerated() {
            if offset > 0 { builder.requestGap(listItemGap) }
            if let anchor = item.anchor, anchorLocations[anchor] == nil {
                anchorLocations[anchor] = builder.length
            }

            let marker = NSMutableAttributedString(string: "\t", attributes: [.font: markerFont])
            if let task = item.task {
                let name = task == .checked ? "checkmark.square.fill" : "square"
                // Palette layers: the checkmark first, then the square.
                let colors: [NSColor] = task == .checked ? [.white, .controlAccentColor] : [.secondaryLabelColor]
                if let symbol = symbolAttachment(name, colors: colors, size: base * 0.95) {
                    marker.append(symbol)
                }
            } else if list.isOrdered {
                marker.append(NSAttributedString(string: "\(list.startIndex + offset).", attributes: [
                    .font: markerFont,
                    .foregroundColor: context.textColor,
                ]))
            } else {
                let bullets = ["•", "◦", "▪︎"]
                marker.append(NSAttributedString(string: bullets[min(depth, bullets.count - 1)], attributes: [
                    .font: markerFont,
                    .foregroundColor: context.textColor,
                ]))
            }
            marker.append(NSAttributedString(string: "\t", attributes: [.font: markerFont]))

            let firstParagraph = paragraphStyle(context)
            firstParagraph.firstLineHeadIndent = context.indent
            firstParagraph.headIndent = contentIndent
            firstParagraph.tabStops = [
                NSTextTab(textAlignment: .right, location: markerTab),
                NSTextTab(textAlignment: .left, location: contentIndent),
            ]

            var itemContext = context
            itemContext.indent = contentIndent
            itemContext.listDepth = depth + 1

            var remaining = item.blocks[...]
            if case .paragraph(let inlines)? = item.blocks.first {
                appendInlines(inlines, state: InlineState(size: base, color: context.textColor), into: marker)
                remaining = item.blocks.dropFirst()
            }
            builder.appendParagraph(marker, style: firstParagraph)

            var previous: MarkdownBlock? = item.blocks.first
            for block in remaining {
                builder.requestGap(block.isList ? listItemGap : (base * 0.55).rounded())
                if case .heading = block { builder.requestGap(gap(between: previous, and: block)) }
                renderBlock(block, context: itemContext)
                previous = block
            }
        }
    }

    private func renderTable(_ table: MarkdownTable, context: Context) {
        let columns = table.columnCount
        guard columns > 0 else { return }

        let rows = [table.header] + table.rows
        let horizontalPadding = (base * 0.75).rounded()
        let verticalPadding = (base * 0.4).rounded()

        // First build every cell's text so the table can be sized to its content, like GitHub.
        var cellTexts: [[NSAttributedString]] = []
        var naturalColumnWidths = Array(repeating: CGFloat(0), count: columns)
        var minimumColumnWidths = Array(repeating: CGFloat(0), count: columns)
        for (rowIndex, row) in rows.enumerated() {
            var texts: [NSAttributedString] = []
            for column in 0..<columns {
                let text = NSMutableAttributedString()
                if column < row.count {
                    appendInlines(row[column], state: InlineState(size: base, weight: rowIndex == 0 ? .semibold : .regular, color: context.textColor), into: text)
                }
                if text.length == 0 {
                    text.append(NSAttributedString(string: " ", attributes: [.font: bodyFont]))
                }
                let width = text.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).width
                // Cell text is laid out with the text container's line fragment padding on both sides.
                let fragmentPadding: CGFloat = 10
                naturalColumnWidths[column] = max(naturalColumnWidths[column], ceil(width) + fragmentPadding)
                minimumColumnWidths[column] = max(minimumColumnWidths[column], Self.longestWordWidth(text) + fragmentPadding)
                texts.append(text)
            }
            cellTexts.append(texts)
        }

        let textTable = FittingTextTable()
        textTable.numberOfColumns = columns
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        textTable.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        textTable.minimumColumnWidths = minimumColumnWidths
        textTable.naturalColumnWidths = naturalColumnWidths
        textTable.cellChrome = horizontalPadding * 2 + 1

        for (rowIndex, texts) in cellTexts.enumerated() {
            let isHeader = rowIndex == 0
            for column in 0..<columns {
                let cell = NSTextTableBlock(table: textTable, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setBorderColor(ReaderPalette.tableBorder)
                cell.setWidth(horizontalPadding, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(horizontalPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
                cell.setWidth(verticalPadding, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(verticalPadding, type: .absoluteValueType, for: .padding, edge: .maxY)
                if isHeader {
                    cell.backgroundColor = ReaderPalette.tableHeaderBackground
                } else if rowIndex % 2 == 0 {
                    cell.backgroundColor = ReaderPalette.tableStripe
                }

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = context.blocks + [cell]
                paragraph.lineSpacing = (base * 0.2).rounded()
                let alignment: MarkdownTable.Alignment = column < table.alignments.count ? table.alignments[column] : .none
                paragraph.alignment = switch alignment {
                case .center: .center
                case .right: .right
                case .left, .none: .natural
                }
                builder.appendParagraph(texts[column], style: paragraph)
            }
        }
    }

    /// Width of the longest unbreakable word in a cell.
    private static func longestWordWidth(_ text: NSAttributedString) -> CGFloat {
        let string = text.string as NSString
        var longest: CGFloat = 0
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            let width = text.attributedSubstring(from: range).size().width
            longest = max(longest, ceil(width))
        }
        return longest
    }

    /// Column widths as percentages of the table, sized like a browser's automatic table layout:
    /// every column gets at least its longest word; space beyond that goes to the columns in
    /// proportion to how much more they would need to avoid wrapping.
    nonisolated static func columnShares(minimum: [CGFloat], natural: [CGFloat], available: CGFloat, cellChrome: CGFloat) -> [CGFloat] {
        let count = natural.count
        guard count > 0 else { return [] }
        let chrome = cellChrome * CGFloat(count)
        let naturalTotal = natural.reduce(0, +)
        var widths: [CGFloat]
        if naturalTotal + chrome <= available {
            widths = natural
        } else {
            let minimumTotal = minimum.reduce(0, +)
            let extra = available - chrome - minimumTotal
            let wanted = zip(natural, minimum).map { max(0, $0 - $1) }
            let wantedTotal = wanted.reduce(0, +)
            if extra <= 0 || wantedTotal <= 0 {
                widths = minimum
            } else {
                widths = zip(minimum, wanted).map { $0 + $1 / wantedTotal * extra }
            }
        }
        let withChrome = widths.map { max($0, 1) + cellChrome }
        let total = max(withChrome.reduce(0, +), 1)
        return withChrome.map { $0 / total * 100 }
    }

    // MARK: - Inlines

    private struct InlineState {
        var size: CGFloat
        var weight: NSFont.Weight = .regular
        var italic = false
        var strikethrough = false
        var underline = false
        var baselineOffset: CGFloat = 0
        var background: NSColor?
        var link: String?
        var color: NSColor
    }

    private func attributes(for state: InlineState) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(size: state.size, weight: state.weight, italic: state.italic),
            .foregroundColor: state.link == nil ? state.color : ReaderPalette.link,
        ]
        if state.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if state.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if state.baselineOffset != 0 {
            attributes[.baselineOffset] = state.baselineOffset
        }
        if let background = state.background {
            attributes[.backgroundColor] = background
        }
        if let link = state.link {
            attributes[.link] = link
            attributes[.toolTip] = link
        }
        return attributes
    }

    private func appendInlines(_ inlines: [MarkdownInline], state: InlineState, into output: NSMutableAttributedString) {
        for inline in inlines {
            switch inline {
            case .text(let string):
                output.append(NSAttributedString(string: string, attributes: attributes(for: state)))
            case .emphasis(let children):
                var inner = state
                inner.italic = true
                appendInlines(children, state: inner, into: output)
            case .strong(let children):
                var inner = state
                inner.weight = state.weight == .regular ? .semibold : .bold
                appendInlines(children, state: inner, into: output)
            case .strikethrough(let children):
                var inner = state
                inner.strikethrough = true
                appendInlines(children, state: inner, into: output)
            case .code(let code):
                var attributes = attributes(for: state)
                attributes[.font] = font(size: (state.size * 0.87).rounded(), weight: state.weight, monospaced: true)
                attributes[.backgroundColor] = ReaderPalette.inlineCodeBackground
                // Hair spaces keep the rounded background from touching neighbouring glyphs.
                output.append(NSAttributedString(string: "\u{200A}", attributes: self.attributes(for: state)))
                output.append(NSAttributedString(string: code, attributes: attributes))
                output.append(NSAttributedString(string: "\u{200A}", attributes: self.attributes(for: state)))
            case .link(let destination, _, let children):
                var inner = state
                inner.link = destination
                appendInlines(children, state: inner, into: output)
            case .image(let source, let title, let alt, let width):
                output.append(imageAttachment(source: source, title: title, alt: alt, width: width, state: state))
            case .softBreak:
                output.append(NSAttributedString(string: " ", attributes: attributes(for: state)))
            case .lineBreak:
                output.append(NSAttributedString(string: "\u{2028}", attributes: attributes(for: state)))
            case .styled(let style, let children):
                appendStyled(style, children: children, state: state, into: output)
            case .math(let latex, let display):
                output.append(inlineMath(latex, display: display, state: state))
            case .footnoteReference(let label, let number):
                let anchor = MarkdownFootnote.referenceAnchor(for: label)
                if anchorLocations[anchor] == nil {
                    anchorLocations[anchor] = builder.length + output.length
                }
                var inner = state
                inner.size = (state.size * 0.72).rounded()
                inner.baselineOffset = (state.size * 0.38).rounded()
                inner.link = "#" + MarkdownFootnote.anchor(for: label)
                var attributes = attributes(for: inner)
                attributes[.toolTip] = footnoteTexts[label] ?? "Footnote \(number)"
                output.append(NSAttributedString(string: "\(number)", attributes: attributes))
            }
        }
    }

    private func appendStyled(_ style: MarkdownInlineStyle, children: [MarkdownInline], state: InlineState, into output: NSMutableAttributedString) {
        var inner = state
        switch style {
        case .keyboard:
            inner.size = (state.size * 0.85).rounded()
            inner.weight = .medium
            inner.background = ReaderPalette.keyboardBackground
            let spacer = NSAttributedString(string: "\u{2009}", attributes: attributes(for: state))
            output.append(spacer)
            appendInlines(children, state: inner, into: output)
            output.append(spacer)
            return
        case .superscript:
            inner.size = (state.size * 0.72).rounded()
            inner.baselineOffset = state.baselineOffset + (state.size * 0.38).rounded()
        case .subscript:
            inner.size = (state.size * 0.72).rounded()
            inner.baselineOffset = state.baselineOffset - (state.size * 0.16).rounded()
        case .underline:
            inner.underline = true
        case .highlight:
            inner.background = ReaderPalette.highlight
        }
        appendInlines(children, state: inner, into: output)
    }

    private func inlineMath(_ latex: String, display: Bool, state: InlineState) -> NSAttributedString {
        guard let rendered = MathRenderer.render(latex, fontSize: (state.size * 1.08).rounded(), display: display) else {
            // Unparseable LaTeX: show the source like inline code.
            var attributes = attributes(for: state)
            attributes[.font] = font(size: (state.size * 0.87).rounded(), monospaced: true)
            attributes[.backgroundColor] = ReaderPalette.inlineCodeBackground
            attributes[.toolTip] = "Invalid math"
            return NSAttributedString(string: "$\(latex)$", attributes: attributes)
        }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MathAttachmentCell(image: rendered.image, descent: rendered.descent, color: state.link == nil ? state.color : ReaderPalette.link, centered: false)
        let result = NSMutableAttributedString(attachment: attachment)
        var extra = attributes(for: state)
        extra[.toolTip] = state.link ?? latex
        result.addAttributes(extra, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func imageAttachment(source: String, title: String?, alt: String, width: Double?, state: InlineState) -> NSAttributedString {
        let placeholderFont = font(size: (base * 0.87).rounded())
        let cell: ImageAttachmentCell
        var tooltip = title ?? (alt.isEmpty ? source : alt)

        if let url = LinkResolver.resourceURL(source, relativeTo: documentURL) {
            if url.isFileURL {
                if let image = imageLoader.localImage(at: url) {
                    cell = ImageAttachmentCell(image: image, altText: alt, preferredWidth: width, font: placeholderFont)
                } else {
                    cell = ImageAttachmentCell(image: nil, altText: alt, isMissing: true, font: placeholderFont)
                    tooltip = "Image not found: \(source)"
                }
            } else if let image = imageLoader.cachedRemoteImage(for: url) {
                cell = ImageAttachmentCell(image: image, altText: alt, preferredWidth: width, font: placeholderFont)
            } else {
                let failed = imageLoader.hasFailed(url)
                cell = ImageAttachmentCell(image: nil, altText: alt, remoteURL: failed ? nil : url, isMissing: failed, preferredWidth: width, font: placeholderFont)
                if failed {
                    tooltip = "Image could not be loaded: \(source)"
                } else {
                    imageLoader.loadRemoteImage(url)
                }
            }
        } else {
            cell = ImageAttachmentCell(image: nil, altText: alt, isMissing: true, font: placeholderFont)
            tooltip = "Invalid image source: \(source)"
        }

        let attachment = NSTextAttachment()
        attachment.attachmentCell = cell
        let result = NSMutableAttributedString(attachment: attachment)
        var extra = attributes(for: state)
        extra[.toolTip] = state.link ?? tooltip
        result.addAttributes(extra, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func symbolAttachment(_ name: String, colors: [NSColor], size: CGFloat) -> NSAttributedString? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular).applying(.init(paletteColors: colors)))
        else { return nil }
        let height = size
        let width = symbol.size.width * (height / max(symbol.size.height, 1))
        let cell = ImageAttachmentCell(symbol: symbol, size: NSSize(width: width, height: height), baselineOffset: -(size * 0.18).rounded())
        let attachment = NSTextAttachment()
        attachment.attachmentCell = cell
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: font(size: base), range: NSRange(location: 0, length: result.length))
        return result
    }
}

private extension MarkdownBlock {
    var isList: Bool {
        if case .list = self { return true }
        return false
    }
}

// MARK: - Attributed string builder

/// Appends paragraphs and resolves the vertical gap between them.
///
/// Gaps are expressed differently depending on context: between two plain paragraphs a gap is
/// paragraph spacing, but when content enters or leaves a text block (code block, quote, table)
/// the gap must become a block margin, otherwise it would be drawn inside the block's
/// background or border.
@MainActor
private final class AttributedBuilder {
    private let output = NSMutableAttributedString()
    private var lastRange: NSRange?
    private var lastStyle: NSParagraphStyle?
    private var pendingGap: CGFloat = 0

    var length: Int { output.length }

    func requestGap(_ gap: CGFloat) {
        pendingGap = max(pendingGap, gap)
    }

    func appendParagraph(_ content: NSAttributedString, style: NSMutableParagraphStyle) {
        if pendingGap > 0, let lastRange, let lastStyle {
            applyGap(pendingGap, previousRange: lastRange, previousStyle: lastStyle, next: style)
        }
        pendingGap = 0

        let start = output.length
        output.append(content)
        var newlineAttributes: [NSAttributedString.Key: Any] = [:]
        if content.length > 0 {
            newlineAttributes[.font] = content.attribute(.font, at: content.length - 1, effectiveRange: nil)
        }
        output.append(NSAttributedString(string: "\n", attributes: newlineAttributes))
        let range = NSRange(location: start, length: output.length - start)
        output.addAttribute(.paragraphStyle, value: style, range: range)
        lastRange = range
        lastStyle = style
    }

    func finish() -> NSAttributedString {
        // Drop the final newline so the document doesn't end with an empty line.
        if output.length > 0, output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    private func applyGap(_ gap: CGFloat, previousRange: NSRange, previousStyle: NSParagraphStyle, next: NSMutableParagraphStyle) {
        let previousBlocks = previousStyle.textBlocks
        let nextBlocks = next.textBlocks
        var common = 0
        while common < min(previousBlocks.count, nextBlocks.count), previousBlocks[common] === nextBlocks[common] {
            common += 1
        }
        let closing = previousBlocks.dropFirst(common)
        let opening = nextBlocks.dropFirst(common)

        if let block = closing.first, !(block is NSTextTableBlock) {
            let current = block.width(for: .margin, edge: .maxY)
            block.setWidth(max(current, gap), type: .absoluteValueType, for: .margin, edge: .maxY)
            return
        }
        if let block = opening.first, !(block is NSTextTableBlock) {
            let current = block.width(for: .margin, edge: .minY)
            block.setWidth(max(current, gap), type: .absoluteValueType, for: .margin, edge: .minY)
            return
        }
        if opening.isEmpty {
            next.paragraphSpacingBefore = max(next.paragraphSpacingBefore, gap)
            return
        }
        // A table follows: add the space after the previous paragraph instead.
        guard let updated = previousStyle.mutableCopy() as? NSMutableParagraphStyle else { return }
        updated.paragraphSpacing = max(updated.paragraphSpacing, gap)
        output.addAttribute(.paragraphStyle, value: updated, range: previousRange)
        lastStyle = updated
    }
}
