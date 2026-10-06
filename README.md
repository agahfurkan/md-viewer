# MD Viewer

A fast, native macOS app for **reading** Markdown files — built for developers who keep checking
Markdown produced by tools and AI agents (`PLAN.md`, `README.md`, generated docs).

- Open files in tabs, across as many windows as you like; the session (windows, files, tab
  order, active tabs, scroll positions, window frames, sidebar) is restored on the next launch.
- Files update automatically when another app or agent changes them on disk — the view stays on
  the text you were reading, and follows the end of a growing file.
- GitHub-flavored rendering: tables sized to their content, task lists, strikethrough, footnotes,
  alerts (`> [!NOTE]`), fenced code with syntax highlighting (scrolls horizontally, copy
  button), math (`$…$`, `$$…$$`), Mermaid diagrams, relative images, embedded HTML (`<kbd>`,
  `<sup>`, `<details>`, centered blocks), and links to other Markdown files that open in a tab.
- Outline sidebar, find in document (including inside code blocks), light/dark mode, adjustable
  text size and reading width.
- Opens `.md`, `.markdown`, `.mdown`, `.mkd`, `.mdx` and friends, plus `.txt`.
- Source editing when needed (⇧⌘E): line numbers, Markdown coloring, live preview, Save / Save As
  / Revert.

Requires macOS 15 or later.

## Build and run

Open `MDViewer.xcodeproj` in Xcode and run the **MDViewer** scheme, or:

```bash
xcodebuild -project MDViewer.xcodeproj -scheme MDViewer -configuration Release -derivedDataPath build/DerivedData build
```

```bash
open "build/DerivedData/Build/Products/Release/MD Viewer.app"
```

To make it the default for Markdown files: Finder → Get Info on any `.md` file → Open with →
MD Viewer → Change All.

Once installed, the app updates itself: it checks daily (Settings → Updates; or MD Viewer →
Check for Updates…) and installs new versions from this repo's GitHub releases.

## Release

1. Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (the build number must increase —
   it's what the updater compares), and commit.
2. Run `scripts/release.sh`. It builds, tags `v<version>`, zips the app, signs the zip and
   writes `appcast.xml` with Sparkle's `generate_appcast`, pushes, and creates the GitHub release.

Update archives are signed with the EdDSA key stored in the login keychain under the account
`MDViewer`. Keep a copy of it somewhere safe (`generate_keys --account MDViewer -x <file>` from
`build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin`): without it, installed copies
can't be updated.

## Test

```bash
xcodebuild -project MDViewer.xcodeproj -scheme MDViewer test
```

`Samples/Showcase.md` exercises every supported Markdown feature.

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| New window | ⌘N |
| Open file | ⌘O |
| Close tab / window | ⌘W / ⇧⌘W |
| Reopen closed tab | ⇧⌘T |
| Previous / next tab | ⇧⌘[ / ⇧⌘] or ⌃⇧⇥ / ⌃⇥ |
| Go to tab 1–8 / last tab | ⌘1…⌘8 / ⌘9 |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Toggle sidebar | ⌃⌘S |
| Edit source / back to reader | ⇧⌘E |
| Save / Save As (while editing) | ⌘S / ⇧⌘S |
| Show / hide live preview | ⌥⌘P |
| Text size | ⌘+ / ⌘- / ⌘0 |
| Reveal in Finder | ⇧⌘R |
| Settings | ⌘, |

See [ARCHITECTURE.md](ARCHITECTURE.md) for design decisions and [TODO.md](TODO.md) for deferred
work.
