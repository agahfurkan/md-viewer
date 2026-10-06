# Architecture

MD Viewer is a native macOS Markdown **reader** (SwiftUI + AppKit, Swift 6, macOS 15+).
Editing exists but is secondary; whenever viewer and editor needs conflict, the viewer wins.

## Layout

```text
MDViewer/
├── App/        MarkdownViewerApp (+ AppDelegate), AppModel, WindowState, AppCommands
│               (+ UserActions), SessionManager
├── Document/   DocumentSession (+ EditorState), DocumentManager, FileLoader, FileWatcher,
│               RecentFilesManager, SecurityScopedBookmarkManager (+ FileIdentity),
│               FolderAccessManager
├── Markdown/   MarkdownModel, MarkdownPreprocessor, MarkdownParser, HTMLSupport,
│               MarkdownRenderer, SyntaxHighlighter, MarkdownSourceHighlighter,
│               TextAttachments (image/rule cells, fitting tables)
├── UI/         MainWindow, TabBar, ReaderView, ReaderFindClient, CodeBlockView,
│               SourceEditorView (+ line numbers), OutlineView, MissingFileView, SettingsView
├── Services/   LinkHandler (LinkResolver), ThemeManager (settings, palette), SessionPersistence,
│               ImageLoader, MathRenderer, MermaidRenderer, Updater (Sparkle)
└── Resources/  Assets, Mermaid/mermaid.min.js (11.12.0, MIT)
```

Dependencies: `swift-markdown` (parsing) and `SwiftMath` (LaTeX typesetting). Mermaid is
vendored JavaScript run in an offscreen `WKWebView` — the only web technology in the app,
because Mermaid has no native implementation.

## Pipeline

```text
FileWatcher ─► DocumentManager.reload ─► FileLoader ─► MarkdownPreprocessor ─► MarkdownParser ─► MarkdownRenderer
 (kqueue)       (main actor, generations)  (background)  (math, footnotes)     (large-stack thread)  (main actor)
```

- **FileWatcher** uses `DispatchSource` file-system sources (kqueue) — no polling. It debounces
  bursts (150 ms), survives atomic saves (delete/rename of the old inode → re-arm on the path),
  follows renames via `F_GETPATH`, and watches the parent directory while a file is missing so
  it notices re-creation.
- **DocumentManager** loads off the main actor and skips parsing when the text didn't change.
  Every load bumps `loadGeneration`; stale results are dropped.
- **MarkdownPreprocessor** handles what cmark can't see: `$…$`/`$$…$$` math is swapped for
  private-use placeholders (so `_` inside math isn't emphasis), and `[^label]:` footnote
  definitions are cut out. Fenced code and code spans are left alone. Delimiter rules follow
  Pandoc, so `$5 and $10` stays text.
- **MarkdownParser** wraps Apple's `swift-markdown` (cmark-gfm: tables, strikethrough, task lists)
  and converts its AST into the app's own `MarkdownDocumentModel` (plain `Sendable` values), so
  nothing outside `MarkdownParser.swift` imports the parser library. It adds bare-URL autolinks,
  GitHub alerts, footnote numbering (by first reference), math, Mermaid and syntax tokens.
  **HTMLSupport** tokenizes embedded HTML and folds matching tags: inline (`<kbd>`, `<sup>`,
  `<mark>`, `<a>`, …) and across blocks (`<details>` around Markdown, `<p align="center">`,
  headings, lists, tables). A final pass assigns heading anchors, the outline and `<details>` ids
  in document order. Nesting is capped and parsing runs on a thread with a 32 MB stack because
  swift-markdown's conversion is recursive.
- **MarkdownRenderer** turns the model into one `NSAttributedString`.

## Key decisions

**One TextKit 1 `NSTextView` per reader, not a SwiftUI view per block.** A single text view gives
continuous selection, native copy and a document-like feel. TextKit 1 because it supports
`NSTextTable` and `NSTextBlock`. Notes:
- Every `NSTextBlock` needs `setContentWidth(100%)`; without it blocks collapse to zero width.
- Vertical spacing is resolved by `AttributedBuilder`: paragraph spacing between plain
  paragraphs, block margins when entering or leaving a block.
- Images, rules, math and diagrams are `NSTextAttachmentCell`s that size themselves to the line
  width at layout time, so window resizes don't need a re-render. Math is drawn as a mask in the
  text color; diagrams keep a light and a dark rendering; all colors are dynamic.
- Tables (`FittingTextTable`) are sized to their content and, when squeezed, give each column at
  least its longest word — widths are recomputed at layout time for the actual width.
- The reader's scroller never auto-hides: with legacy scrollers, a scroller appearing mid-layout
  narrows the container and TextKit abandons the layout pass.

**Code blocks are embedded views.** Each fenced block is an attachment hosting a non-wrapping,
horizontally scrollable `NSTextView` with a copy button (`CodeBlockView`). Views are positioned
from the cell's draw call (deferred to the next run-loop turn) and hidden whenever layout shifts,
so stale positions never show. Because the code is no longer in the reader's text:
- **Find** uses `ReaderFindClient`, an `NSTextFinderClient` spanning several views: the document
  text with each code block's attachment character replaced by its code. Matches in code blocks
  are highlighted and scrolled to inside the block. As with any incremental find bar, Find Next
  moves the find indicator; the selection is set when the bar is closed.
- **Copy** of a selection spanning code blocks writes the code in place of the attachments.

**Reader state vs. filesystem state.** `DocumentSession` holds the file reference and the parsed
model separately. `contentVersion` changes only when the model actually changes; the reader
re-renders only for a new version, new settings, toggled `<details>` or an explicit
`renderGeneration` bump. Rendered strings are cached per tab (`RenderCache`).

**One reader view per window for all tabs.** Switching tabs swaps the text storage and restores
that tab's scroll position (the character index at the top of the viewport). Scrolls requested
before the view has a real width are deferred. Live reloads keep the viewport on the same text
(`ViewportAnchor`: the text at the top is found again in the new document, nearest to where it
was) and stay pinned to the bottom when following a growing file.

**Windows own tabs; the app owns services.** `AppModel` holds the windows, and each window has a
`WindowState` with its documents, active tab, closed-tab history and sidebar state. Services —
`DocumentManager`, `RecentFilesManager`, `SessionManager` — are shared. A file is only ever open
in one window; opening it elsewhere activates the existing tab. Menu commands act on the focused
window via `@FocusedValue`. Neither type has view code; both are unit tested directly. AppKit UI
around the actions (panels, alerts) lives in `UserActions`.

SwiftUI's `WindowGroup(for: UUID.self)` shows one `WindowState` per window. SwiftUI's own window
restoration is disabled — the session file restores windows — and the `defaultValue` for the
launch window is a fixed ID, because SwiftUI evaluates it more than once and runs it during view
updates (so it must not mutate observed state). The scene handles no external events
(`handlesExternalEvents(matching: [])`), so files opened from Finder or the Dock don't make SwiftUI
open a new window; the app delegate opens them as tabs in the last active window. Because SwiftUI
then shows no window when the app is launched by opening a file, the delegate presents the launch
window after launch if none is on screen (`openWindow` comes from the menu commands, which exist
before any window).

**File identity.** Files are tracked by canonical URL (standardized, symlinks resolved), and
duplicates are also detected via `fileResourceIdentifier` (case-insensitive volumes, hard links).

**Session persistence.** `AppSessionSnapshot` (JSON, version 2, in `~/Library/Application
Support/MD Viewer/session.json`) stores every window: file references (path, bookmark,
scroll index), active tab, sidebar visibility and window frame — never document contents.
Version-1 (single window) files still load. Saves are coalesced (~0.6 s) and flushed on quit; a
corrupt file is moved aside. The last window's tabs survive closing it because the app quits
then.

**No App Sandbox; bookmarks anyway.** A Markdown viewer must read sibling resources (relative
images, linked documents), which the sandbox blocks without per-folder grants, so the app is
unsandboxed. Bookmarks are still stored (security-scoped when possible): restoration follows
files moved while the app was closed, and the stored **path wins** when a file exists there
(tools replace files). If the sandbox is ever enabled, `FolderAccessManager` activates: the reader
offers to grant access to a document's folder, and grants persist as security-scoped bookmarks.

**Updates** use Sparkle (`Updater`). The feed is `appcast.xml` attached to the latest GitHub
release (`SUFeedURL`); each update archive is signed with an EdDSA key whose public half is
`SUPublicEDKey` in Info.plist and whose private half lives in the release machine's keychain.
Sparkle installs an update only if that signature matches, so the app itself can stay ad-hoc
signed. `scripts/release.sh` builds, zips, signs and publishes a release with its feed. The
updater isn't started when hosting tests.

**Recent files** are app-managed (`RecentFilesManager`, UserDefaults) rather than
`NSDocumentController`, which would take over file-open routing.

**Editing is a mode, not the architecture.** `EditorState` is attached to a session only while
editing. The editor (TextKit 1) shows line numbers and Markdown coloring via temporary attributes
(no effect on undo), and a live preview re-parsed off the main thread after typing pauses.
External changes apply silently without local edits; with unsaved edits the user gets a banner.
Save As retargets the tab to the new file; Revert reloads from disk.

## Testing

`MDViewerTests` (Swift Testing) covers the preprocessor, parser (HTML, footnotes, math,
Mermaid, nesting limits), highlighters, link/image resolution, file loading, window/tab logic
(multi-window, closed tabs, ⌘1–9), session v1/v2 serialization and restoration, recent files,
folder grants, the file watcher, the reload/edit/preview pipeline, table sizing, viewport
anchoring, code-block Find/Copy, and Math/Mermaid rendering.

Opt-in visual checks render the reader, tables, editor and the live main window to PNGs:

```bash
TEST_RUNNER_SNAPSHOT_DIR=/tmp/snapshots xcodebuild -project MDViewer.xcodeproj -scheme MDViewer test -only-testing:MDViewerTests/ReaderSnapshotTests -only-testing:MDViewerTests/TableSnapshotTests -only-testing:MDViewerTests/EditorSnapshotTests -only-testing:MDViewerTests/WindowSnapshotTests
```
