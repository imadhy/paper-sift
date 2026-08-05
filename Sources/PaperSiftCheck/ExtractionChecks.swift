import AppKit
import Foundation
import PaperSiftCore

enum ExtractionChecks {
    static let cases: [(String, @Sendable (TestRun) async throws -> Void)] = [
        ("Line breaks collapse and hyphenated words are rejoined", normalizeText),
        ("Headings are the runs that stand out from the body size", headingDetection),
        ("A generated PDF round-trips through the extractor", pdfRoundTrip),
        ("A picture-only page comes back empty, flagged as a scan", scanDetection),
        ("An unsupported extension is rejected, not silently skipped", unsupportedExtension),
        ("Lemmas widen recall without repeating the surface form", lemmatization),
    ]

    static func normalizeText(_ run: TestRun) async throws {
        await run.equal(
            PDFTextExtractor.normalize("The annual\n  economic   report\n"),
            "The annual economic report")
        await run.equal(
            PDFTextExtractor.normalize("eco-\nnomic growth"),
            "economic growth",
            "a hyphen at a line break is a typesetting artifact")
        await run.equal(
            PDFTextExtractor.normalize("Anti-\nAmerican sentiment"),
            "Anti- American sentiment",
            "an uppercase continuation is a real hyphen, keep it")
        await run.equal(PDFTextExtractor.normalize(""), "")
    }

    static func headingDetection(_ run: TestRun) async throws {
        let page = NSMutableAttributedString()
        page.append(NSAttributedString(
            string: "Quarterly Review\n",
            attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        page.append(NSAttributedString(
            string: String(repeating: "Body text that carries most of the characters. ", count: 8),
            attributes: [.font: NSFont.systemFont(ofSize: 11)]))

        let headings = HeadingDetector.headings(in: page)
        await run.equal(headings, "Quarterly Review")

        // Uniform text has no heading to find.
        let flat = NSAttributedString(
            string: "All one size, nothing stands out.",
            attributes: [.font: NSFont.systemFont(ofSize: 11)])
        await run.equal(HeadingDetector.headings(in: flat), "")
        await run.equal(HeadingDetector.headings(in: NSAttributedString(string: "")), "")
    }

    static func pdfRoundTrip(_ run: TestRun) async throws {
        let directory = tempDirectory("extract")
        let url = directory.appendingPathComponent("report.pdf")
        try PDFFixtures.write([
            PDFFixtures.Page(title: "Annual Report",
                             body: "Economic growth was steady across the region."),
            PDFFixtures.Page(body: "Appendix listing the raw figures for each quarter."),
        ], to: url)

        let pages = try PDFTextExtractor().extract(from: url)
        await run.equal(pages.count, 2)

        let first = try await run.require(pages.first)
        await run.equal(first.pageNumber, 1)
        await run.expect(first.body.contains("Economic growth was steady"),
                         "body was \(first.body.prefix(80))…")
        await run.expect(first.title.contains("Annual Report"),
                         "the larger run should be picked up as a heading, got '\(first.title)'")
        await run.expect(!first.looksLikeScan)
        await run.expect(pages[1].title.isEmpty, "page 2 has no heading, got '\(pages[1].title)'")
    }

    static func scanDetection(_ run: TestRun) async throws {
        let url = tempDirectory("scan").appendingPathComponent("scan.pdf")
        try PDFFixtures.writeScan(to: url)

        let pages = try PDFTextExtractor().extract(from: url)
        await run.equal(pages.count, 1)
        let page = try await run.require(pages.first)
        await run.expect(page.looksLikeScan, "body was '\(page.body)'")
    }

    static func unsupportedExtension(_ run: TestRun) async throws {
        let url = tempDirectory("unsupported").appendingPathComponent("notes.xyz")
        try "some text".write(to: url, atomically: true, encoding: .utf8)

        var threw = false
        do {
            _ = try ExtractorRegistry.default.extract(from: url)
        } catch is ExtractionError {
            threw = true
        }
        await run.expect(threw, "an unknown extension must raise ExtractionError")
        await run.expect(ExtractorRegistry.default.indexableExtensions.contains("pdf"))
    }

    static func lemmatization(_ run: TestRun) async throws {
        let lemmatizer = Lemmatizer()

        let english = lemmatizer.lemmas(of: "The children were hiking through the valleys.")
        await run.expect(english.contains("child"), "got '\(english)'")
        await run.expect(english.contains("hike"), "got '\(english)'")
        await run.expect(!english.contains("children"),
                         "surface forms already live in the body column: '\(english)'")

        await run.equal(lemmatizer.lemmas(of: ""), "")
        await run.equal(lemmatizer.lemma(ofTerm: "children"), "child")
        await run.equal(lemmatizer.lemma(ofTerm: "child"), nil, "a lemma equal to the term adds nothing")
        await run.equal(lemmatizer.lemma(ofTerm: "a"), nil)
    }
}
