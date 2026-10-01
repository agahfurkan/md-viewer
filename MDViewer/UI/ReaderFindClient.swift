import AppKit

/// Presents the reader to `NSTextFinder` as one string: the document text with each code block's
/// attachment character replaced by the block's code. NSTextFinder supports clients spread over
/// several views, so matches inside code blocks are found, highlighted and scrolled to in the
/// code block's own text view.
@MainActor
final class ReaderFindClient: NSObject, @preconcurrency NSTextFinderClient {
    private struct Segment {
        /// Range in the combined string.
        let range: NSRange
        /// Start of the segment in the main text storage.
        let mainLocation: Int
        /// Set for code blocks; `nil` for document text.
        let codeCell: CodeBlockAttachmentCell?
    }

    weak var textView: ReaderTextView?
    /// Places a code block's view so its text can be scrolled to and highlighted.
    var revealCodeBlock: ((CodeBlockAttachmentCell, Int) -> Void)?

    private var segments: [Segment] = []
    private var combined = NSMutableString()

    /// Rebuilds the combined string; call after the document text changes.
    func rebuild() {
        segments = []
        combined = NSMutableString()
        guard let storage = textView?.textStorage else { return }
        let text = storage.string as NSString
        var mainLocation = 0

        func appendMain(upTo end: Int) {
            guard end > mainLocation else { return }
            let range = NSRange(location: combined.length, length: end - mainLocation)
            combined.append(text.substring(with: NSRange(location: mainLocation, length: end - mainLocation)))
            segments.append(Segment(range: range, mainLocation: mainLocation, codeCell: nil))
            mainLocation = end
        }

        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let cell = (value as? NSTextAttachment)?.attachmentCell as? CodeBlockAttachmentCell else { return }
            appendMain(upTo: range.location)
            let code = cell.code as NSString
            segments.append(Segment(range: NSRange(location: combined.length, length: max(code.length, 1)), mainLocation: range.location, codeCell: cell))
            combined.append(code.length > 0 ? code as String : " ")
            mainLocation = range.location + range.length
        }
        appendMain(upTo: text.length)
    }

    // MARK: Mapping

    private func segmentIndex(containing index: Int) -> Int? {
        guard !segments.isEmpty else { return nil }
        var low = 0
        var high = segments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = segments[mid].range
            if index < range.location {
                high = mid - 1
            } else if index >= NSMaxRange(range) {
                low = mid + 1
            } else {
                return mid
            }
        }
        return index >= combined.length ? segments.count - 1 : nil
    }

    /// Converts a main-storage index to the combined string.
    private func combinedIndex(forMain main: Int) -> Int {
        for segment in segments {
            if segment.codeCell != nil {
                if main == segment.mainLocation { return segment.range.location }
            } else if main >= segment.mainLocation, main <= segment.mainLocation + segment.range.length {
                return segment.range.location + (main - segment.mainLocation)
            }
        }
        return combined.length
    }

    private func local(_ range: NSRange, in segment: Segment) -> NSRange {
        let start = max(range.location, segment.range.location) - segment.range.location
        let end = min(NSMaxRange(range), NSMaxRange(segment.range)) - segment.range.location
        if segment.codeCell != nil {
            return NSRange(location: start, length: max(0, end - start))
        }
        return NSRange(location: segment.mainLocation + start, length: max(0, end - start))
    }

    // MARK: NSTextFinderClient

    var string: String { combined as String }

    var isSelectable: Bool { true }
    var allowsMultipleSelection: Bool { false }
    var isEditable: Bool { false }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        guard let position = segmentIndex(containing: index), let textView else {
            outRange.pointee = NSRange(location: 0, length: combined.length)
            return textView ?? NSView()
        }
        // Consecutive document segments belong to the same view.
        let segment = segments[position]
        if let cell = segment.codeCell {
            outRange.pointee = segment.range
            return cell.textView
        }
        outRange.pointee = segment.range
        return textView
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let position = segmentIndex(containing: range.location) else { return nil }
        let segment = segments[position]
        let localRange = local(range, in: segment)
        let view: NSTextView
        if let cell = segment.codeCell {
            guard cell.hasView, cell.view.superview != nil else { return nil }
            view = cell.textView
        } else {
            guard let textView else { return nil }
            view = textView
        }
        guard let layoutManager = view.layoutManager, let container = view.textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: localRange, actualCharacterRange: nil)
        var rects: [NSValue] = []
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
            rects.append(NSValue(rect: rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)))
        }
        return rects
    }

    var visibleCharacterRanges: [NSValue] {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return [] }
        var visible = textView.visibleRect
        visible.origin.x -= textView.textContainerOrigin.x
        visible.origin.y -= textView.textContainerOrigin.y
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let start = combinedIndex(forMain: characters.location)
        let end = combinedIndex(forMain: NSMaxRange(characters))
        // A code block at the end of the range is visible as a whole.
        var endIncludingCode = end
        if let position = segmentIndex(containing: max(start, end - 1)), segments[position].codeCell != nil {
            endIncludingCode = max(end, NSMaxRange(segments[position].range))
        }
        return [NSValue(range: NSRange(location: start, length: max(0, endIncludingCode - start)))]
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let position = segmentIndex(containing: range.location),
              let textView = view as? NSTextView,
              let layoutManager = textView.layoutManager
        else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: local(range, in: segments[position]), actualCharacterRange: nil)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: textView.textContainerOrigin)
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let position = segmentIndex(containing: range.location), let textView else { return }
        let segment = segments[position]
        if let cell = segment.codeCell {
            revealCodeBlock?(cell, segment.mainLocation)
            cell.textView.scrollRangeToVisible(local(range, in: segment))
        } else {
            textView.scrollRangeToVisible(local(range, in: segment))
        }
    }

    var firstSelectedRange: NSRange {
        (selectedRanges.first as? NSValue)?.rangeValue ?? NSRange(location: 0, length: 0)
    }

    var selectedRanges: [NSValue] {
        get {
            guard let textView else { return [] }
            // A selection inside a code block wins when that block has focus.
            if let codeView = textView.window?.firstResponder as? CodeTextView,
               let segment = segments.first(where: { $0.codeCell?.hasView == true && $0.codeCell?.textView === codeView }) {
                let selection = codeView.selectedRange()
                return [NSValue(range: NSRange(location: segment.range.location + selection.location, length: selection.length))]
            }
            let selection = textView.selectedRange()
            let start = combinedIndex(forMain: selection.location)
            let end = combinedIndex(forMain: NSMaxRange(selection))
            return [NSValue(range: NSRange(location: start, length: max(0, end - start)))]
        }
        set {
            guard let range = newValue.first?.rangeValue,
                  let position = segmentIndex(containing: range.location),
                  let textView
            else { return }
            let segment = segments[position]
            if let cell = segment.codeCell {
                textView.setSelectedRange(NSRange(location: segment.mainLocation, length: 0))
                revealCodeBlock?(cell, segment.mainLocation)
                cell.textView.setSelectedRange(local(range, in: segment))
            } else {
                textView.setSelectedRange(local(range, in: segment))
            }
        }
    }
}
