import AppKit
import SwiftUI

/// A plain-text Markdown source editor. Deliberately minimal: monospaced text with line numbers
/// and Markdown coloring, undo/redo, find, and save — no formatting tools.
struct SourceEditorView: NSViewRepresentable {
    let editor: EditorState
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(editor: editor)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, so the line-number ruler and temporary-attribute coloring can use the
        // layout manager directly.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 14)
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.string = editor.text
        textView.delegate = context.coordinator
        textView.registerForDraggedTypes([.string])
        textView.setAccessibilityLabel("Markdown source")

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.revision = editor.revision
        context.coordinator.highlightNow()
        ActiveTextView.register(textView)
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let revision = editor.revision
        if revision != context.coordinator.revision {
            // Replaced from disk: keep the selection roughly where it was.
            let selection = textView.selectedRange()
            textView.string = editor.text
            let length = (editor.text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            context.coordinator.revision = revision
            context.coordinator.highlightNow()
        }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.font != font {
            textView.font = font
            context.coordinator.ruler?.invalidateThickness()
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let view = coordinator.textView { ActiveTextView.unregister(view) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let editor: EditorState
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        var revision = 0
        private var highlightWork: DispatchWorkItem?

        init(editor: EditorState) {
            self.editor = editor
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            editor.userEdited(textView.string)
            ruler?.textDidChange()
            scheduleHighlight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            ruler?.needsDisplay = true
        }

        private func scheduleHighlight() {
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlightNow() }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        /// Colors the Markdown with temporary attributes, which don't affect undo or the text.
        func highlightNow() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let string = textView.string
            let length = (string as NSString).length
            let whole = NSRange(location: 0, length: length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
            for token in MarkdownSourceHighlighter.tokens(for: string) where NSMaxRange(token.range) <= length {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: ReaderPalette.syntax(token.kind), forCharacterRange: token.range)
            }
        }
    }
}

/// Line numbers for the source editor, drawn for each logical (not wrapped) line.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// Character index where each line starts; rebuilt lazily after edits.
    private var lineStarts: [Int] = [0]
    private var lineStartsValid = false

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        invalidateThickness()
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func textDidChange() {
        lineStartsValid = false
        invalidateThickness()
        needsDisplay = true
    }

    func invalidateThickness() {
        let lines = max(lineCount, 1)
        let digits = max(3, String(lines).count)
        let width = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
        let thickness = ceil(CGFloat(digits) * width + 16)
        if ruleThickness != thickness { ruleThickness = thickness }
    }

    @objc private func boundsChanged(_ notification: Notification) {
        if let clip = notification.object as? NSClipView, clip === scrollView?.contentView {
            needsDisplay = true
        }
    }

    private var numberFont: NSFont {
        let size = (textView?.font?.pointSize ?? NSFont.systemFontSize) * 0.85
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    private var lineCount: Int {
        rebuildLineStartsIfNeeded()
        return lineStarts.count
    }

    private func rebuildLineStartsIfNeeded() {
        guard !lineStartsValid, let string = textView?.string as NSString? else { return }
        var starts = [0]
        var index = 0
        while index < string.length {
            let range = string.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index < string.length || (index == string.length && string.length > 0 && [0x0A, 0x0D].contains(string.character(at: index - 1))) {
                starts.append(index)
            }
        }
        lineStarts = starts
        lineStartsValid = true
    }

    /// The 0-based line containing a character index.
    private func lineIndex(for characterIndex: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= characterIndex { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        rebuildLineStartsIfNeeded()

        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let currentLine = lineIndex(for: textView.selectedRange().location)
        let currentAttributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.secondaryLabelColor]

        var visible = textView.visibleRect
        visible.origin.y -= textView.textContainerOrigin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let length = (textView.string as NSString).length

        var line = lineIndex(for: characterRange.location)
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characterRange) {
            let start = lineStarts[line]
            let fragmentRect: NSRect
            if start >= length {
                fragmentRect = layoutManager.extraLineFragmentRect
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let y = convert(NSPoint(x: 0, y: fragmentRect.minY + textView.textContainerOrigin.y), from: textView).y
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let baselineAdjust = ((textView.font?.ascender ?? 12) - numberFont.ascender)
            label.draw(
                at: NSPoint(x: ruleThickness - size.width - 8, y: y + baselineAdjust),
                withAttributes: line == currentLine ? currentAttributes : attributes
            )
            line += 1
        }
    }
}
