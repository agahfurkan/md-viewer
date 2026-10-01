import AppKit
import SwiftUI

/// Displays a rendered Markdown document in a read-only, selectable `NSTextView`.
///
/// One reader view is reused across tabs: switching documents swaps the text storage and
/// restores that document's scroll position. The same view shows the editor's live preview.
struct ReaderView: NSViewRepresentable {
    enum Source {
        /// The document as loaded from disk.
        case document
        /// The editor's unsaved text.
        case preview
    }

    let session: DocumentSession
    let style: ReaderStyle
    var source: Source = .document
    let onLink: (String) -> Void

    func makeCoordinator() -> ReaderCoordinator {
        ReaderCoordinator(isPreview: source == .preview)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onLink = onLink
        // Reading these observed properties is what makes SwiftUI call us again when they change.
        let toggles = session.detailsToggles
        let generation = session.renderGeneration
        switch source {
        case .document:
            let request = session.navigationRequest
            if let model = session.model {
                let content = ReaderContent(id: session.id, model: model, version: session.contentVersion, documentURL: session.fileURL, detailsToggles: toggles, renderGeneration: generation)
                coordinator.display(content, session: session, style: style)
            }
            if let request {
                coordinator.handle(request, for: session)
            }
        case .preview:
            guard let editor = session.editor, let model = editor.previewModel else { return }
            let content = ReaderContent(id: editor.id, model: model, version: editor.previewVersion, documentURL: session.fileURL, detailsToggles: toggles, renderGeneration: generation)
            coordinator.display(content, session: session, style: style)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: ReaderCoordinator) {
        coordinator.teardown()
    }
}

/// What the reader shows: a parsed model plus what's needed to render it.
struct ReaderContent {
    /// Identifies the content for caching and scroll restoration (document or editor preview).
    let id: UUID
    let model: MarkdownDocumentModel
    let version: Int
    let documentURL: URL
    let detailsToggles: Set<Int>
    var renderGeneration = 0
}

// MARK: - Coordinator

@MainActor
final class ReaderCoordinator: NSObject, NSTextViewDelegate {
    var onLink: ((String) -> Void)?

    private let isPreview: Bool
    private var scrollView: NSScrollView!
    private var textView: ReaderTextView!
    private weak var displayedSession: DocumentSession?
    private var displayedID: UUID?
    private var displayedVersion = -1
    private var displayedStyle: ReaderStyle?
    private var displayedToggles: Set<Int> = []
    private var displayedGeneration = 0
    private var rendered: RenderedMarkdown?
    private var handledNavigationToken: UUID?
    private var isProgrammaticScroll = false
    private var observers: [NSObjectProtocol] = []
    /// A scroll that must wait until the view has a real width (layout depends on it).
    private var pendingScroll: (index: Int, topMargin: CGFloat)?

    init(isPreview: Bool) {
        self.isPreview = isPreview
    }

    func makeScrollView() -> NSScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = ReaderLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = ReaderTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        // Find is handled by a finder that also searches code blocks (see ReaderFindClient).
        textView.usesFindBar = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.displaysLinkToolTips = false
        // Link colors come from the rendered text itself (so e.g. a <details> summary keeps the
        // text color); the text view only supplies the cursor.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = self
        textView.onUsableWidth = { [weak self] in self?.applyPendingScroll() }
        textView.setAccessibilityLabel(isPreview ? "Preview" : "Document")
        // Let file drops fall through to the window so they open as tabs.
        textView.unregisterDraggedTypes()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // Not auto-hidden: with legacy (always-visible) scrollers, a scroller appearing in the
        // middle of a layout pass narrows the text container and TextKit abandons the pass,
        // leaving the rest of the document unlaid. Overlay scrollers are unaffected either way.
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        self.textView = textView
        self.scrollView = scrollView
        if !isPreview { ActiveTextView.register(textView) }

        let findClient = ReaderFindClient()
        findClient.textView = textView
        findClient.revealCodeBlock = { [weak self] cell, location in
            self?.revealCodeBlock(cell, at: location)
        }
        let finder = NSTextFinder()
        finder.client = findClient
        finder.findBarContainer = scrollView
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = true
        textView.findClient = findClient
        textView.textFinder = finder

        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollPositionDidChange() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .remoteImageDidLoad,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let url = notification.object as? URL
            MainActor.assumeIsolated { self?.remoteImageDidLoad(url) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .diagramDidRender,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let source = notification.object as? String
            MainActor.assumeIsolated { self?.refreshDiagrams(source: source) }
        })
        return scrollView
    }

    func teardown() {
        storeScrollPosition()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let view = textView { ActiveTextView.unregister(view) }
    }

    // MARK: Display

    func display(_ content: ReaderContent, session: DocumentSession, style: ReaderStyle) {
        let isNewContent = displayedID != content.id
        guard isNewContent || content.version != displayedVersion || style != displayedStyle
            || content.detailsToggles != displayedToggles || content.renderGeneration != displayedGeneration
        else { return }

        // Where to be after the update: a switched-to document goes back to its stored
        // position; a re-rendered one (file changed on disk, settings, preview) keeps its place.
        let anchor: ViewportAnchor?
        let targetScroll: Int
        if isNewContent {
            storeScrollPosition()
            anchor = nil
            targetScroll = isPreview ? 0 : session.scrollPosition
        } else {
            anchor = captureViewportAnchor()
            targetScroll = topCharacterIndex()
        }

        textView.maxContentWidth = style.maxContentWidth
        let rendered = RenderCache.shared.rendered(for: content, style: style)
        isProgrammaticScroll = true
        textView.textFinder?.noteClientStringWillChange()
        textView.removeEmbeddedViews()
        textView.textStorage?.setAttributedString(rendered.attributedString)
        textView.findClient?.rebuild()
        self.rendered = rendered
        displayedSession = session
        displayedID = content.id
        displayedVersion = content.version
        displayedStyle = style
        displayedToggles = content.detailsToggles
        displayedGeneration = content.renderGeneration
        if !isPreview { ActiveTextView.register(textView) }
        refreshDiagrams(source: nil)

        if let anchor {
            restore(anchor)
        } else {
            scroll(toCharacterIndex: targetScroll, topMargin: 0)
        }
        isProgrammaticScroll = false
        updateCurrentOutlineItem()

        if isNewContent, !isPreview, let window = textView.window, !(window.firstResponder is NSTextView) || window.firstResponder === textView {
            window.makeFirstResponder(textView)
        }
    }

    func handle(_ request: DocumentSession.NavigationRequest, for session: DocumentSession) {
        guard !isPreview, request.token != handledNavigationToken, displayedID == session.id, let rendered else { return }
        handledNavigationToken = request.token

        let location: Int?
        switch request.target {
        case .anchor(let anchor):
            location = rendered.anchorLocations[anchor]
                ?? rendered.anchorLocations[anchor.lowercased()]
                ?? rendered.anchorLocations[HeadingSlugger.baseSlug(for: anchor)]
        case .outlineItem(let index):
            location = rendered.outlineLocations.indices.contains(index) ? rendered.outlineLocations[index] : nil
        }

        if let location {
            isProgrammaticScroll = true
            scroll(toCharacterIndex: location, topMargin: 14)
            isProgrammaticScroll = false
            storeScrollPosition()
            updateCurrentOutlineItem()
        } else {
            NSSound.beep()
        }

        // Clear the handled request so a future reader for this document doesn't replay it.
        let token = request.token
        DispatchQueue.main.async { [weak session] in
            if session?.navigationRequest?.token == token {
                session?.navigationRequest = nil
            }
        }
    }

    // MARK: Scrolling

    private func scroll(toCharacterIndex index: Int, topMargin: CGFloat) {
        guard textView.hasUsableWidth else {
            pendingScroll = (index, topMargin)
            return
        }
        pendingScroll = nil
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let length = textView.textStorage?.length
        else { return }

        var y: CGFloat = 0
        if index > 0, length > 0 {
            let clamped = min(index, length - 1)
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(length, clamped + 1)))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: clamped, length: 1), actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            y = rect.minY + textView.textContainerOrigin.y - topMargin
            // With non-contiguous layout the view may not have grown to cover the laid-out
            // text yet; make sure it is tall enough for the target to be scrollable.
            let needed = layoutManager.usedRect(for: container).maxY + textView.textContainerInset.height * 2
            let minimum = max(needed, y + scrollView.contentView.bounds.height)
            if textView.frame.height < minimum {
                textView.setFrameSize(NSSize(width: textView.frame.width, height: minimum))
            }
        }
        scroll(toY: y)
    }

    private func scroll(toY y: CGFloat) {
        let clipView = scrollView.contentView
        let maxY = max(0, textView.frame.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func applyPendingScroll() {
        guard let pending = pendingScroll else { return }
        // Let the container pick up the new width before measuring.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingScroll != nil, self.textView.hasUsableWidth else { return }
            self.isProgrammaticScroll = true
            self.scroll(toCharacterIndex: pending.index, topMargin: pending.topMargin)
            self.isProgrammaticScroll = false
            self.updateCurrentOutlineItem()
        }
    }

    /// The character at the top edge of the viewport.
    private func topCharacterIndex() -> Int {
        if let pendingScroll { return pendingScroll.index }
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let length = textView.textStorage?.length, length > 0
        else { return 0 }
        let visible = scrollView.contentView.bounds
        if visible.minY <= 1 { return 0 }
        let point = NSPoint(x: 8, y: max(0, visible.minY - textView.textContainerOrigin.y + 1))
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        return min(layoutManager.characterIndexForGlyph(at: glyph), length - 1)
    }

    // MARK: Viewport anchoring

    private func captureViewportAnchor() -> ViewportAnchor? {
        guard pendingScroll == nil,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let string = textView.textStorage?.string as NSString?, string.length > 0
        else { return nil }
        let visible = scrollView.contentView.bounds
        let atTop = visible.minY <= 1
        let atBottom = textView.frame.height > visible.height + 4 && visible.maxY >= textView.frame.height - 4
        let index = topCharacterIndex()
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let lineTop = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container).minY + textView.textContainerOrigin.y
        let snippetLength = min(80, string.length - index)
        return ViewportAnchor(
            snippet: string.substring(with: NSRange(location: index, length: snippetLength)),
            location: index,
            offset: visible.minY - lineTop,
            isAtTop: atTop,
            isAtBottom: atBottom
        )
    }

    private func restore(_ anchor: ViewportAnchor) {
        guard let string = textView.textStorage?.string as NSString? else { return }
        if anchor.isAtTop {
            scroll(toY: 0)
        } else if anchor.isAtBottom, let layoutManager = textView.layoutManager, let container = textView.textContainer {
            // Following a file that grows at the end (logs, agent output): stay at the bottom.
            layoutManager.ensureLayout(for: container)
            textView.sizeToFit()
            scroll(toY: .greatestFiniteMagnitude)
        } else {
            let index = ViewportAnchor.locate(anchor.snippet, near: anchor.location, in: string) ?? min(anchor.location, max(0, string.length - 1))
            scroll(toCharacterIndex: index, topMargin: -anchor.offset)
        }
    }

    private func storeScrollPosition() {
        guard !isPreview, let displayedSession, displayedID == displayedSession.id, textView != nil else { return }
        displayedSession.scrollPosition = topCharacterIndex()
    }

    private func scrollPositionDidChange() {
        guard !isProgrammaticScroll else { return }
        storeScrollPosition()
        updateCurrentOutlineItem()
    }

    private func updateCurrentOutlineItem() {
        guard !isPreview, let displayedSession, let rendered else { return }
        let top = topCharacterIndex()
        // The last heading at or above the top of the viewport (with a little tolerance).
        let locations = rendered.sortedOutlineLocations
        var current = locations.first?.index
        for entry in locations {
            guard entry.location <= top + 2 else { break }
            current = entry.index
        }
        if displayedSession.currentOutlineIndex != current {
            displayedSession.currentOutlineIndex = current
        }
    }

    // MARK: Code blocks

    /// Makes sure a code block's view is on screen and in place (for Find).
    private func revealCodeBlock(_ cell: CodeBlockAttachmentCell, at location: Int) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let characterRange = NSRange(location: location, length: 1)
        layoutManager.ensureLayout(forCharacterRange: characterRange)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        var frame = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        frame.origin.x += textView.textContainerOrigin.x
        frame.origin.y += textView.textContainerOrigin.y
        let view = cell.view
        if view.superview !== textView { textView.addSubview(view) }
        view.frame = frame.integral
        view.isHidden = false
        cell.textView.findTarget = textView
        textView.scrollToVisible(frame)
    }

    // MARK: Images and diagrams

    private func remoteImageDidLoad(_ url: URL?) {
        guard let url, let storage = textView.textStorage, let layoutManager = textView.layoutManager else { return }
        RenderCache.shared.removeAll(except: displayedID)
        guard let image = ImageLoader.shared.cachedRemoteImage(for: url) else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  let cell = attachment.attachmentCell as? ImageAttachmentCell,
                  cell.remoteURL == url
            else { return }
            cell.updateImage(image)
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
        textView.layoutDidShift()
    }

    /// Picks up finished Mermaid renders (all diagrams when `source` is nil).
    private func refreshDiagrams(source: String?) {
        guard let storage = textView.textStorage, let layoutManager = textView.layoutManager else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let cell = (value as? NSTextAttachment)?.attachmentCell as? DiagramAttachmentCell,
                  source == nil || cell.source == source
            else { return }
            cell.refresh()
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
        textView.layoutDidShift()
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let destination: String? = (link as? String) ?? (link as? URL)?.absoluteString
        guard let destination else { return false }
        if let id = ReaderLink.detailsID(from: destination) {
            displayedSession?.toggleDetails(id)
            return true
        }
        onLink?(destination)
        return true
    }
}

/// Remembers what was at the top of the viewport so a re-render can keep it there even when
/// text was inserted or removed above it.
struct ViewportAnchor: Equatable {
    let snippet: String
    let location: Int
    /// How far the viewport top is below the top of the anchor's line.
    let offset: CGFloat
    let isAtTop: Bool
    let isAtBottom: Bool

    /// Finds `snippet` in `string`, preferring the occurrence closest to `location`. Falls back to
    /// shorter prefixes when the anchored text itself was edited.
    static func locate(_ snippet: String, near location: Int, in string: NSString) -> Int? {
        let nsSnippet = snippet as NSString
        var tried = Set<String>()
        for length in [80, 40, 16] {
            let needle = nsSnippet.substring(to: min(length, nsSnippet.length))
            guard tried.insert(needle).inserted,
                  needle.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
            else { continue }
            var best: Int?
            var searchRange = NSRange(location: 0, length: string.length)
            var matches = 0
            while matches < 200 {
                let found = string.range(of: needle, options: [.literal], range: searchRange)
                guard found.location != NSNotFound else { break }
                if best == nil || abs(found.location - location) < abs(best! - location) {
                    best = found.location
                }
                matches += 1
                let next = found.location + 1
                guard next < string.length else { break }
                searchRange = NSRange(location: next, length: string.length - next)
            }
            if let best { return best }
        }
        return nil
    }
}

// MARK: - Text view

/// Keeps the text column centered at a comfortable maximum width.
final class ReaderTextView: NSTextView {
    var maxContentWidth: CGFloat = ReadingWidth.standard.points {
        didSet { if oldValue != maxContentWidth { updateInsets() } }
    }

    /// Called when the view first becomes wide enough for meaningful layout.
    var onUsableWidth: (() -> Void)?
    var findClient: ReaderFindClient?
    var textFinder: NSTextFinder?

    private let minimumHorizontalInset: CGFloat = 30
    private let verticalInset: CGFloat = 26

    var hasUsableWidth: Bool { bounds.width > minimumHorizontalInset * 2 + 40 }

    override func setFrameSize(_ newSize: NSSize) {
        let wasUsable = hasUsableWidth
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        updateInsets()
        if widthChanged { layoutDidShift() }
        if !wasUsable, hasUsableWidth {
            onUsableWidth?()
        }
    }

    // MARK: Embedded code block views

    /// Code block views sit at positions computed during drawing. When the layout moves, hide
    /// them all; drawing puts the visible ones back in their new places.
    func layoutDidShift() {
        var hidden = false
        for case let view as CodeBlockView in subviews where !view.isHidden {
            view.isHidden = true
            hidden = true
        }
        if hidden { needsDisplay = true }
    }

    func removeEmbeddedViews() {
        for case let view as CodeBlockView in subviews {
            view.removeFromSuperview()
        }
    }

    // MARK: Find

    override func performTextFinderAction(_ sender: Any?) {
        guard let textFinder, let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
              let action = NSTextFinder.Action(rawValue: tag)
        else { return }
        textFinder.performAction(action)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) {
            guard let textFinder, let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
            return textFinder.validateAction(action)
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Copy

    /// Copying a selection that spans code blocks includes their code (the text view itself
    /// only holds an attachment character for each block).
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage else { return super.writeSelection(to: pboard, types: types) }
        var containsCode = false
        var text = ""
        let string = storage.string as NSString
        for value in selectedRanges {
            let range = value.rangeValue
            guard range.length > 0 else { continue }
            storage.enumerateAttribute(.attachment, in: range) { attachment, subrange, _ in
                if let cell = (attachment as? NSTextAttachment)?.attachmentCell as? CodeBlockAttachmentCell {
                    containsCode = true
                    text += cell.code
                } else {
                    text += string.substring(with: subrange).replacingOccurrences(of: "\u{FFFC}", with: "")
                }
            }
        }
        guard containsCode else { return super.writeSelection(to: pboard, types: types) }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(text.replacingOccurrences(of: "\u{2028}", with: "\n"), forType: .string)
    }

    private func updateInsets() {
        let horizontal = max(minimumHorizontalInset, floor((bounds.width - maxContentWidth) / 2))
        let inset = NSSize(width: horizontal, height: verticalInset)
        if textContainerInset != inset {
            textContainerInset = inset
        }
    }
}

// MARK: - Render cache

/// Keeps recently rendered documents so switching tabs doesn't re-render.
@MainActor
final class RenderCache {
    static let shared = RenderCache()

    private struct Entry {
        let version: Int
        let style: ReaderStyle
        let toggles: Set<Int>
        let generation: Int
        let rendered: RenderedMarkdown
    }

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private let capacity = 8

    func rendered(for content: ReaderContent, style: ReaderStyle) -> RenderedMarkdown {
        if let entry = entries[content.id], entry.version == content.version, entry.style == style,
           entry.toggles == content.detailsToggles, entry.generation == content.renderGeneration {
            touch(content.id)
            return entry.rendered
        }
        let rendered = MarkdownRenderer(style: style, documentURL: content.documentURL, detailsToggles: content.detailsToggles).render(content.model)
        entries[content.id] = Entry(version: content.version, style: style, toggles: content.detailsToggles, generation: content.renderGeneration, rendered: rendered)
        touch(content.id)
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
        return rendered
    }

    func removeAll(except id: UUID?) {
        entries = entries.filter { $0.key == id }
        order = order.filter { $0 == id }
    }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}
