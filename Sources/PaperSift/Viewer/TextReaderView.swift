import PaperSiftCore
import SwiftUI

/// The detail pane for documents that have no pages of their own.
///
/// A text file or a Word document was split into chunks at indexing time, so there
/// is no page to render — the chunk is shown as text instead, with every match
/// marked, and the real file is one click away.
struct TextReaderView: View {
    @Environment(LibraryModel.self) private var library
    let document: DocumentResult
    let hit: PageHit

    @State private var snippet: Snippet?

    var body: some View {
        ScrollView {
            if let snippet {
                SnippetText(snippet: snippet, font: .system(.body, design: bodyDesign))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.gutter)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .padding(Metrics.gutter * 2)
            }
        }
        .task(id: hit.pageID) {
            snippet = await library.pageSnippet(for: hit)
        }
    }

    /// Code reads better monospaced, prose does not.
    private var bodyDesign: Font.Design {
        let ext = document.url.pathExtension.lowercased()
        let prose: Set<String> = [
            "txt", "text", "me", "md", "markdown", "rst", "org",
            "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "xhtml",
            "pptx", "xlsx", "odp", "ods", "pages", "key", "numbers",
        ]
        return prose.contains(ext) ? .default : .monospaced
    }
}
