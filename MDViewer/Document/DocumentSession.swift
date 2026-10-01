import Foundation
import Observation

/// One open tab: a reference to a Markdown file plus its loaded and parsed state.
///
/// Filesystem state (URL, bookmark, modification date) and rendered state (the parsed model) are
/// kept as separate properties; rendering itself lives in the reader view.
@MainActor
@Observable
final class DocumentSession: Identifiable {
    enum State: Equatable {
        case loading
        case ready
        case missing
        case error(String)
    }

    /// A request for the reader to scroll to a heading. `token` makes repeated requests distinct.
    /// It stays pending until the reader has rendered the document and handled it.
    struct NavigationRequest: Equatable {
        enum Target: Equatable {
            case anchor(String)
            case outlineItem(Int)
        }

        let target: Target
        let token = UUID()
    }

    let id: UUID
    private(set) var fileURL: URL
    var state: State = .loading
    /// The parsed document. Kept while reloading or when the file goes missing so the last good
    /// content isn't lost.
    private(set) var model: MarkdownDocumentModel?
    /// Incremented whenever `model` changes; the reader re-renders when it sees a new version.
    private(set) var contentVersion = 0
    var navigationRequest: NavigationRequest?
    /// Index of the outline item at the top of the reader, for highlighting in the sidebar.
    var currentOutlineIndex: Int?
    /// Source editor state; `nil` while reading.
    var editor: EditorState?
    /// `<details>` elements whose open/closed state the user flipped.
    private(set) var detailsToggles: Set<Int> = []
    /// Bumped to re-render unchanged content (e.g. after folder access was granted).
    private(set) var renderGeneration = 0

    @ObservationIgnored var sourceText: String?
    @ObservationIgnored var lastKnownModificationDate: Date?
    @ObservationIgnored var bookmarkData: Data?
    /// Character index at the top of the reader viewport, used to restore scroll position.
    @ObservationIgnored var scrollPosition: Int = 0
    @ObservationIgnored var loadGeneration = 0
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var watcher: FileWatcher?

    init(fileURL: URL, id: UUID = UUID(), bookmarkData: Data? = nil, scrollPosition: Int = 0) {
        self.id = id
        self.fileURL = fileURL
        self.bookmarkData = bookmarkData
        self.scrollPosition = scrollPosition
    }

    var displayName: String { fileURL.lastPathComponent }

    var isEditing: Bool { editor != nil }

    var hasUnsavedChanges: Bool { editor?.isDirty ?? false }

    func updateLocation(_ url: URL) {
        fileURL = url
    }

    func apply(text: String, model: MarkdownDocumentModel, modificationDate: Date?) {
        sourceText = text
        lastKnownModificationDate = modificationDate
        if self.model != model {
            self.model = model
            contentVersion += 1
        }
        state = .ready
    }

    func navigate(to target: NavigationRequest.Target) {
        navigationRequest = NavigationRequest(target: target)
    }

    func invalidateRendering() {
        renderGeneration += 1
    }

    func toggleDetails(_ id: Int) {
        if detailsToggles.contains(id) {
            detailsToggles.remove(id)
        } else {
            detailsToggles.insert(id)
        }
    }
}

/// State of the Markdown source editor for a document.
@MainActor
@Observable
final class EditorState {
    let id = UUID()
    /// The text as last loaded from or saved to disk.
    @ObservationIgnored var baseText: String
    /// The current editor contents. Not observed: the editor view owns live text.
    @ObservationIgnored var text: String
    private(set) var isDirty = false
    /// The file changed on disk while there were unsaved edits.
    var hasExternalChange = false
    /// Incremented when `text` is replaced from outside the editor view (e.g. reload).
    private(set) var revision = 0
    /// Whether the live preview is shown next to the source.
    var showsPreview = true
    /// The rendered preview of the current text, updated shortly after typing pauses.
    private(set) var previewModel: MarkdownDocumentModel?
    private(set) var previewVersion = 0
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored var previewDelay: Duration = .milliseconds(250)

    init(text: String, model: MarkdownDocumentModel? = nil) {
        self.baseText = text
        self.text = text
        self.previewModel = model
        if model == nil { schedulePreviewUpdate(delay: .zero) }
    }

    func userEdited(_ newText: String) {
        text = newText
        let dirty = newText != baseText
        if dirty != isDirty { isDirty = dirty }
        schedulePreviewUpdate(delay: previewDelay)
    }

    func replaceFromDisk(_ newText: String) {
        baseText = newText
        text = newText
        isDirty = false
        hasExternalChange = false
        revision += 1
        schedulePreviewUpdate(delay: .zero)
    }

    /// Re-parses the text for the live preview, debounced so typing stays fast.
    private func schedulePreviewUpdate(delay: Duration) {
        previewTask?.cancel()
        let text = self.text
        previewTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            let model = await MarkdownParser.parseInBackground(text)
            guard !Task.isCancelled, let self, self.text == text else { return }
            if self.previewModel != model {
                self.previewModel = model
                self.previewVersion += 1
            }
        }
    }

    func markSaved() {
        baseText = text
        isDirty = false
        hasExternalChange = false
    }
}
