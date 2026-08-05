import PaperSiftCore
import SwiftUI

/// The detail behind the sidebar's one-line status: what is queued, what failed,
/// and how far each folder has got.
struct IndexStatusView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            HStack {
                Text("Index Status").font(.headline)
                Spacer()
                Button {
                    Task { await library.pauseOrResumeIndexing() }
                } label: {
                    Label(
                        library.progress.isPaused ? "Resume" : "Pause",
                        systemImage: library.progress.isPaused ? "play.fill" : "pause.fill")
                }
                .disabled(!library.progress.isRunning && library.stats.outstanding == 0)
                Button("Rescan") {
                    Task { await library.rescan() }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: Metrics.tight, verticalSpacing: 4) {
                row("Searchable", "\(library.stats.indexed.formatted()) documents")
                row("Pages", "\(library.stats.pages.formatted()) · \(library.stats.ocrPages.formatted()) from OCR")
                if library.stats.pending > 0 {
                    row("To read", "\(library.stats.pending.formatted()) documents")
                }
                if library.stats.ocrPending > 0 {
                    row("To recognize",
                        "\(library.stats.ocrPagesPending.formatted()) pages "
                            + "in \(library.stats.ocrPending.formatted()) documents")
                }
                if library.stats.empty > 0 {
                    row("No text inside", "\(library.stats.empty.formatted()) documents")
                }
                if library.stats.failed > 0 {
                    row("Unreadable", "\(library.stats.failed.formatted()) documents")
                }
                if library.stats.unsupported > 0 {
                    row("Unsupported", "\(library.stats.unsupported.formatted()) documents")
                }
                row("Index size", library.stats.databaseBytes.formatted(.byteCount(style: .file)))
            }

            if library.progress.isRunning {
                HStack(spacing: 6) {
                    Text(phaseLabel).captionStyle()
                    Text(library.progress.currentFilename ?? "starting…")
                        .captionStyle()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if library.progress.ocrPages > 0 {
                    Text("\(library.progress.ocrPages.formatted()) pages recognized this session")
                        .captionStyle()
                }
            }

            if !library.failures.isEmpty {
                Divider()
                HStack {
                    Text("Not searchable")
                        .font(.callout)
                    Spacer()
                    Button("Try Again") {
                        Task { await library.retryFailures() }
                    }
                    .help("Re-reads them — worth a try after updating PaperSift")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(library.failures) { document in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(document.filename)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(document.error ?? "unknown reason")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .help(document.path)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }

            if !library.rootStats.isEmpty {
                Divider()
                ForEach(library.rootStats) { root in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(root.name).font(.callout)
                            Spacer()
                            Text("\(root.indexed.formatted())/\(root.documents.formatted())")
                                .captionStyle()
                                .monospacedDigit()
                        }
                        if root.progress < 1 {
                            ProgressView(value: root.progress)
                        }
                    }
                    .help(root.path)
                }
            }
        }
        .padding(Metrics.gutter)
        .frame(width: 360)
        .overlay(refreshTicker)
    }

    private var phaseLabel: String {
        switch library.progress.phase {
        case .idle: ""
        case .text: "Reading"
        case .ocr: "Recognizing"
        }
    }

    /// The status popover is the one place that must never look stale.
    private var refreshTicker: some View {
        Color.clear.frame(height: 0)
            .task {
                while !Task.isCancelled {
                    await library.refreshRootStats()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).captionStyle()
            Text(value).font(.callout).monospacedDigit()
        }
    }
}
