import Foundation
import Testing
@testable import MDViewer

struct SyntaxHighlighterTests {
    private func kinds(_ code: String, _ language: String) -> [(String, SyntaxToken.Kind)] {
        let ns = code as NSString
        return SyntaxHighlighter.tokens(for: code, language: language).map { (ns.substring(with: $0.range), $0.kind) }
    }

    @Test func unknownOrMissingLanguageHasNoTokens() {
        #expect(SyntaxHighlighter.tokens(for: "let x = 1", language: nil).isEmpty)
        #expect(SyntaxHighlighter.tokens(for: "let x = 1", language: "klingon").isEmpty)
    }

    @Test func swiftTokens() {
        let tokens = kinds("@MainActor func load() -> String { return \"x\" } // done", "swift")
        #expect(tokens.contains { $0 == ("@MainActor", .attribute) })
        #expect(tokens.contains { $0 == ("func", .keyword) })
        #expect(tokens.contains { $0 == ("load", .function) })
        #expect(tokens.contains { $0 == ("String", .type) })
        #expect(tokens.contains { $0 == ("\"x\"", .string) })
        #expect(tokens.contains { $0 == ("// done", .comment) })
    }

    @Test func pythonTripleQuotedStrings() {
        let tokens = kinds("def f():\n    \"\"\"doc\nstring\"\"\"\n    return 1  # one", "python")
        #expect(tokens.contains { $0 == ("def", .keyword) })
        #expect(tokens.contains { $0 == ("\"\"\"doc\nstring\"\"\"", .string) })
        #expect(tokens.contains { $0 == ("1", .number) })
        #expect(tokens.contains { $0 == ("# one", .comment) })
    }

    @Test func shellHashOnlyCommentsAtWordBoundary() {
        let tokens = kinds("echo $HOME#notcomment # real", "bash")
        #expect(tokens.contains { $0 == ("$HOME", .variable) })
        #expect(tokens.contains { $0 == ("# real", .comment) })
        #expect(!tokens.contains { $0.0.hasPrefix("#notcomment") })
    }

    @Test func jsonKeysAndValues() {
        let tokens = kinds("{\"name\": \"viewer\", \"ok\": true, \"n\": 3}", "json")
        #expect(tokens.contains { $0 == ("\"name\"", .property) })
        #expect(tokens.contains { $0 == ("\"viewer\"", .string) })
        #expect(tokens.contains { $0 == ("true", .keyword) })
        #expect(tokens.contains { $0 == ("3", .number) })
    }

    @Test func diffLines() {
        let tokens = kinds("@@ -1 +1 @@\n-old\n+new\n same", "diff")
        #expect(tokens.map(\.1) == [.meta, .deletion, .addition])
    }

    @Test func htmlTagsAndAttributes() {
        let tokens = kinds("<a href=\"x\">hi</a><!-- c -->", "html")
        #expect(tokens.contains { $0 == ("a", .tag) })
        #expect(tokens.contains { $0 == ("href", .attribute) })
        #expect(tokens.contains { $0 == ("\"x\"", .string) })
        #expect(tokens.contains { $0 == ("<!-- c -->", .comment) })
    }

    @Test func unterminatedConstructsDoNotCrash() {
        for language in ["swift", "js", "python", "c", "html", "json", "yaml", "sql", "bash"] {
            _ = SyntaxHighlighter.tokens(for: "\"unterminated /* comment <tag attr='x", language: language)
        }
    }

    @Test func tokenRangesAreWithinBounds() {
        let code = "let emoji = \"😀\" // 👍\nvar x = 1"
        let length = (code as NSString).length
        for token in SyntaxHighlighter.tokens(for: code, language: "swift") {
            #expect(token.location >= 0 && token.location + token.length <= length)
        }
    }
}
