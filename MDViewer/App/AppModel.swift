import AppKit
import Observation

/// App-wide state: the set of windows (each a `WindowState` with its own tabs) and the services
/// they share. Owns session persistence for all windows.
@MainActor
@Observable
final class AppModel {
    /// Not observed: SwiftUI asks for window IDs (and so may create window states) in the middle
    /// of a view update, where mutating observed state is not allowed. No view depends on it.
    @ObservationIgnored private(set) var windows: [WindowState] = []

    @ObservationIgnored let documentManager: DocumentManager
    @ObservationIgnored let recentFiles: RecentFilesManager
    @ObservationIgnored let sessionManager: SessionManager
    /// Opens a SwiftUI window for a window state. Provided by the first window that appears.
    @ObservationIgnored var presentWindow: ((UUID) -> Void)?
    /// Windows whose SwiftUI window currently exists.
    @ObservationIgnored private var presentedIDs: Set<UUID> = []
    /// The most recently focused window; files opened from Finder go there.
    @ObservationIgnored private weak var lastActiveWindow: WindowState?
    @ObservationIgnored private var activeWindowIDAtRestore: UUID?

    init(documentManager: DocumentManager, recentFiles: RecentFilesManager, sessionManager: SessionManager) {
        self.documentManager = documentManager
        self.recentFiles = recentFiles
        self.sessionManager = sessionManager
        sessionManager.snapshotProvider = { [weak self] in
            self?.makeSnapshot() ?? .empty
        }
        documentManager.onLocationChange = { [weak self] _ in
            self?.sessionManager.scheduleSave()
        }
    }

    var hasUnsavedChanges: Bool {
        windows.contains { $0.hasUnsavedChanges }
    }

    func window(withID id: UUID) -> WindowState? {
        windows.first { $0.id == id }
    }

    @discardableResult
    func makeWindow(id: UUID = UUID()) -> WindowState {
        if let existing = window(withID: id) { return existing }
        let state = WindowState(id: id, documentManager: documentManager, recentFiles: recentFiles, sessionManager: sessionManager)
        state.app = self
        windows.append(state)
        return state
    }

    /// The window shown by the window SwiftUI creates at launch. SwiftUI may ask for this value
    /// several times and expects the same answer, so it is fixed once: the first restored window,
    /// or a new one. Other windows are opened with explicit IDs.
    var launchWindowID: UUID {
        if let fixedLaunchWindowID { return fixedLaunchWindowID }
        let id = windows.first?.id ?? makeWindow().id
        fixedLaunchWindowID = id
        return id
    }

    @ObservationIgnored private var fixedLaunchWindowID: UUID?

    /// Finds the window (other than `excluded`) that already shows a file.
    func windowShowing(_ url: URL, excluding excluded: WindowState?) -> (WindowState, DocumentSession)? {
        for window in windows where window !== excluded {
            if let session = window.document(for: url) {
                return (window, session)
            }
        }
        return nil
    }

    /// Where files opened from Finder, the Dock or Open Recent go.
    var targetWindow: WindowState {
        if let lastActiveWindow, windows.contains(where: { $0 === lastActiveWindow }) {
            return lastActiveWindow
        }
        return windows.first ?? makeWindow()
    }

    func open(_ urls: [URL]) {
        targetWindow.open(urls)
    }

    // MARK: - Window lifecycle (called by the window views)

    func windowDidAppear(_ state: WindowState) {
        presentedIDs.insert(state.id)
        if lastActiveWindow == nil || state.id == activeWindowIDAtRestore {
            lastActiveWindow = state
        }
        // Show the other windows of a restored session.
        for pending in windows where !presentedIDs.contains(pending.id) {
            presentedIDs.insert(pending.id)
            presentWindow?(pending.id)
        }
    }

    func windowDidBecomeKey(_ state: WindowState) {
        lastActiveWindow = state
    }

    /// A window closed. Its tabs are discarded unless it was the last window: then the app quits
    /// and the tabs must still be part of the saved session.
    func windowWillClose(_ state: WindowState) {
        presentedIDs.remove(state.id)
        let remaining = windows.filter { $0 !== state && presentedIDs.contains($0.id) }
        guard !remaining.isEmpty else { return }
        state.closeAll()
        windows.removeAll { $0 === state }
        if lastActiveWindow === state { lastActiveWindow = remaining.last }
        sessionManager.scheduleSave()
    }

    /// Creates a new empty window.
    @discardableResult
    func newWindow() -> WindowState {
        let state = makeWindow()
        presentedIDs.insert(state.id)
        presentWindow?(state.id)
        return state
    }

    /// Moves a tab into a new window of its own.
    func moveToNewWindow(_ session: DocumentSession, from source: WindowState) {
        guard source.documents.count > 1, let removed = source.remove(session.id) else { return }
        let destination = newWindow()
        destination.adopt(removed)
    }

    func bringToFront(_ state: WindowState) {
        state.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Session

    func makeSnapshot() -> AppSessionSnapshot {
        let active = lastActiveWindow.flatMap { active in windows.firstIndex { $0 === active } }
        return AppSessionSnapshot(windows: windows.map { $0.makeSnapshot() }, activeWindowIndex: active)
    }

    func restore(from snapshot: AppSessionSnapshot) {
        for windowSnapshot in snapshot.windows {
            let state = makeWindow(id: windowSnapshot.id ?? UUID())
            state.restore(from: windowSnapshot)
        }
        // Drop windows that ended up empty because all their files were open elsewhere.
        if windows.count > 1 {
            windows.removeAll { $0.documents.isEmpty }
        }
        if let index = snapshot.activeWindowIndex, snapshot.windows.indices.contains(index) {
            activeWindowIDAtRestore = snapshot.windows[index].id
        }
    }

    func saveSessionNow() {
        sessionManager.flush()
    }
}
