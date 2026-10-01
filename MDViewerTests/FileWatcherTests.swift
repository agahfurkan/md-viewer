import Foundation
import Testing
@testable import MDViewer

/// Collects watcher events on the main actor.
@MainActor
final class EventRecorder {
    var events: [FileWatcher.Event] = []
}

@MainActor
@Suite(.serialized)
struct FileWatcherTests {
    let directory = TemporaryDirectory()

    private func makeWatcher(for url: URL, recorder: EventRecorder) -> FileWatcher {
        let watcher = FileWatcher(url: url, debounce: .milliseconds(80)) { event in
            recorder.events.append(event)
        }
        watcher.start()
        return watcher
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test func inPlaceWriteIsReported() async throws {
        let url = directory.write("a.md", "one")
        let recorder = EventRecorder()
        let watcher = makeWatcher(for: url, recorder: recorder)
        defer { watcher.stop() }
        await settle()

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" two".utf8))
        try handle.close()

        #expect(await waitUntil { recorder.events == [.changed] })
    }

    @Test func rapidWritesAreDebounced() async throws {
        let url = directory.write("a.md", "start")
        let recorder = EventRecorder()
        let watcher = makeWatcher(for: url, recorder: recorder)
        defer { watcher.stop() }
        await settle()

        for index in 0..<10 {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(index)".utf8))
            try handle.close()
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(await waitUntil { !recorder.events.isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.events == [.changed])
    }

    @Test func atomicReplaceIsReportedAsChange() async throws {
        let url = directory.write("a.md", "old")
        let recorder = EventRecorder()
        let watcher = makeWatcher(for: url, recorder: recorder)
        defer { watcher.stop() }
        await settle()

        try Data("new".utf8).write(to: url, options: .atomic)
        #expect(await waitUntil { recorder.events == [.changed] })

        // The watcher re-armed on the new file: further writes are still seen.
        recorder.events.removeAll()
        try Data("newer".utf8).write(to: url, options: .atomic)
        #expect(await waitUntil { recorder.events == [.changed] })
    }

    @Test func deletionIsReported() async throws {
        let url = directory.write("a.md", "bye")
        let recorder = EventRecorder()
        let watcher = makeWatcher(for: url, recorder: recorder)
        defer { watcher.stop() }
        await settle()

        try FileManager.default.removeItem(at: url)
        #expect(await waitUntil { recorder.events == [.deleted] })
    }

    @Test func recreationAfterDeletionIsReported() async throws {
        let url = directory.write("a.md", "bye")
        let recorder = EventRecorder()
        let watcher = makeWatcher(for: url, recorder: recorder)
        defer { watcher.stop() }
        await settle()

        try FileManager.default.removeItem(at: url)
        #expect(await waitUntil { recorder.events == [.deleted] })
        directory.write("a.md", "hello again")
        #expect(await waitUntil { recorder.events == [.deleted, .changed] })
    }

    @Test func renameIsFollowed() async throws {
        let url = directory.write("a.md", "content")
        let destination = directory.url.appendingPathComponent("renamed.md")
        let recorder = EventRecorder()
        let watcher = makeWatcher(for: url, recorder: recorder)
        defer { watcher.stop() }
        await settle()

        try FileManager.default.moveItem(at: url, to: destination)
        #expect(await waitUntil { recorder.events.count == 1 })
        guard case .moved(let newURL) = recorder.events.first else {
            Issue.record("Expected move, got \(recorder.events)")
            return
        }
        #expect(FileIdentity.isSameFile(newURL, destination))
    }

    @Test func watchingAMissingFileReportsItsCreation() async throws {
        let url = directory.path("later.md")
        let recorder = EventRecorder()
        let watcher = makeWatcher(for: url, recorder: recorder)
        defer { watcher.stop() }
        await settle()

        directory.write("later.md", "# Here")
        #expect(await waitUntil { recorder.events == [.changed] })
    }
}

@MainActor
@Suite(.serialized)
struct DocumentManagerTests {
    let directory = TemporaryDirectory()

    @Test func externalChangesUpdateTheParsedDocument() async throws {
        let state = makeWindowState(watchesFiles: true)
        let url = directory.write("PLAN.md", "# Plan\n\n- step one")
        let session = state.open(url)
        #expect(await waitUntil { session.model?.outline.map(\.title) == ["Plan"] })
        let version = session.contentVersion

        // An agent rewrites the file.
        try Data("# Plan\n\n## Phase 2\n\n- step two".utf8).write(to: url, options: .atomic)

        #expect(await waitUntil { session.model?.outline.map(\.title) == ["Plan", "Phase 2"] })
        #expect(session.contentVersion == version + 1)
        #expect(session.state == .ready)
    }

    @Test func unchangedContentDoesNotReparse() async throws {
        let url = directory.write("a.md", "# Same")
        let manager = DocumentManager(watchesFiles: false)
        let session = DocumentSession(fileURL: url)
        await manager.reload(session)
        let version = session.contentVersion
        #expect(version == 1)

        // Touch the file without changing its text.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        await manager.reload(session)
        #expect(session.contentVersion == version)
    }

    @Test func deletedFileBecomesMissingAndRecovers() async throws {
        let state = makeWindowState(watchesFiles: true)
        let url = directory.write("a.md", "# A")
        let session = state.open(url)
        #expect(await waitUntil { session.state == .ready })

        try FileManager.default.removeItem(at: url)
        #expect(await waitUntil { session.state == .missing })
        // The last good content is kept.
        #expect(session.model != nil)

        directory.write("a.md", "# A again")
        #expect(await waitUntil { session.state == .ready && session.model?.outline.first?.title == "A again" })
    }

    @Test func renamedFileIsFollowed() async throws {
        let state = makeWindowState(watchesFiles: true)
        let url = directory.write("a.md", "# A")
        let session = state.open(url)
        #expect(await waitUntil { session.state == .ready })

        let destination = directory.url.appendingPathComponent("b.md")
        try FileManager.default.moveItem(at: url, to: destination)
        #expect(await waitUntil { session.fileURL.lastPathComponent == "b.md" })
        #expect(session.state == .ready)
    }

    @Test func unreadableFileIsAnError() async throws {
        let url = directory.write("a.md", "# A")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let session = DocumentSession(fileURL: url)
        await DocumentManager(watchesFiles: false).reload(session)
        #expect(session.state == .error(FileLoader.LoadError.permissionDenied.message))
    }

    @Test func externalChangeWhileEditingIsNotSilentlyApplied() async throws {
        let state = makeWindowState(watchesFiles: false)
        let url = directory.write("a.md", "# A")
        let session = state.open(url)
        #expect(await waitUntil { session.state == .ready })

        state.startEditing(session)
        session.editor?.userEdited("# A\n\nmy local edit")
        try Data("# A\n\nchanged elsewhere".utf8).write(to: url, options: .atomic)
        await state.documentManager.reload(session)

        #expect(session.editor?.text == "# A\n\nmy local edit")
        #expect(session.editor?.hasExternalChange == true)
    }

    @Test func externalChangeWithoutLocalEditsUpdatesTheEditor() async throws {
        let state = makeWindowState(watchesFiles: false)
        let url = directory.write("a.md", "# A")
        let session = state.open(url)
        #expect(await waitUntil { session.state == .ready })

        state.startEditing(session)
        try Data("# B".utf8).write(to: url, options: .atomic)
        await state.documentManager.reload(session)

        #expect(session.editor?.text == "# B")
        #expect(session.editor?.isDirty == false)
    }

    @Test func savingWritesTheFileAndUpdatesTheReader() async throws {
        let state = makeWindowState(watchesFiles: false)
        let url = directory.write("a.md", "# A")
        let session = state.open(url)
        #expect(await waitUntil { session.state == .ready })

        state.startEditing(session)
        session.editor?.userEdited("# Saved")
        #expect(session.hasUnsavedChanges)
        state.save(session)

        #expect(!session.hasUnsavedChanges)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Saved")
        #expect(session.model?.outline.first?.title == "Saved")
    }
}
