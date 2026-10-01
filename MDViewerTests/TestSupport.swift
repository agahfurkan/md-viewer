import Foundation
@testable import MDViewer

/// A temporary directory removed when the value is deinitialized.
final class TemporaryDirectory {
    let url: URL

    init() {
        // Resolve symlinks (/var → /private/var) so paths compare equal to canonical URLs.
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDViewerTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = url.resolvingSymlinksInPath()
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ name: String, _ contents: String) -> URL {
        let file = url.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(contents.utf8).write(to: file)
        return FileIdentity.canonicalURL(file)
    }

    func path(_ name: String) -> URL {
        FileIdentity.canonicalURL(url.appendingPathComponent(name))
    }
}

/// Polls `condition` on the main actor until it is true or the timeout elapses.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Keeps test app models alive (window states only hold them weakly).
@MainActor
private var retainedModels: [AppModel] = []

@MainActor
func makeAppModel(persistence: SessionPersistence? = nil, defaults: UserDefaults? = nil, watchesFiles: Bool = false) -> AppModel {
    let suite = defaults ?? UserDefaults(suiteName: "MDViewerTests-\(UUID().uuidString)")!
    let model = AppModel(
        documentManager: DocumentManager(watchDebounce: .milliseconds(40), watchesFiles: watchesFiles),
        recentFiles: RecentFilesManager(defaults: suite),
        sessionManager: SessionManager(persistence: persistence, saveDelay: .milliseconds(10))
    )
    retainedModels.append(model)
    return model
}

/// A window state inside its own app model.
@MainActor
func makeWindowState(persistence: SessionPersistence? = nil, defaults: UserDefaults? = nil, watchesFiles: Bool = false) -> WindowState {
    let state = makeAppModel(persistence: persistence, defaults: defaults, watchesFiles: watchesFiles).makeWindow()
    state.openExternally = { _ in }
    return state
}
