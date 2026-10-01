import SwiftUI
import UniformTypeIdentifiers

extension FocusedValues {
    /// The window state of the focused main window.
    @Entry var windowState: WindowState?
}

/// Menu bar commands and their keyboard shortcuts. Commands act on the focused window.
struct AppCommands: Commands {
    let model: AppModel
    @FocusedValue(\.windowState) private var focusedWindow
    @AppStorage(SettingsKey.fontSize) private var fontSize = Double(ReaderStyle.defaultFontSize)

    private var window: WindowState? { focusedWindow }
    private var document: DocumentSession? { focusedWindow?.activeDocument }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { model.newWindow() }
                .keyboardShortcut("n")
            Button("Open…") { UserActions.showOpenPanel(window ?? model.targetWindow) }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                RecentFilesMenu(model: model, target: window, recentFiles: model.recentFiles)
            }
            Menu("Open from Enclosing Folder") {
                EnclosingFolderMenu(window: window, document: document)
            }
            .disabled(document == nil)
            Divider()
            Button("Reopen Closed Tab") { window?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(window?.recentlyClosed.isEmpty ?? true)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { UserActions.closeActiveTabOrWindow(window) }
                .keyboardShortcut("w")
            Button("Close Window") { UserActions.requestCloseWindow(window) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Save") {
                if let window, let document { window.save(document) }
            }
            .keyboardShortcut("s")
            .disabled(!(document?.isEditing ?? false))
            Button("Save As…") {
                if let window, let document { UserActions.saveAs(document, windowState: window) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(document?.state != .ready && !(document?.isEditing ?? false))
            Button("Revert to Saved") {
                if let window, let document { UserActions.revert(document, windowState: window) }
            }
            .disabled(!(document?.hasUnsavedChanges ?? false))
            Divider()
            Button("Reveal in Finder") {
                if let document { NSWorkspace.shared.activateFileViewerSelecting([document.fileURL]) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(document == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { UserActions.performFind(.showFindInterface) }
                .keyboardShortcut("f")
            Button("Find Next") { UserActions.performFind(.nextMatch) }
                .keyboardShortcut("g")
            Button("Find Previous") { UserActions.performFind(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") { UserActions.performFind(.setSearchString) }
                .keyboardShortcut("e")
        }

        CommandGroup(before: .sidebar) {
            Button(document?.isEditing == true ? "Show Reader" : "Edit Markdown Source") {
                if let window, let document { UserActions.toggleEditing(document, windowState: window) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(document?.state != .ready && !(document?.isEditing ?? false))
            Button(document?.editor?.showsPreview == false ? "Show Live Preview" : "Hide Live Preview") {
                document?.editor?.showsPreview.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!(document?.isEditing ?? false))
            Divider()
            Button("Actual Size") { fontSize = Double(ReaderStyle.defaultFontSize) }
                .keyboardShortcut("0")
            Button("Zoom In") { fontSize = min(Double(ReaderStyle.fontSizeRange.upperBound), fontSize + 1) }
                .keyboardShortcut("+")
            Button("Zoom Out") { fontSize = max(Double(ReaderStyle.fontSizeRange.lowerBound), fontSize - 1) }
                .keyboardShortcut("-")
            Divider()
        }

        SidebarCommands()

        CommandGroup(before: .windowList) {
            Button("Show Previous Tab") { window?.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled((window?.documents.count ?? 0) < 2)
            Button("Show Next Tab") { window?.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled((window?.documents.count ?? 0) < 2)
            Button("Move Tab to New Window") {
                if let window, let document { model.moveToNewWindow(document, from: window) }
            }
            .disabled((window?.documents.count ?? 0) < 2)
            Divider()
        }
    }
}

private struct RecentFilesMenu: View {
    let model: AppModel
    let target: WindowState?
    let recentFiles: RecentFilesManager

    var body: some View {
        ForEach(recentFiles.entries) { entry in
            Button(entry.displayName) {
                UserActions.openRecent(entry, windowState: target ?? model.targetWindow)
            }
        }
        if !recentFiles.entries.isEmpty {
            Divider()
        }
        Button("Clear Menu") { recentFiles.clear() }
            .disabled(recentFiles.entries.isEmpty)
    }
}

/// Lists the other documents next to the active one, for quick access to sibling files such as
/// `PLAN.md` and `NOTES.md` written by the same tool.
private struct EnclosingFolderMenu: View {
    let window: WindowState?
    let document: DocumentSession?

    var body: some View {
        if let window, let document {
            let folder = document.fileURL.deletingLastPathComponent()
            let siblings = FolderListing.documents(in: folder)
            ForEach(siblings, id: \.self) { url in
                Button(url.lastPathComponent) { window.open(url) }
                    .disabled(FileIdentity.isSameFile(url, document.fileURL))
            }
            if siblings.isEmpty {
                Text("No Other Documents")
            }
            Divider()
            Button("Open Enclosing Folder") { NSWorkspace.shared.open(folder) }
        }
    }
}

enum FolderListing {
    /// Supported documents directly inside `folder`, sorted by name.
    static func documents(in folder: URL, limit: Int = 100) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { LinkResolver.isSupportedDocument($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit)
            .map { FileIdentity.canonicalURL($0) }
    }
}

/// User-initiated actions that need AppKit UI (panels, confirmation alerts) around the plain
/// state changes in `WindowState`.
@MainActor
enum UserActions {
    static var documentContentTypes: [UTType] {
        var types: [UTType] = [UTType("net.daringfireball.markdown"), .plainText].compactMap { $0 }
        types += LinkResolver.documentExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        return types
    }

    static func showOpenPanel(_ windowState: WindowState) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = documentContentTypes
        panel.message = "Choose Markdown files to open"
        if let current = windowState.activeDocument?.fileURL.deletingLastPathComponent() {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK else { return }
        windowState.open(panel.urls)
    }

    static func openRecent(_ entry: RecentFilesManager.Entry, windowState: WindowState) {
        let url = windowState.recentFiles.resolvedURL(for: entry)
        guard FileManager.default.fileExists(atPath: url.path) else {
            windowState.recentFiles.remove(URL(fileURLWithPath: entry.path))
            windowState.alert = AlertMessage(title: "File Not Found", message: "“\(entry.displayName)” no longer exists at \(entry.path).")
            return
        }
        windowState.open(url)
    }

    static func locate(_ session: DocumentSession, windowState: WindowState) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = documentContentTypes
        panel.message = "Locate “\(session.displayName)”"
        let directory = session.fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        windowState.relocate(session, to: url)
    }

    static func saveAs(_ session: DocumentSession, windowState: WindowState) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.displayName
        panel.directoryURL = session.fileURL.deletingLastPathComponent()
        panel.allowedContentTypes = documentContentTypes
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        windowState.saveAs(session, to: url)
    }

    static func revert(_ session: DocumentSession, windowState: WindowState) {
        let alert = NSAlert()
        alert.messageText = "Revert “\(session.displayName)” to the saved version?"
        alert.informativeText = "Your unsaved changes will be lost."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        windowState.revert(session)
    }

    static func closeActiveTabOrWindow(_ windowState: WindowState?) {
        if let windowState, let session = windowState.activeDocument {
            requestClose(session, windowState: windowState)
        } else {
            requestCloseWindow(windowState)
        }
    }

    /// Closes a window, first asking about unsaved edits in any of its tabs.
    static func requestCloseWindow(_ windowState: WindowState?) {
        guard let windowState, let window = windowState.window ?? NSApp.keyWindow else {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        let dirty = windowState.documents.filter(\.hasUnsavedChanges)
        guard !dirty.isEmpty else {
            window.close()
            return
        }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Do you want to save the changes to “\(dirty[0].displayName)” before closing the window?"
            : "This window has unsaved changes in \(dirty.count) documents."
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for session in dirty { windowState.save(session) }
            if !windowState.hasUnsavedChanges { window.close() }
        case .alertThirdButtonReturn:
            for session in dirty { windowState.stopEditing(session) }
            window.close()
        default:
            break
        }
    }

    static func requestClose(_ session: DocumentSession, windowState: WindowState) {
        guard session.hasUnsavedChanges else {
            windowState.close(session.id)
            return
        }
        switch confirmDiscard(session, action: "closing") {
        case .save:
            windowState.save(session)
            if !session.hasUnsavedChanges { windowState.close(session.id) }
        case .discard:
            windowState.close(session.id)
        case .cancel:
            break
        }
    }

    static func toggleEditing(_ session: DocumentSession, windowState: WindowState) {
        guard session.isEditing else {
            windowState.startEditing(session)
            return
        }
        guard session.hasUnsavedChanges else {
            windowState.stopEditing(session)
            return
        }
        switch confirmDiscard(session, action: "leaving the editor") {
        case .save:
            windowState.save(session)
            if !session.hasUnsavedChanges { windowState.stopEditing(session) }
        case .discard:
            windowState.stopEditing(session)
        case .cancel:
            break
        }
    }

    enum DiscardChoice { case save, discard, cancel }

    private static func confirmDiscard(_ session: DocumentSession, action: String) -> DiscardChoice {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(session.displayName)” before \(action)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Routes a find command to the text view showing the key window's document (reader or
    /// editor), focusing it if needed.
    static func performFind(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        if let textView = ActiveTextView.current(in: NSApp.keyWindow) {
            textView.performTextFinderAction(item)
        } else {
            NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: nil, from: item)
        }
    }
}

/// Tracks the text views showing documents so Find commands reach the right one in each window.
@MainActor
enum ActiveTextView {
    private final class WeakBox {
        weak var view: NSTextView?
        init(_ view: NSTextView) { self.view = view }
    }

    private static var boxes: [WeakBox] = []

    /// Marks a text view as the most recently shown document view.
    static func register(_ view: NSTextView) {
        boxes.removeAll { $0.view == nil || $0.view === view }
        boxes.append(WeakBox(view))
    }

    static func unregister(_ view: NSTextView) {
        boxes.removeAll { $0.view == nil || $0.view === view }
    }

    /// The most recently registered visible text view in `window` (any window if `nil`).
    static func current(in window: NSWindow?) -> NSTextView? {
        for box in boxes.reversed() {
            guard let view = box.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { continue }
            if window == nil || view.window === window { return view }
        }
        return nil
    }
}
