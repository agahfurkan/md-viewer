import AppKit
import WebKit

extension Notification.Name {
    /// Posted on the main actor when a Mermaid diagram finished rendering. `object` is the source.
    static let diagramDidRender = Notification.Name("MDViewer.diagramDidRender")
}

/// Renders Mermaid diagrams to vector images.
///
/// Mermaid has no native implementation, so this is the one place the app uses web technology:
/// a single offscreen `WKWebView` runs the bundled `mermaid.min.js` and exports each diagram as
/// PDF. Results are cached per source and appearance. Diagrams render lazily and announce
/// completion with `diagramDidRender`.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()

    enum Result {
        case image(NSImage)
        case failure(String)
    }

    struct Key: Hashable {
        let source: String
        let dark: Bool
    }

    private var cache: [Key: Result] = [:]
    private var pending: [Key] = []
    private var inFlight: Key?
    private var webView: WKWebView?
    private var isReady = false

    func result(for source: String, dark: Bool) -> Result? {
        cache[Key(source: source, dark: dark)]
    }

    /// Requests rendering; does nothing if the result is cached or already queued.
    func render(_ source: String, dark: Bool) {
        let key = Key(source: source, dark: dark)
        guard cache[key] == nil, inFlight != key, !pending.contains(key) else { return }
        pending.append(key)
        startIfNeeded()
        processQueue()
    }

    /// Renders and waits for the result (used by tests).
    func renderAndWait(_ source: String, dark: Bool, timeout: Duration = .seconds(20)) async -> Result? {
        render(source, dark: dark)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let result = result(for: source, dark: dark) { return result }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    // MARK: - Web view

    private func startIfNeeded() {
        guard webView == nil else { return }
        guard let scriptURL = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8)
        else {
            failAll("Mermaid support files are missing.")
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4000, height: 3000), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;padding:0} #diagram{display:inline-block;padding:8px}</style>
        <script>\(script)</script>
        <script>
        async function renderDiagram(code, dark, background, textColor) {
          document.body.style.background = background;
          mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default',
                               themeVariables: { fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif' } });
          const container = document.getElementById('diagram');
          container.innerHTML = '';
          const { svg } = await mermaid.render('graph' + Date.now(), code);
          container.innerHTML = svg;
          // Mermaid makes the SVG fluid (width 100%); pin it to its natural size so labels
          // render at their real font size. The reader scales it down if it's too wide.
          const element = container.querySelector('svg');
          const box = element.viewBox && element.viewBox.baseVal;
          if (box && box.width > 0) {
            element.setAttribute('width', box.width);
            element.setAttribute('height', box.height);
            element.style.maxWidth = 'none';
          }
          const rect = container.getBoundingClientRect();
          return { width: Math.ceil(rect.width), height: Math.ceil(rect.height) };
        }
        </script></head><body><div id="diagram"></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            isReady = true
            processQueue()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { failAll(error.localizedDescription) }
    }

    private func processQueue() {
        guard isReady, inFlight == nil, !pending.isEmpty, let webView else { return }
        let key = pending.removeFirst()
        inFlight = key
        let background = Self.hexColor(NSColor.textBackgroundColor, dark: key.dark)
        let textColor = Self.hexColor(NSColor.labelColor, dark: key.dark)

        Task {
            let result: Result
            do {
                let value = try await webView.callAsyncJavaScript(
                    "return await renderDiagram(code, dark, background, textColor)",
                    arguments: ["code": key.source, "dark": key.dark, "background": background, "textColor": textColor],
                    contentWorld: .page
                )
                guard let size = value as? [String: Any],
                      let width = (size["width"] as? NSNumber)?.doubleValue,
                      let height = (size["height"] as? NSNumber)?.doubleValue,
                      width > 0, height > 0
                else { throw MermaidError.emptyDiagram }

                let configuration = WKPDFConfiguration()
                configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
                let pdf = try await webView.pdf(configuration: configuration)
                guard let image = NSImage(data: pdf) else { throw MermaidError.emptyDiagram }
                image.size = NSSize(width: width, height: height)
                result = .image(image)
            } catch {
                result = .failure(Self.message(for: error))
            }
            cache[key] = result
            inFlight = nil
            NotificationCenter.default.post(name: .diagramDidRender, object: key.source)
            processQueue()
        }
    }

    private func failAll(_ message: String) {
        for key in pending { cache[key] = .failure(message) }
        let sources = pending.map(\.source)
        pending.removeAll()
        for source in Set(sources) {
            NotificationCenter.default.post(name: .diagramDidRender, object: source)
        }
    }

    private enum MermaidError: LocalizedError {
        case emptyDiagram
        var errorDescription: String? { "The diagram is empty." }
    }

    private static func message(for error: any Error) -> String {
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return message
        }
        return error.localizedDescription
    }

    private static func hexColor(_ color: NSColor, dark: Bool) -> String {
        var resolved = NSColor.white
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? .white
        }
        return String(format: "#%02X%02X%02X", Int(resolved.redComponent * 255), Int(resolved.greenComponent * 255), Int(resolved.blueComponent * 255))
    }
}

/// Shows a Mermaid diagram (in the variant matching the current appearance), a placeholder while
/// it renders, or the error.
final class DiagramAttachmentCell: NSTextAttachmentCell {
    let source: String
    nonisolated(unsafe) private var lightImage: NSImage?
    nonisolated(unsafe) private var darkImage: NSImage?
    nonisolated(unsafe) private var errorMessage: String?
    nonisolated(unsafe) private let labelFont: NSFont

    init(source: String, font: NSFont) {
        self.source = source
        self.labelFont = font
        super.init(imageCell: nil)
        MainActor.assumeIsolated { refresh() }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Picks up finished renders from the renderer's cache and requests missing variants.
    @MainActor
    func refresh() {
        for dark in [false, true] {
            switch MermaidRenderer.shared.result(for: source, dark: dark) {
            case .image(let image):
                if dark { darkImage = image } else { lightImage = image }
            case .failure(let message):
                errorMessage = message
            case nil:
                MermaidRenderer.shared.render(source, dark: dark)
            }
        }
    }

    nonisolated private var isDark: Bool {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    nonisolated private var currentImage: NSImage? {
        isDark ? (darkImage ?? lightImage) : (lightImage ?? darkImage)
    }

    nonisolated private var placeholderText: String {
        if let errorMessage { return "Mermaid diagram error: \(errorMessage)" }
        return "Rendering diagram…"
    }

    override func cellSize() -> NSSize {
        if let currentImage { return currentImage.size }
        return NSSize(width: 320, height: labelFont.pointSize * 3)
    }

    override func wantsToTrackMouse() -> Bool { false }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let available = max(24, lineFrag.width - position.x - textContainer.lineFragmentPadding * 2)
        guard let image = lightImage ?? darkImage else {
            return NSRect(x: 0, y: 0, width: available, height: ceil(labelFont.pointSize * 3))
        }
        var size = image.size
        if size.width > available {
            size = NSSize(width: available, height: (size.height * available / size.width).rounded())
        }
        return NSRect(origin: .zero, size: size)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        if let currentImage {
            currentImage.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            return
        }
        let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        ReaderPalette.placeholderBorder.setStroke()
        path.setLineDash([3, 2], count: 2, phase: 0)
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: errorMessage == nil ? NSColor.secondaryLabelColor : NSColor.systemRed,
        ]
        let text = placeholderText as NSString
        let bounds = cellFrame.insetBy(dx: 12, dy: 8)
        text.draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}
