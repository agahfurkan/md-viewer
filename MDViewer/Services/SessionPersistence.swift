import Foundation
import OSLog

/// One window's persisted state: references to open files, never their contents.
struct SessionSnapshot: Codable, Equatable {
    struct DocumentReference: Codable, Equatable {
        var path: String
        var bookmark: Data?
        /// Character index at the top of the reader viewport.
        var scrollPosition: Int?
    }

    /// Version 1 files stored a single window in this shape.
    static let legacyVersion = 1

    var version = SessionSnapshot.legacyVersion
    var id: UUID?
    var documents: [DocumentReference] = []
    /// Index into `documents` of the active tab.
    var activeIndex: Int?
    var isSidebarVisible = true
    /// `NSWindow.frameDescriptor` of the window.
    var frame: String?

    init(id: UUID? = nil, documents: [DocumentReference] = [], activeIndex: Int? = nil, isSidebarVisible: Bool = true, frame: String? = nil) {
        self.id = id
        self.documents = documents
        self.activeIndex = activeIndex
        self.isSidebarVisible = isSidebarVisible
        self.frame = frame
    }

    static let empty = SessionSnapshot()

    mutating func repair() {
        if let index = activeIndex, !documents.indices.contains(index) {
            activeIndex = documents.isEmpty ? nil : 0
        }
    }
}

/// The persisted working session: all windows.
struct AppSessionSnapshot: Codable, Equatable {
    static let currentVersion = 2

    var version = AppSessionSnapshot.currentVersion
    var windows: [SessionSnapshot] = []
    /// Index into `windows` of the frontmost window.
    var activeWindowIndex: Int?

    static let empty = AppSessionSnapshot()
}

/// Reads and writes the session file in Application Support.
///
/// A missing, unreadable or corrupt file never prevents launch: it yields `nil`, and a corrupt
/// file is moved aside for inspection.
struct SessionPersistence {
    let fileURL: URL
    private let logger = Logger(subsystem: "com.local.MDViewer", category: "Session")

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("MD Viewer", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    func load() -> AppSessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            var snapshot: AppSessionSnapshot
            if let current = try? JSONDecoder().decode(AppSessionSnapshot.self, from: data), current.version >= 2 {
                snapshot = current
            } else {
                // Version 1: a single window.
                let legacy = try JSONDecoder().decode(SessionSnapshot.self, from: data)
                snapshot = AppSessionSnapshot(windows: [legacy], activeWindowIndex: 0)
            }
            guard snapshot.version <= AppSessionSnapshot.currentVersion else {
                logger.warning("Ignoring session written by a newer version (\(snapshot.version))")
                return nil
            }
            for index in snapshot.windows.indices {
                snapshot.windows[index].repair()
            }
            if let index = snapshot.activeWindowIndex, !snapshot.windows.indices.contains(index) {
                snapshot.activeWindowIndex = snapshot.windows.isEmpty ? nil : 0
            }
            return snapshot
        } catch {
            logger.error("Session file is corrupt: \(error.localizedDescription, privacy: .public)")
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return nil
        }
    }

    func save(_ snapshot: AppSessionSnapshot) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save session: \(error.localizedDescription, privacy: .public)")
        }
    }
}
