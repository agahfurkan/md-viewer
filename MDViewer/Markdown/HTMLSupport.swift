import Foundation

/// Markdown files embed small amounts of HTML: `<kbd>`, `<sup>`, badges wrapped in
/// `<p align="center">`, collapsible `<details>`, the odd table. The viewer does not run a web
/// engine for these; instead the HTML is tokenized and mapped onto the Markdown model. Unknown
/// tags are dropped and their text kept.
enum HTMLToken: Equatable, Sendable {
    case text(String)
    case open(String, [String: String])
    case close(String)
    /// Void element or self-closing tag (`<br>`, `<img …>`, `<hr/>`).
    case void(String, [String: String])
}

enum HTMLTokenizer {
    static let voidElements: Set<String> = ["br", "img", "hr", "wbr", "input", "source", "meta", "link", "col", "area", "base", "embed", "param", "track"]

    static func tokenize(_ html: String) -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        var text = ""
        var index = html.startIndex

        func flushText() {
            if !text.isEmpty {
                tokens.append(.text(HTMLEntities.decode(text)))
                text = ""
            }
        }

        while index < html.endIndex {
            let c = html[index]
            guard c == "<" else {
                text.append(c)
                index = html.index(after: index)
                continue
            }
            let rest = html[index...]
            if rest.hasPrefix("<!--") {
                flushText()
                if let end = html.range(of: "-->", range: html.index(index, offsetBy: 4)..<html.endIndex) {
                    index = end.upperBound
                } else {
                    index = html.endIndex
                }
                continue
            }
            guard let close = findTagEnd(html, from: index) else {
                text.append(c)
                index = html.index(after: index)
                continue
            }
            let inner = html[html.index(after: index)..<close]
            index = html.index(after: close)

            if inner.hasPrefix("!") || inner.hasPrefix("?") { continue } // doctype, processing instructions
            if inner.hasPrefix("/") {
                let name = inner.dropFirst().prefix { $0.isLetter || $0.isNumber }.lowercased()
                guard !name.isEmpty else { continue }
                flushText()
                tokens.append(.close(name))
                continue
            }
            let name = inner.prefix { $0.isLetter || $0.isNumber || $0 == "-" }.lowercased()
            guard !name.isEmpty, inner.first?.isLetter == true else {
                // Not a tag after all ("a < b"): keep it as text.
                text += "<" + inner + ">"
                continue
            }
            flushText()
            let attributes = parseAttributes(String(inner.dropFirst(name.count)))
            if inner.hasSuffix("/") || voidElements.contains(name) {
                tokens.append(.void(name, attributes))
            } else {
                tokens.append(.open(name, attributes))
            }
        }
        flushText()
        return tokens
    }

    /// Finds the `>` closing a tag, ignoring `>` inside quoted attribute values.
    private static func findTagEnd(_ html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = html.index(after: start)
        while index < html.endIndex {
            let c = html[index]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return index
            } else if c == "<" {
                return nil
            }
            index = html.index(after: index)
        }
        return nil
    }

    static func parseAttributes(_ string: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let chars = Array(string)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "/" { i += 1 }
            let nameStart = i
            while i < chars.count, !chars[i].isWhitespace, chars[i] != "=", chars[i] != "/" { i += 1 }
            guard i > nameStart else { i += 1; continue }
            let name = String(chars[nameStart..<i]).lowercased()
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            var value = ""
            if i < chars.count, chars[i] == "=" {
                i += 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]
                    i += 1
                    let valueStart = i
                    while i < chars.count, chars[i] != quote { i += 1 }
                    value = String(chars[valueStart..<min(i, chars.count)])
                    i += 1
                } else {
                    let valueStart = i
                    while i < chars.count, !chars[i].isWhitespace { i += 1 }
                    value = String(chars[valueStart..<i])
                }
            }
            attributes[name] = HTMLEntities.decode(value)
        }
        return attributes
    }
}

enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "mdash": "—", "ndash": "–", "hellip": "…",
        "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "harr": "↔", "times": "×",
        "middot": "·", "bull": "•", "deg": "°", "plusmn": "±", "laquo": "«", "raquo": "»",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "check": "✓", "zwj": "\u{200D}",
    ]

    static func decode(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = ""
        var index = string.startIndex
        while index < string.endIndex {
            let c = string[index]
            if c == "&", let semicolon = string[index...].prefix(12).firstIndex(of: ";") {
                let entity = string[string.index(after: index)..<semicolon]
                if let replacement = resolve(entity) {
                    result += replacement
                    index = string.index(after: semicolon)
                    continue
                }
            }
            result.append(c)
            index = string.index(after: index)
        }
        return result
    }

    private static func resolve(_ entity: Substring) -> String? {
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if entity.hasPrefix("#") {
            return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[String(entity)]
    }
}

// MARK: - Inline folding

/// A converted inline or an HTML tag, before tags are matched up.
enum InlinePiece: Equatable {
    case inline(MarkdownInline)
    case tag(HTMLToken)
}

enum HTMLInlineFolder {
    private struct Frame {
        let name: String
        let attributes: [String: String]
        var children: [MarkdownInline] = []
    }

    /// Matches opening and closing tags among the pieces and wraps what's between them.
    static func fold(_ pieces: [InlinePiece]) -> [MarkdownInline] {
        var stack: [Frame] = [Frame(name: "#root", attributes: [:])]

        func append(_ inline: MarkdownInline) {
            stack[stack.count - 1].children.append(inline)
        }
        func closeTop() {
            let frame = stack.removeLast()
            for inline in wrap(frame) { append(inline) }
        }

        for piece in pieces {
            switch piece {
            case .inline(let inline):
                append(inline)
            case .tag(.text(let text)):
                append(.text(text))
            case .tag(.void(let name, let attributes)):
                if let inline = voidInline(name, attributes) { append(inline) }
            case .tag(.open(let name, let attributes)):
                stack.append(Frame(name: name, attributes: attributes))
            case .tag(.close(let name)):
                guard let index = stack.lastIndex(where: { $0.name == name }), index > 0 else { continue }
                while stack.count > index { closeTop() }
            }
        }
        while stack.count > 1 { closeTop() }
        return stack[0].children
    }

    static func voidInline(_ name: String, _ attributes: [String: String]) -> MarkdownInline? {
        switch name {
        case "br": return .lineBreak
        case "img":
            guard let source = attributes["src"], !source.isEmpty else { return nil }
            return .image(source: source, title: attributes["title"], alt: attributes["alt"] ?? "", width: pixelValue(attributes["width"]))
        default: return nil
        }
    }

    /// "64" or "64px" → 64; percentages and other units are ignored.
    static func pixelValue(_ value: String?) -> Double? {
        guard var value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if value.hasSuffix("px") { value.removeLast(2) }
        guard let number = Double(value), number > 0 else { return nil }
        return number
    }

    private static func wrap(_ frame: Frame) -> [MarkdownInline] {
        let children = frame.children
        switch frame.name {
        case "b", "strong": return [.strong(children)]
        case "i", "em", "cite", "dfn", "var": return [.emphasis(children)]
        case "s", "strike", "del": return [.strikethrough(children)]
        case "u", "ins": return [.styled(.underline, children)]
        case "mark": return [.styled(.highlight, children)]
        case "kbd": return [.styled(.keyboard, children)]
        case "sup": return [.styled(.superscript, children)]
        case "sub": return [.styled(.subscript, children)]
        case "code", "tt", "samp": return [.code(children.plainText)]
        case "a":
            if let href = frame.attributes["href"], !href.isEmpty {
                return [.link(destination: href, title: frame.attributes["title"], content: children)]
            }
            return children
        default:
            return children
        }
    }
}

// MARK: - Block folding

/// A converted block or an HTML block's tokens, before block-level tags are matched up.
enum BlockPiece {
    case block(MarkdownBlock)
    case html([HTMLToken])
}

enum HTMLBlockFolder {
    static let blockElements: Set<String> = [
        "p", "div", "center", "section", "article", "header", "footer", "main", "nav", "aside", "figure", "figcaption",
        "details", "summary", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "ul", "ol", "li", "pre",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "dl", "dt", "dd",
    ]

    private struct Frame {
        let name: String
        let attributes: [String: String]
        var blocks: [MarkdownBlock] = []
        var inline: [InlinePiece] = []
        var rawText = ""
        var summary: [MarkdownInline]?
        var listItems: [MarkdownListItem] = []
        var rows: [[[MarkdownInline]]] = []
        var cells: [[MarkdownInline]] = []
        var headerRowCount = 0
        var rowIsHeader = false
    }

    /// - Parameter finishInlines: turns inline pieces into inlines (tag folding, autolinks, …).
    static func fold(_ pieces: [BlockPiece], finishInlines: ([InlinePiece]) -> [MarkdownInline]) -> [MarkdownBlock] {
        guard pieces.contains(where: { if case .html = $0 { return true } else { return false } }) else {
            return pieces.compactMap { if case .block(let block) = $0 { return block } else { return nil } }
        }

        var stack: [Frame] = [Frame(name: "#root", attributes: [:])]

        func flushInline() {
            let pieces = stack[stack.count - 1].inline
            stack[stack.count - 1].inline = []
            let inlines = trimmed(finishInlines(pieces))
            guard !inlines.isEmpty else { return }
            stack[stack.count - 1].blocks.append(.paragraph(inlines))
        }

        func closeTop() {
            flushInline()
            let frame = stack.removeLast()
            let parent = stack.count - 1
            switch frame.name {
            case "summary":
                let content = frame.blocks.flatMap(Self.inlines(of:))
                if stack[parent].name == "details" {
                    stack[parent].summary = content
                } else if !content.isEmpty {
                    stack[parent].blocks.append(.paragraph(content))
                }
            case "details":
                let details = MarkdownDetails(
                    id: 0,
                    summary: frame.summary ?? [.text("Details")],
                    blocks: frame.blocks,
                    isOpenByDefault: frame.attributes["open"] != nil
                )
                stack[parent].blocks.append(.details(details))
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(String(frame.name.dropFirst())) ?? 1
                let content = frame.blocks.flatMap(Self.inlines(of:))
                let heading = MarkdownBlock.heading(level: level, content: content, anchor: "")
                stack[parent].blocks.append(alignment(of: frame).map { .aligned($0, [heading]) } ?? heading)
            case "blockquote":
                stack[parent].blocks.append(.blockQuote(frame.blocks))
            case "pre":
                var code = frame.rawText
                if code.hasPrefix("\n") { code.removeFirst() }
                if code.hasSuffix("\n") { code.removeLast() }
                stack[parent].blocks.append(.codeBlock(MarkdownCodeBlock(language: nil, code: code, tokens: [])))
            case "li":
                if stack[parent].name == "ul" || stack[parent].name == "ol" {
                    stack[parent].listItems.append(MarkdownListItem(blocks: frame.blocks))
                } else {
                    stack[parent].blocks.append(contentsOf: frame.blocks)
                }
            case "ul", "ol":
                let start = Int(frame.attributes["start"] ?? "") ?? 1
                stack[parent].blocks.append(.list(MarkdownList(isOrdered: frame.name == "ol", startIndex: start, items: frame.listItems)))
            case "td", "th":
                let content = frame.blocks.flatMap(Self.inlines(of:))
                if let row = stack.lastIndex(where: { $0.name == "tr" }) {
                    stack[row].cells.append(content)
                    if frame.name == "th" { stack[row].rowIsHeader = true }
                } else {
                    stack[parent].blocks.append(.paragraph(content))
                }
            case "tr":
                if let table = stack.lastIndex(where: { $0.name == "table" }) {
                    stack[table].rows.append(frame.cells)
                    if frame.rowIsHeader, stack[table].rows.count == 1 { stack[table].headerRowCount = 1 }
                }
            case "table":
                var rows = frame.rows
                guard !rows.isEmpty else { break }
                let header = frame.headerRowCount > 0 ? rows.removeFirst() : []
                let columns = max(header.count, rows.map(\.count).max() ?? 0)
                stack[parent].blocks.append(.table(MarkdownTable(
                    alignments: Array(repeating: .none, count: columns),
                    header: header.isEmpty ? Array(repeating: [], count: columns) : header,
                    rows: rows
                )))
            case "thead", "tbody", "tfoot":
                break
            default:
                // p, div, center, …: keep the content, applying any alignment.
                if let alignment = alignment(of: frame), !frame.blocks.isEmpty {
                    stack[parent].blocks.append(.aligned(alignment, frame.blocks))
                } else {
                    stack[parent].blocks.append(contentsOf: frame.blocks)
                }
            }
        }

        for piece in pieces {
            switch piece {
            case .block(let block):
                flushInline()
                stack[stack.count - 1].blocks.append(block)
            case .html(let tokens):
                for token in tokens {
                    let isInPre = stack.contains { $0.name == "pre" }
                    switch token {
                    case .text(let text):
                        if isInPre {
                            stack[stack.count - 1].rawText += text
                        } else {
                            stack[stack.count - 1].inline.append(.tag(.text(collapseWhitespace(text))))
                        }
                    case .void("hr", _):
                        flushInline()
                        stack[stack.count - 1].blocks.append(.thematicBreak)
                    case .void:
                        stack[stack.count - 1].inline.append(.tag(token))
                    case .open(let name, let attributes) where blockElements.contains(name):
                        flushInline()
                        // A new <li>, <tr> or cell implicitly closes an unclosed sibling.
                        if ["li", "tr", "td", "th", "dt", "dd", "p"].contains(name), stack.last?.name == name {
                            closeTop()
                        }
                        stack.append(Frame(name: name, attributes: attributes))
                    case .close(let name) where blockElements.contains(name):
                        guard let index = stack.lastIndex(where: { $0.name == name }), index > 0 else { continue }
                        while stack.count > index { closeTop() }
                    case .open, .close:
                        if isInPre { continue }
                        stack[stack.count - 1].inline.append(.tag(token))
                    }
                }
            }
        }
        while stack.count > 1 { closeTop() }
        flushInline()
        return stack[0].blocks
    }

    private static func alignment(of frame: Frame) -> MarkdownTextAlignment? {
        if frame.name == "center" { return .center }
        switch frame.attributes["align"]?.lowercased() {
        case "center", "middle": return .center
        case "right": return .right
        case "left": return .left
        default: return nil
        }
    }

    /// The inline content of blocks (for summaries, HTML headings and cells).
    private static func inlines(of block: MarkdownBlock) -> [MarkdownInline] {
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines, _): return inlines
        case .aligned(_, let blocks): return blocks.flatMap(inlines(of:))
        default: return []
        }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for c in text {
            if c.isWhitespace, c != "\u{00A0}" {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(c)
                lastWasSpace = false
            }
        }
        return result
    }

    /// Drops leading/trailing whitespace-only text and line breaks.
    private static func trimmed(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var result = inlines
        func isBlank(_ inline: MarkdownInline) -> Bool {
            switch inline {
            case .text(let text): return text.allSatisfy { $0.isWhitespace && $0 != "\u{00A0}" }
            case .lineBreak, .softBreak: return true
            default: return false
            }
        }
        while let first = result.first, isBlank(first) { result.removeFirst() }
        while let last = result.last, isBlank(last) { result.removeLast() }
        if case .text(let text)? = result.first {
            result[0] = .text(String(text.drop { $0 == " " }))
        }
        if case .text(let text)? = result.last {
            result[result.count - 1] = .text(String(text.reversed().drop { $0 == " " }.reversed()))
        }
        return result
    }
}
