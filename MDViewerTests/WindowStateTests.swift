import Foundation
import Testing
@testable import MDViewer

@MainActor
struct WindowStateTests {
    let directory = TemporaryDirectory()

    @Test func openingFilesCreatesTabsAndActivatesTheNewest() async {
        let state = makeWindowState()
        let a = directory.write("a.md", "# A")
        let b = directory.write("b.md", "# B")

        let first = state.open(a)
        let second = state.open(b)

        #expect(state.documents.map(\.id) == [first.id, second.id])
        #expect(state.activeDocumentID == second.id)
        #expect(await waitUntil { second.state == .ready && second.model?.outline.first?.title == "B" })
    }

    @Test func openingAnAlreadyOpenFileActivatesItsTab() {
        let state = makeWindowState()
        let a = directory.write("a.md", "# A")
        let b = directory.write("b.md", "# B")

        let first = state.open(a)
        state.open(b)
        let again = state.open(a)

        #expect(again.id == first.id)
        #expect(state.documents.count == 2)
        #expect(state.activeDocumentID == first.id)
    }

    @Test func duplicateDetectionSeesThroughPathSpellings() throws {
        let state = makeWindowState()
        let a = directory.write("a.md", "# A")
        state.open(a)

        // Relative components and symlinks point at the same file.
        state.open(directory.url.appendingPathComponent("sub/../a.md"))
        let link = directory.url.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        state.open(link)

        #expect(state.documents.count == 1)
    }

    @Test func duplicateDetectionOnCaseInsensitiveVolumes() throws {
        let a = directory.write("README.md", "# A")
        let lower = directory.url.appendingPathComponent("readme.md")
        guard FileManager.default.fileExists(atPath: lower.path) else { return } // case-sensitive volume

        let state = makeWindowState()
        state.open(a)
        state.open(lower)
        #expect(state.documents.count == 1)
    }

    @Test func newTabsOpenToTheRightOfTheActiveTab() {
        let state = makeWindowState()
        let a = state.open(directory.write("a.md", "a"))
        let b = state.open(directory.write("b.md", "b"))
        state.activate(a.id)
        let c = state.open(directory.write("c.md", "c"))
        #expect(state.documents.map(\.id) == [a.id, c.id, b.id])
    }

    @Test func closingTheActiveTabActivatesItsNeighbour() {
        let state = makeWindowState()
        let a = state.open(directory.write("a.md", "a"))
        let b = state.open(directory.write("b.md", "b"))
        let c = state.open(directory.write("c.md", "c"))

        state.activate(b.id)
        state.close(b.id)
        #expect(state.documents.map(\.id) == [a.id, c.id])
        #expect(state.activeDocumentID == c.id)

        state.close(c.id)
        #expect(state.activeDocumentID == a.id)

        state.close(a.id)
        #expect(state.activeDocumentID == nil)
        #expect(state.documents.isEmpty)
    }

    @Test func closingAnInactiveTabKeepsTheActiveOne() {
        let state = makeWindowState()
        let a = state.open(directory.write("a.md", "a"))
        let b = state.open(directory.write("b.md", "b"))
        state.close(a.id)
        #expect(state.activeDocumentID == b.id)
    }

    @Test func closeOthersAndCloseToTheRight() {
        let state = makeWindowState()
        let a = state.open(directory.write("a.md", "a"))
        let b = state.open(directory.write("b.md", "b"))
        let c = state.open(directory.write("c.md", "c"))
        state.open(directory.write("d.md", "d"))

        state.closeTabsToRight(of: b.id)
        #expect(state.documents.map(\.id) == [a.id, b.id])

        state.closeOthers(keeping: a.id)
        #expect(state.documents.map(\.id) == [a.id])
        #expect(state.activeDocumentID == a.id)
        _ = c
    }

    @Test func reorderingTabs() {
        let state = makeWindowState()
        let a = state.open(directory.write("a.md", "a"))
        let b = state.open(directory.write("b.md", "b"))
        let c = state.open(directory.write("c.md", "c"))

        state.moveTab(c.id, to: 0)
        #expect(state.documents.map(\.id) == [c.id, a.id, b.id])
        state.moveTab(c.id, to: 99)
        #expect(state.documents.map(\.id) == [a.id, b.id, c.id])
        state.moveTab(a.id, to: 1)
        #expect(state.documents.map(\.id) == [b.id, a.id, c.id])
        #expect(state.activeDocumentID == c.id)
    }

    @Test func nextAndPreviousTabWrapAround() {
        let state = makeWindowState()
        let a = state.open(directory.write("a.md", "a"))
        let b = state.open(directory.write("b.md", "b"))
        let c = state.open(directory.write("c.md", "c"))

        state.selectNextTab()
        #expect(state.activeDocumentID == a.id)
        state.selectNextTab()
        #expect(state.activeDocumentID == b.id)
        state.selectPreviousTab()
        state.selectPreviousTab()
        #expect(state.activeDocumentID == c.id)
    }

    @Test func droppingIgnoresNonMarkdownFiles() {
        let state = makeWindowState()
        let md = directory.write("notes.markdown", "# Notes")
        let png = directory.write("image.png", "png")
        let txt = directory.write("archive.zip", "zip")

        #expect(state.openDropped([png, md, txt]))
        #expect(state.documents.map(\.fileURL) == [md])
        #expect(!state.openDropped([png, txt]))
    }

    @Test func missingFileOpensAsMissingTab() async {
        let state = makeWindowState()
        let session = state.open(directory.path("gone.md"))
        #expect(await waitUntil { session.state == .missing })
        state.close(session.id)
        #expect(state.documents.isEmpty)
    }

    @Test func relocatingAMissingFile() async {
        let state = makeWindowState()
        let session = state.open(directory.path("old.md"))
        #expect(await waitUntil { session.state == .missing })

        let moved = directory.write("new.md", "# Moved")
        state.relocate(session, to: moved)
        #expect(session.fileURL == moved)
        #expect(await waitUntil { session.state == .ready })
        #expect(session.model?.outline.first?.title == "Moved")
    }

    @Test func followingLinks() async {
        let state = makeWindowState()
        var opened: [URL] = []
        state.openExternally = { opened.append($0) }
        let readme = directory.write("README.md", "# Readme")
        let arch = directory.write("ARCHITECTURE.md", "# Arch\n\n## Data Flow")
        let session = state.open(readme)

        state.openLink("./ARCHITECTURE.md#data-flow", from: session)
        #expect(state.activeDocument?.fileURL == arch)
        #expect(state.activeDocument?.navigationRequest?.target == .anchor("data-flow"))

        state.openLink("#readme", from: session)
        #expect(session.navigationRequest?.target == .anchor("readme"))

        state.openLink("https://example.com", from: session)
        #expect(opened == [URL(string: "https://example.com")!])

        state.openLink("./MISSING.md", from: session)
        #expect(state.alert?.title == "Linked File Not Found")
        #expect(state.documents.count == 2)
    }

    @Test func recentFilesAreRecordedWhenOpening() {
        let state = makeWindowState()
        let a = directory.write("a.md", "a")
        let b = directory.write("b.md", "b")
        state.open(a)
        state.open(b)
        #expect(state.recentFiles.entries.map(\.path) == [b.path, a.path])
    }
}

@MainActor
struct TabShortcutAndHistoryTests {
    let directory = TemporaryDirectory()

    @Test func numberShortcutsSelectTabsAndNineSelectsTheLast() {
        let state = makeWindowState()
        let tabs = (1...4).map { state.open(directory.write("\($0).md", "")) }
        state.selectTab(number: 1)
        #expect(state.activeDocumentID == tabs[0].id)
        state.selectTab(number: 3)
        #expect(state.activeDocumentID == tabs[2].id)
        state.selectTab(number: 9)
        #expect(state.activeDocumentID == tabs[3].id)
        state.selectTab(number: 7) // no 7th tab: unchanged
        #expect(state.activeDocumentID == tabs[3].id)
    }

    @Test func reopenClosedTabRestoresPositionAndScroll() {
        let state = makeWindowState()
        let a = state.open(directory.write("a.md", "a"))
        let b = state.open(directory.write("b.md", "b"))
        let c = state.open(directory.write("c.md", "c"))
        b.scrollPosition = 77
        state.close(b.id)
        state.close(a.id)

        let reopenedA = state.reopenClosedTab()
        #expect(reopenedA?.displayName == "a.md")
        #expect(state.documents.map(\.displayName) == ["a.md", "c.md"])

        let reopenedB = state.reopenClosedTab()
        #expect(reopenedB?.displayName == "b.md")
        #expect(reopenedB?.scrollPosition == 77)
        #expect(state.documents.map(\.displayName) == ["a.md", "b.md", "c.md"])
        #expect(state.activeDocumentID == reopenedB?.id)
        #expect(state.reopenClosedTab() == nil)
        _ = c
    }

    @Test func reopenSkipsFilesThatNoLongerExist() throws {
        let state = makeWindowState()
        let a = state.open(directory.write("a.md", "a"))
        let gone = state.open(directory.write("gone.md", "x"))
        state.close(a.id)
        state.close(gone.id)
        try FileManager.default.removeItem(at: directory.path("gone.md"))
        #expect(state.reopenClosedTab()?.displayName == "a.md")
    }

    @Test func plainTextAndOtherMarkdownExtensionsAreSupported() {
        let state = makeWindowState()
        let files = ["notes.txt", "a.mdown", "b.mkd", "c.mdx", "d.markdown"].map { directory.write($0, "# x") }
        #expect(state.openDropped(files + [directory.write("image.png", "")]))
        #expect(state.documents.count == 5)
    }
}

@MainActor
struct MultiWindowTests {
    let directory = TemporaryDirectory()

    @Test func aFileIsOnlyOpenInOneWindow() {
        let model = makeAppModel()
        let left = model.makeWindow()
        let right = model.makeWindow()
        let url = directory.write("a.md", "# A")
        let original = left.open(url)
        let again = right.open(url)
        #expect(again.id == original.id)
        #expect(right.documents.isEmpty)
        #expect(left.documents.count == 1)
    }

    @Test func moveTabToNewWindow() {
        let model = makeAppModel()
        let source = model.makeWindow()
        let a = source.open(directory.write("a.md", "a"))
        let b = source.open(directory.write("b.md", "b"))
        model.moveToNewWindow(b, from: source)
        #expect(model.windows.count == 2)
        #expect(source.documents.map(\.id) == [a.id])
        #expect(model.windows[1].documents.map(\.id) == [b.id])
        #expect(model.windows[1].activeDocumentID == b.id)
    }

    @Test func closingAWindowDiscardsItsTabsUnlessItIsTheLast() {
        let model = makeAppModel()
        let first = model.makeWindow()
        let second = model.makeWindow()
        model.windowDidAppear(first)
        model.windowDidAppear(second)
        first.open(directory.write("a.md", "a"))
        second.open(directory.write("b.md", "b"))

        model.windowWillClose(second)
        #expect(model.windows.map(\.id) == [first.id])

        // The last window keeps its tabs so they are saved when the app quits.
        model.windowWillClose(first)
        #expect(model.windows.map(\.id) == [first.id])
        #expect(first.documents.count == 1)
    }

    @Test func filesFromFinderGoToTheLastActiveWindow() {
        let model = makeAppModel()
        let first = model.makeWindow()
        let second = model.makeWindow()
        model.windowDidAppear(first)
        model.windowDidAppear(second)
        model.windowDidBecomeKey(second)
        model.open([directory.write("a.md", "a")])
        #expect(second.documents.count == 1)
        #expect(first.documents.isEmpty)
    }
}

@MainActor
struct SaveAsAndRevertTests {
    let directory = TemporaryDirectory()

    @Test func saveAsWritesTheNewFileAndRetargetsTheTab() async throws {
        let state = makeWindowState()
        let session = state.open(directory.write("a.md", "# A"))
        #expect(await waitUntil { session.state == .ready })
        state.startEditing(session)
        session.editor?.userEdited("# Copy")

        let destination = directory.url.appendingPathComponent("copy.md")
        state.saveAs(session, to: destination)

        #expect(session.fileURL == FileIdentity.canonicalURL(destination))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "# Copy")
        #expect(try String(contentsOf: directory.path("a.md"), encoding: .utf8) == "# A")
        #expect(!session.hasUnsavedChanges)
        #expect(session.model?.outline.first?.title == "Copy")
    }

    @Test func saveAsWhileReadingCopiesTheFile() async throws {
        let state = makeWindowState()
        let session = state.open(directory.write("a.md", "# A"))
        #expect(await waitUntil { session.state == .ready })
        let destination = directory.url.appendingPathComponent("sub/b.md")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        state.saveAs(session, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "# A")
        #expect(session.displayName == "b.md")
    }

    @Test func revertDiscardsEdits() async {
        let state = makeWindowState()
        let session = state.open(directory.write("a.md", "# A"))
        #expect(await waitUntil { session.state == .ready })
        state.startEditing(session)
        session.editor?.userEdited("# Changed")
        #expect(session.hasUnsavedChanges)
        state.revert(session)
        #expect(!session.hasUnsavedChanges)
        #expect(session.editor?.text == "# A")
    }
}
