import Foundation

/// A parsed Markdown document, independent of both the parser library and the renderer.
///
/// The model is a plain value type so it can be produced off the main actor and handed to the UI.
struct MarkdownDocumentModel: Equatable, Sendable {
    var blocks: [MarkdownBlock]
    var outline: [OutlineItem]

    static let empty = MarkdownDocumentModel(blocks: [], outline: [])
}

/// One entry in the document outline, generated from a heading.
struct OutlineItem: Identifiable, Hashable, Sendable {
    /// Position of the heading in document order. Stable for a given parse.
    let id: Int
    let level: Int
    let title: String
    /// GitHub-style slug used for `#anchor` links.
    let anchor: String
}

indirect enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, content: [MarkdownInline], anchor: String)
    case paragraph([MarkdownInline])
    case codeBlock(MarkdownCodeBlock)
    case blockQuote([MarkdownBlock])
    /// GitHub alert syntax: `> [!NOTE]`, `> [!WARNING]`, …
    case alert(MarkdownAlertKind, [MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case thematicBreak
    /// Content aligned by HTML (`<p align="center">`, `<center>`).
    case aligned(MarkdownTextAlignment, [MarkdownBlock])
    /// `<details><summary>…</summary>…</details>`, collapsible in the reader.
    case details(MarkdownDetails)
    /// Display math (`$$…$$` or a ```` ```math ```` block), as LaTeX.
    case mathBlock(String)
    /// A ```` ```mermaid ```` diagram, as Mermaid source.
    case mermaid(String)
    /// Footnote definitions, collected at the end of the document in reference order.
    case footnotes([MarkdownFootnote])
}

enum MarkdownTextAlignment: String, Equatable, Sendable {
    case left, center, right
}

struct MarkdownDetails: Equatable, Sendable {
    /// Position among the document's `<details>` elements; identifies it for expand/collapse.
    var id: Int
    var summary: [MarkdownInline]
    var blocks: [MarkdownBlock]
    var isOpenByDefault: Bool
}

struct MarkdownFootnote: Equatable, Sendable {
    var label: String
    var number: Int
    var blocks: [MarkdownBlock]

    /// Anchor of the footnote itself and of its first reference.
    var anchor: String { MarkdownFootnote.anchor(for: label) }
    var referenceAnchor: String { MarkdownFootnote.referenceAnchor(for: label) }

    static func anchor(for label: String) -> String { "fn-\(HeadingSlugger.baseSlug(for: label))" }
    static func referenceAnchor(for label: String) -> String { "fnref-\(HeadingSlugger.baseSlug(for: label))" }
}

enum MarkdownAlertKind: String, Equatable, Sendable, CaseIterable {
    case note, tip, important, warning, caution

    var title: String { rawValue.capitalized }
}

struct MarkdownCodeBlock: Equatable, Sendable {
    var language: String?
    var code: String
    /// Syntax tokens as UTF-16 ranges into `code`.
    var tokens: [SyntaxToken]
}

struct MarkdownList: Equatable, Sendable {
    var isOrdered: Bool
    var startIndex: Int
    var items: [MarkdownListItem]
}

struct MarkdownListItem: Equatable, Sendable {
    enum TaskState: Equatable, Sendable { case checked, unchecked }

    var task: TaskState?
    var blocks: [MarkdownBlock]
    /// Link target at the start of the item (used by footnotes).
    var anchor: String?

    init(task: TaskState? = nil, blocks: [MarkdownBlock], anchor: String? = nil) {
        self.task = task
        self.blocks = blocks
        self.anchor = anchor
    }
}

struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case none, left, center, right }

    var alignments: [Alignment]
    var header: [[MarkdownInline]]
    var rows: [[[MarkdownInline]]]

    var columnCount: Int {
        max(alignments.count, header.count, rows.map(\.count).max() ?? 0)
    }
}

indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(destination: String, title: String?, content: [MarkdownInline])
    /// `width` comes from an HTML `<img width=…>`, in points.
    case image(source: String, title: String?, alt: String, width: Double? = nil)
    case softBreak
    case lineBreak
    /// Inline HTML formatting without a Markdown equivalent (`<kbd>`, `<sup>`, …).
    case styled(MarkdownInlineStyle, [MarkdownInline])
    /// `$…$` math as LaTeX; `display` for `$$…$$` written inside a paragraph.
    case math(String, display: Bool)
    /// `[^label]` reference to a footnote, numbered in order of first reference.
    case footnoteReference(label: String, number: Int)
}

enum MarkdownInlineStyle: Equatable, Sendable {
    case keyboard, superscript, `subscript`, underline, highlight
}

extension Array where Element == MarkdownInline {
    /// The visible text of a run of inlines, used for outline titles and slugs.
    var plainText: String {
        var result = ""
        for inline in self {
            switch inline {
            case .text(let string), .code(let string):
                result += string
            case .emphasis(let children), .strong(let children), .strikethrough(let children), .styled(_, let children):
                result += children.plainText
            case .math(let latex, _):
                result += latex
            case .footnoteReference:
                break
            case .link(_, _, let children):
                result += children.plainText
            case .image(_, _, let alt, _):
                result += alt
            case .softBreak, .lineBreak:
                result += " "
            }
        }
        return result
    }
}
