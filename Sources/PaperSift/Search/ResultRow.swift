import PaperSiftCore
import SwiftUI

/// One document in the results list: what it is, when you last touched it, and the
/// passage that answered the query.
///
/// The row is also the way into the document's other matches — the chevron opens the
/// page list underneath it, so a 486-page contract stops being one line and becomes
/// the nine places your words actually appear.
struct DocumentResultRow: View {
    @Environment(LibraryModel.self) private var library
    let document: DocumentResult

    private var isExpanded: Bool { library.isExpanded(document.documentID) }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.tight) {
            disclosure
            DocumentThumbnail(document: document)
            VStack(alignment: .leading, spacing: Metrics.hairline) {
                title
                metadata
                SnippetText(snippet: document.bestHit.snippet, font: .callout, selectable: false)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                footnote
            }
        }
        .padding(.vertical, Metrics.rowSpacing)
        .help(document.path + "\n\n" + scoreExplanation)
    }

    @ViewBuilder
    private var disclosure: some View {
        if document.hits.count > 1 {
            Button(isExpanded ? "Hide the other matches" : "Show every matching page",
                   systemImage: "chevron.right",
                   action: toggle)
                .labelStyle(.iconOnly)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 15, height: 15)
                .contentShape(.rect)
                .buttonStyle(.plain)
                .padding(.top, 2)
        } else {
            // Keeps single-match rows aligned with the ones that can open.
            Color.clear
                .frame(width: 15, height: 15)
                .accessibilityHidden(true)
        }
    }

    private var title: some View {
        HStack(spacing: Metrics.hairline) {
            Text(document.filename)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if document.bestHit.fromOCR {
                Image(systemName: "text.viewfinder")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help("Read by OCR — this document is a scan")
                    .accessibilityLabel("Read by OCR")
            }
            Spacer(minLength: Metrics.hairline)
            actions
        }
    }

    private var metadata: some View {
        HStack(alignment: .top, spacing: 14) {
            MetadataItem(label: "Modified", value: document.modifiedAt.resultRowFormat)
            if document.size > 0 {
                MetadataItem(label: "Size", value: document.size.fileSizeFormat)
            }
            MetadataItem(
                label: document.isPDF ? "Pages" : "Parts",
                value: document.pageCount.formatted())
        }
    }

    private var footnote: some View {
        HStack(spacing: Metrics.rowSpacing) {
            if document.hits.count > 1 {
                Button(action: toggle) {
                    Chip(
                        text: "\(document.hits.count) matching pages",
                        symbol: isExpanded ? "chevron.up" : "list.number")
                }
                .buttonStyle(.plain)
            } else {
                Chip(text: "page \(document.bestHit.pageNumber)", symbol: "doc.text.magnifyingglass")
            }
            Text(document.folder)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private var actions: some View {
        Menu("Actions for \(document.filename)", systemImage: "ellipsis") {
            DocumentActions(library: library, document: document)
        }
        .labelStyle(.iconOnly)
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.22)) {
            library.toggleExpansion(document.documentID)
        }
    }

    /// The ranking is not a black box: hovering a result says why it is here.
    private var scoreExplanation: String {
        let hit = document.bestHit
        let breakdown = hit.breakdown
        return String(
            format: """
            score %.2f
            terms found: %d of %d
            relevance %.2f · proximity %.2f · density %.2f
            heading %.2f · recency %.2f
            """,
            hit.score, hit.matchedTermCount, hit.queryTermCount,
            breakdown.relevance, breakdown.proximity, breakdown.density,
            breakdown.title, breakdown.recency)
    }
}

/// One matching page under its document: which page, where it landed in the overall
/// ordering, and the line it matched on.
struct PageHitRow: View {
    let hit: PageHit
    let rank: Int?
    let isPDF: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.tight) {
            Image(systemName: hit.fromOCR ? "text.viewfinder" : "doc.text")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(isPDF ? "Page \(hit.pageNumber)" : "Part \(hit.pageNumber)")
                    .font(.callout)
                    .monospacedDigit()
                SnippetText(snippet: hit.snippet, font: .caption, selectable: false)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Metrics.hairline)
            if let rank {
                Chip(text: "Rank \(rank)", emphasis: rank <= 3 ? .primary : .secondary)
                    .help("This page is number \(rank) across every result")
            }
        }
        .padding(.leading, 22)
        .padding(.vertical, 3)
    }
}
