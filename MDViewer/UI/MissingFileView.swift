import SwiftUI

/// Shown for a tab whose file no longer exists.
struct MissingFileView: View {
    let session: DocumentSession
    let windowState: WindowState

    var body: some View {
        ContentUnavailableView {
            Label("File Not Found", systemImage: "questionmark.folder")
        } description: {
            VStack(spacing: 6) {
                Text("“\(session.displayName)” was moved, renamed, or deleted.")
                Text(session.fileURL.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("It will reopen automatically if it reappears.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        } actions: {
            HStack {
                Button("Locate…") { UserActions.locate(session, windowState: windowState) }
                    .keyboardShortcut(.defaultAction)
                Button("Close Tab") { windowState.close(session.id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Shown when a file exists but can't be displayed (permissions, encoding, …).
struct DocumentErrorView: View {
    let session: DocumentSession
    let message: String
    let windowState: WindowState

    var body: some View {
        ContentUnavailableView {
            Label("Can't Open “\(session.displayName)”", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 6) {
                Text(message)
                Text(session.fileURL.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        } actions: {
            HStack {
                Button("Try Again") { windowState.retry(session) }
                    .keyboardShortcut(.defaultAction)
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.fileURL]) }
                Button("Close Tab") { windowState.close(session.id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Shown when no document is open.
struct EmptyStateView: View {
    let windowState: WindowState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("No Document Open")
                    .font(.title2.weight(.semibold))
                Text("Open a Markdown file or drop one here.")
                    .foregroundStyle(.secondary)
            }
            Button("Open…") { UserActions.showOpenPanel(windowState) }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

            let recent = Array(windowState.recentFiles.entries.prefix(8))
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                    ForEach(recent) { entry in
                        Button {
                            UserActions.openRecent(entry, windowState: windowState)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(entry.displayName)
                                Text(entry.url.deletingLastPathComponent().abbreviatedPath)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .buttonStyle(.link)
                        .foregroundStyle(.primary)
                        .help(entry.path)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.top, 12)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

extension URL {
    /// The path with the home directory shown as `~`.
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
