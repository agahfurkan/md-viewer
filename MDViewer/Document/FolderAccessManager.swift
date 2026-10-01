import AppKit
import Observation

/// Folder access for relative images and links when the app runs in the App Sandbox.
///
/// The shipped app is not sandboxed, so this stays inactive there. In a sandboxed build, opening
/// a file grants access to that file only; images and linked documents next to it need access to
/// the folder. The user grants it once per folder, and the grant is kept as a security-scoped
/// bookmark and re-activated at every launch.
@MainActor
@Observable
final class FolderAccessManager {
    static let shared = FolderAccessManager()
    static let defaultsKey = "folderAccessBookmarks"

    /// Folders the app currently has access to through a grant.
    private(set) var grantedFolders: [URL] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let isSandboxed: Bool

    init(defaults: UserDefaults = .standard, isSandboxed: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil) {
        self.defaults = defaults
        self.isSandboxed = isSandboxed
        restoreGrants()
    }

    /// Whether to offer the user a folder grant for a document.
    func needsAccess(for documentURL: URL) -> Bool {
        guard isSandboxed else { return false }
        let folder = documentURL.deletingLastPathComponent().standardizedFileURL
        if isCovered(folder) { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil
    }

    func isCovered(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        return grantedFolders.contains { path == $0.path || path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
    }

    /// Records a folder the user granted (from an open panel) and starts using it.
    func grant(_ folder: URL) {
        let bookmark = (try? folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        guard let bookmark else { return }
        var stored = storedBookmarks
        stored.append(bookmark)
        defaults.set(stored, forKey: Self.defaultsKey)
        _ = folder.startAccessingSecurityScopedResource()
        if !grantedFolders.contains(folder.standardizedFileURL) {
            grantedFolders.append(folder.standardizedFileURL)
        }
    }

    func revokeAll() {
        for folder in grantedFolders { folder.stopAccessingSecurityScopedResource() }
        grantedFolders.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    /// Asks the user to grant access to a document's folder.
    func requestAccess(for documentURL: URL) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = documentURL.deletingLastPathComponent()
        panel.prompt = "Grant Access"
        panel.message = "Allow MD Viewer to show images and follow links in this folder."
        guard panel.runModal() == .OK, let folder = panel.url else { return false }
        grant(folder)
        return true
    }

    // MARK: - Persistence

    private var storedBookmarks: [Data] {
        defaults.array(forKey: Self.defaultsKey) as? [Data] ?? []
    }

    private func restoreGrants() {
        var kept: [Data] = []
        for bookmark in storedBookmarks {
            var isStale = false
            let url = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale))
                ?? (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale))
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            grantedFolders.append(url.standardizedFileURL)
            if isStale, let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
                kept.append(fresh)
            } else {
                kept.append(bookmark)
            }
        }
        if kept.count != storedBookmarks.count || kept != storedBookmarks {
            defaults.set(kept, forKey: Self.defaultsKey)
        }
    }
}
