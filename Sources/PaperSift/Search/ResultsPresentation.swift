import Foundation
import PaperSiftCore

/// Which folder a search covers.
///
/// An enum rather than an optional id, because the results list is a `List` with a
/// selection: a row tagged `Int64?.none` can never equal a non-optional selection
/// value, so "All folders" was drawn but could not be clicked — once you had scoped
/// a search to one folder there was no way back. `.all` is a real, selectable case.
enum SearchScope: Hashable {
    case all
    case root(Int64)

    init(rootID: Int64?) {
        self = rootID.map(SearchScope.root) ?? .all
    }

    var rootID: Int64? {
        switch self {
        case .all: nil
        case .root(let id): id
        }
    }
}

/// What the results list highlights.
///
/// A document row and one of its page rows both point at a page, but they are not
/// the same selection: clicking the document means "your best page", clicking a page
/// row means "that one". The list needs to know which of the two to draw.
enum ResultSelection: Hashable {
    case document(Int64)
    case page(document: Int64, pageID: Int64)

    var documentID: Int64 {
        switch self {
        case .document(let id): id
        case .page(let id, _): id
        }
    }
}

/// How the results column orders documents.
enum ResultSort: String, CaseIterable, Identifiable {
    case relevance
    case name
    case modified
    case size
    case matchingPages

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relevance: "Best match"
        case .name: "Name"
        case .modified: "Date modified"
        case .size: "File size"
        case .matchingPages: "Matching pages"
        }
    }

    var symbol: String {
        switch self {
        case .relevance: "sparkle.magnifyingglass"
        case .name: "textformat.abc"
        case .modified: "calendar"
        case .size: "internaldrive"
        case .matchingPages: "doc.on.doc"
        }
    }

    /// Applies the order. Reversing is left to the caller so the menu can offer it
    /// for every field without five more cases.
    func apply(to documents: [DocumentResult]) -> [DocumentResult] {
        switch self {
        case .relevance:
            // The ranker already sorted these, and re-sorting on `score` would
            // throw away its tie-break on modification date.
            return documents
        case .name:
            return documents.sorted {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
        case .modified:
            return documents.sorted { $0.modifiedAt > $1.modifiedAt }
        case .size:
            return documents.sorted { $0.size > $1.size }
        case .matchingPages:
            return documents.sorted { $0.hits.count > $1.hits.count }
        }
    }
}
