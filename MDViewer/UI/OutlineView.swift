import SwiftUI

/// Sidebar listing the active document's headings. Clicking one scrolls the reader to it; the
/// heading currently at the top of the reader is highlighted.
struct OutlineView: View {
    let session: DocumentSession?

    var body: some View {
        if let session, let outline = session.model?.outline, !outline.isEmpty {
            OutlineList(session: session, outline: outline)
        } else {
            ContentUnavailableView {
                Label("No Outline", systemImage: "list.bullet.indent")
            } description: {
                Text(session == nil ? "Open a Markdown file to see its headings." : "This document has no headings.")
            }
        }
    }
}

private struct OutlineList: View {
    let session: DocumentSession
    let outline: [OutlineItem]

    var body: some View {
        let minimumLevel = outline.map(\.level).min() ?? 1
        let current = session.currentOutlineIndex

        ScrollViewReader { proxy in
            List {
                Section("Outline") {
                    ForEach(outline) { item in
                        OutlineRow(
                            item: item,
                            depth: item.level - minimumLevel,
                            isCurrent: item.id == current
                        ) {
                            session.navigate(to: .outlineItem(item.id))
                        }
                        .id(item.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: current) { _, newValue in
                if let newValue { proxy.scrollTo(newValue) }
            }
        }
    }
}

private struct OutlineRow: View {
    let item: OutlineItem
    let depth: Int
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Text(item.title.isEmpty ? "Untitled" : item.title)
            .font(depth == 0 ? .body.weight(.medium) : .body)
            .foregroundStyle(depth >= 2 ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, CGFloat(min(depth, 5)) * 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isCurrent ? Color.accentColor.opacity(0.16) : Color.clear)
                    .padding(.horizontal, 10)
            )
            .help(item.title)
            .accessibilityAddTraits(.isButton)
    }
}
