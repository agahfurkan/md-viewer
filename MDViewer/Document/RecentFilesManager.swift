import Foundation
import Observation

/// Maintains File → Open Recent.
///
/// Stored in UserDefaults as paths plus bookmarks; the most recently opened file comes first and
/// each file appears once.
@MainActor
@Observable
final class RecentFilesManager {
    struct Entry: Codable, Equatable, Identifiable {
        var path: String
        var bookmark: Data?

        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
        var displayName: String { url.lastPathComponent }
    }

    static let defaultsKey = "recentFiles"

    private(set) var entries: [Entry] = []
    let maximumCount: Int
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, maximumCount: Int = 20) {
        self.defaults = defaults
        self.maximumCount = maximumCount
        load()
    }

    func noteOpened(_ url: URL) {
        let canonical = FileIdentity.canonicalURL(url)
        entries.removeAll { $0.path == canonical.path }
        entries.insert(Entry(path: canonical.path, bookmark: SecurityScopedBookmarkManager.makeBookmark(for: canonical)), at: 0)
        if entries.count > maximumCount {
            entries.removeLast(entries.count - maximumCount)
        }
        save()
    }

    /// Removes entries whose files clearly no longer exist.
    func pruneMissing() {
        let before = entries.count
        entries.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if entries.count != before { save() }
    }

    func remove(_ url: URL) {
        let path = FileIdentity.canonicalURL(url).path
        entries.removeAll { $0.path == path }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// The URL to open for an entry, following the bookmark if the file was moved.
    func resolvedURL(for entry: Entry) -> URL {
        SecurityScopedBookmarkManager.restoreURL(path: entry.path, bookmark: entry.bookmark).url
    }

    // MARK: Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([Entry].self, from: data)
            var seen = Set<String>()
            entries = decoded.filter { seen.insert($0.path).inserted }.prefix(maximumCount).map { $0 }
        } catch {
            // Corrupt data: start over rather than failing.
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
