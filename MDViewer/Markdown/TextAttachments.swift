import AppKit

/// Attachment cell for images. It scales the image down to the available line width at layout
/// time, so window resizes don't require re-rendering the document.
final class ImageAttachmentCell: NSTextAttachmentCell {
    // Layout queries (`cellSize`, `cellFrame`) are nonisolated in AppKit's declarations but are
    // only ever called by the text system on the main thread.
    nonisolated(unsafe) private(set) var displayImage: NSImage?
    let altText: String
    let remoteURL: URL?
    private let isMissing: Bool
    private let fixedSize: NSSize?
    /// Width requested by HTML (`<img width>`); the image keeps its aspect ratio.
    private let preferredWidth: Double?
    private let baseline: CGFloat
    nonisolated(unsafe) private let placeholderFont: NSFont

    /// A regular image, scaled to fit.
    init(image: NSImage?, altText: String, remoteURL: URL? = nil, isMissing: Bool = false, preferredWidth: Double? = nil, font: NSFont) {
        self.displayImage = image
        self.altText = altText
        self.remoteURL = remoteURL
        self.isMissing = isMissing
        self.fixedSize = nil
        self.preferredWidth = preferredWidth
        self.baseline = image == nil ? -font.pointSize * 0.35 : 0
        self.placeholderFont = font
        super.init(imageCell: nil)
    }

    /// A small inline glyph (checkboxes, alert icons) drawn at a fixed size.
    init(symbol: NSImage, size: NSSize, baselineOffset: CGFloat) {
        self.displayImage = symbol
        self.altText = ""
        self.remoteURL = nil
        self.isMissing = false
        self.fixedSize = size
        self.preferredWidth = nil
        self.baseline = baselineOffset
        self.placeholderFont = .systemFont(ofSize: NSFont.systemFontSize)
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func updateImage(_ image: NSImage) {
        displayImage = image
    }

    nonisolated private var placeholderText: String {
        let label = altText.isEmpty ? (isMissing ? "Image not found" : "Image") : altText
        return label
    }

    nonisolated private var naturalSize: NSSize {
        if let fixedSize { return fixedSize }
        if let displayImage {
            let size = displayImage.size
            if let preferredWidth, size.width > 0 {
                return NSSize(width: preferredWidth, height: (size.height * preferredWidth / size.width).rounded())
            }
            return size
        }
        let textWidth = (placeholderText as NSString).size(withAttributes: [.font: placeholderFont]).width
        return NSSize(width: ceil(textWidth) + placeholderFont.pointSize * 2.6, height: ceil(placeholderFont.pointSize * 1.9))
    }

    override func cellSize() -> NSSize { naturalSize }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: baseline) }

    override func wantsToTrackMouse() -> Bool { false }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        var size = naturalSize
        let available = max(24, lineFrag.width - position.x - textContainer.lineFragmentPadding * 2)
        if size.width > available {
            size = NSSize(width: available, height: (size.height * available / size.width).rounded())
        }
        return NSRect(origin: NSPoint(x: 0, y: baseline), size: size)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        if let displayImage {
            displayImage.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            return
        }
        drawPlaceholder(in: cellFrame)
    }

    private func drawPlaceholder(in frame: NSRect) {
        let rect = frame.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        ReaderPalette.placeholderBorder.setStroke()
        path.setLineDash([3, 2], count: 2, phase: 0)
        path.stroke()

        let symbolName = isMissing ? "exclamationmark.triangle" : "photo"
        let iconSize = placeholderFont.pointSize
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))) {
            let symbolRect = NSRect(
                x: rect.minX + iconSize * 0.5,
                y: rect.midY - symbol.size.height / 2,
                width: symbol.size.width,
                height: symbol.size.height
            )
            symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: placeholderFont, .foregroundColor: NSColor.secondaryLabelColor]
        let text = placeholderText as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.minX + iconSize * 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
    }
}

/// Draws a full-width horizontal rule.
final class HorizontalRuleCell: NSTextAttachmentCell {
    private let height: CGFloat

    init(height: CGFloat) {
        self.height = height
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func cellSize() -> NSSize { NSSize(width: 100, height: height) }

    override func wantsToTrackMouse() -> Bool { false }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let width = max(24, lineFrag.width - position.x - textContainer.lineFragmentPadding * 2)
        return NSRect(x: 0, y: 0, width: width, height: height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let line = NSRect(x: cellFrame.minX, y: cellFrame.midY - 1, width: cellFrame.width, height: 2)
        ReaderPalette.rule.setFill()
        NSBezierPath(roundedRect: line, xRadius: 1, yRadius: 1).fill()
    }
}

/// A table that is no wider than its content needs (like GitHub), but still shrinks and wraps
/// when the window is narrower.
final class FittingTextTable: NSTextTable {
    /// Per-column widths: the longest word, and the width to fit the column on one line.
    nonisolated(unsafe) var minimumColumnWidths: [CGFloat] = []
    nonisolated(unsafe) var naturalColumnWidths: [CGFloat] = []
    /// Horizontal padding plus border of one cell.
    nonisolated(unsafe) var cellChrome: CGFloat = 0
    nonisolated(unsafe) private var sharesWidth: CGFloat = -1
    nonisolated(unsafe) private var shares: [CGFloat] = []

    /// Width the table needs to show every cell on one line.
    var naturalWidth: CGFloat {
        naturalColumnWidths.reduce(0) { $0 + $1 + cellChrome } + 4
    }

    private func fitting(_ rect: NSRect) -> NSRect {
        let margin = width(for: .margin, edge: .minX)
        var fitted = rect
        fitted.size.width = min(rect.width, naturalWidth + margin)
        return fitted
    }

    /// Column widths are recomputed for the width actually available, so a narrow window
    /// squeezes the long columns rather than breaking short words.
    private func applyShare(to block: NSTextTableBlock, available: CGFloat) {
        let column = block.startingColumn
        guard naturalColumnWidths.indices.contains(column) else { return }
        let space = available - width(for: .margin, edge: .minX)
        if naturalWidth <= space {
            // Everything fits on one line: each column is exactly as wide as its content.
            block.setValue(naturalColumnWidths[column] + 1, type: .absoluteValueType, for: .width)
            return
        }
        if available != sharesWidth {
            shares = MarkdownRenderer.columnShares(
                minimum: minimumColumnWidths,
                natural: naturalColumnWidths,
                available: space,
                cellChrome: cellChrome
            )
            sharesWidth = available
        }
        block.setValue(shares[column], type: .percentageValueType, for: .width)
    }

    override func rect(for block: NSTextTableBlock, layoutAt startingPoint: NSPoint, in rect: NSRect, textContainer: NSTextContainer, characterRange charRange: NSRange) -> NSRect {
        applyShare(to: block, available: rect.width)
        return super.rect(for: block, layoutAt: startingPoint, in: fitting(rect), textContainer: textContainer, characterRange: charRange)
    }

    override func boundsRect(for block: NSTextTableBlock, contentRect: NSRect, in rect: NSRect, textContainer: NSTextContainer, characterRange charRange: NSRange) -> NSRect {
        super.boundsRect(for: block, contentRect: contentRect, in: fitting(rect), textContainer: textContainer, characterRange: charRange)
    }
}

/// Layout manager that draws inline-code backgrounds as rounded rectangles.
final class ReaderLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        if color === ReaderPalette.inlineCodeBackground {
            color.setFill()
            for index in 0..<rectCount {
                let rect = rectArray[index].insetBy(dx: -1.5, dy: 0)
                NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
            }
        } else if color === ReaderPalette.keyboardBackground {
            // <kbd>: a small key cap with a border and a heavier bottom edge.
            for index in 0..<rectCount {
                let rect = rectArray[index].insetBy(dx: -2, dy: 0.5)
                let path = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
                color.setFill()
                path.fill()
                ReaderPalette.keyboardBorder.setStroke()
                path.lineWidth = 1
                path.stroke()
                ReaderPalette.keyboardBorder.setFill()
                NSBezierPath(rect: NSRect(x: rect.minX + 3, y: rect.maxY - 1, width: rect.width - 6, height: 1)).fill()
            }
        } else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
    }
}
