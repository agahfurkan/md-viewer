import SwiftUI

/// Browser-style document tabs: click to activate, close button, drag to reorder, context menu.
struct TabBar: View {
    let windowState: WindowState
    @State private var draggingID: UUID?

    static let height: CGFloat = 30

    var body: some View {
        GeometryReader { geometry in
            let count = CGFloat(max(1, windowState.documents.count))
            let tabWidth = min(230, max(130, (geometry.size.width / count).rounded(.down)))
            let titles = Self.disambiguatedTitles(for: windowState.documents)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(windowState.documents) { session in
                            TabItem(
                                session: session,
                                title: titles[session.id] ?? session.displayName,
                                isActive: session.id == windowState.activeDocumentID,
                                width: tabWidth,
                                windowState: windowState
                            )
                            .id(session.id)
                            .onDrag {
                                draggingID = session.id
                                return NSItemProvider(object: session.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabDropDelegate(target: session.id, windowState: windowState, draggingID: $draggingID))
                        }
                    }
                }
                .onChange(of: windowState.activeDocumentID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
                .onAppear {
                    if let id = windowState.activeDocumentID { proxy.scrollTo(id) }
                }
            }
        }
        .frame(height: Self.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Tabs with the same file name get their parent folder appended, like VS Code.
    static func disambiguatedTitles(for documents: [DocumentSession]) -> [UUID: String] {
        let counts = Dictionary(grouping: documents, by: { $0.displayName.lowercased() }).mapValues(\.count)
        var titles: [UUID: String] = [:]
        for session in documents {
            if counts[session.displayName.lowercased(), default: 0] > 1 {
                let folder = session.fileURL.deletingLastPathComponent().lastPathComponent
                titles[session.id] = "\(session.displayName) — \(folder)"
            } else {
                titles[session.id] = session.displayName
            }
        }
        return titles
    }
}

private struct TabItem: View {
    let session: DocumentSession
    let title: String
    let isActive: Bool
    let width: CGFloat
    let windowState: WindowState
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            trailingControl
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: width, height: TabBar.height)
        .background(background)
        .overlay(alignment: .top) {
            if isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .overlay(alignment: .bottom) {
            if !isActive {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { windowState.activate(session.id) }
        .onHover { isHovering = $0 }
        .help(session.fileURL.path)
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        switch session.state {
        case .missing:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("File not found")
        case .error:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        default:
            Image(systemName: session.isEditing ? "pencil.line" : "doc.text")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trailingControl: some View {
        if session.hasUnsavedChanges, !isHovering {
            Circle()
                .fill(Color.secondary)
                .frame(width: 7, height: 7)
                .frame(width: 16, height: 16)
                .help("Unsaved changes")
        } else {
            Button {
                UserActions.requestClose(session, windowState: windowState)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TabCloseButtonStyle())
            .opacity(isHovering || isActive ? 1 : 0)
            .help("Close Tab")
            .accessibilityLabel("Close \(session.displayName)")
        }
    }

    private var background: Color {
        if isActive { return Color(nsColor: .textBackgroundColor) }
        return isHovering ? Color.primary.opacity(0.045) : Color.clear
    }

    @ViewBuilder private var contextMenu: some View {
        Button("Close Tab") { UserActions.requestClose(session, windowState: windowState) }
        Button("Close Other Tabs") { windowState.closeOthers(keeping: session.id) }
            .disabled(windowState.documents.count < 2)
        Button("Close Tabs to the Right") { windowState.closeTabsToRight(of: session.id) }
            .disabled(windowState.documents.last?.id == session.id)
        Divider()
        Button("Move to New Window") { windowState.app?.moveToNewWindow(session, from: windowState) }
            .disabled(windowState.documents.count < 2)
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.fileURL]) }
            .disabled(session.state == .missing)
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.fileURL.path, forType: .string)
        }
    }
}

private struct TabCloseButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (isHovering ? 0.09 : 0)))
            )
            .onHover { isHovering = $0 }
    }
}

/// Live reordering while a tab is dragged over its neighbours.
private struct TabDropDelegate: DropDelegate {
    let target: UUID
    let windowState: WindowState
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != target,
              let destination = windowState.documents.firstIndex(where: { $0.id == target })
        else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            windowState.moveTab(draggingID, to: destination)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}
