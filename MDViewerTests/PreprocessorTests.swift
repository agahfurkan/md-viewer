import Foundation
import Testing
@testable import MDViewer

struct PreprocessorTests {
    @Test func inlineMathRules() {
        var math: [String] = []
        let line = MarkdownPreprocessor.replaceInlineMath(in: #"$x$ and $ y$ and \$z$ and $5 or $a$b and $$c$$"#, math: &math)
        #expect(math == ["x", "a", "c"])
        #expect(!line.contains("$x$"))
        #expect(line.contains("$ y$"))
        #expect(line.contains(#"\$z$"#))
        #expect(line.contains("$5 or"))
    }

    @Test func fencedCodeIsUntouched() {
        let source = "~~~\n$x$ [^1]: no\n~~~\n$y$"
        let result = MarkdownPreprocessor.process(source)
        #expect(result.source.hasPrefix("~~~\n$x$ [^1]: no\n~~~\n"))
        #expect(result.math == ["y"])
        #expect(result.footnotes.isEmpty)
    }

    @Test func unterminatedDisplayMathIsLeftAsText() {
        let result = MarkdownPreprocessor.process("$$\nnever closed")
        #expect(result.math.isEmpty)
        #expect(result.source == "$$\nnever closed")
    }

    @Test func footnoteDefinitionsAreRemoved() {
        let result = MarkdownPreprocessor.process("Text[^n].\n\n[^n]: The note\n    more.\n\nAfter.")
        #expect(result.footnotes == [.init(label: "n", text: "The note\nmore.")])
        #expect(!result.source.contains("The note"))
        #expect(result.source.contains("After."))
    }

    @Test func sourceWithoutSpecialSyntaxIsUnchanged() {
        let source = "# Title\n\nPlain text."
        #expect(MarkdownPreprocessor.process(source).source == source)
    }
}

@MainActor
struct ViewportAnchorTests {
    @Test func findsTheNearestOccurrence() {
        let text = "intro\nrepeat line\nmiddle\nrepeat line\nend" as NSString
        let second = text.range(of: "repeat line", options: .backwards).location
        #expect(ViewportAnchor.locate("repeat line", near: second - 2, in: text) == second)
        #expect(ViewportAnchor.locate("repeat line", near: 0, in: text) == 6)
    }

    @Test func followsTextMovedByInsertionsAbove() {
        let old = "# A\n\nSome paragraph that the reader is looking at right now.\n" as NSString
        let new = "# A\n\nA brand new paragraph inserted above by an agent.\n\nSome paragraph that the reader is looking at right now.\n" as NSString
        let location = old.range(of: "Some paragraph").location
        let snippet = old.substring(from: location)
        #expect(ViewportAnchor.locate(snippet, near: location, in: new) == new.range(of: "Some paragraph").location)
    }

    @Test func fallsBackToAShorterPrefixWhenTheLineWasEdited() {
        let new = "Header\n\nSome paragraph that changed its ending entirely." as NSString
        let located = ViewportAnchor.locate("Some paragraph that the reader is looking at right now.", near: 8, in: new)
        #expect(located == new.range(of: "Some paragraph").location)
    }

    @Test func missingTextReturnsNil() {
        #expect(ViewportAnchor.locate("nothing like this", near: 0, in: "completely different" as NSString) == nil)
    }
}
