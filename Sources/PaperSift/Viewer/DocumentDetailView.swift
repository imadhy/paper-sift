import PaperSiftCore
import SwiftUI

/// The right column: the selected page, with a bar to walk through the other matches
/// in the same document.
struct DocumentDetailView: View {
    @Environment(LibraryModel.self) private var library
    /// 1 means "fit the width", which is where every document opens.
    @State private var zoom: Double = 1

    private static let zoomSteps: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    var body: some View {
        if let document = library.selectedDocument, let hit = library.selectedHit {
            VStack(spacing: 0) {
                header(document: document, hit: hit)
                PageViewer(document: document, hit: hit, zoom: zoom)
            }
            .onChange(of: document.documentID) { zoom = 1 }
        } else {
            placeholder
        }
    }

    // MARK: - Header

    private func header(document: DocumentResult, hit: PageHit) -> some View {
        HStack(spacing: Metrics.tight) {
            VStack(alignment: .leading, spacing: 1) {
                Text(document.filename)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Metrics.rowSpacing) {
                    // "Part" rather than "page" when the pages are our invention.
                    Text(document.isPDF
                         ? "page \(hit.pageNumber) of \(document.pageCount)"
                         : "part \(hit.pageNumber) of \(document.pageCount)")
                        .monospacedDigit()
                    if let rank = library.rank(of: hit) {
                        Text("· rank \(rank)").monospacedDigit()
                    }
                    if hit.fromOCR {
                        Label("OCR", systemImage: "text.viewfinder")
                    }
                }
                .captionStyle()
            }
            .help(document.path)

            Spacer(minLength: Metrics.tight)

            if document.hits.count > 1 { matchNavigator(document: document) }
            if document.isPDF { zoomControls }
            fileActions
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.tight)
        .glassGroup()
        .background(.bar)
    }

    /// Previous / next match, with the position between them — the same gesture as a
    /// browser's find bar, which is what this is.
    private func matchNavigator(document: DocumentResult) -> some View {
        HStack(spacing: Metrics.hairline) {
            // The shortcuts themselves live in the Results menu, so they work with the
            // focus in the search field too.
            Button("Previous matching page", systemImage: "chevron.up",
                   action: library.showPreviousHit)
                .disabled(library.selectedPageIndex == 0)
                .help("Previous matching page (⌘⌥↑)")

            Text("\(library.selectedPageIndex + 1) of \(document.hits.count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 46)
                .accessibilityLabel("Match \(library.selectedPageIndex + 1) of \(document.hits.count)")

            Button("Next matching page", systemImage: "chevron.down",
                   action: library.showNextHit)
                .disabled(library.selectedPageIndex >= document.hits.count - 1)
                .help("Next matching page (⌘⌥↓)")
        }
        .barControlStyle()
        .help("Walk through this document's matching pages")
    }

    private var zoomControls: some View {
        HStack(spacing: Metrics.hairline) {
            Button("Zoom out", systemImage: "minus.magnifyingglass") { step(-1) }
                .disabled(zoom <= Self.zoomSteps[0])
                .help("Zoom out (⌘−)")
                .keyboardShortcut("-", modifiers: .command)

            Button {
                zoom = 1
            } label: {
                Text(zoom == 1 ? "Fit" : "\(Int(zoom * 100))%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 34)
            }
            .help("Fit the width (⌘0)")
            .keyboardShortcut("0", modifiers: .command)
            .accessibilityLabel("Fit the width")

            Button("Zoom in", systemImage: "plus.magnifyingglass") { step(1) }
                .disabled(zoom >= Self.zoomSteps[Self.zoomSteps.count - 1])
                .help("Zoom in (⌘+)")
                .keyboardShortcut("+", modifiers: .command)
        }
        .barControlStyle()
    }

    private func step(_ direction: Int) {
        let current = Self.zoomSteps.firstIndex(of: zoom) ?? Self.zoomSteps.firstIndex(of: 1)!
        let next = min(max(0, current + direction), Self.zoomSteps.count - 1)
        zoom = Self.zoomSteps[next]
    }

    private var fileActions: some View {
        HStack(spacing: Metrics.hairline) {
            Button("Reveal in Finder", systemImage: "folder", action: library.revealInFinder)
                .help("Reveal in Finder")

            Button("Open in the default app", systemImage: "arrow.up.forward.app",
                   action: library.openInDefaultApp)
                .help("Open in the default app")
        }
        .barControlStyle()
    }

    // MARK: - Page

    /// Holds the OCR layout for the page on screen: a scan has no selectable text, so
    /// the highlights come from the stored word boxes instead.
    private struct PageViewer: View {
        @Environment(LibraryModel.self) private var library
        let document: DocumentResult
        let hit: PageHit
        let zoom: Double
        @State private var layout: OCRLayout?

        var body: some View {
            if document.isPDF {
                PDFViewerView(
                    url: document.url,
                    pageNumber: hit.pageNumber,
                    terms: hit.matchedText,
                    ocrLayout: layout,
                    zoom: zoom)
                    .id(document.documentID)
                    .task(id: hit.pageID) {
                        layout = await library.layout(for: hit)
                    }
            } else {
                TextReaderView(document: document, hit: hit)
            }
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            library.hasQuery ? "Pick a result" : "Nothing selected",
            systemImage: "doc.text.magnifyingglass",
            description: Text("The page opens here, with your words marked."))
    }
}
