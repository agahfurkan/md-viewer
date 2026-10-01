import Foundation

/// Decides when the session is written to disk.
///
/// Changes such as opening, closing, reordering or switching tabs schedule a save that is
/// coalesced over a short delay; termination flushes immediately.
@MainActor
final class SessionManager {
    private let persistence: SessionPersistence?
    private let saveDelay: Duration
    private var pendingSave: Task<Void, Never>?
    private var lastSaved: AppSessionSnapshot?
    var snapshotProvider: (() -> AppSessionSnapshot)?

    /// - Parameter persistence: `nil` disables persistence entirely (used when hosting tests).
    init(persistence: SessionPersistence?, saveDelay: Duration = .milliseconds(600)) {
        self.persistence = persistence
        self.saveDelay = saveDelay
    }

    func loadSnapshot() -> AppSessionSnapshot? {
        let snapshot = persistence?.load()
        lastSaved = snapshot
        return snapshot
    }

    func scheduleSave() {
        guard persistence != nil else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let persistence, let snapshot = snapshotProvider?() else { return }
        guard snapshot != lastSaved else { return }
        persistence.save(snapshot)
        lastSaved = snapshot
    }
}
