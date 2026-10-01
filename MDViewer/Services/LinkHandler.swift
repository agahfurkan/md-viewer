import Foundation

/// What a Markdown link destination points at, relative to the document containing it.
enum LinkTarget: Equatable {
    /// `http`, `https`, `mailto`, or any other URL scheme: handed to the system.
    case external(URL)
    /// A Markdown (or plain-text) file that should open in a tab, optionally scrolled to a heading.
    case markdownFile(URL, fragment: String?)
    /// Any other local file or folder: opened with the default application.
    case localFile(URL)
    /// `#heading` inside the current document.
    case anchor(String)
    case invalid
}

/// Resolves link and image destinations. Pure functions so they can be unit tested.
enum LinkResolver {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "markdn", "mdx"]
    /// Plain-text files are shown as Markdown too (most notes are Markdown-ish).
    static let plainTextExtensions: Set<String> = ["txt", "text"]
    static let documentExtensions = markdownExtensions.union(plainTextExtensions)

    static func isMarkdownFile(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether the app opens this file in a tab (Markdown or plain text).
    static func isSupportedDocument(_ url: URL) -> Bool {
        documentExtensions.contains(url.pathExtension.lowercased())
    }

    static func resolve(_ rawDestination: String, relativeTo documentURL: URL) -> LinkTarget {
        let destination = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return .invalid }

        if destination.hasPrefix("#") {
            let fragment = String(destination.dropFirst())
            return .anchor(fragment.removingPercentEncoding ?? fragment)
        }

        if let scheme = scheme(of: destination) {
            if scheme == "file", let url = URL(string: destination) {
                return classifyLocal(url.standardizedFileURL, fragment: url.fragment)
            }
            if let url = URL(string: destination) ?? URL(string: destination.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") {
                return .external(url)
            }
            return .invalid
        }

        let (path, fragment) = splitFragment(destination)
        if path.isEmpty {
            // "?query#frag" or similar: treat as an in-document anchor when a fragment exists.
            return fragment.map { .anchor($0) } ?? .invalid
        }
        guard let fileURL = localURL(forPath: path, relativeTo: documentURL) else { return .invalid }
        return classifyLocal(fileURL, fragment: fragment)
    }

    /// Resolves an image `src`. Returns a file URL for local images or a remote URL.
    static func resourceURL(_ rawSource: String, relativeTo documentURL: URL?) -> URL? {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        if let scheme = scheme(of: source) {
            if scheme == "data" { return URL(string: source) }
            return URL(string: source) ?? URL(string: source.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        }
        guard let documentURL else { return nil }
        let (path, _) = splitFragment(source)
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return localURL(forPath: withoutQuery, relativeTo: documentURL)
    }

    // MARK: Helpers

    private static func scheme(of destination: String) -> String? {
        guard let colon = destination.firstIndex(of: ":") else { return nil }
        let candidate = destination[..<colon]
        // Single letters would be Windows drive letters; schemes must start with a letter.
        guard candidate.count > 1,
              let first = candidate.first, first.isLetter,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        return candidate.lowercased()
    }

    private static func splitFragment(_ destination: String) -> (path: String, fragment: String?) {
        guard let hash = destination.firstIndex(of: "#") else { return (destination, nil) }
        let path = String(destination[..<hash])
        let fragment = String(destination[destination.index(after: hash)...])
        return (path, fragment.isEmpty ? nil : (fragment.removingPercentEncoding ?? fragment))
    }

    private static func localURL(forPath rawPath: String, relativeTo documentURL: URL) -> URL? {
        let path = rawPath.removingPercentEncoding ?? rawPath
        guard !path.isEmpty else { return nil }
        let directory = documentURL.deletingLastPathComponent()

        if path.hasPrefix("~/") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        }
        if path.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: path).standardizedFileURL
            if FileManager.default.fileExists(atPath: absolute.path) {
                return absolute
            }
            // GitHub treats leading-slash links as repository-root relative.
            if let root = repositoryRoot(containing: directory) {
                let candidate = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return absolute
        }
        return directory.appendingPathComponent(path).standardizedFileURL
    }

    private static func classifyLocal(_ url: URL, fragment: String?) -> LinkTarget {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // Linking to a folder: prefer its README like GitHub does.
            for name in ["README.md", "readme.md", "Readme.md", "index.md"] {
                let readme = url.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: readme.path) {
                    return .markdownFile(readme, fragment: fragment)
                }
            }
            return .localFile(url)
        }
        return isSupportedDocument(url) ? .markdownFile(url, fragment: fragment) : .localFile(url)
    }

    static func repositoryRoot(containing directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }
}
