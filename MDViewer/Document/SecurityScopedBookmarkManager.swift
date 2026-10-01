import Foundation

/// Creates and resolves file bookmarks.
///
/// The app is not sandboxed (a Markdown viewer must read images and linked files next to the
/// document), so bookmarks are not strictly required for access. They are still stored because
/// they let restoration follow files that were renamed or moved while the app was closed, and
/// because they keep working unchanged if the App Sandbox is ever enabled: security-scoped
/// bookmarks are attempted first, with a plain bookmark as fallback.
enum SecurityScopedBookmarkManager {
    struct Resolution {
        let url: URL
        let isStale: Bool
    }

    static func makeBookmark(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data) -> Resolution? {
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return Resolution(url: url, isStale: isStale)
        }
        isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return Resolution(url: url, isStale: isStale)
        }
        return nil
    }

    /// Chooses the URL to reopen for a stored file reference.
    ///
    /// The stored path wins when a file still exists there (tools often replace files, which
    /// changes their identity but not their path). Otherwise the bookmark is used to find a file
    /// that was moved — unless it now lives in the Trash, which counts as deleted.
    static func restoreURL(path: String, bookmark: Data?) -> (url: URL, refreshedBookmark: Data?) {
        let pathURL = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            return (pathURL, nil)
        }
        if let bookmark, let resolution = resolve(bookmark),
           !FileWatcher.isInTrash(resolution.url.path),
           FileManager.default.fileExists(atPath: resolution.url.path) {
            let url = resolution.url.standardizedFileURL
            return (url, makeBookmark(for: url))
        }
        return (pathURL, nil)
    }

    // MARK: Scoped access

    /// Starts security-scoped access if the URL carries a scope. Harmless otherwise.
    @discardableResult
    static func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    static func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Helpers for identifying files so the same document is never opened twice.
enum FileIdentity {
    /// A normalized file URL: absolute, standardized, symlinks resolved.
    static func canonicalURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Whether two URLs refer to the same file on disk. Handles case-insensitive volumes and
    /// hard links by comparing file resource identifiers when both files exist.
    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = canonicalURL(lhs)
        let right = canonicalURL(rhs)
        if left.path == right.path { return true }
        guard let leftID = resourceIdentifier(left), let rightID = resourceIdentifier(right) else {
            return false
        }
        return leftID.isEqual(rightID)
    }

    private static func resourceIdentifier(_ url: URL) -> NSObjectProtocol? {
        // A fresh URL avoids stale cached resource values.
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObjectProtocol
    }
}
