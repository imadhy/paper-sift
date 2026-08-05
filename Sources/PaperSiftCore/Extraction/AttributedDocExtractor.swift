import AppKit
import Foundation

/// Word documents, RTF and OpenDocument text.
///
/// AppKit already reads all of these — `NSAttributedString(url:)` handles
/// officeOpenXML, RTF/RTFD and OpenDocument — which means no dependency, and the
/// text arrives with its fonts intact so `HeadingDetector` picks out the headings
/// exactly as it does for a PDF.
///
/// HTML is deliberately *not* here: AppKit imports it through WebKit, which wants
/// the main thread, and indexing runs anywhere but. `HTMLTextExtractor` handles it.
public struct AttributedDocExtractor: TextExtractor {
    public let supportedExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt"]

    public init() {}

    public func extract(from url: URL) throws -> [PageContent] {
        var documentAttributes: NSDictionary?
        guard let attributed = try? NSAttributedString(
            url: url, options: [:], documentAttributes: &documentAttributes)
        else { throw ExtractionError.unreadable("\(url.lastPathComponent) could not be opened") }

        let text = PDFTextExtractor.normalize(attributed.string)
        guard !text.isEmpty else {
            throw ExtractionError.empty("\(url.lastPathComponent) holds no readable text")
        }

        // Chunk the plain text, then map each chunk back onto the attributed
        // string, so a chunk's headings are the ones that live inside it.
        let source = attributed.string
        var offset = 0
        return PageChunker.chunk(text).enumerated().map { index, chunk in
            var title = ""
            let length = min(chunk.count, max(0, attributed.length - offset))
            if length > 0 {
                title = HeadingDetector.headings(
                    in: attributed.attributedSubstring(
                        from: NSRange(location: offset, length: length)))
            }
            // Chunking collapses whitespace, so this walk drifts on documents with
            // heavy blank space; headings stay approximate rather than wrong.
            offset = min(offset + chunk.count, source.utf16.count)
            return PageContent(pageNumber: index + 1, body: chunk, title: title)
        }
    }
}

/// HTML, without WebKit.
///
/// Tags are stripped by hand rather than handed to AppKit: the AppKit importer
/// needs the main thread, and it would drag a whole web engine into a background
/// indexing pass.
public struct HTMLTextExtractor: TextExtractor {
    public let supportedExtensions: Set<String> = ["html", "htm", "xhtml"]

    public init() {}

    public func extract(from url: URL) throws -> [PageContent] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let markup = PlainTextExtractor.decode(data) else {
            throw ExtractionError.unreadable("\(url.lastPathComponent): unknown text encoding")
        }

        let title = Self.firstMatch(in: markup, pattern: "<title[^>]*>(.*?)</title>")
            ?? Self.firstMatch(in: markup, pattern: "<h1[^>]*>(.*?)</h1>")
            ?? ""
        let text = Self.strippingTags(markup)
        guard !text.isEmpty else { throw ExtractionError.empty(url.lastPathComponent) }

        return PageChunker.chunk(text).enumerated().map { index, chunk in
            // The document title belongs to the first chunk only, or every page of
            // a long page would claim the same heading.
            PageContent(pageNumber: index + 1, body: chunk,
                        title: index == 0 ? Self.strippingTags(title) : "")
        }
    }

    static func strippingTags(_ markup: String) -> String {
        var text = markup
        for pattern in ["<script[^>]*>[\\s\\S]*?</script>", "<style[^>]*>[\\s\\S]*?</style>",
                        "<!--[\\s\\S]*?-->"] {
            text = text.replacingOccurrences(
                of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Block-level tags become spaces so words on either side stay separate.
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodingEntities(text)
        return PDFTextExtractor.normalize(text)
    }

    private static func decodingEntities(_ text: String) -> String {
        var output = text
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–",
            "&rsquo;": "’", "&lsquo;": "‘", "&eacute;": "é", "&egrave;": "è", "&agrave;": "à",
        ]
        for (entity, replacement) in entities {
            output = output.replacingOccurrences(of: entity, with: replacement,
                                                 options: .caseInsensitive)
        }
        return output
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(
                in: text, range: NSRange(location: 0, length: text.utf16.count)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
