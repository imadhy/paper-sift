import PaperSiftCore
import SwiftUI

/// The one control the whole app is about: a glass capsule holding the query.
///
/// Its own view rather than a slice of `ResultsColumn`, so a keystroke redraws the
/// field and not the list of results behind it.
struct SearchFieldBar: View {
    @Environment(LibraryModel.self) private var library
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var library = library
        HStack(spacing: Metrics.rowSpacing) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)

            TextField("Search every page", text: $library.queryText)
                .textFieldStyle(.plain)
                .focused($isFocused)

            if library.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching")
            } else if !library.queryText.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill", action: clear)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }

            if let scope = scopeName {
                Chip(text: scope, symbol: "folder")
                    .help("Only this folder is being searched — pick All Folders in the sidebar to widen it")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassPanel(in: Capsule(), interactive: true)
        .overlay {
            // The focus ring is drawn rather than inherited: a plain TextField inside
            // a glass capsule has no ring of its own to show.
            Capsule()
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.55 : 0), lineWidth: 2)
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .padding(.horizontal, Metrics.tight)
        .padding(.top, Metrics.tight)
        .padding(.bottom, Metrics.rowSpacing)
        .onAppear { isFocused = true }
        .onReceive(of: .focusSearchField) { isFocused = true }
    }

    private var scopeName: String? {
        guard let id = library.scopedRootID else { return nil }
        return library.roots.first { $0.id == id }?.name
    }

    private func clear() {
        library.queryText = ""
        isFocused = true
    }
}
