import Foundation

/// Runs the pipeline for each open document:
///
///     File watching → Document loading → Markdown parsing → (rendering, in the reader view)
///
/// Loading and parsing happen off the main actor; results are applied on the main actor.
@MainActor
final class DocumentManager {
    private let watchDebounce: DispatchTimeInterval
    private let watchesFiles: Bool
    /// Called when a document's location changed on its own (renamed/moved on disk).
    var onLocationChange: ((DocumentSession) -> Void)?

    init(watchDebounce: DispatchTimeInterval = .milliseconds(150), watchesFiles: Bool = true) {
        self.watchDebounce = watchDebounce
        self.watchesFiles = watchesFiles
    }

    /// Starts watching and loading a newly opened document.
    func attach(_ session: DocumentSession) {
        SecurityScopedBookmarkManager.startAccessing(session.fileURL)
        startWatching(session)
        scheduleReload(session)
    }

    /// Stops all work for a closed document.
    func detach(_ session: DocumentSession) {
        session.watcher?.stop()
        session.watcher = nil
        session.loadTask?.cancel()
        session.loadTask = nil
        session.loadGeneration += 1
        SecurityScopedBookmarkManager.stopAccessing(session.fileURL)
    }

    /// Points a document at a new file (the user located a moved file).
    func relocate(_ session: DocumentSession, to url: URL) {
        SecurityScopedBookmarkManager.stopAccessing(session.fileURL)
        session.updateLocation(FileIdentity.canonicalURL(url))
        session.bookmarkData = SecurityScopedBookmarkManager.makeBookmark(for: session.fileURL)
        SecurityScopedBookmarkManager.startAccessing(session.fileURL)
        if let watcher = session.watcher {
            watcher.retarget(to: session.fileURL)
        } else {
            startWatching(session)
        }
        session.state = .loading
        scheduleReload(session)
    }

    func scheduleReload(_ session: DocumentSession) {
        session.loadTask?.cancel()
        session.loadTask = Task { [weak self] in
            await self?.reload(session)
        }
    }

    /// Loads the file and, if its text changed, parses it. Safe to call repeatedly: stale
    /// results from overlapping loads are discarded.
    func reload(_ session: DocumentSession) async {
        session.loadGeneration += 1
        let generation = session.loadGeneration
        let url = session.fileURL
        let previousText = session.sourceText

        let loaded = await Task.detached(priority: .userInitiated) { FileLoader.load(url) }.value
        guard generation == session.loadGeneration, !Task.isCancelled else { return }

        switch loaded {
        case .failure(.missing):
            session.state = .missing
        case .failure(let error):
            session.state = .error(error.message)
        case .success(let file):
            // Skip parsing when the text is unchanged (e.g. only metadata was touched).
            if file.text == previousText, session.model != nil {
                session.lastKnownModificationDate = file.modificationDate
                session.state = .ready
            } else {
                let model = await MarkdownParser.parseInBackground(file.text)
                guard generation == session.loadGeneration, !Task.isCancelled else { return }
                session.apply(text: file.text, model: model, modificationDate: file.modificationDate)
            }
            updateEditor(session, diskText: file.text)
            if session.bookmarkData == nil {
                session.bookmarkData = SecurityScopedBookmarkManager.makeBookmark(for: url)
            }
        }
    }

    /// Writes the editor contents to disk.
    func save(_ session: DocumentSession) throws {
        guard let editor = session.editor else { return }
        let text = editor.text
        try Data(text.utf8).write(to: session.fileURL, options: .atomic)
        editor.markSaved()
        // Update the reader immediately; the watcher's reload will then be a no-op.
        let model = MarkdownParser.parse(text)
        let date = (try? session.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        session.apply(text: text, model: model, modificationDate: date)
    }

    /// Writes the document to a new location and makes the session refer to that file.
    func saveAs(_ session: DocumentSession, to url: URL) throws {
        let text = session.editor?.text ?? session.sourceText ?? ""
        let destination = FileIdentity.canonicalURL(url)
        try Data(text.utf8).write(to: destination, options: .atomic)

        SecurityScopedBookmarkManager.stopAccessing(session.fileURL)
        session.updateLocation(FileIdentity.canonicalURL(destination))
        session.bookmarkData = SecurityScopedBookmarkManager.makeBookmark(for: session.fileURL)
        SecurityScopedBookmarkManager.startAccessing(session.fileURL)
        if let watcher = session.watcher {
            watcher.retarget(to: session.fileURL)
        } else {
            startWatching(session)
        }
        session.editor?.markSaved()
        let date = (try? session.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        session.apply(text: text, model: MarkdownParser.parse(text), modificationDate: date)
    }

    // MARK: - Private

    private func updateEditor(_ session: DocumentSession, diskText: String) {
        guard let editor = session.editor, diskText != editor.baseText else { return }
        if editor.isDirty {
            if diskText != editor.text {
                editor.hasExternalChange = true
            } else {
                editor.markSaved()
            }
        } else {
            editor.replaceFromDisk(diskText)
        }
    }

    private func startWatching(_ session: DocumentSession) {
        guard watchesFiles else { return }
        let watcher = FileWatcher(url: session.fileURL, debounce: watchDebounce) { [weak self, weak session] event in
            guard let self, let session else { return }
            self.handle(event, for: session)
        }
        session.watcher = watcher
        watcher.start()
    }

    private func handle(_ event: FileWatcher.Event, for session: DocumentSession) {
        switch event {
        case .changed:
            scheduleReload(session)
        case .deleted:
            session.loadGeneration += 1
            session.loadTask?.cancel()
            session.state = .missing
        case .moved(let newURL):
            session.updateLocation(FileIdentity.canonicalURL(newURL))
            session.bookmarkData = SecurityScopedBookmarkManager.makeBookmark(for: session.fileURL)
            onLocationChange?(session)
            scheduleReload(session)
        }
    }
}
