import Foundation

/// Watches a single file for changes using kqueue-backed dispatch sources (no polling).
///
/// Handles the ways tools actually write files:
/// - in-place writes (`write`, `extend`)
/// - atomic saves that replace the file (`delete`/`rename` of the old inode, new file at the path)
/// - the file being renamed or moved (followed via `F_GETPATH`)
/// - the file being deleted and later re-created (the parent directory is watched meanwhile)
///
/// Bursts of events are debounced so an editor or agent writing a file several times in quick
/// succession produces a single notification.
final class FileWatcher: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        /// The file's contents may have changed (or it reappeared after being missing).
        case changed
        /// The file no longer exists at its path.
        case deleted
        /// The file was renamed or moved; the watcher now follows the new location.
        case moved(URL)
    }

    typealias Handler = @MainActor @Sendable (Event) -> Void

    // All mutable state is confined to `queue`.
    private let queue: DispatchQueue
    private let debounce: DispatchTimeInterval
    private let handler: Handler
    private var url: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingEvaluation: DispatchWorkItem?
    /// Set when the watched inode was deleted or renamed; the next evaluation decides what happened.
    private var fileWasDisturbed = false
    private var movedToPath: String?
    private var isStopped = false
    /// Whether the last event reported was `.deleted`, so reappearance is reported as `.changed`.
    private var reportedMissing = false

    init(url: URL, debounce: DispatchTimeInterval = .milliseconds(150), handler: @escaping Handler) {
        self.url = url
        self.debounce = debounce
        self.handler = handler
        self.queue = DispatchQueue(label: "MDViewer.FileWatcher", qos: .utility)
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }

    func start() {
        queue.async { [self] in
            isStopped = false
            if !armFile() {
                reportedMissing = true
                armDirectory()
            }
        }
    }

    func stop() {
        queue.sync {
            isStopped = true
            pendingEvaluation?.cancel()
            pendingEvaluation = nil
            fileSource?.cancel()
            fileSource = nil
            directorySource?.cancel()
            directorySource = nil
        }
    }

    /// Point the watcher at a different file (e.g. after the user relocated a missing file).
    func retarget(to newURL: URL) {
        queue.async { [self] in
            fileSource?.cancel()
            fileSource = nil
            directorySource?.cancel()
            directorySource = nil
            url = newURL
            fileWasDisturbed = false
            movedToPath = nil
            if !armFile() {
                reportedMissing = true
                armDirectory()
            } else {
                reportedMissing = false
            }
        }
    }

    // MARK: - Sources (on `queue`)

    @discardableResult
    private func armFile() -> Bool {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib, .link],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.handleFileEvent(source.data, descriptor: descriptor)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        fileSource = source
        source.resume()
        return true
    }

    private func armDirectory() {
        guard directorySource == nil else { return }
        let directory = url.deletingLastPathComponent().path
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .link, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleEvaluation()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        directorySource = source
        source.resume()
    }

    private func handleFileEvent(_ flags: DispatchSource.FileSystemEvent, descriptor: Int32) {
        if flags.contains(.rename) {
            movedToPath = Self.currentPath(of: descriptor)
        }
        if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
            // The inode we watch is gone or elsewhere; stop watching it and decide after the
            // debounce interval what actually happened (atomic save, move, or deletion).
            fileWasDisturbed = true
            fileSource?.cancel()
            fileSource = nil
        }
        scheduleEvaluation()
    }

    private func scheduleEvaluation() {
        pendingEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.evaluate()
        }
        pendingEvaluation = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func evaluate() {
        pendingEvaluation = nil
        guard !isStopped else { return }

        let existsAtPath = FileManager.default.fileExists(atPath: url.path)

        if !fileWasDisturbed, fileSource != nil {
            // Plain write to the same inode.
            deliver(.changed)
            return
        }

        fileWasDisturbed = false
        let movedPath = movedToPath
        movedToPath = nil

        if existsAtPath {
            // Atomic save (new file at the same path) or the file reappeared.
            directorySource?.cancel()
            directorySource = nil
            if fileSource == nil { armFile() }
            reportedMissing = false
            deliver(.changed)
            return
        }

        if let movedPath, movedPath != url.path, !Self.isInTrash(movedPath), FileManager.default.fileExists(atPath: movedPath) {
            url = URL(fileURLWithPath: movedPath)
            directorySource?.cancel()
            directorySource = nil
            armFile()
            reportedMissing = false
            deliver(.moved(url))
            return
        }

        armDirectory()
        if !reportedMissing {
            reportedMissing = true
            deliver(.deleted)
        }
    }

    private func deliver(_ event: Event) {
        let handler = handler
        Task { @MainActor in
            handler(event)
        }
    }

    // MARK: - Helpers

    private static func currentPath(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }
}
