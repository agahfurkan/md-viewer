import Foundation

/// Reads Markdown files from disk and decodes them to text.
///
/// Pure and synchronous; callers run it off the main actor.
enum FileLoader {
    struct LoadedFile: Equatable, Sendable {
        let text: String
        let modificationDate: Date?
    }

    enum LoadError: Error, Equatable, Sendable {
        case missing
        case permissionDenied
        case isDirectory
        case unsupportedEncoding
        case tooLarge
        case unreadable(String)

        var message: String {
            switch self {
            case .missing: "The file no longer exists."
            case .permissionDenied: "You don't have permission to read this file."
            case .isDirectory: "This is a folder, not a Markdown file."
            case .unsupportedEncoding: "The file's text encoding is not supported."
            case .tooLarge: "The file is too large to display."
            case .unreadable(let reason): reason
            }
        }
    }

    /// Files larger than this are refused to keep the app responsive.
    static let maximumFileSize = 64 * 1024 * 1024

    static func load(_ url: URL) -> Result<LoadedFile, LoadError> {
        let path = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .failure(.missing)
        }
        if isDirectory.boolValue {
            return .failure(.isDirectory)
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            return .failure(.permissionDenied)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        if let size = attributes?[.size] as? Int, size > maximumFileSize {
            return .failure(.tooLarge)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as CocoaError {
            switch error.code {
            case .fileReadNoSuchFile: return .failure(.missing)
            case .fileReadNoPermission: return .failure(.permissionDenied)
            default: return .failure(.unreadable(error.localizedDescription))
            }
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }

        guard let text = decode(data) else {
            return .failure(.unsupportedEncoding)
        }
        return .success(LoadedFile(text: text, modificationDate: attributes?[.modificationDate] as? Date))
    }

    /// Decodes file contents, preferring UTF-8 and honouring byte order marks.
    static func decode(_ data: Data) -> String? {
        if data.isEmpty { return "" }

        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        // Binary content (NUL bytes) is not text in any encoding we want to show.
        if data.contains(0) {
            return nil
        }
        var converted: NSString?
        var usedLossy: ObjCBool = false
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [String.Encoding.windowsCP1252.rawValue, String.Encoding.isoLatin1.rawValue, String.Encoding.macOSRoman.rawValue],
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: &usedLossy
        )
        if encoding != 0, let converted, !usedLossy.boolValue {
            return converted as String
        }
        return nil
    }
}
