import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Bindable var windowState: WindowState
    @AppStorage(SettingsKey.fontSize) private var fontSize = Double(ReaderStyle.defaultFontSize)
    @AppStorage(SettingsKey.fontDesign) private var fontDesign = ReaderFontDesign.system.rawValue
    @AppStorage(SettingsKey.readingWidth) private var readingWidth = ReadingWidth.standard.rawValue
    @AppStorage(SettingsKey.sidebarWidth) private var storedSidebarWidth = 230.0
    /// Width the sidebar starts with, read once so live resizing doesn't feed back into layout.
    @State private var initialSidebarWidth: Double?
    @State private var isDropTargeted = false

    private var style: ReaderStyle {
        ReaderStyle(
            baseFontSize: CGFloat(fontSize).clamped(to: ReaderStyle.fontSizeRange),
            fontDesign: ReaderFontDesign(rawValue: fontDesign) ?? .system,
            maxContentWidth: (ReadingWidth(rawValue: readingWidth) ?? .standard).points
        )
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { windowState.isSidebarVisible ? .all : .detailOnly },
            set: { windowState.isSidebarVisible = $0 != .detailOnly }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            OutlineView(session: windowState.activeDocument)
                .navigationSplitViewColumnWidth(min: 170, ideal: initialSidebarWidth ?? storedSidebarWidth, max: 420)
                .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width in
                    // Remember the user's sidebar width (ignore the collapsed/zero state).
                    if width >= 170 { storedSidebarWidth = width.rounded() }
                }
        } detail: {
            VStack(spacing: 0) {
                if !windowState.documents.isEmpty {
                    TabBar(windowState: windowState)
                }
                DocumentArea(windowState: windowState, style: style)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.06))
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationTitle(windowState.activeDocument?.displayName ?? "MD Viewer")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarItems
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .frame(minWidth: 560, minHeight: 360)
        .background(WindowAccessor(windowState: windowState))
        .focusedSceneValue(\.windowState, windowState)
        .onAppear { if initialSidebarWidth == nil { initialSidebarWidth = storedSidebarWidth } }
        .alert(
            windowState.alert?.title ?? "",
            isPresented: Binding(get: { windowState.alert != nil }, set: { if !$0 { windowState.alert = nil } }),
            presenting: windowState.alert
        ) { _ in
            Button("OK") { windowState.alert = nil }
        } message: { alert in
            Text(alert.message)
        }
    }

    private var subtitle: String {
        guard let session = windowState.activeDocument else { return "" }
        if session.hasUnsavedChanges { return "Edited" }
        return session.fileURL.deletingLastPathComponent().abbreviatedPath
    }

    @ViewBuilder private var toolbarItems: some View {
        if let session = windowState.activeDocument, session.state == .ready || session.isEditing {
            if let editor = session.editor {
                Button {
                    editor.showsPreview.toggle()
                } label: {
                    Label(editor.showsPreview ? "Hide Preview" : "Show Preview", systemImage: editor.showsPreview ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                }
                .help(editor.showsPreview ? "Hide live preview (⌥⌘P)" : "Show live preview (⌥⌘P)")
                Button {
                    windowState.save(session)
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .help("Save (⌘S)")
                .disabled(!session.hasUnsavedChanges)
            }
            Button {
                UserActions.toggleEditing(session, windowState: windowState)
            } label: {
                Label(session.isEditing ? "Done" : "Edit", systemImage: session.isEditing ? "book" : "pencil")
            }
            .help(session.isEditing ? "Return to reading (⇧⌘E)" : "Edit Markdown source (⇧⌘E)")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await provider.loadFileURL() {
                    urls.append(url)
                }
            }
            if !windowState.openDropped(urls) {
                NSSound.beep()
            }
        }
        return true
    }
}

/// The content below the tab bar for the active document.
private struct DocumentArea: View {
    let windowState: WindowState
    let style: ReaderStyle

    var body: some View {
        if let session = windowState.activeDocument {
            DocumentContent(session: session, windowState: windowState, style: style)
        } else {
            EmptyStateView(windowState: windowState)
        }
    }
}

private struct DocumentContent: View {
    let session: DocumentSession
    let windowState: WindowState
    let style: ReaderStyle

    var body: some View {
        if let editor = session.editor {
            VStack(spacing: 0) {
                if session.state == .missing {
                    Banner(
                        systemImage: "exclamationmark.triangle.fill",
                        message: "The file was deleted or moved. Saving will create it again."
                    ) {}
                } else if editor.hasExternalChange {
                    Banner(
                        systemImage: "arrow.triangle.2.circlepath",
                        message: "“\(session.displayName)” was changed by another application."
                    ) {
                        Button("Reload from Disk") { windowState.reloadFromDisk(session) }
                        Button("Keep My Version") { editor.hasExternalChange = false }
                    }
                }
                if editor.showsPreview {
                    HSplitView {
                        SourceEditorView(editor: editor, fontSize: (style.baseFontSize * 0.9).rounded())
                            .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                        ReaderView(session: session, style: style, source: .preview) { destination in
                            windowState.openLink(destination, from: session)
                        }
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    SourceEditorView(editor: editor, fontSize: (style.baseFontSize * 0.9).rounded())
                }
            }
        } else {
            switch session.state {
            case .missing:
                MissingFileView(session: session, windowState: windowState)
            case .error(let message):
                DocumentErrorView(session: session, message: message, windowState: windowState)
            case .loading, .ready:
                if session.model != nil {
                    VStack(spacing: 0) {
                        if FolderAccessManager.shared.needsAccess(for: session.fileURL) {
                            Banner(
                                systemImage: "lock.fill",
                                message: "Images and links next to this file need access to its folder."
                            ) {
                                Button("Grant Access…") {
                                    if FolderAccessManager.shared.requestAccess(for: session.fileURL) {
                                        session.invalidateRendering()
                                    }
                                }
                            }
                        }
                        ReaderView(session: session, style: style) { destination in
                            windowState.openLink(destination, from: session)
                        }
                    }
                } else {
                    LoadingView()
                }
            }
        }
    }
}

private struct Banner<Actions: View>: View {
    let systemImage: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
            Text(message)
                .lineLimit(2)
            Spacer()
            actions()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Shows a spinner only if loading takes noticeably long, to avoid flashing it.
private struct LoadingView: View {
    @State private var isVisible = false

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if isVisible {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            isVisible = true
        }
    }
}

/// Connects the SwiftUI window to its `WindowState`: restores the saved frame and reports focus
/// and closing to the app model.
private struct WindowAccessor: NSViewRepresentable {
    let windowState: WindowState

    func makeNSView(context: Context) -> NSView {
        WindowObservingView(windowState: windowState)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowObservingView: NSView {
        let windowState: WindowState
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        init(windowState: WindowState) {
            self.windowState = windowState
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window, windowState.window !== window else { return }
            windowState.window = window
            // The close button asks about unsaved edits first (SwiftUI owns the window delegate).
            if let closeButton = window.standardWindowButton(.closeButton) {
                closeButton.target = self
                closeButton.action = #selector(closeButtonClicked)
            }
            if let frame = windowState.restoredFrame {
                window.setFrame(from: frame)
                windowState.restoredFrame = nil
            }
            let state = windowState
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { state.app?.windowDidBecomeKey(state) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { state.app?.windowWillClose(state) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { state.sessionManager.scheduleSave() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { state.sessionManager.scheduleSave() }
            })
        }

        @objc private func closeButtonClicked(_ sender: Any?) {
            UserActions.requestCloseWindow(windowState)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

private extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
