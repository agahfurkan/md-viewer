import Foundation

/// Tokens for coloring Markdown *source* in the editor (not for rendering).
///
/// Line-oriented and regex-based: good enough to make structure visible while typing, and fast
/// enough to rerun on the whole document after each pause in typing.
enum MarkdownSourceHighlighter {
    static func tokens(for text: String) -> [SyntaxToken] {
        let string = text as NSString
        var tokens: [SyntaxToken] = []
        var fence: (marker: String, count: Int)?
        var lineStart = 0

        while lineStart <= string.length {
            let lineRange = string.lineRange(for: NSRange(location: min(lineStart, string.length), length: 0))
            var contentRange = lineRange
            // Exclude the line terminator.
            while contentRange.length > 0 {
                let last = string.character(at: NSMaxRange(contentRange) - 1)
                guard last == 0x0A || last == 0x0D else { break }
                contentRange.length -= 1
            }
            let line = string.substring(with: contentRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                if trimmed.hasPrefix(open.marker), trimmed.prefix(while: { String($0) == open.marker }).count >= open.count,
                   trimmed.allSatisfy({ String($0) == open.marker }) {
                    tokens.append(token(contentRange, .meta))
                    fence = nil
                } else if contentRange.length > 0 {
                    tokens.append(token(contentRange, .string))
                }
            } else if let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                let count = trimmed.prefix(while: { String($0) == String(marker.first!) }).count
                fence = (String(marker.first!), count)
                tokens.append(token(contentRange, .meta))
            } else {
                tokens.append(contentsOf: lineTokens(line, offset: contentRange.location))
            }

            if NSMaxRange(lineRange) <= lineStart { break }
            lineStart = NSMaxRange(lineRange)
            if lineStart >= string.length { break }
        }
        return tokens
    }

    private static func token(_ range: NSRange, _ kind: SyntaxToken.Kind) -> SyntaxToken {
        SyntaxToken(location: range.location, length: range.length, kind: kind)
    }

    private static let heading = try! NSRegularExpression(pattern: "^ {0,3}#{1,6}(\\s.*)?$")
    private static let quote = try! NSRegularExpression(pattern: "^ {0,3}>.*$")
    private static let rule = try! NSRegularExpression(pattern: "^ {0,3}([-*_])( *\\1){2,} *$")
    private static let listMarker = try! NSRegularExpression(pattern: "^\\s*(?:[-*+]|\\d{1,9}[.)])(?:\\s+\\[[ xX]\\])?(?=\\s)")
    private static let tableRow = try! NSRegularExpression(pattern: "\\|")
    private static let codeSpan = try! NSRegularExpression(pattern: "(`+)[^`]+?\\1")
    private static let link = try! NSRegularExpression(pattern: "!?\\[([^\\]]*)\\]\\(([^)\\s]*)(?:\\s+\"[^\"]*\")?\\)")
    private static let strong = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let emphasis = try! NSRegularExpression(pattern: "(?<![*_\\w])([*_])(?=\\S)(.+?)(?<=\\S)\\1(?![*_\\w])")
    private static let strike = try! NSRegularExpression(pattern: "~~(?=\\S)(.+?)(?<=\\S)~~")
    private static let htmlTag = try! NSRegularExpression(pattern: "</?[A-Za-z][^>]*>")
    private static let autolink = try! NSRegularExpression(pattern: "https?://[^\\s<>)]+")

    private static func lineTokens(_ line: String, offset: Int) -> [SyntaxToken] {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var tokens: [SyntaxToken] = []
        func add(_ range: NSRange, _ kind: SyntaxToken.Kind) {
            guard range.location != NSNotFound, range.length > 0 else { return }
            tokens.append(SyntaxToken(location: range.location + offset, length: range.length, kind: kind))
        }

        if heading.firstMatch(in: line, range: whole) != nil {
            add(whole, .keyword)
            return tokens
        }
        if rule.firstMatch(in: line, range: whole) != nil {
            add(whole, .meta)
            return tokens
        }
        if quote.firstMatch(in: line, range: whole) != nil {
            add(whole, .comment)
        }
        if let marker = listMarker.firstMatch(in: line, range: whole) {
            add(marker.range, .attribute)
        }
        if line.contains("|") {
            for match in tableRow.matches(in: line, range: whole) { add(match.range, .meta) }
        }

        // Inline constructs; code spans first so their contents aren't treated as emphasis.
        var covered = IndexSet()
        for match in codeSpan.matches(in: line, range: whole) {
            add(match.range, .string)
            covered.insert(integersIn: match.range.location..<NSMaxRange(match.range))
        }
        func isFree(_ range: NSRange) -> Bool {
            !covered.intersects(integersIn: range.location..<NSMaxRange(range))
        }
        for match in link.matches(in: line, range: whole) where isFree(match.range) {
            add(match.range(at: 1), .function)
            add(match.range(at: 2), .variable)
        }
        for match in autolink.matches(in: line, range: whole) where isFree(match.range) {
            add(match.range, .variable)
        }
        for match in strong.matches(in: line, range: whole) where isFree(match.range) {
            add(match.range, .type)
        }
        for match in emphasis.matches(in: line, range: whole) where isFree(match.range) {
            add(match.range, .type)
        }
        for match in strike.matches(in: line, range: whole) where isFree(match.range) {
            add(match.range, .comment)
        }
        for match in htmlTag.matches(in: line, range: whole) where isFree(match.range) {
            add(match.range, .tag)
        }
        return tokens
    }
}
