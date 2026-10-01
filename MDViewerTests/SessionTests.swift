import Foundation
import Testing
@testable import MDViewer

@MainActor
struct SessionTests {
    let directory = TemporaryDirectory()

    var persistence: SessionPersistence {
        SessionPersistence(fileURL: directory.url.appendingPathComponent("state/session.json"))
    }

    /// A fresh app model restored from the session file, as at the next launch.
    private func relaunch() -> AppModel {
        let model = makeAppModel(persistence: persistence)
        if let snapshot = model.sessionManager.loadSnapshot() {
            model.restore(from: snapshot)
        }
        return model
    }

    @Test func snapshotRoundTripsThroughJSON() {
        let window = SessionSnapshot(
            id: UUID(),
            documents: [
                .init(path: "/tmp/a.md", bookmark: Data([1, 2, 3]), scrollPosition: 120),
                .init(path: "/tmp/b.md", bookmark: nil, scrollPosition: nil),
            ],
            activeIndex: 1,
            isSidebarVisible: false,
            frame: "100 100 800 600 0 0 1920 1080 "
        )
        let snapshot = AppSessionSnapshot(windows: [window, SessionSnapshot(id: UUID())], activeWindowIndex: 1)
        persistence.save(snapshot)
        #expect(persistence.load() == snapshot)
    }

    @Test func missingSessionFileLoadsNothing() {
        #expect(persistence.load() == nil)
    }

    @Test func corruptSessionFileIsSetAsideAndIgnored() throws {
        let file = persistence.fileURL
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: file)

        #expect(persistence.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("corrupt.json").path))
    }

    @Test func versionOneSessionFilesStillLoad() throws {
        let json = #"{"version":1,"documents":[{"path":"/tmp/a.md"},{"path":"/tmp/b.md"}],"activeIndex":7,"isSidebarVisible":false}"#
        let file = persistence.fileURL
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)
        let snapshot = try #require(persistence.load())
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].documents.map(\.path) == ["/tmp/a.md", "/tmp/b.md"])
        #expect(snapshot.windows[0].activeIndex == 0) // out of range → repaired
        #expect(snapshot.windows[0].isSidebarVisible == false)
    }

    @Test func sessionsFromNewerVersionsAreIgnored() throws {
        let json = #"{"version":99,"windows":[],"activeWindowIndex":null}"#
        let file = persistence.fileURL
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)
        #expect(persistence.load() == nil)
    }

    @Test func snapshotStoresReferencesNotContents() throws {
        let state = makeWindowState(persistence: persistence)
        state.open(directory.write("a.md", "# Secret content"))
        state.app?.saveSessionNow()
        let json = try String(contentsOf: persistence.fileURL, encoding: .utf8)
        #expect(!json.contains("Secret content"))
        #expect(json.contains("a.md"))
    }

    @Test func sessionIsRestoredWithOrderActiveTabAndScroll() async {
        let a = directory.write("a.md", "# A")
        let b = directory.write("b.md", "# B")
        let c = directory.write("c.md", "# C")

        let first = makeWindowState(persistence: persistence)
        let sa = first.open(a)
        let sb = first.open(b)
        first.open(c)
        first.moveTab(sa.id, to: 2)          // b, c, a
        first.activate(sb.id)
        sb.scrollPosition = 42
        first.isSidebarVisible = false
        first.app?.saveSessionNow()

        let second = try! #require(relaunch().windows.first)
        #expect(second.id == first.id)
        #expect(second.documents.map(\.fileURL) == [b, c, a])
        #expect(second.activeDocument?.fileURL == b)
        #expect(second.activeDocument?.scrollPosition == 42)
        #expect(second.isSidebarVisible == false)
        #expect(await waitUntil { second.documents.allSatisfy { $0.state == .ready } })
    }

    @Test func multipleWindowsAreRestoredWithTheirOwnTabs() async {
        let model = makeAppModel(persistence: persistence)
        let left = model.makeWindow()
        let right = model.makeWindow()
        left.open(directory.write("a.md", "# A"))
        left.open(directory.write("b.md", "# B"))
        right.open(directory.write("c.md", "# C"))
        model.saveSessionNow()

        let restored = relaunch()
        #expect(restored.windows.map(\.id) == [left.id, right.id])
        #expect(restored.windows[0].documents.map(\.displayName) == ["a.md", "b.md"])
        #expect(restored.windows[1].documents.map(\.displayName) == ["c.md"])
    }

    @Test func restoringAMissingFileShowsItAsMissing() async throws {
        let a = directory.write("a.md", "# A")
        let b = directory.write("b.md", "# B")
        let first = makeWindowState(persistence: persistence)
        first.open(a)
        first.open(b)
        first.app?.saveSessionNow()

        try FileManager.default.removeItem(at: b)

        let second = try #require(relaunch().windows.first)
        #expect(second.documents.count == 2)
        let missing = second.documents[1]
        #expect(await waitUntil { missing.state == .missing })
        #expect(second.activeDocumentID == missing.id)
        #expect(second.documents[0].state == .ready)
    }

    @Test func restoringFollowsAFileMovedWhileClosed() async throws {
        let original = directory.write("plan.md", "# Plan")
        let first = makeWindowState(persistence: persistence)
        first.open(original)
        first.app?.saveSessionNow()

        let moved = directory.url.appendingPathComponent("archive/plan-v1.md")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)

        let second = try #require(relaunch().windows.first)
        #expect(second.documents.first?.fileURL == FileIdentity.canonicalURL(moved))
        #expect(await waitUntil { second.documents.first?.state == .ready })
    }

    @Test func pathWinsOverBookmarkWhenFileWasReplaced() throws {
        // Tools often "save" by moving the old file aside and writing a new one.
        let original = directory.write("plan.md", "# Old")
        let bookmark = SecurityScopedBookmarkManager.makeBookmark(for: original)
        try FileManager.default.moveItem(at: original, to: directory.url.appendingPathComponent("plan.md.bak"))
        directory.write("plan.md", "# New")

        let restored = SecurityScopedBookmarkManager.restoreURL(path: original.path, bookmark: bookmark)
        #expect(restored.url.path == original.path)
    }

    @Test func sessionSavesAreCoalesced() async {
        let state = makeWindowState(persistence: persistence)
        state.open(directory.write("a.md", "a"))
        state.open(directory.write("b.md", "b"))
        #expect(await waitUntil { persistence.load()?.windows.first?.documents.count == 2 })
        #expect(persistence.load()?.windows.first?.activeIndex == 1)
    }
}

@MainActor
struct RecentFilesTests {
    let directory = TemporaryDirectory()
    let defaults = UserDefaults(suiteName: "RecentFilesTests-\(UUID().uuidString)")!

    @Test func mostRecentFirstWithoutDuplicates() {
        let recent = RecentFilesManager(defaults: defaults)
        let a = directory.write("a.md", "a")
        let b = directory.write("b.md", "b")
        recent.noteOpened(a)
        recent.noteOpened(b)
        recent.noteOpened(a)
        #expect(recent.entries.map(\.path) == [a.path, b.path])
    }

    @Test func limitedToMaximumCount() {
        let recent = RecentFilesManager(defaults: defaults, maximumCount: 3)
        for index in 0..<5 {
            recent.noteOpened(directory.write("\(index).md", ""))
        }
        #expect(recent.entries.map(\.displayName) == ["4.md", "3.md", "2.md"])
    }

    @Test func persistsAcrossInstances() {
        let a = directory.write("a.md", "a")
        RecentFilesManager(defaults: defaults).noteOpened(a)
        #expect(RecentFilesManager(defaults: defaults).entries.map(\.path) == [a.path])
    }

    @Test func pruneRemovesMissingFiles() throws {
        let recent = RecentFilesManager(defaults: defaults)
        let a = directory.write("a.md", "a")
        let b = directory.write("b.md", "b")
        recent.noteOpened(a)
        recent.noteOpened(b)
        try FileManager.default.removeItem(at: a)
        recent.pruneMissing()
        #expect(recent.entries.map(\.path) == [b.path])
    }

    @Test func clearEmptiesTheList() {
        let recent = RecentFilesManager(defaults: defaults)
        recent.noteOpened(directory.write("a.md", "a"))
        recent.clear()
        #expect(recent.entries.isEmpty)
        #expect(RecentFilesManager(defaults: defaults).entries.isEmpty)
    }

    @Test func corruptStoredDataIsIgnored() {
        defaults.set(Data("garbage".utf8), forKey: RecentFilesManager.defaultsKey)
        #expect(RecentFilesManager(defaults: defaults).entries.isEmpty)
    }
}

@MainActor
struct FolderAccessTests {
    let directory = TemporaryDirectory()

    @Test func inactiveOutsideTheSandbox() {
        let manager = FolderAccessManager(defaults: UserDefaults(suiteName: "FolderAccess-\(UUID().uuidString)")!, isSandboxed: false)
        #expect(!manager.needsAccess(for: directory.write("a.md", "x")))
    }

    @Test func grantsPersistAndCoverSubfolders() {
        let defaults = UserDefaults(suiteName: "FolderAccess-\(UUID().uuidString)")!
        let manager = FolderAccessManager(defaults: defaults, isSandboxed: true)
        manager.grant(directory.url)
        #expect(manager.isCovered(directory.url.appendingPathComponent("docs/images")))
        #expect(!manager.isCovered(directory.url.deletingLastPathComponent()))

        let relaunched = FolderAccessManager(defaults: defaults, isSandboxed: true)
        #expect(relaunched.grantedFolders.map(\.path) == [directory.url.standardizedFileURL.path])
        #expect(!relaunched.needsAccess(for: directory.write("a.md", "x")))
        relaunched.revokeAll()
        #expect(FolderAccessManager(defaults: defaults, isSandboxed: true).grantedFolders.isEmpty)
    }

    @Test func grantsForDeletedFoldersAreDropped() throws {
        let defaults = UserDefaults(suiteName: "FolderAccess-\(UUID().uuidString)")!
        let folder = directory.url.appendingPathComponent("gone")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FolderAccessManager(defaults: defaults, isSandboxed: true).grant(folder)
        try FileManager.default.removeItem(at: folder)
        #expect(FolderAccessManager(defaults: defaults, isSandboxed: true).grantedFolders.isEmpty)
    }
}
