import PaperSiftCore
import SwiftUI

/// The middle column: the search field, the ranked results, and one line saying how
/// many there were and how long it took.
///
/// Documents and their matching pages are two kinds of row in one flat list rather
/// than a nested outline. That keeps the arrow keys walking naturally from a document
/// into its pages and out into the next document, and it keeps the selection a single
/// value the model can round-trip.
struct ResultsColumn: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        VStack(spacing: 0) {
            SearchFieldBar()
            if library.hasQuery, library.results?.documents.isEmpty == false {
                ResultsHeaderBar()
            }
            // `ContentUnavailableView` sizes to its content, so without this the empty
            // states let the stack shrink and drag the search field down the column
            // with them.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: Metrics.resultsMinWidth, idealWidth: Metrics.resultsIdealWidth)
    }

    @ViewBuilder
    private var content: some View {
        if library.roots.isEmpty {
            ContentUnavailableView(
                "No folder yet",
                systemImage: "folder.badge.plus",
                description: Text("Add a folder and every page inside it becomes searchable."))
        } else if !library.hasQuery {
            ContentUnavailableView(
                "Search your documents",
                systemImage: "sparkle.magnifyingglass",
                description: Text("Try a phrase in quotes, +required, -excluded or a prefix*."))
        } else if library.results?.documents.isEmpty == true {
            ContentUnavailableView(
                "No match",
                systemImage: "questionmark.folder",
                description: Text("Nothing in the indexed folders contains that."))
        } else {
            ResultsList()
        }
    }
}

/// The rows themselves, and the selection that walks them.
private struct ResultsList: View {
    @Environment(LibraryModel.self) private var library

    /// Documents and their expanded pages, flattened into the rows a `List` wants.
    private enum Row: Identifiable {
        case document(DocumentResult)
        case page(document: DocumentResult, hit: PageHit)

        var id: ResultSelection {
            switch self {
            case .document(let document):
                .document(document.documentID)
            case .page(let document, let hit):
                .page(document: document.documentID, pageID: hit.pageID)
            }
        }
    }

    private var rows: [Row] {
        library.displayedDocuments.flatMap { document -> [Row] in
            guard library.isExpanded(document.documentID), document.hits.count > 1 else {
                return [.document(document)]
            }
            return [.document(document)] + document.hits.map { .page(document: document, hit: $0) }
        }
    }

    var body: some View {
        @Bindable var library = library
        ScrollViewReader { proxy in
            List(selection: $library.resultSelection) {
                ForEach(rows) { row in
                    switch row {
                    case .document(let document):
                        DocumentResultRow(document: document)
                            .tag(row.id)
                            .contextMenu { DocumentActions(library: library, document: document) }
                    case .page(let document, let hit):
                        PageHitRow(hit: hit, rank: library.rank(of: hit), isPDF: document.isPDF)
                            .tag(row.id)
                            .contextMenu { DocumentActions(library: library, document: document) }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: 1, leading: Metrics.rowSpacing, bottom: 1, trailing: Metrics.rowSpacing))
            }
            .listStyle(.inset)
            .clearScrollBackground()
            // ⌘⌥↓ and the Results menu move the selection from outside the list, and a
            // list does not follow its own selection.
            .onChange(of: library.resultSelection) { _, selection in
                guard let selection else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
    }
}

/// The actions a result offers, shared by its context menu and its row menu.
///
/// The model arrives as a property rather than from the environment on purpose: menu
/// content is built in its own presentation context, and a missing environment value
/// there is a crash rather than a layout glitch.
struct DocumentActions: View {
    let library: LibraryModel
    let document: DocumentResult

    var body: some View {
        Button("Reveal in Finder", action: reveal)
        Button("Open in Default App", action: open)
        Divider()
        Button("Copy Path", action: copyPath)
        if document.hits.count > 1 {
            Divider()
            Button(library.isExpanded(document.documentID)
                   ? "Hide Matching Pages" : "Show Matching Pages") {
                library.toggleExpansion(document.documentID)
            }
        }
    }

    private func reveal() {
        library.resultSelection = .document(document.documentID)
        library.revealInFinder()
    }

    private func open() {
        library.resultSelection = .document(document.documentID)
        library.openInDefaultApp()
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.path, forType: .string)
    }
}

extension Notification.Name {
    /// Posted by the Find menu item; the search field listens for it.
    static let focusSearchField = Notification.Name("com.imadhy.papersift.focusSearchField")
}

extension View {
    func onReceive(of name: Notification.Name, perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { _ in action() }
    }
}
