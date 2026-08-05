import AppKit
import Foundation
import PaperSiftCore

enum FormatChecks {
    static let cases: [(String, @Sendable (TestRun) async throws -> Void)] = [
        ("Long text is cut into chunks on paragraph seams", chunking),
        ("Plain text and Markdown are indexed, headings included", plainText),
        ("Unknown encodings are decoded rather than dropped", encodings),
        ("RTF and Word documents come through AppKit", attributedFormats),
        ("HTML loses its tags, keeps its title", htmlStripping),
        ("A pptx is read out of the archive", officeArchive),
        ("Source code is searchable, build folders are not", codeAndSkippedFolders),
        ("A text file is searchable end to end", endToEndText),
        ("A lying byte-order mark does not lose the file", brokenBOM),
        ("Files with nothing in them are not failures", emptyIsNotFailure),
        ("A short text file is short, not a scan", shortTextIsNotAScan),
        ("An unreadable format is not an unreadable file", unsupportedIsNotFailed),
    ]

    /// A folder of Pages documents used to report a dozen "could not be read"
    /// errors. The files are fine; the format is the problem, and the two deserve
    /// different words and different counters.
    static func unsupportedIsNotFailed(_ run: TestRun) async throws {
        let directory = tempDirectory("iwork")
        let staging = directory.appendingPathComponent("staging/Index", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02]).write(to: staging.appendingPathComponent("Document.iwa"))

        // A .pages bundle with no Quick Look preview inside — the modern layout.
        let archive = directory.appendingPathComponent("lettre.pages")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", archive.path, "Index"]
        zip.currentDirectoryURL = directory.appendingPathComponent("staging")
        try zip.run()
        zip.waitUntilExit()

        let store = try makeStore()
        let coordinator = IndexCoordinator(store: store, concurrency: 1)
        try await coordinator.addFolder(directory)
        _ = try await coordinator.runUntilIdle()

        let stats = try await store.stats()
        await run.equal(stats.failed, 0, "the file is not broken")
        await run.equal(stats.unsupported, 1)
        await run.equal(stats.unreadable, 1, "it is still not searchable, and says so")

        let listed = try await store.unreadableDocuments()
        await run.equal(listed.count, 1)
        await run.expect(listed.first?.error?.contains("Quick Look") == true,
                         "the reason must explain itself, got '\(listed.first?.error ?? "")'")

        // "Try Again" covers unsupported formats too: a new version may read them.
        await run.equal(try await store.retryFailures(), 1)
        await run.equal(try await store.stats().pending, 1)
    }

    /// The regression this pins down: any non-PDF whose text ran under the
    /// scan threshold was queued for OCR, handed to `PDFDocument(url:)`, and
    /// reported as "could not be read" — for a file that had been read fine.
    static func shortTextIsNotAScan(_ run: TestRun) async throws {
        let directory = tempDirectory("short-text")
        try "Back at 14h.".write(to: directory.appendingPathComponent("readme.txt"),
                                 atomically: true, encoding: .utf8)
        try "<html><head><title>App layout</title></head><body><p>Hi</p></body></html>".write(
            to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let store = try makeStore()
        let coordinator = IndexCoordinator(store: store, concurrency: 2)
        try await coordinator.addFolder(directory)
        let progress = try await coordinator.runUntilIdle()

        await run.equal(progress.failed, 0, "neither file is broken")
        await run.equal(progress.indexed, 2)
        await run.equal(try await store.queueDepth(kind: .ocr), 0,
                        "a text file has no page to rasterize")

        let stats = try await store.stats()
        await run.equal(stats.indexed, 2)
        await run.equal(stats.ocrPending, 0)
        await run.equal(stats.failed, 0)

        // And they are searchable, which is the point.
        let engine = SearchEngine(store: store)
        await run.equal(try await engine.search("14h").documents.count, 1)
        await run.equal(try await engine.search("layout").documents.count, 1)
    }

    static func brokenBOM(_ run: TestRun) async throws {
        // A UTF-16 BOM on something that is not UTF-16 (odd byte count here).
        // Trusting the mark and giving up would drop the file silently.
        let url = tempDirectory("bom").appendingPathComponent("mislabelled.txt")
        var data = Data([0xFF, 0xFE])
        data.append(contentsOf: Array("turbine".utf8))
        try data.write(to: url)

        let pages = try PlainTextExtractor().extract(from: url)
        let body = try await run.require(pages.first?.body)
        await run.expect(body.contains("turbine"), "decoded as: \(body)")

        // A real UTF-16 file still decodes as UTF-16 — with a mark…
        let marked = tempDirectory("bom").appendingPathComponent("marked.txt")
        try "gearbox inspection".data(using: .utf16LittleEndian)!.write(to: marked)
        await run.expect(
            try PlainTextExtractor().extract(from: marked).first?.body.contains("gearbox") == true,
            "a BOM-marked UTF-16 file must decode")

        // …and without one, where the NUL bytes are the only clue.
        let bare = tempDirectory("bom").appendingPathComponent("bare.txt")
        var bareData = Data()
        for scalar in "turbine inspection".unicodeScalars {
            bareData.append(UInt8(scalar.value & 0xFF))
            bareData.append(UInt8(scalar.value >> 8))
        }
        try bareData.write(to: bare)
        await run.expect(
            try PlainTextExtractor().extract(from: bare).first?.body.contains("turbine") == true,
            "UTF-16 with no mark must not decode as UTF-8 full of holes")
    }

    static func emptyIsNotFailure(_ run: TestRun) async throws {
        let directory = tempDirectory("empty-doc")
        // Markup with no words in it — the "logo.html" case.
        try "<html><body><img src=\"logo.png\"></body></html>".write(
            to: directory.appendingPathComponent("logo.html"), atomically: true, encoding: .utf8)
        try "The turbine is fine.".write(
            to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let store = try makeStore()
        let coordinator = IndexCoordinator(store: store, concurrency: 2)
        try await coordinator.addFolder(directory)
        let progress = try await coordinator.runUntilIdle()

        await run.equal(progress.failed, 0, "an empty file is readable, just empty")
        await run.equal(progress.skipped, 1)
        await run.equal(progress.indexed, 1)

        let stats = try await store.stats()
        await run.equal(stats.failed, 0)
        await run.equal(stats.empty, 1)
        await run.equal(stats.pending, 0, "it must not be retried on every pass")
        await run.equal(try await store.queueDepth(), 0)
    }

    static func chunking(_ run: TestRun) async throws {
        await run.equal(PageChunker.chunk(""), [])
        await run.equal(PageChunker.chunk("   \n  "), [])
        await run.equal(PageChunker.chunk("short text"), ["short text"])

        let paragraphs = (1...20)
            .map { "Paragraph \($0). " + String(repeating: "word ", count: 60) }
            .joined(separator: "\n\n")
        let chunks = PageChunker.chunk(paragraphs, targetLength: 1_000)
        await run.expect(chunks.count > 1, "long text must be split, got \(chunks.count)")
        await run.expect(chunks.allSatisfy { $0.count <= 2_000 },
                         "chunks were \(chunks.map(\.count))")
        // Nothing may be lost in the cutting.
        let rejoined = chunks.joined(separator: " ")
        await run.expect(rejoined.contains("Paragraph 1."))
        await run.expect(rejoined.contains("Paragraph 20."))

        // A single paragraph longer than the target is still cut.
        let wall = String(repeating: "sentence here. ", count: 500)
        await run.expect(PageChunker.chunk(wall, targetLength: 500).count > 1)
    }

    static func plainText(_ run: TestRun) async throws {
        let directory = tempDirectory("plain")
        let text = directory.appendingPathComponent("notes.txt")
        try "The turbine inspection is due in March.".write(
            to: text, atomically: true, encoding: .utf8)

        let pages = try PlainTextExtractor().extract(from: text)
        await run.equal(pages.count, 1)
        await run.expect(pages.first?.body.contains("turbine inspection") == true)
        await run.equal(pages.first?.title, "")

        let markdown = directory.appendingPathComponent("readme.md")
        try """
        # Maintenance Guide

        Inspect the gearbox twice a year.

        ## Lubrication

        Use the recommended grade.
        """.write(to: markdown, atomically: true, encoding: .utf8)

        let markdownPages = try PlainTextExtractor().extract(from: markdown)
        let title = try await run.require(markdownPages.first?.title)
        await run.expect(title.contains("Maintenance Guide"), "got '\(title)'")
        await run.expect(title.contains("Lubrication"), "got '\(title)'")

        // Empty files are an error, not an empty page.
        let empty = directory.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        var threw = false
        do { _ = try PlainTextExtractor().extract(from: empty) } catch { threw = true }
        await run.expect(threw)
    }

    static func encodings(_ run: TestRun) async throws {
        let directory = tempDirectory("encodings")
        let latin1 = directory.appendingPathComponent("legacy.txt")
        let content = "Le rapport économique annuel"
        guard let data = content.data(using: .isoLatin1) else {
            await run.expect(false, "could not build the fixture")
            return
        }
        try data.write(to: latin1)

        let pages = try PlainTextExtractor().extract(from: latin1)
        let body = try await run.require(pages.first?.body)
        await run.expect(body.contains("économique"), "decoded as: \(body)")
    }

    static func attributedFormats(_ run: TestRun) async throws {
        let directory = tempDirectory("attributed")
        let styled = NSMutableAttributedString(
            string: "Turbine Maintenance\n",
            attributes: [.font: NSFont.systemFont(ofSize: 24)])
        styled.append(NSAttributedString(
            string: String(repeating: "Inspect the gearbox and record the readings. ", count: 6),
            attributes: [.font: NSFont.systemFont(ofSize: 12)]))

        // AppKit writes these formats as well as it reads them, which is how the
        // fixtures stay out of git.
        for (ext, type) in [("rtf", NSAttributedString.DocumentType.rtf),
                            ("docx", NSAttributedString.DocumentType.officeOpenXML)] {
            let url = directory.appendingPathComponent("memo.\(ext)")
            let data = try styled.data(
                from: NSRange(location: 0, length: styled.length),
                documentAttributes: [.documentType: type])
            try data.write(to: url)

            let pages = try AttributedDocExtractor().extract(from: url)
            let body = try await run.require(pages.first?.body)
            await run.expect(body.contains("Inspect the gearbox"), ".\(ext) body was: \(body.prefix(60))")
            await run.expect(pages.first?.title.contains("Turbine Maintenance") == true,
                             ".\(ext) heading was '\(pages.first?.title ?? "")'")
        }
    }

    static func htmlStripping(_ run: TestRun) async throws {
        let url = tempDirectory("html").appendingPathComponent("page.html")
        try """
        <html><head><title>Quarterly Report</title>
        <style>body { color: red; }</style>
        <script>console.log("ignored");</script></head>
        <body><h1>Turbine&nbsp;Maintenance</h1>
        <p>Inspect the <b>gearbox</b> twice a year.</p></body></html>
        """.write(to: url, atomically: true, encoding: .utf8)

        let pages = try HTMLTextExtractor().extract(from: url)
        let page = try await run.require(pages.first)
        await run.expect(page.body.contains("Inspect the gearbox twice a year"),
                         "got: \(page.body)")
        await run.expect(!page.body.contains("console.log"), "scripts must be dropped")
        await run.expect(!page.body.contains("color: red"), "styles must be dropped")
        await run.expect(!page.body.contains("<"), "no markup may survive: \(page.body)")
        await run.expect(page.body.contains("Turbine Maintenance"), "&nbsp; should become a space")
        await run.equal(page.title, "Quarterly Report")
    }

    static func officeArchive(_ run: TestRun) async throws {
        // A minimal .pptx: the parts PaperSift reads, zipped the way Keynote and
        // PowerPoint do it.
        let directory = tempDirectory("pptx")
        let staging = directory.appendingPathComponent("staging/ppt/slides", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?><p:sld xmlns:a="x"><p:cSld><p:spTree>
        <a:t>Kirkwall substation review</a:t><a:t>Decommissioning in the third quarter</a:t>
        </p:spTree></p:cSld></p:sld>
        """.write(to: staging.appendingPathComponent("slide1.xml"),
                  atomically: true, encoding: .utf8)

        let archive = directory.appendingPathComponent("deck.pptx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", archive.path, "ppt"]
        zip.currentDirectoryURL = directory.appendingPathComponent("staging")
        try zip.run()
        zip.waitUntilExit()
        await run.equal(zip.terminationStatus, 0, "could not build the .pptx fixture")

        let pages = try ZipXMLExtractor().extract(from: archive)
        let body = try await run.require(pages.first?.body)
        await run.expect(body.contains("Kirkwall substation review"), "got: \(body)")
        await run.expect(body.contains("Decommissioning"), "got: \(body)")
        await run.expect(!body.contains("<a:t>"), "XML tags must be stripped: \(body)")
    }

    static func codeAndSkippedFolders(_ run: TestRun) async throws {
        let directory = tempDirectory("code")
        try "func inspectTurbine() { /* every six months */ }".write(
            to: directory.appendingPathComponent("Engine.swift"),
            atomically: true, encoding: .utf8)

        // The kind of folder that would otherwise swamp an index.
        let noise = directory.appendingPathComponent("node_modules/left-pad", isDirectory: true)
        try FileManager.default.createDirectory(at: noise, withIntermediateDirectories: true)
        try "module.exports = function inspectTurbine() {}".write(
            to: noise.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let found = DocumentScanner(extensions: ExtractorRegistry.default.indexableExtensions)
            .scan(rootID: 1, at: directory)
        let names = found.candidates.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        await run.equal(names, ["Engine.swift"], "node_modules must be pruned, got \(names)")

        await run.expect(DocumentScanner.skippedDirectories.contains(".git"))
        await run.expect(ExtractorRegistry.default.indexableExtensions.contains("docx"))
        await run.expect(ExtractorRegistry.default.indexableExtensions.contains("swift"))
    }

    static func endToEndText(_ run: TestRun) async throws {
        let directory = tempDirectory("text-pipeline")
        try """
        # Field Notes

        The Kirkwall substation was inspected on Tuesday. The turbine bearings
        showed no wear, and the lubrication schedule stays unchanged.
        """.write(to: directory.appendingPathComponent("notes.md"),
                  atomically: true, encoding: .utf8)

        let store = try makeStore()
        let coordinator = IndexCoordinator(store: store, concurrency: 2)
        try await coordinator.addFolder(directory)
        let progress = try await coordinator.runUntilIdle()

        await run.equal(progress.indexed, 1)
        await run.equal(progress.failed, 0)

        let engine = SearchEngine(store: store)
        let results = try await engine.search("Kirkwall bearings")
        await run.equal(results.documents.count, 1)
        let document = try await run.require(results.documents.first)
        await run.equal(document.filename, "notes.md")
        await run.expect(!document.isPDF, "a Markdown file must open in the text reader")
        await run.expect(document.bestHit.snippet.text.contains("Kirkwall"))

        // The Markdown heading went into the title column; body words did not.
        await run.equal(try await store.matchPages(
            expression: "title: field", columnWeights: checkWeights, limit: 5).count, 1)
        await run.equal(try await store.matchPages(
            expression: "title: bearings", columnWeights: checkWeights, limit: 5).count, 0,
            "a word that only appears in the body must not land in the title column")
    }
}
