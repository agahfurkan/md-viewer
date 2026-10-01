import Foundation

/// Source-level work that has to happen before cmark sees the text.
///
/// - **Math**: `$…$` and `$$…$$` would otherwise be mangled by Markdown (underscores become
///   emphasis). Each math span is replaced by a private-use placeholder that the converter turns
///   back into math.
/// - **Footnotes**: swift-markdown doesn't support them, so `[^label]: text` definitions are cut
///   out here and parsed separately; references are resolved by the converter.
///
/// Fenced code blocks and inline code spans are left untouched.
struct PreprocessedMarkdown: Equatable {
    struct Footnote: Equatable {
        let label: String
        let text: String
    }

    var source: String
    /// Math sources, indexed by placeholder number.
    var math: [String]
    var footnotes: [Footnote]
}

enum MarkdownPreprocessor {
    static let placeholderStart: Character = "\u{E000}"
    static let placeholderEnd: Character = "\u{E001}"
    /// Placeholder kinds.
    static let inlineMathKind: Character = "I"
    static let displayMathKind: Character = "D"

    static func placeholder(kind: Character, index: Int) -> String {
        "\(placeholderStart)\(kind)\(index)\(placeholderEnd)"
    }

    static func process(_ source: String) -> PreprocessedMarkdown {
        guard source.contains("$") || source.contains("[^") else {
            return PreprocessedMarkdown(source: source, math: [], footnotes: [])
        }

        var output: [String] = []
        var math: [String] = []
        var footnotes: [PreprocessedMarkdown.Footnote] = []

        let lines = source.components(separatedBy: "\n")
        var fence: (marker: Character, count: Int)?
        var index = 0

        while index < lines.count {
            let line = lines[index]

            // Inside a fenced code block: copy verbatim until the closing fence.
            if let open = fence {
                output.append(line)
                if isClosingFence(line, marker: open.marker, count: open.count) { fence = nil }
                index += 1
                continue
            }
            if let open = openingFence(line) {
                fence = open
                output.append(line)
                index += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Display math on its own lines: $$ … $$
            if trimmed.hasPrefix("$$"), leadingSpaces(line) <= 3 {
                if trimmed.count > 4, trimmed.hasSuffix("$$") {
                    let body = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                    output.append(contentsOf: ["", placeholder(kind: displayMathKind, index: math.count), ""])
                    math.append(body)
                    index += 1
                    continue
                }
                if trimmed == "$$" || !trimmed.dropFirst(2).contains("$") {
                    var body: [String] = []
                    let first = String(trimmed.dropFirst(2))
                    if !first.trimmingCharacters(in: .whitespaces).isEmpty { body.append(first) }
                    var end = index + 1
                    var closed = false
                    while end < lines.count {
                        let candidate = lines[end].trimmingCharacters(in: .whitespaces)
                        if candidate.hasSuffix("$$") {
                            let last = String(candidate.dropLast(2))
                            if !last.trimmingCharacters(in: .whitespaces).isEmpty { body.append(last) }
                            closed = true
                            break
                        }
                        body.append(lines[end])
                        end += 1
                    }
                    if closed {
                        output.append(contentsOf: ["", placeholder(kind: displayMathKind, index: math.count), ""])
                        math.append(body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                        index = end + 1
                        continue
                    }
                }
            }

            // Footnote definition: [^label]: text, plus continuation lines.
            if let (label, firstText) = footnoteDefinition(line) {
                var body = [firstText]
                var end = index + 1
                var previousBlank = false
                while end < lines.count {
                    let next = lines[end]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.isEmpty {
                        previousBlank = true
                        body.append("")
                        end += 1
                        continue
                    }
                    if footnoteDefinition(next) != nil { break }
                    let indented = leadingSpaces(next) >= 2 || next.hasPrefix("\t")
                    if indented {
                        body.append(dedent(next))
                    } else if !previousBlank, !startsBlock(nextTrimmed) {
                        body.append(next) // lazy continuation of the paragraph
                    } else {
                        break
                    }
                    previousBlank = false
                    end += 1
                }
                while body.last?.isEmpty == true { body.removeLast() }
                footnotes.append(.init(label: label, text: body.joined(separator: "\n")))
                output.append("")
                index = end
                continue
            }

            output.append(replaceInlineMath(in: line, math: &math))
            index += 1
        }

        return PreprocessedMarkdown(source: output.joined(separator: "\n"), math: math, footnotes: footnotes)
    }

    // MARK: - Inline math

    /// Replaces `$…$` (and inline `$$…$$`) spans, skipping code spans and escaped dollars.
    static func replaceInlineMath(in line: String, math: inout [String]) -> String {
        guard line.contains("$") else { return line }
        let chars = Array(line)
        var result = ""
        var i = 0

        while i < chars.count {
            let c = chars[i]

            // Code span: copy through the matching backtick run.
            if c == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                if let close = findBacktickRun(chars, from: i + run, length: run) {
                    result += String(chars[i..<(close + run)])
                    i = close + run
                } else {
                    result += String(chars[i..<(i + run)])
                    i += run
                }
                continue
            }

            if c == "\\", i + 1 < chars.count {
                result.append(c)
                result.append(chars[i + 1])
                i += 2
                continue
            }

            if c == "$" {
                let isDisplay = i + 1 < chars.count && chars[i + 1] == "$"
                let delimiter = isDisplay ? 2 : 1
                let start = i + delimiter
                if start < chars.count, !chars[start].isWhitespace, chars[start] != "$",
                   let end = findClosingDollar(chars, from: start, display: isDisplay) {
                    let body = String(chars[start..<end])
                    result += placeholder(kind: isDisplay ? displayMathKind : inlineMathKind, index: math.count)
                    math.append(body)
                    i = end + delimiter
                    continue
                }
            }

            result.append(c)
            i += 1
        }
        return result
    }

    /// Finds the closing delimiter. Like Pandoc: the content may not contain another unescaped
    /// `$` or a code span, the closing `$` must follow a non-space character, and a single `$`
    /// must not be followed by a digit (so "$5 and $10" stays text).
    private static func findClosingDollar(_ chars: [Character], from start: Int, display: Bool) -> Int? {
        var j = start
        while j < chars.count {
            let c = chars[j]
            if c == "\\" { j += 2; continue }
            if c == "`" { return nil }
            if c == "$" {
                guard j > start, !chars[j - 1].isWhitespace else { return nil }
                if display {
                    return j + 1 < chars.count && chars[j + 1] == "$" ? j : nil
                }
                let nextIsDigit = j + 1 < chars.count && chars[j + 1].isNumber
                return nextIsDigit ? nil : j
            }
            j += 1
        }
        return nil
    }

    private static func findBacktickRun(_ chars: [Character], from start: Int, length: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == "`" {
                var run = 0
                while j + run < chars.count, chars[j + run] == "`" { run += 1 }
                if run == length { return j }
                j += run
            } else {
                j += 1
            }
        }
        return nil
    }

    // MARK: - Line helpers

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func dedent(_ line: String) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        return String(line.dropFirst(min(4, leadingSpaces(line))))
    }

    private static func openingFence(_ line: String) -> (marker: Character, count: Int)? {
        guard leadingSpaces(line) <= 3 else { return nil }
        let trimmed = line.drop { $0 == " " }
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let count = trimmed.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        // Backtick fences may not contain backticks in the info string.
        if marker == "`", trimmed.dropFirst(count).contains("`") { return nil }
        return (marker, count)
    }

    private static func isClosingFence(_ line: String, marker: Character, count: Int) -> Bool {
        guard leadingSpaces(line) <= 3 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= count && trimmed.allSatisfy { $0 == marker }
    }

    private static func footnoteDefinition(_ line: String) -> (String, String)? {
        guard leadingSpaces(line) <= 3 else { return nil }
        let trimmed = line.drop { $0 == " " }
        guard trimmed.hasPrefix("[^"), let close = trimmed.firstIndex(of: "]") else { return nil }
        let label = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close]
        guard !label.isEmpty, !label.contains(where: \.isWhitespace) else { return nil }
        let afterClose = trimmed[trimmed.index(after: close)...]
        guard afterClose.hasPrefix(":") else { return nil }
        let text = afterClose.dropFirst().drop { $0 == " " || $0 == "\t" }
        return (String(label), String(text))
    }

    /// Lines that start a new block end a lazy footnote continuation.
    private static func startsBlock(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
            || trimmed.hasPrefix("|") || trimmed.hasPrefix("<")
            || trimmed.first.map { $0.isNumber && trimmed.contains(". ") } == true
    }
}
