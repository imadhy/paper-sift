import Foundation
import PDFKit

/// Office and iWork formats that are really zip archives.
///
/// Best-effort, and honest about it:
///
/// * `pptx` / `xlsx` / `odp` / `ods` — the text lives in XML inside the archive,
///   so the tags are stripped and what is left is indexed. Slide and cell order is
///   preserved; layout is not.
/// * `pages` / `key` / `numbers` — modern iWork stores compressed protobuf, which
///   is not readable this way. But the bundles usually carry a Quick Look preview
///   PDF, and that *is* readable, so it gets handed to `PDFTextExtractor`.
///
/// `unzip` does the unpacking: it ships with macOS, and pulling in an archive
/// library for one feature is a poor trade.
public struct ZipXMLExtractor: TextExtractor {
    public let supportedExtensions: Set<String> = [
        "pptx", "xlsx", "odp", "ods", "pages", "key", "numbers",
    ]

    private static let unzip = "/usr/bin/unzip"

    public init() {}

    public func extract(from url: URL) throws -> [PageContent] {
        let ext = url.pathExtension.lowercased()

        if ["pages", "key", "numbers"].contains(ext) {
            return try extractFromPreview(url)
        }

        let members: [String]
        switch ext {
        case "pptx": members = ["ppt/slides/slide*.xml"]
        case "xlsx": members = ["xl/sharedStrings.xml", "xl/worksheets/sheet*.xml"]
        default: members = ["content.xml"]  // OpenDocument
        }

        var pieces: [String] = []
        for member in members {
            let xml = try Self.read(member: member, from: url)
            guard !xml.isEmpty else { continue }
            let text = HTMLTextExtractor.strippingTags(xml)
            if !text.isEmpty { pieces.append(text) }
        }
        let joined = pieces.joined(separator: "\n\n")
        guard !joined.isEmpty else { throw ExtractionError.empty("\(url.lastPathComponent) holds no readable text") }

        return PageChunker.chunk(joined).enumerated().map {
            PageContent(pageNumber: $0.offset + 1, body: $0.element)
        }
    }

    /// iWork bundles ship a Quick Look PDF; that is the only text we can reach.
    private func extractFromPreview(_ url: URL) throws -> [PageContent] {
        let candidates = ["QuickLook/Preview.pdf", "preview.pdf", "Data/Preview.pdf"]
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("papersift-preview-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }

        for candidate in candidates {
            guard let data = try? Self.readData(member: candidate, from: url), !data.isEmpty
            else { continue }
            try data.write(to: temporary)
            let pages = try PDFTextExtractor().extract(from: temporary)
            guard !pages.isEmpty else { continue }
            return pages
        }
        throw ExtractionError.unsupportedFormat(
            "\(url.lastPathComponent): iWork files only expose their text through a "
                + "Quick Look preview, and this one carries none")
    }

    private static func read(member: String, from url: URL) throws -> String {
        let data = try readData(member: member, from: url)
        return PlainTextExtractor.decode(data) ?? ""
    }

    /// `unzip -p` streams a member to stdout without unpacking the archive.
    private static func readData(member: String, from url: URL) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: unzip) else {
            throw ExtractionError.unsupportedFormat("zip archives cannot be read: /usr/bin/unzip is missing")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: unzip)
        process.arguments = ["-p", url.path, member]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw ExtractionError.unreadable("\(url.lastPathComponent) could not be unpacked: \(error)")
        }
        // Read before waiting: a large member would fill the pipe and deadlock.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}
