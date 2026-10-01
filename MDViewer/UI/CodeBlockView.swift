import AppKit

/// A fenced code block shown as its own non-wrapping, horizontally scrollable text view inside
/// the reader, with a copy button. The reader's text holds a single attachment character for it;
/// Find and Copy treat the code as part of the document (see `ReaderFindClient`).
final class CodeBlockAttachmentCell: NSTextAttachmentCell {
    let code: String
    let language: String?
    /// The syntax-highlighted code.
    nonisolated(unsafe) let highlightedCode: NSAttributedString
    /// Size of the code text laid out without wrapping.
    private let contentSize: NSSize
    private let padding: CGFloat
    nonisolated(unsafe) private var hostedView: CodeBlockView?

    init(code: String, language: String?, highlighted: NSAttributedString, padding: CGFloat) {
        self.code = code
        self.language = language
        self.highlightedCode = highlighted
        self.padding = padding
        self.contentSize = CodeBlockView.measure(highlighted)
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The view showing this block, created on first use.
    @MainActor
    var view: CodeBlockView {
        if let hostedView { return hostedView }
        let view = CodeBlockView(highlighted: highlightedCode, code: code, language: language, padding: padding)
        hostedView = view
        return view
    }

    @MainActor
    var textView: CodeTextView { view.textView }

    /// Whether this block's view currently exists (so Find can avoid creating views needlessly).
    var hasView: Bool { hostedView != nil }

    nonisolated private var height: CGFloat {
        ceil(contentSize.height + padding * 2)
    }

    override func cellSize() -> NSSize {
        NSSize(width: contentSize.width + padding * 2, height: height)
    }

    override func wantsToTrackMouse() -> Bool { false }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let available = max(40, lineFrag.width - position.x - textContainer.lineFragmentPadding * 2)
        var height = self.height
        // Legacy (always visible) scrollers take room at the bottom when the code overflows.
        if contentSize.width + padding * 2 > available, NSScroller.preferredScrollerStyle == .legacy {
            height += NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        }
        return NSRect(x: 0, y: 0, width: floor(available), height: height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        // Draw the background so nothing flashes before the view is in place.
        CodeBlockView.drawBackground(in: cellFrame)
        guard let controlView else { return }
        let frame = cellFrame.integral
        // Moving views while drawing is not allowed; place it right after this pass.
        DispatchQueue.main.async { [weak self, weak controlView] in
            guard let self, let controlView else { return }
            let view = self.view
            if view.superview !== controlView {
                controlView.addSubview(view)
            }
            if view.frame != frame { view.frame = frame }
            view.isHidden = false
            view.textView.findTarget = controlView as? NSTextView
        }
    }
}

/// The view hosting a code block: rounded background, horizontal scroll view, copy button.
final class CodeBlockView: NSView {
    let textView: CodeTextView
    private let scrollView: HorizontalScrollView
    private let copyButton: NSButton
    private let languageLabel: NSTextField
    private let code: String
    private var trackingArea: NSTrackingArea?
    private var copyResetWork: DispatchWorkItem?

    static let cornerRadius: CGFloat = 6

    init(highlighted: NSAttributedString, code: String, language: String?, padding: CGFloat) {
        self.code = code

        let storage = NSTextStorage(attributedString: highlighted)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        textView = CodeTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.textContainerInset = NSSize(width: padding, height: padding)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.usesFindBar = false
        textView.unregisterDraggedTypes()
        textView.setAccessibilityLabel(language.map { "\($0) code" } ?? "Code")
        let size = CodeBlockView.measure(highlighted)
        textView.frame = NSRect(x: 0, y: 0, width: ceil(size.width + padding * 2), height: ceil(size.height + padding * 2))

        scrollView = HorizontalScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.verticalScrollElasticity = .none

        copyButton = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")!, target: nil, action: nil)
        copyButton.isBordered = false
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = "Copy code"
        copyButton.alphaValue = 0

        languageLabel = NSTextField(labelWithString: language ?? "")
        languageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        languageLabel.textColor = .tertiaryLabelColor
        languageLabel.alphaValue = 0

        super.init(frame: .zero)
        addSubview(scrollView)
        addSubview(languageLabel)
        addSubview(copyButton)
        copyButton.target = self
        copyButton.action = #selector(copyCode)
    }

    required init?(coder: NSCoder) { nil }

    /// Size of highlighted code laid out on unwrapped lines.
    static func measure(_ text: NSAttributedString) -> NSSize {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    static func drawBackground(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        ReaderPalette.codeBackground.setFill()
        path.fill()
        ReaderPalette.codeBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Self.drawBackground(in: bounds)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChildren()
    }

    /// Positions the subviews. Done on every resize rather than in `layout()`, which AppKit only
    /// calls when a layout pass is scheduled.
    private func layoutChildren() {
        scrollView.frame = bounds.insetBy(dx: 1, dy: 1)
        let buttonSize = NSSize(width: 26, height: 22)
        copyButton.frame = NSRect(x: bounds.maxX - buttonSize.width - 6, y: 6, width: buttonSize.width, height: buttonSize.height)
        languageLabel.sizeToFit()
        languageLabel.frame.origin = NSPoint(x: copyButton.frame.minX - languageLabel.frame.width - 4, y: 9)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setControlsVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        setControlsVisible(false)
    }

    private func setControlsVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            copyButton.animator().alphaValue = visible ? 1 : 0
            languageLabel.animator().alphaValue = visible ? 1 : 0
        }
    }

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        copyButton.contentTintColor = .systemGreen
        copyButton.toolTip = "Copied"
        copyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
            self?.copyButton.contentTintColor = .secondaryLabelColor
            self?.copyButton.toolTip = "Copy code"
        }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

/// Scrolls horizontally only; vertical scrolling goes to the document.
final class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The code's text view. Find commands go to the reader, which searches the whole document.
final class CodeTextView: NSTextView {
    weak var findTarget: NSTextView?

    override func performTextFinderAction(_ sender: Any?) {
        if let findTarget {
            findTarget.performTextFinderAction(sender)
        } else {
            super.performTextFinderAction(sender)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)), let findTarget {
            return findTarget.validateUserInterfaceItem(item)
        }
        return super.validateUserInterfaceItem(item)
    }
}
