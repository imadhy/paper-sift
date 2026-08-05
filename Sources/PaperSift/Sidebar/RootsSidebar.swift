import PaperSiftCore
import SwiftUI

/// The left column: which folders are indexed, what the indexer is doing, and the
/// button that adds another one.
///
/// The scope rows are a `SearchScope` rather than an optional root id — see the
/// comment on that enum for why "All folders" used to be a one-way door.
struct RootsSidebar: View {
    @Environment(LibraryModel.self) private var library
    @State private var showingStatus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            scopeList
            indexStatus
        }
        .frame(minWidth: Metrics.sidebarMinWidth)
    }

    private var scopeList: some View {
        // Clicking past the last row hands back nil; searching everything is the right
        // answer to "no folder in particular".
        List(selection: Binding<SearchScope?>(
            get: { library.scope },
            set: { library.scope = $0 ?? .all })
        ) {
            Section("Library") {
                Label("All folders", systemImage: "square.stack.3d.up.fill")
                    .badge(library.stats.documents)
                    .tag(SearchScope.all)

                ForEach(library.roots) { root in
                    Label(root.name, systemImage: "folder.fill")
                        .badge(documentCount(of: root))
                        .help(root.path)
                        .tag(SearchScope.root(root.id))
                        .contextMenu {
                            Button("Rescan Now") {
                                Task { await library.rescan() }
                            }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([root.url])
                            }
                            Divider()
                            Button("Remove from Index", role: .destructive) {
                                Task { await library.removeFolder(root) }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func documentCount(of root: Root) -> Int {
        library.rootStats.first { $0.rootID == root.id }?.documents ?? 0
    }

    // MARK: - Footer

    private var indexStatus: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            activity

            if library.stats.unreadable > 0 {
                Button {
                    showingStatus = true
                } label: {
                    Label(library.unreadableSummary, systemImage: library.stats.failed > 0
                          ? "exclamationmark.triangle.fill" : "questionmark.square.dashed")
                        .font(.caption)
                        .foregroundStyle(library.stats.failed > 0 ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help("Open Index status to see which files, and why")
            }

            HStack(spacing: Metrics.rowSpacing) {
                Button {
                    Task { await library.addFolder() }
                } label: {
                    Label("Add Folder", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .glassButton(prominent: true)

                Button("Index status", systemImage: "info.circle") {
                    showingStatus = true
                }
                .labelStyle(.iconOnly)
                .glassButton()
                .help("Index status")
                .popover(isPresented: $showingStatus, arrowEdge: .trailing) {
                    IndexStatusView()
                        .environment(library)
                }
            }
            .glassGroup()
            .controlSize(.large)
        }
        .padding(Metrics.tight)
    }

    @ViewBuilder
    private var activity: some View {
        if library.isBusy, let label = library.activityLabel {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Metrics.rowSpacing) {
                    Text(label)
                        .captionStyle()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button(library.progress.isPaused ? "Resume indexing" : "Pause indexing",
                           systemImage: library.progress.isPaused ? "play.fill" : "pause.fill") {
                        Task { await library.pauseOrResumeIndexing() }
                    }
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .help(library.progress.isPaused ? "Resume indexing" : "Pause indexing")
                }
                // An indeterminate bar rather than a spinner: it reads as "still
                // going" from the corner of the eye, which is all it has to say.
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .opacity(library.progress.isPaused ? 0.25 : 1)
                if let filename = library.progress.currentFilename {
                    Text(filename)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, Metrics.tight)
            .padding(.vertical, Metrics.rowSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        } else {
            Text("\(library.stats.documents.formatted()) documents · \(library.stats.pages.formatted()) pages")
                .captionStyle()
                .padding(.horizontal, Metrics.hairline)
        }
    }
}
