import AppKit

extension Notification.Name {
    /// Posted on the main actor when a remote image finished downloading. `object` is the URL.
    static let remoteImageDidLoad = Notification.Name("MDViewer.remoteImageDidLoad")
}

/// Loads and caches images referenced by documents.
///
/// Local images are read synchronously (they are small and on disk); remote images are fetched
/// asynchronously and announced via `remoteImageDidLoad` so the reader can update in place.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private struct LocalKey: Hashable {
        let url: URL
        let modificationDate: Date?
    }

    private var localCache: [LocalKey: NSImage] = [:]
    private let remoteCache = NSCache<NSURL, NSImage>()
    private var inFlight: Set<URL> = []
    private var failed: Set<URL> = []

    func localImage(at url: URL) -> NSImage? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        let key = LocalKey(url: url, modificationDate: values?.contentModificationDate)
        if let cached = localCache[key] { return cached }
        guard let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 else { return nil }
        if localCache.count > 200 { localCache.removeAll() }
        localCache[key] = image
        return image
    }

    func cachedRemoteImage(for url: URL) -> NSImage? {
        remoteCache.object(forKey: url as NSURL)
    }

    func hasFailed(_ url: URL) -> Bool {
        failed.contains(url)
    }

    func loadRemoteImage(_ url: URL) {
        guard !inFlight.contains(url), !failed.contains(url), cachedRemoteImage(for: url) == nil else { return }
        guard ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else { return }
        inFlight.insert(url)
        Task {
            defer { inFlight.remove(url) }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                guard let image = NSImage(data: data), image.isValid else { throw URLError(.cannotDecodeContentData) }
                remoteCache.setObject(image, forKey: url as NSURL)
            } catch {
                failed.insert(url)
            }
            NotificationCenter.default.post(name: .remoteImageDidLoad, object: url)
        }
    }
}
