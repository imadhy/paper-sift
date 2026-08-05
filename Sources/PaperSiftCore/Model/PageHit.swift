import Foundation

/// A piece of a page's text with the matched words marked.
///
/// `highlights` are UTF-16 offset ranges into `text`, which is what
/// `NSAttributedString` and `String.Index(utf16Offset:in:)` both speak.
public struct Snippet: Sendable, Equatable {
    public var text: String
    public var highlights: [Range<Int>]

    public init(text: String, highlights: [Range<Int>]) {
        self.text = text
        self.highlights = highlights
    }

    public static let empty = Snippet(text: "", highlights: [])
}

extension String {
    /// Substring by UTF-16 offsets — the currency `Snippet.highlights` uses.
    /// Returns `nil` rather than trapping when the range is out of bounds.
    public func utf16Substring(start: Int, length: Int) -> String? {
        guard start >= 0, length >= 0, start + length <= utf16.count else { return nil }
        let from = String.Index(utf16Offset: start, in: self)
        let to = String.Index(utf16Offset: start + length, in: self)
        guard from <= to else { return nil }
        return String(self[from..<to])
    }
}

/// Why the ranker put a page where it did. Shown in the UI as a tooltip, and the
/// reason the weights are tunable rather than magic.
public struct ScoreBreakdown: Sendable, Equatable {
    public var relevance = 0.0
    public var coverage = 0.0
    public var proximity = 0.0
    public var density = 0.0
    public var title = 0.0
    public var recency = 0.0

    public init() {}
}

/// One page that matched, scored.
public struct PageHit: Sendable, Identifiable, Equatable {
    public var id: Int64 { pageID }

    public let pageID: Int64
    public let documentID: Int64
    public let pageNumber: Int
    public let score: Double
    public let breakdown: ScoreBreakdown
    public let snippet: Snippet
    public let fromOCR: Bool
    /// The words as they appear on the page — what the viewer highlights.
    public let matchedText: [String]
    /// How many query terms this page carries, out of how many were asked for.
    public let matchedTermCount: Int
    public let queryTermCount: Int
}

/// A document, with its best pages.
public struct DocumentResult: Sendable, Identifiable, Equatable {
    public var id: Int64 { documentID }

    public let documentID: Int64
    public let path: String
    public let filename: String
    public let modifiedAt: Date
    public let pageCount: Int
    /// Bytes on disk, as the last scan saw them.
    public let size: Int64
    /// Score of the best page — what documents are sorted by.
    public let score: Double
    /// Matching pages, best first.
    public let hits: [PageHit]

    public var url: URL { URL(fileURLWithPath: path) }
    public var bestHit: PageHit { hits[0] }
    public var folder: String { url.deletingLastPathComponent().path }
    /// PDFs open in the page viewer; everything else in the text reader, because
    /// its "pages" are chunks we invented rather than pages someone laid out.
    public var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }
}

public struct SearchResults: Sendable {
    public var query: ParsedQuery
    /// The best documents, capped by the caller's limit.
    public var documents: [DocumentResult]
    /// Where each returned page sits in the overall ordering, by page id, 1-based.
    ///
    /// Grouping by document hides how a page compares to the pages of every *other*
    /// document — "page 12 is the second best page you have" is exactly what makes a
    /// long document's list of matches readable. Computed once here rather than in
    /// the views, which would re-sort every hit on each redraw.
    public var pageRanks: [Int64: Int] = [:]
    /// How many documents matched in total — `documents` may be a prefix of that.
    public var documentCount: Int
    /// Matching pages across every matched document, not only the ones returned.
    public var pageCount: Int
    /// True when FTS5 could not express the query and we scanned page bodies.
    public var usedScan: Bool
    /// True when the recall stage returned as many rows as it was allowed, so
    /// there may be more matches beyond the shortlist.
    public var truncated: Bool
    public var duration: Duration

    public var isEmpty: Bool { documents.isEmpty }

    /// This page's place in the overall ordering, 1 for the best page found.
    public func rank(ofPage pageID: Int64) -> Int? { pageRanks[pageID] }

    /// Numbers every returned page by score, best first — ties broken by the page
    /// number so the same query always produces the same list.
    public static func ranks(across documents: [DocumentResult]) -> [Int64: Int] {
        let ordered = documents
            .flatMap(\.hits)
            .sorted { ($0.score, -Double($0.pageNumber)) > ($1.score, -Double($1.pageNumber)) }
        return Dictionary(
            uniqueKeysWithValues: ordered.enumerated().map { ($0.element.pageID, $0.offset + 1) })
    }

    public static func empty(query: ParsedQuery) -> SearchResults {
        SearchResults(query: query, documents: [], documentCount: 0, pageCount: 0,
                      usedScan: false, truncated: false, duration: .zero)
    }
}
