import AppKit
import SwiftMath

/// Typesets LaTeX math with SwiftMath (native CoreText rendering, no web view).
///
/// Images are rendered in black and drawn as a mask in the current text color, so they follow
/// light/dark mode without re-rendering.
@MainActor
enum MathRenderer {
    struct Rendered {
        let image: NSImage
        /// Distance from the baseline to the bottom of the image.
        let descent: CGFloat
    }

    private struct Key: Hashable {
        let latex: String
        let fontSize: CGFloat
        let display: Bool
    }

    private static var cache: [Key: Rendered?] = [:]

    static func render(_ latex: String, fontSize: CGFloat, display: Bool) -> Rendered? {
        let key = Key(latex: latex, fontSize: fontSize, display: display)
        if let cached = cache[key] { return cached }
        var math = MathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: .black,
            labelMode: display ? .display : .text,
            textAlignment: .left
        )
        let (error, image, layout) = math.asImage()
        let result: Rendered?
        if error == nil, let image, image.size.width > 0, image.size.height > 0 {
            result = Rendered(image: image, descent: layout?.descent ?? 0)
        } else {
            result = nil
        }
        if cache.count > 500 { cache.removeAll() }
        cache[key] = result
        return result
    }
}

/// Draws a math image as a mask filled with the text color at draw time.
final class MathAttachmentCell: NSTextAttachmentCell {
    nonisolated(unsafe) private let mathImage: NSImage
    nonisolated(unsafe) private let color: NSColor
    private let descent: CGFloat
    private let centered: Bool

    init(image: NSImage, descent: CGFloat, color: NSColor, centered: Bool) {
        self.mathImage = image
        self.descent = descent
        self.color = color
        self.centered = centered
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func cellSize() -> NSSize { mathImage.size }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -descent) }

    override func wantsToTrackMouse() -> Bool { false }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        var size = mathImage.size
        let available = max(24, lineFrag.width - position.x - textContainer.lineFragmentPadding * 2)
        var descent = self.descent
        if size.width > available {
            let scale = available / size.width
            size = NSSize(width: available, height: size.height * scale)
            descent *= scale
        }
        return NSRect(origin: NSPoint(x: 0, y: -descent), size: size)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let cgImage = mathImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        context.saveGState()
        // The text view is flipped; masks are drawn unflipped.
        context.translateBy(x: cellFrame.minX, y: cellFrame.maxY)
        context.scaleBy(x: 1, y: -1)
        let rect = CGRect(origin: .zero, size: cellFrame.size)
        context.clip(to: rect, mask: cgImage)
        context.setFillColor(color.cgColor)
        context.fill(rect)
        context.restoreGState()
    }
}
