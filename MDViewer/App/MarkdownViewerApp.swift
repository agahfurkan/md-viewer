import SwiftUI

@main
struct MarkdownViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(SettingsKey.appearance) private var appearance = AppearancePreference.system.rawValue

    var body: some Scene {
        // Each window shows one `WindowState`, identified by its ID. SwiftUI's own window
        // restoration is off: the session file restores windows and their tabs.
        WindowGroup(id: "workspace", for: UUID.self) { $windowID in
            WorkspaceWindow(model: appDelegate.model, windowID: windowID)
                .onAppear { ThemeManager.apply(AppearancePreference(rawValue: appearance) ?? .system) }
                .onChange(of: appearance) { _, newValue in
                    ThemeManager.apply(AppearancePreference(rawValue: newValue) ?? .system)
                }
        } defaultValue: {
            appDelegate.model.launchWindowID
        }
        .defaultSize(width: 1100, height: 780)
        .windowToolbarStyle(.unified(showsTitle: true))
        .restorationBehavior(.disabled)
        // Files opened from Finder or the Dock are opened as tabs by the app delegate; without
        // this SwiftUI would also open a new window for each one.
        .handlesExternalEvents(matching: [])
        .commands {
            AppCommands(model: appDelegate.model)
        }

        Settings {
            SettingsView()
        }
    }
}

/// Resolves the window's state and wires up window-level events.
private struct WorkspaceWindow: View {
    let model: AppModel
    let windowID: UUID
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = model.makeWindow(id: windowID)
        MainWindow(windowState: state)
            .onAppear {
                model.presentWindow = { id in openWindow(id: "workspace", value: id) }
                model.windowDidAppear(state)
            }
    }
}

/// Handles app-level events SwiftUI doesn't expose: opening files from Finder or the Dock,
/// session restoration at launch, keyboard shortcuts without menu items, and saving on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The delegate instance, for code that can't reach it through SwiftUI (e.g. hosted tests).
    private(set) static weak var current: AppDelegate?

    let model: AppModel
    private var keyMonitor: Any?

    override init() {
        let isTesting = AppEnvironment.isRunningTests
        let sessionManager = SessionManager(persistence: isTesting ? nil : SessionPersistence(fileURL: SessionPersistence.defaultFileURL()))
        model = AppModel(
            documentManager: DocumentManager(),
            recentFiles: RecentFilesManager(defaults: isTesting ? UserDefaults(suiteName: "MDViewer.hostedTests") ?? .standard : .standard),
            sessionManager: sessionManager
        )
        super.init()
        Self.current = self
        // Restore before any open-file events arrive so they are added after the session's tabs.
        if let snapshot = sessionManager.loadSnapshot() {
            model.restore(from: snapshot)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The app has its own document tabs; system window tabbing would only confuse.
        NSWindow.allowsAutomaticWindowTabbing = false
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handleTabShortcut(event) ?? false }
            return handled ? nil : event
        }
    }

    /// ⌘1…⌘9 select a tab, ⌃⇥ / ⌃⇧⇥ cycle tabs. Handled here rather than as menu items to keep
    /// the menus short. Physical key codes keep ⌘1…9 working on every keyboard layout.
    private func handleTabShortcut(_ event: NSEvent) -> Bool {
        guard let window = event.window, let state = model.windows.first(where: { $0.window === window }) else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if modifiers == .command, let number = Self.digitKeyCodes[event.keyCode] {
            state.selectTab(number: number)
            return true
        }
        if event.keyCode == 48 /* Tab */, modifiers == .control || modifiers == [.control, .shift] {
            modifiers.contains(.shift) ? state.selectPreviousTab() : state.selectNextTab()
            return true
        }
        return false
    }

    private static let digitKeyCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched by opening a file, SwiftUI shows no window (the scene doesn't handle
        // external events), so show the launch window here.
        DispatchQueue.main.async { [model] in model.presentLaunchWindowIfNeeded() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        model.open(fileURLs)
        if let window = model.targetWindow.window {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasUnsavedChanges else { return .terminateNow }
        let dirty = model.windows.flatMap { window in window.documents.filter(\.hasUnsavedChanges).map { (window, $0) } }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Do you want to save the changes to “\(dirty[0].1.displayName)”?"
            : "You have unsaved changes in \(dirty.count) documents."
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for (window, session) in dirty {
                window.save(session)
            }
            return model.hasUnsavedChanges ? .terminateCancel : .terminateNow
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveSessionNow()
    }
}

enum AppEnvironment {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
