import Foundation

/// Plain text, Markdown, and source code.
public struct PlainTextExtractor: TextExtractor {
    /// Anything whose bytes are already the text. Source code is in here because
    /// searching your own code next to your documents turns out to be the point.
    public let supportedExtensions: Set<String> = [
        "txt", "text", "me", "md", "markdown", "rst", "org", "csv", "tsv", "log",
        "json", "yaml", "yml", "toml", "ini", "conf", "plist",
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "cs", "java", "kt", "kts",
        "js", "jsx", "ts", "tsx", "vue", "py", "rb", "go", "rs", "php", "pl", "lua",
        "sh", "bash", "zsh", "fish", "sql", "css", "scss", "less", "tex", "bib",
    ]

    /// A log file can be enormous, and a search index is not a log viewer.
    public static let maximumBytes = 20 * 1_024 * 1_024

    public init() {}

    public func extract(from url: URL) throws -> [PageContent] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw ExtractionError.empty("\(url.lastPathComponent) is empty") }
        guard data.count <= Self.maximumBytes else {
            throw ExtractionError.unreadable(
                "\(url.lastPathComponent) is larger than \(Self.maximumBytes / 1_024 / 1_024) MB")
        }
        guard let text = Self.decode(data) else {
            throw ExtractionError.unreadable("\(url.lastPathComponent): unknown text encoding")
        }

        let isMarkdown = ["md", "markdown", "rst", "org"].contains(url.pathExtension.lowercased())
        return PageChunker.chunk(text).enumerated().map { index, chunk in
            PageContent(
                pageNumber: index + 1,
                body: chunk,
                title: isMarkdown ? Self.markdownHeadings(in: chunk) : "")
        }
    }

    /// UTF-8 covers almost everything; the rest is legacy encodings.
    ///
    /// Order matters more than it looks. `String(data:encoding: .utf16)` almost
    /// never fails — it reinterprets arbitrary bytes as UTF-16 code units — so
    /// trying it speculatively turns every Latin-1 file into mojibake. UTF-16 is
    /// therefore only considered when a byte-order mark says so, and the
    /// single-byte encodings that cannot fail come last.
    static func decode(_ data: Data) -> String? {
        // A byte-order mark is a hint, not a promise. UTF-16 decoding is lenient
        // enough to "succeed" on an odd number of bytes and hand back mojibake, so
        // the mark is only trusted when the length agrees with it and the result
        // holds no replacement characters. Otherwise fall through — a mislabelled
        // file belongs with the single-byte encodings.
        let bom = [UInt8](data.prefix(4))
        if bom.count >= 2, data.count % 2 == 0 {
            if bom[0] == 0xFF, bom[1] == 0xFE, let text = utf16(data, .utf16LittleEndian) {
                return text
            }
            if bom[0] == 0xFE, bom[1] == 0xFF, let text = utf16(data, .utf16BigEndian) {
                return text
            }
        }
        // UTF-16 without a mark: NUL is a perfectly valid UTF-8 byte, so trying
        // UTF-8 first would succeed and produce text riddled with holes. A quarter
        // of the sample being NUL means wide characters, not text.
        let sample = data.prefix(4_096)
        if data.count % 2 == 0, sample.count(where: { $0 == 0 }) > sample.count / 4 {
            if let text = utf16(data, .utf16LittleEndian) ?? utf16(data, .utf16BigEndian) {
                return text
            }
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        // CP1252 has undefined bytes and can still reject; Latin-1 accepts
        // anything, which is exactly why it is the last resort.
        for encoding: String.Encoding in [.windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    /// A UTF-16 decode that only counts if it produced real text.
    private static func utf16(_ data: Data, _ encoding: String.Encoding) -> String? {
        guard let text = String(data: data, encoding: encoding),
              !text.contains("\u{FFFD}") else { return nil }
        return text
    }

    /// `#`-prefixed lines are this format's headings — the same role the large type
    /// plays in a PDF.
    static func markdownHeadings(in text: String) -> String {
        text.split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("#") else { return nil }
                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return heading.isEmpty ? nil : heading
            }
            .joined(separator: " · ")
    }
}
