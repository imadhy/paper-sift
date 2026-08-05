import AppKit
import Foundation
import PDFKit

/// Reads a PDF's own text layer, one `PageContent` per page.
///
/// Pages that come back empty are not a failure: they are scans, and the OCR
/// queue picks them up from there.
public struct PDFTextExtractor: TextExtractor {
    public let supportedExtensions: Set<String> = ["pdf"]

    public init() {}

    public func extract(from url: URL) throws -> [PageContent] {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.unreadable("\(url.lastPathComponent) could not be opened")
        }
        if document.isLocked, !document.unlock(withPassword: "") {
            throw ExtractionError.encrypted("\(url.lastPathComponent) is password-protected")
        }
        guard document.pageCount > 0 else { throw ExtractionError.empty("\(url.lastPathComponent) has no pages") }

        return (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let body = PDFTextExtractor.normalize(page.string ?? "")
            let title = page.attributedString.map { HeadingDetector.headings(in: $0) } ?? ""
            return PageContent(pageNumber: index + 1, body: body, title: title)
        }
    }

    /// PDF text arrives with hard line breaks wherever the typesetter wrapped.
    /// Rejoin hyphenated words, then collapse whitespace so snippets read like
    /// sentences and proximity scoring sees real word distances.
    public static func normalize(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var text = raw.replacingOccurrences(of: "\u{00AD}", with: "")  // soft hyphen
        text = text.replacingOccurrences(
            of: "([a-zà-ÿ])-\\s*\\n\\s*([a-zà-ÿ])",
            with: "$1$2",
            options: [.regularExpression])
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Picks out the text on a page that reads like a heading.
///
/// The trick is that "big" is relative: we take the font size carrying the most
/// characters as the page's body size, then keep runs that are noticeably larger,
/// or bold at body size. Short runs only — a bold paragraph is not a title.
public enum HeadingDetector {
    public static func headings(in attributed: NSAttributedString, maxLength: Int = 400) -> String {
        guard attributed.length > 0 else { return "" }

        var charactersPerSize: [Double: Int] = [:]
        var runs: [(text: String, size: Double, bold: Bool)] = []
        let whole = NSRange(location: 0, length: attributed.length)

        attributed.enumerateAttribute(.font, in: whole, options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let size = (font.pointSize * 10).rounded() / 10
            charactersPerSize[size, default: 0] += range.length
            runs.append((
                text: attributed.attributedSubstring(from: range).string,
                size: size,
                bold: font.fontDescriptor.symbolicTraits.contains(.bold)))
        }

        // Most characters wins; on a tie the smaller size is the body text.
        guard let bodySize = charactersPerSize
            .max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key
        else { return "" }

        var headings: [String] = []
        var seen = Set<String>()
        for run in runs {
            let text = PDFTextExtractor.normalize(run.text)
            guard !text.isEmpty, text.count <= 120 else { continue }
            let isLarger = run.size >= bodySize * 1.15
            let isBold = run.bold && run.size >= bodySize
            guard isLarger || isBold, seen.insert(text).inserted else { continue }
            headings.append(text)
        }

        let joined = headings.joined(separator: " · ")
        guard joined.count > maxLength else { return joined }
        return String(joined.prefix(maxLength))
    }
}
