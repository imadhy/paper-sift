import Foundation

/// Why a file could not be turned into pages.
///
/// The payload is the whole sentence the user will read, composed where the
/// problem is known — assembling it here produced messages like "no extractor
/// handles .pages (no readable Quick Look preview inside) files". The case still
/// carries the meaning, which is what decides whether a document is a failure or
/// simply has nothing in it.
public enum ExtractionError: Error, CustomStringConvertible {
    /// The format is beyond us.
    case unsupportedFormat(String)
    /// The file should have been readable and was not.
    case unreadable(String)
    case encrypted(String)
    /// A perfectly valid file with no text in it — not a failure.
    case empty(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let message), .unreadable(let message),
             .encrypted(let message), .empty(let message):
            message
        }
    }

    /// `empty` means "nothing to index", which is not the same as "broken".
    public var isFailure: Bool {
        if case .empty = self { return false }
        return true
    }
}

/// Turns a file into indexable pages.
///
/// Implementations must be cheap to create and safe to call from any thread —
/// the indexer runs several of them at once, one per document.
public protocol TextExtractor: Sendable {
    /// Lowercased extensions this extractor claims, without the dot.
    var supportedExtensions: Set<String> { get }

    /// Pages in document order. Pages may legitimately come back with an empty
    /// body — that is how a scan announces itself to the OCR queue.
    func extract(from url: URL) throws -> [PageContent]
}

/// Dispatches a file to whichever extractor claims its extension.
public struct ExtractorRegistry: Sendable {
    private let extractors: [any TextExtractor]

    public init(_ extractors: [any TextExtractor]) {
        self.extractors = extractors
    }

    /// Everything PaperSift can read today. Order matters only in that the first
    /// extractor claiming an extension wins.
    public static let `default` = ExtractorRegistry([
        PDFTextExtractor(),
        PlainTextExtractor(),
        AttributedDocExtractor(),
        HTMLTextExtractor(),
        ZipXMLExtractor(),
    ])

    public var indexableExtensions: Set<String> {
        extractors.reduce(into: Set<String>()) { $0.formUnion($1.supportedExtensions) }
    }

    public func extractor(for url: URL) -> (any TextExtractor)? {
        let ext = url.pathExtension.lowercased()
        return extractors.first { $0.supportedExtensions.contains(ext) }
    }

    public func extract(from url: URL) throws -> [PageContent] {
        guard let extractor = extractor(for: url) else {
            throw ExtractionError.unsupportedFormat(
                "PaperSift cannot read .\(url.pathExtension.lowercased()) files")
        }
        return try extractor.extract(from: url)
    }
}
