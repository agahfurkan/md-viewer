import Foundation

/// A highlighted span inside a code block. `range` is expressed in UTF-16 code units so it maps
/// directly onto `NSAttributedString` ranges.
struct SyntaxToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case keyword, string, comment, number, type, function
        case attribute, property, variable, tag, meta
        case addition, deletion
    }

    let location: Int
    let length: Int
    let kind: Kind

    var range: NSRange { NSRange(location: location, length: length) }
}

/// A small, dependency-free tokenizer that covers the languages most commonly found in
/// developer documentation. It favours speed and robustness over perfect grammar accuracy:
/// unknown languages simply produce no tokens.
enum SyntaxHighlighter {
    static func tokens(for code: String, language: String?) -> [SyntaxToken] {
        guard let language, let mode = mode(for: language) else { return [] }
        let chars = Array(code.utf16)
        switch mode {
        case .generic(let spec):
            var scanner = GenericScanner(chars: chars, spec: spec)
            scanner.run()
            return scanner.tokens
        case .markup:
            return MarkupScanner.scan(chars)
        case .diff:
            return DiffScanner.scan(chars)
        }
    }

    static func isSupported(language: String) -> Bool {
        mode(for: language) != nil
    }

    // MARK: - Language table

    private enum Mode {
        case generic(LanguageSpec)
        case markup
        case diff
    }

    private static func mode(for rawLanguage: String) -> Mode? {
        // Info strings may contain extra words ("swift title=foo"); only the first word counts.
        let language = rawLanguage
            .split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," })
            .first
            .map { $0.lowercased() } ?? ""
        switch language {
        case "swift": return .generic(.swift)
        case "js", "javascript", "jsx", "mjs", "cjs", "node": return .generic(.javascript)
        case "ts", "typescript", "tsx", "mts", "cts": return .generic(.typescript)
        case "py", "python", "python3", "py3": return .generic(.python)
        case "go", "golang": return .generic(.go)
        case "rs", "rust": return .generic(.rust)
        case "java": return .generic(.java)
        case "kt", "kotlin", "kts": return .generic(.kotlin)
        case "cs", "csharp", "c#": return .generic(.csharp)
        case "c", "h", "cpp", "c++", "cc", "cxx", "hpp", "hh", "objc", "objective-c", "objectivec", "m", "mm":
            return .generic(.cFamily)
        case "rb", "ruby": return .generic(.ruby)
        case "sh", "bash", "zsh", "shell", "console", "shellsession", "fish", "ksh", "make", "makefile":
            return .generic(.shell)
        case "sql", "mysql", "postgresql", "postgres", "sqlite", "plsql": return .generic(.sql)
        case "php": return .generic(.php)
        case "lua": return .generic(.lua)
        case "json", "jsonc", "json5", "geojson": return .generic(.json)
        case "yaml", "yml": return .generic(.yaml)
        case "toml", "ini", "cfg", "conf", "properties", "editorconfig": return .generic(.toml)
        case "css", "scss", "sass", "less": return .generic(.css)
        case "dockerfile", "docker", "containerfile": return .generic(.dockerfile)
        case "graphql", "gql": return .generic(.graphql)
        case "html", "htm", "xml", "xhtml", "svg", "plist", "vue", "svelte", "xaml": return .markup
        case "diff", "patch": return .diff
        default: return nil
        }
    }
}

// MARK: - Language specifications

private struct LanguageSpec {
    var keywords: Set<String> = []
    var types: Set<String> = []
    var lineComments: [[UInt16]] = []
    var blockComment: (open: [UInt16], close: [UInt16])?
    var quotes: Set<UInt16> = [.doubleQuote, .singleQuote]
    var multilineQuotes: Set<UInt16> = []
    var tripleQuotes = false
    var capitalizedIdentifiersAreTypes = false
    var attributePrefix: UInt16?
    var variablePrefix: UInt16?
    var extraIdentifierChars: Set<UInt16> = [.underscore]
    var caseInsensitiveKeywords = false
    /// `#` only starts a comment at the start of a line or after whitespace (shell, YAML).
    var hashCommentRequiresBoundary = false
    /// A `#` at the start of a line begins a preprocessor directive (C family).
    var preprocessorHash = false
    /// Identifiers/strings followed by one of these characters are highlighted as keys.
    var propertyTerminators: Set<UInt16> = []
    /// `[section]` at the start of a line is highlighted (TOML/INI).
    var sectionHeaders = false
    var highlightsFunctionCalls = true

    static func words(_ string: String) -> Set<String> {
        Set(string.split(separator: " ").map(String.init))
    }

    static let slashComments: [[UInt16]] = [Array("//".utf16)]
    static let cBlockComment: (open: [UInt16], close: [UInt16]) = (Array("/*".utf16), Array("*/".utf16))
    static let hashComments: [[UInt16]] = [Array("#".utf16)]

    static let swift = LanguageSpec(
        keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as Any false is nil self Self super throws true try async await actor some any nonisolated isolated macro package consume borrowing consuming mutating nonmutating override final lazy weak unowned required convenience dynamic indirect get set willSet didSet"),
        lineComments: slashComments,
        blockComment: cBlockComment,
        quotes: [.doubleQuote],
        tripleQuotes: true,
        capitalizedIdentifiersAreTypes: true,
        attributePrefix: .at
    )

    static let javascript = LanguageSpec(
        keywords: words("break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof new return super switch this throw try typeof var void while with yield let static async await of null true false undefined NaN Infinity get set from as"),
        lineComments: slashComments,
        blockComment: cBlockComment,
        quotes: [.doubleQuote, .singleQuote, .backtick],
        multilineQuotes: [.backtick],
        capitalizedIdentifiersAreTypes: true,
        attributePrefix: .at,
        extraIdentifierChars: [.underscore, .dollar]
    )

    static let typescript: LanguageSpec = {
        var spec = javascript
        spec.keywords.formUnion(words("interface type enum implements namespace declare abstract private protected public readonly keyof infer is satisfies unique module"))
        spec.types = words("any unknown never string number boolean symbol bigint object void")
        return spec
    }()

    static let python = LanguageSpec(
        keywords: words("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls print"),
        types: words("int str float bool list dict set tuple bytes object type complex frozenset bytearray"),
        lineComments: hashComments,
        tripleQuotes: true,
        capitalizedIdentifiersAreTypes: true,
        attributePrefix: .at
    )

    static let go = LanguageSpec(
        keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota"),
        types: words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any comparable"),
        lineComments: slashComments,
        blockComment: cBlockComment,
        quotes: [.doubleQuote, .singleQuote, .backtick],
        multilineQuotes: [.backtick]
    )

    static let rust = LanguageSpec(
        keywords: words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while macro_rules"),
        types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
        lineComments: slashComments,
        blockComment: cBlockComment,
        quotes: [.doubleQuote],
        capitalizedIdentifiersAreTypes: true,
        attributePrefix: .hash
    )

    static let java = LanguageSpec(
        keywords: words("abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try volatile while var record sealed permits yield true false null"),
        types: words("boolean byte char double float int long short void String Object"),
        lineComments: slashComments,
        blockComment: cBlockComment,
        tripleQuotes: true,
        capitalizedIdentifiersAreTypes: true,
        attributePrefix: .at
    )

    static let kotlin = LanguageSpec(
        keywords: words("as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg"),
        lineComments: slashComments,
        blockComment: cBlockComment,
        quotes: [.doubleQuote, .singleQuote],
        tripleQuotes: true,
        capitalizedIdentifiersAreTypes: true,
        attributePrefix: .at
    )

    static let csharp = LanguageSpec(
        keywords: words("abstract as base break case catch checked class const continue default delegate do else enum event explicit extern false finally fixed for foreach goto if implicit in interface internal is lock namespace new null operator out override params private protected public readonly ref return sealed sizeof stackalloc static struct switch this throw true try typeof unchecked unsafe using virtual volatile while async await var record init get set yield where"),
        types: words("bool byte char decimal double float int long object sbyte short string uint ulong ushort void dynamic"),
        lineComments: slashComments,
        blockComment: cBlockComment,
        capitalizedIdentifiersAreTypes: true,
        preprocessorHash: true
    )

    static let cFamily = LanguageSpec(
        keywords: words("auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while true false nullptr NULL class namespace template typename public private protected virtual override new delete this using try catch throw operator friend constexpr noexcept static_cast dynamic_cast reinterpret_cast const_cast explicit mutable final self super nil YES NO"),
        types: words("bool char double float int long short signed unsigned void size_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t id instancetype BOOL"),
        lineComments: slashComments,
        blockComment: cBlockComment,
        capitalizedIdentifiersAreTypes: true,
        attributePrefix: .at,
        preprocessorHash: true
    )

    static let ruby = LanguageSpec(
        keywords: words("alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer puts private protected public lambda proc"),
        lineComments: hashComments,
        capitalizedIdentifiersAreTypes: true,
        variablePrefix: .at
    )

    static let shell = LanguageSpec(
        keywords: words("if then else elif fi case esac for select while until do done in function return exit export local readonly declare unset source alias echo cd set shift trap eval exec sudo"),
        lineComments: hashComments,
        variablePrefix: .dollar,
        extraIdentifierChars: [.underscore, .hyphen],
        hashCommentRequiresBoundary: true,
        highlightsFunctionCalls: false
    )

    static let sql = LanguageSpec(
        keywords: words("select from where and or not insert into values update set delete create table drop alter add column index primary key foreign references join inner left right outer full cross on as group by order having limit offset union all distinct null is in like ilike between exists case when then else end view default unique check constraint returning with asc desc count sum avg min max true false if begin commit rollback transaction database schema grant revoke trigger function procedure returns language replace"),
        types: words("int integer bigint smallint decimal numeric real float double varchar char text boolean date time timestamp timestamptz uuid json jsonb serial blob"),
        lineComments: [Array("--".utf16)],
        blockComment: cBlockComment,
        caseInsensitiveKeywords: true
    )

    static let php = LanguageSpec(
        keywords: words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield true false null self parent"),
        lineComments: slashComments + hashComments,
        blockComment: cBlockComment,
        capitalizedIdentifiersAreTypes: true,
        variablePrefix: .dollar
    )

    static let lua = LanguageSpec(
        keywords: words("and break do else elseif end false for function goto if in local nil not or repeat return then true until while self"),
        lineComments: [Array("--".utf16)]
    )

    static let json = LanguageSpec(
        keywords: words("true false null"),
        lineComments: slashComments,
        blockComment: cBlockComment,
        quotes: [.doubleQuote],
        propertyTerminators: [.colon],
        highlightsFunctionCalls: false
    )

    static let yaml = LanguageSpec(
        keywords: words("true false null yes no on off True False Null Yes No"),
        lineComments: hashComments,
        extraIdentifierChars: [.underscore, .hyphen, .dot],
        hashCommentRequiresBoundary: true,
        propertyTerminators: [.colon],
        highlightsFunctionCalls: false
    )

    static let toml = LanguageSpec(
        keywords: words("true false"),
        lineComments: hashComments + [Array(";".utf16)],
        tripleQuotes: true,
        extraIdentifierChars: [.underscore, .hyphen, .dot],
        propertyTerminators: [.equals],
        sectionHeaders: true,
        highlightsFunctionCalls: false
    )

    static let css = LanguageSpec(
        keywords: words("important inherit initial unset none auto"),
        blockComment: cBlockComment,
        attributePrefix: .at,
        extraIdentifierChars: [.underscore, .hyphen],
        propertyTerminators: [.colon]
    )

    static let dockerfile = LanguageSpec(
        keywords: words("from run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck shell as"),
        lineComments: hashComments,
        variablePrefix: .dollar,
        caseInsensitiveKeywords: true,
        hashCommentRequiresBoundary: true,
        highlightsFunctionCalls: false
    )

    static let graphql = LanguageSpec(
        keywords: words("query mutation subscription fragment on type interface union enum input scalar schema extend implements directive true false null"),
        lineComments: hashComments,
        quotes: [.doubleQuote],
        tripleQuotes: true,
        capitalizedIdentifiersAreTypes: true,
        attributePrefix: .at,
        variablePrefix: .dollar
    )
}

// MARK: - Character constants

private extension UInt16 {
    static let newline: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let tab: UInt16 = 0x09
    static let doubleQuote: UInt16 = 0x22
    static let singleQuote: UInt16 = 0x27
    static let backtick: UInt16 = 0x60
    static let backslash: UInt16 = 0x5C
    static let underscore: UInt16 = 0x5F
    static let dollar: UInt16 = 0x24
    static let hyphen: UInt16 = 0x2D
    static let dot: UInt16 = 0x2E
    static let colon: UInt16 = 0x3A
    static let equals: UInt16 = 0x3D
    static let at: UInt16 = 0x40
    static let hash: UInt16 = 0x23
    static let openParen: UInt16 = 0x28
    static let openBracket: UInt16 = 0x5B
    static let closeBracket: UInt16 = 0x5D
    static let openBrace: UInt16 = 0x7B
    static let closeBrace: UInt16 = 0x7D
    static let lessThan: UInt16 = 0x3C
    static let greaterThan: UInt16 = 0x3E
    static let slash: UInt16 = 0x2F
    static let exclamation: UInt16 = 0x21
    static let question: UInt16 = 0x3F
    static let plus: UInt16 = 0x2B

    var isASCIILetter: Bool { (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self) }
    var isDigit: Bool { (0x30...0x39).contains(self) }
    var isUppercase: Bool { (0x41...0x5A).contains(self) }
    var isHorizontalWhitespace: Bool { self == .space || self == .tab || self == .carriageReturn }
}

// MARK: - Generic scanner

private struct GenericScanner {
    let chars: [UInt16]
    let spec: LanguageSpec
    var tokens: [SyntaxToken] = []

    init(chars: [UInt16], spec: LanguageSpec) {
        self.chars = chars
        self.spec = spec
    }

    private func isIdentifierStart(_ c: UInt16) -> Bool {
        c.isASCIILetter || c == .underscore || c > 0x7F || (c == .dollar && spec.extraIdentifierChars.contains(.dollar))
    }

    private func isIdentifierChar(_ c: UInt16) -> Bool {
        c.isASCIILetter || c.isDigit || c > 0x7F || spec.extraIdentifierChars.contains(c)
    }

    private func matches(_ pattern: [UInt16], at index: Int) -> Bool {
        guard index + pattern.count <= chars.count else { return false }
        for offset in 0..<pattern.count where chars[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    private func lineEnd(from index: Int) -> Int {
        var i = index
        while i < chars.count, chars[i] != .newline { i += 1 }
        return i
    }

    private func nextNonSpace(from index: Int) -> UInt16? {
        var i = index
        while i < chars.count, chars[i].isHorizontalWhitespace { i += 1 }
        return i < chars.count ? chars[i] : nil
    }

    private mutating func add(_ kind: SyntaxToken.Kind, _ start: Int, _ end: Int) {
        guard end > start else { return }
        tokens.append(SyntaxToken(location: start, length: end - start, kind: kind))
    }

    mutating func run() {
        let n = chars.count
        var i = 0
        var atLineStart = true

        while i < n {
            let c = chars[i]
            if c == .newline {
                atLineStart = true
                i += 1
                continue
            }
            if c.isHorizontalWhitespace {
                i += 1
                continue
            }
            defer { atLineStart = false }

            if spec.preprocessorHash, atLineStart, c == .hash {
                let end = lineEnd(from: i)
                add(.meta, i, end)
                i = end
                continue
            }

            if spec.sectionHeaders, atLineStart, c == .openBracket {
                var end = i
                while end < n, chars[end] != .closeBracket, chars[end] != .newline { end += 1 }
                if end < n, chars[end] == .closeBracket { end += 1 }
                add(.type, i, end)
                i = end
                continue
            }

            if let block = spec.blockComment, matches(block.open, at: i) {
                var end = i + block.open.count
                while end < n, !matches(block.close, at: end) { end += 1 }
                end = min(n, end + block.close.count)
                add(.comment, i, end)
                i = end
                continue
            }

            if let comment = spec.lineComments.first(where: { matches($0, at: i) }) {
                let isHash = comment == [.hash]
                let boundaryOK = !isHash || !spec.hashCommentRequiresBoundary || i == 0 || chars[i - 1].isHorizontalWhitespace || chars[i - 1] == .newline
                if boundaryOK {
                    let end = lineEnd(from: i)
                    add(.comment, i, end)
                    i = end
                    continue
                }
            }

            if spec.tripleQuotes, c == .doubleQuote || c == .singleQuote, matches([c, c, c], at: i) {
                var end = i + 3
                while end < n, !matches([c, c, c], at: end) {
                    end += chars[end] == .backslash ? 2 : 1
                }
                end = min(n, end + 3)
                add(.string, i, end)
                i = end
                continue
            }

            if spec.quotes.contains(c) {
                let multiline = spec.multilineQuotes.contains(c)
                var end = i + 1
                while end < n {
                    let d = chars[end]
                    if d == .backslash { end += 2; continue }
                    if d == c { end += 1; break }
                    if d == .newline, !multiline { break }
                    end += 1
                }
                end = min(end, n)
                let isKey = !spec.propertyTerminators.isEmpty && nextNonSpace(from: end).map(spec.propertyTerminators.contains) == true
                add(isKey ? .property : .string, i, end)
                i = end
                continue
            }

            if let prefix = spec.attributePrefix, c == prefix, i + 1 < n, isIdentifierStart(chars[i + 1]) {
                var end = i + 1
                while end < n, isIdentifierChar(chars[end]) { end += 1 }
                add(.attribute, i, end)
                i = end
                continue
            }

            if let prefix = spec.variablePrefix, c == prefix, i + 1 < n {
                var end = i + 1
                if chars[end] == .openBrace {
                    while end < n, chars[end] != .closeBrace, chars[end] != .newline { end += 1 }
                    end = min(n, end + 1)
                } else {
                    while end < n, isIdentifierChar(chars[end]) || chars[end].isDigit { end += 1 }
                }
                if end > i + 1 {
                    add(.variable, i, end)
                    i = end
                    continue
                }
            }

            if c.isDigit, i == 0 || !isIdentifierChar(chars[i - 1]) {
                var end = i + 1
                while end < n {
                    let d = chars[end]
                    if d.isASCIILetter || d.isDigit || d == .underscore || (d == .dot && end + 1 < n && chars[end + 1].isDigit) {
                        end += 1
                    } else {
                        break
                    }
                }
                add(.number, i, end)
                i = end
                continue
            }

            if isIdentifierStart(c) {
                var end = i + 1
                while end < n, isIdentifierChar(chars[end]) { end += 1 }
                // Ruby-style predicate/bang methods (`defined?`, `save!`).
                if end < n, chars[end] == .question || chars[end] == .exclamation, spec.variablePrefix == .at {
                    end += 1
                }
                let word = String(decoding: chars[i..<end], as: UTF16.self)
                let lookup = spec.caseInsensitiveKeywords ? word.lowercased() : word
                let next = nextNonSpace(from: end)
                if !spec.propertyTerminators.isEmpty, let next, spec.propertyTerminators.contains(next), !spec.keywords.contains(lookup) {
                    add(.property, i, end)
                } else if spec.keywords.contains(lookup) {
                    add(.keyword, i, end)
                } else if spec.types.contains(lookup) {
                    add(.type, i, end)
                } else if spec.capitalizedIdentifiersAreTypes, c.isUppercase {
                    add(.type, i, end)
                } else if spec.highlightsFunctionCalls, next == .openParen {
                    add(.function, i, end)
                }
                i = end
                continue
            }

            i += 1
        }
    }
}

// MARK: - Markup (HTML/XML)

private enum MarkupScanner {
    static func scan(_ chars: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        let n = chars.count
        let commentOpen = Array("<!--".utf16)
        let commentClose = Array("-->".utf16)

        func matches(_ pattern: [UInt16], at index: Int) -> Bool {
            guard index + pattern.count <= n else { return false }
            return Array(chars[index..<index + pattern.count]) == pattern
        }
        func isNameChar(_ c: UInt16) -> Bool {
            c.isASCIILetter || c.isDigit || c == .hyphen || c == .underscore || c == .colon || c == .dot || c > 0x7F
        }

        var i = 0
        while i < n {
            if matches(commentOpen, at: i) {
                var end = i + commentOpen.count
                while end < n, !matches(commentClose, at: end) { end += 1 }
                end = min(n, end + commentClose.count)
                tokens.append(SyntaxToken(location: i, length: end - i, kind: .comment))
                i = end
                continue
            }
            guard chars[i] == .lessThan else { i += 1; continue }

            var j = i + 1
            if j < n, chars[j] == .slash || chars[j] == .question || chars[j] == .exclamation { j += 1 }
            let nameStart = j
            while j < n, isNameChar(chars[j]) { j += 1 }
            guard j > nameStart else { i += 1; continue }
            tokens.append(SyntaxToken(location: nameStart, length: j - nameStart, kind: .tag))

            // Attributes until the closing `>`.
            while j < n, chars[j] != .greaterThan {
                let c = chars[j]
                if c == .doubleQuote || c == .singleQuote {
                    var end = j + 1
                    while end < n, chars[end] != c { end += 1 }
                    end = min(n, end + 1)
                    tokens.append(SyntaxToken(location: j, length: end - j, kind: .string))
                    j = end
                } else if c.isASCIILetter {
                    let start = j
                    while j < n, isNameChar(chars[j]) { j += 1 }
                    tokens.append(SyntaxToken(location: start, length: j - start, kind: .attribute))
                } else if c == .lessThan {
                    break
                } else {
                    j += 1
                }
            }
            i = j
        }
        return tokens
    }
}

// MARK: - Diff

private enum DiffScanner {
    static func scan(_ chars: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var lineStart = 0
        let n = chars.count
        while lineStart < n {
            var lineEnd = lineStart
            while lineEnd < n, chars[lineEnd] != .newline { lineEnd += 1 }
            let length = lineEnd - lineStart
            if length > 0 {
                let line = String(decoding: chars[lineStart..<lineEnd], as: UTF16.self)
                let kind: SyntaxToken.Kind?
                if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("@@") {
                    kind = .meta
                } else if chars[lineStart] == .plus {
                    kind = .addition
                } else if chars[lineStart] == .hyphen {
                    kind = .deletion
                } else {
                    kind = nil
                }
                if let kind {
                    tokens.append(SyntaxToken(location: lineStart, length: length, kind: kind))
                }
            }
            lineStart = lineEnd + 1
        }
        return tokens
    }
}
