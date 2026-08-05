import Foundation

/// One indexable page of a document.
///
/// Extractors fill `body`, `title` and — for PDFs without a text layer —
/// nothing at all, leaving the page for the OCR queue. `lemmas` is filled by the
/// indexer right before the page is written, never by the extractor.
public struct PageContent: Sendable, Equatable {
    /// 1-based, as shown to the user.
    public var pageNumber: Int
    /// Full text of the page.
    public var body: String
    /// Text that looked like a heading (large or bold). Weighted up when ranking.
    public var title: String
    /// Space-joined lemmas of `body`, so "children" finds "child".
    public var lemmas: String
    /// Whether `body` came out of OCR rather than the file's own text layer.
    public var fromOCR: Bool
    /// Encoded word boxes, for highlighting matches on OCR'd pages.
    public var layout: Data?

    public init(
        pageNumber: Int,
        body: String,
        title: String = "",
        lemmas: String = "",
        fromOCR: Bool = false,
        layout: Data? = nil
    ) {
        self.pageNumber = pageNumber
        self.body = body
        self.title = title
        self.lemmas = lemmas
        self.fromOCR = fromOCR
        self.layout = layout
    }

    /// A page with almost no text is a scan: worth sending to OCR.
    public var looksLikeScan: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).count < 30
    }
}

/// A page as stored, without its text.
public struct PageRef: Sendable, Identifiable, Equatable {
    public let id: Int64
    public let documentID: Int64
    public let pageNumber: Int
    public let charCount: Int
    public let fromOCR: Bool

    public init(id: Int64, documentID: Int64, pageNumber: Int, charCount: Int, fromOCR: Bool) {
        self.id = id
        self.documentID = documentID
        self.pageNumber = pageNumber
        self.charCount = charCount
        self.fromOCR = fromOCR
    }
}
