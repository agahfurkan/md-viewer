import AppKit
import Observation

/// A message shown to the user as an alert.
struct AlertMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// One window's working set: its open documents (tabs), which one is active, and the actions
/// that change them. Contains no view code so it can be tested without launching the UI.
///
/// Services (loading/watching, recent files, session saving) are shared by all windows and owned
/// by `AppModel`.
@MainActor
@Observable
final class WindowState: Identifiable {
    /// A tab that was closed and can be reopened with ⇧⌘T.
    struct ClosedTab: Equatable {
        let path: String
        let bookmark: Data?
        let scrollPosition: Int
        let index: Int
    }

    static let closedTabLimit = 20

    let id: UUID
    private(set) var documents: [DocumentSession] = []
    private(set) var activeDocumentID: UUID?
    var isSidebarVisible = true {
        didSet { if oldValue != isSidebarVisible { sessionManager.scheduleSave() } }
    }
    var alert: AlertMessage?
    private(set) var recentlyClosed: [ClosedTab] = []

    @ObservationIgnored let documentManager: DocumentManager
    @ObservationIgnored let recentFiles: RecentFilesManager
    @ObservationIgnored let sessionManager: SessionManager
    /// The app model, for cross-window behaviour (a file is only ever open in one window).
    @ObservationIgnored weak var app: AppModel?
    /// The window showing this state, once it exists.
    @ObservationIgnored weak var window: NSWindow?
    /// Saved frame (`NSWindow.frameDescriptor`) to apply when the window appears.
    @ObservationIgnored var restoredFrame: String?
    /// Opens URLs outside the app. Replaceable in tests.
    @ObservationIgnored var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(id: UUID = UUID(), documentManager: DocumentManager, recentFiles: RecentFilesManager, sessionManager: SessionManager) {
        self.id = id
        self.documentManager = documentManager
        self.recentFiles = recentFiles
        self.sessionManager = sessionManager
    }

    var activeDocument: DocumentSession? {
        guard let activeDocumentID else { return nil }
        return documents.first { $0.id == activeDocumentID }
    }

    var activeIndex: Int? {
        guard let activeDocumentID else { return nil }
        return documents.firstIndex { $0.id == activeDocumentID }
    }

    var hasUnsavedChanges: Bool {
        documents.contains { $0.hasUnsavedChanges }
    }

    func document(withID id: UUID) -> DocumentSession? {
        documents.first { $0.id == id }
    }

    func document(for url: URL) -> DocumentSession? {
        documents.first { FileIdentity.isSameFile($0.fileURL, url) }
    }

    // MARK: - Opening

    /// Opens a file in a tab, or activates its existing tab — in this window or, if another
    /// window already shows the file, in that window.
    @discardableResult
    func open(_ url: URL, activate: Bool = true, anchor: String? = nil, at index: Int? = nil) -> DocumentSession {
        let canonical = FileIdentity.canonicalURL(url)

        if let existing = document(for: canonical) {
            if activate { self.activate(existing.id) }
            if let anchor { existing.navigate(to: .anchor(anchor)) }
            recentFiles.noteOpened(existing.fileURL)
            return existing
        }
        if let app, let (otherWindow, existing) = app.windowShowing(canonical, excluding: self) {
            otherWindow.activate(existing.id)
            if let anchor { existing.navigate(to: .anchor(anchor)) }
            app.bringToFront(otherWindow)
            recentFiles.noteOpened(existing.fileURL)
            return existing
        }

        let session = DocumentSession(fileURL: canonical, bookmarkData: SecurityScopedBookmarkManager.makeBookmark(for: canonical))
        if let anchor { session.navigate(to: .anchor(anchor)) }
        insert(session, at: index, activate: activate)
        documentManager.attach(session)
        recentFiles.noteOpened(canonical)
        return session
    }

    /// Opens several files; the last one becomes active.
    func open(_ urls: [URL]) {
        for url in urls {
            open(url)
        }
    }

    /// Opens dropped files, silently ignoring anything that isn't a supported document.
    /// - Returns: whether at least one file was opened.
    @discardableResult
    func openDropped(_ urls: [URL]) -> Bool {
        let supported = urls.filter { LinkResolver.isSupportedDocument($0) }
        open(supported)
        return !supported.isEmpty
    }

    private func insert(_ session: DocumentSession, at index: Int?, activate: Bool) {
        // New tabs open to the right of the active tab, like VS Code.
        let insertionIndex = index.map { min(max($0, 0), documents.count) }
            ?? activeIndex.map { $0 + 1 }
            ?? documents.count
        documents.insert(session, at: insertionIndex)
        if activate || activeDocumentID == nil {
            activeDocumentID = session.id
        }
        sessionManager.scheduleSave()
    }

    // MARK: - Tabs

    func activate(_ id: UUID) {
        guard activeDocumentID != id, documents.contains(where: { $0.id == id }) else { return }
        activeDocumentID = id
        sessionManager.scheduleSave()
    }

    func close(_ id: UUID) {
        guard let session = remove(id) else { return }
        rememberClosed(session)
        documentManager.detach(session)
    }

    /// Removes a tab without stopping its document (used when moving it to another window).
    @discardableResult
    func remove(_ id: UUID) -> DocumentSession? {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return nil }
        let session = documents.remove(at: index)
        if activeDocumentID == id {
            // Like a browser: activate the tab to the right, or else the one to the left.
            let next = documents.indices.contains(index) ? documents[index] : documents.last
            activeDocumentID = next?.id
        }
        lastRemovedIndex = index
        sessionManager.scheduleSave()
        return session
    }

    @ObservationIgnored private var lastRemovedIndex = 0

    /// Takes over a document that was open in another window.
    func adopt(_ session: DocumentSession) {
        insert(session, at: nil, activate: true)
    }

    private func rememberClosed(_ session: DocumentSession) {
        let closed = ClosedTab(
            path: session.fileURL.path,
            bookmark: session.bookmarkData,
            scrollPosition: session.scrollPosition,
            index: lastRemovedIndex
        )
        recentlyClosed.removeAll { $0.path == closed.path }
        recentlyClosed.append(closed)
        if recentlyClosed.count > Self.closedTabLimit {
            recentlyClosed.removeFirst(recentlyClosed.count - Self.closedTabLimit)
        }
    }

    /// Reopens the most recently closed tab at its previous position with its scroll position.
    @discardableResult
    func reopenClosedTab() -> DocumentSession? {
        while let closed = recentlyClosed.popLast() {
            let (url, bookmark) = SecurityScopedBookmarkManager.restoreURL(path: closed.path, bookmark: closed.bookmark)
            if let existing = document(for: url) {
                activate(existing.id)
                return existing
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let session = DocumentSession(
                fileURL: FileIdentity.canonicalURL(url),
                bookmarkData: bookmark ?? closed.bookmark,
                scrollPosition: closed.scrollPosition
            )
            insert(session, at: closed.index, activate: true)
            documentManager.attach(session)
            recentFiles.noteOpened(session.fileURL)
            return session
        }
        return nil
    }

    func closeOthers(keeping id: UUID) {
        for session in documents where session.id != id {
            close(session.id)
        }
        activate(id)
    }

    func closeTabsToRight(of id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        for session in documents[(index + 1)...].reversed() {
            close(session.id)
        }
    }

    /// Moves a tab so that it ends up at `destination` (an index in the final order).
    func moveTab(_ id: UUID, to destination: Int) {
        guard let source = documents.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(destination, 0), documents.count - 1)
        guard source != target else { return }
        let session = documents.remove(at: source)
        documents.insert(session, at: target)
        sessionManager.scheduleSave()
    }

    func selectNextTab() {
        selectTab(offset: 1)
    }

    func selectPreviousTab() {
        selectTab(offset: -1)
    }

    /// ⌘1…⌘8 select that tab; ⌘9 always selects the last tab, as in browsers.
    func selectTab(number: Int) {
        guard !documents.isEmpty, (1...9).contains(number) else { return }
        let index = number == 9 ? documents.count - 1 : number - 1
        guard documents.indices.contains(index) else { return }
        activate(documents[index].id)
    }

    private func selectTab(offset: Int) {
        guard !documents.isEmpty else { return }
        let current = activeIndex ?? 0
        let next = (current + offset + documents.count) % documents.count
        activate(documents[next].id)
    }

    // MARK: - Links

    /// Follows a link clicked in `session`.
    func openLink(_ destination: String, from session: DocumentSession) {
        switch LinkResolver.resolve(destination, relativeTo: session.fileURL) {
        case .anchor(let anchor):
            session.navigate(to: .anchor(anchor))
        case .markdownFile(let url, let fragment):
            if FileIdentity.isSameFile(url, session.fileURL) {
                if let fragment { session.navigate(to: .anchor(fragment)) }
            } else if FileManager.default.fileExists(atPath: url.path) {
                open(url, anchor: fragment)
            } else {
                alert = AlertMessage(title: "Linked File Not Found", message: "“\(destination)” could not be found at \(url.path).")
            }
        case .localFile(let url):
            if FileManager.default.fileExists(atPath: url.path) {
                openExternally(url)
            } else {
                alert = AlertMessage(title: "Linked File Not Found", message: "“\(destination)” could not be found at \(url.path).")
            }
        case .external(let url):
            openExternally(url)
        case .invalid:
            NSSound.beep()
        }
    }

    // MARK: - Missing files

    func retry(_ session: DocumentSession) {
        session.state = .loading
        documentManager.scheduleReload(session)
    }

    func relocate(_ session: DocumentSession, to url: URL) {
        if let other = documents.first(where: { $0.id != session.id && FileIdentity.isSameFile($0.fileURL, url) }) {
            // The located file is already open: just switch to it.
            close(session.id)
            activate(other.id)
            return
        }
        documentManager.relocate(session, to: url)
        recentFiles.noteOpened(url)
        sessionManager.scheduleSave()
    }

    // MARK: - Editing

    func startEditing(_ session: DocumentSession) {
        guard session.editor == nil, session.state == .ready else { return }
        session.editor = EditorState(text: session.sourceText ?? "", model: session.model)
    }

    /// Leaves edit mode, discarding unsaved changes. Callers confirm with the user first.
    func stopEditing(_ session: DocumentSession) {
        session.editor = nil
    }

    func save(_ session: DocumentSession) {
        do {
            try documentManager.save(session)
        } catch {
            alert = AlertMessage(title: "Couldn't Save “\(session.displayName)”", message: error.localizedDescription)
        }
    }

    /// Writes the document (the editor's text while editing) to a new file, which the tab then
    /// shows — the standard Save As behaviour.
    func saveAs(_ session: DocumentSession, to url: URL) {
        if let other = documents.first(where: { $0.id != session.id && FileIdentity.isSameFile($0.fileURL, url) }) {
            close(other.id)
        }
        do {
            try documentManager.saveAs(session, to: url)
            recentFiles.noteOpened(session.fileURL)
            sessionManager.scheduleSave()
        } catch {
            alert = AlertMessage(title: "Couldn't Save “\(url.lastPathComponent)”", message: error.localizedDescription)
        }
    }

    /// Discards unsaved edits and reloads the file. Callers confirm with the user first.
    func revert(_ session: DocumentSession) {
        reloadFromDisk(session)
    }

    func reloadFromDisk(_ session: DocumentSession) {
        session.editor?.replaceFromDisk(session.sourceText ?? "")
        documentManager.scheduleReload(session)
    }

    // MARK: - Session

    func makeSnapshot() -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            documents: documents.map {
                SessionSnapshot.DocumentReference(path: $0.fileURL.path, bookmark: $0.bookmarkData, scrollPosition: $0.scrollPosition)
            },
            activeIndex: activeIndex,
            isSidebarVisible: isSidebarVisible,
            frame: window?.frameDescriptor ?? restoredFrame
        )
    }

    /// Reopens the documents of a previous session. Files that no longer exist are restored as
    /// tabs in the `missing` state so the user can locate or close them.
    func restore(from snapshot: SessionSnapshot) {
        isSidebarVisible = snapshot.isSidebarVisible
        restoredFrame = snapshot.frame
        var activeID: UUID?

        for (index, reference) in snapshot.documents.enumerated() {
            let (url, refreshedBookmark) = SecurityScopedBookmarkManager.restoreURL(path: reference.path, bookmark: reference.bookmark)
            let canonical = FileIdentity.canonicalURL(url)
            let session: DocumentSession
            if let existing = document(for: canonical) {
                session = existing
            } else if app?.windowShowing(canonical, excluding: self) != nil {
                continue
            } else {
                session = DocumentSession(
                    fileURL: canonical,
                    bookmarkData: refreshedBookmark ?? reference.bookmark,
                    scrollPosition: max(0, reference.scrollPosition ?? 0)
                )
                documents.append(session)
                documentManager.attach(session)
            }
            if index == snapshot.activeIndex {
                activeID = session.id
            }
        }
        activeDocumentID = activeID ?? documents.first?.id
    }

    /// Stops all documents (the window is going away).
    func closeAll() {
        for session in documents {
            documentManager.detach(session)
        }
        documents.removeAll()
        activeDocumentID = nil
    }
}
