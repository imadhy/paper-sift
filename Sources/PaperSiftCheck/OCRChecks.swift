import Foundation
import PDFKit
import PaperSiftCore

enum OCRChecks {
    /// `PDFDocument` and `PDFPage` are not `Sendable`, so they cannot come back
    /// out of the main-actor-isolated `require`. Open them here instead.
    private static func firstPage(of url: URL, _ run: TestRun) async -> PDFPage? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            await run.expect(false, "could not open \(url.lastPathComponent)")
            return nil
        }
        return page
    }

    static let cases: [(String, @Sendable (TestRun) async throws -> Void)] = [
        ("A page renders to a bitmap at the requested resolution", rasterizes),
        ("Vision reads a page that has no text layer", recognizesScan),
        ("Word boxes are normalized and locate the match", wordBoxes),
        ("Layouts survive a round trip through the database", layoutRoundTrip),
        ("A scanned document becomes searchable end to end", endToEndOCR),
        ("Turning OCR off leaves scans queued, not lost", disabledKeepsQueue),
        ("Progress reports the queue of the phase it is in", progressReportsTheRightQueue),
        ("Word boxes are stored at the precision they need, no more", quantizedCoordinates),
    ]

    /// Full `Double` precision doubled the size of every stored layout for accuracy
    /// no screen can show. This pins the quantization down — and, more importantly,
    /// pins down that it is still precise enough to place a highlight.
    static func quantizedCoordinates(_ run: TestRun) async throws {
        let raw = OCRWord(text: "RÉPUBLIQUE",
                          x: 0.7041512304821277, y: 0.5081626473853749,
                          width: 0.05270614063038548, height: 0.2047530174255372)
        await run.equal(raw.x, 0.7042)
        await run.equal(raw.height, 0.2048)

        // The invariant, stated the way the file will show it.
        let layout = OCRLayout(words: (0..<50).map { index in
            OCRWord(text: "word\(index)",
                    x: 0.1234567890123 + Double(index) / 1_000,
                    y: 0.9876543210987, width: 0.0523456789, height: 0.0198765432)
        })
        let json = try String(decoding: layout.encoded(), as: UTF8.self)
        await run.expect(
            json.range(of: "[0-9]+\\.[0-9]{6,}", options: .regularExpression) == nil,
            "no number should carry six decimals: \(json.prefix(120))")

        // Round trips are exact, because the value in memory is already quantized.
        await run.equal(try OCRLayout.decode(try layout.encoded()), layout)

        // And the precision still places a box on a page to within a fifth of a
        // point — a hair is 0.2 pt.
        let pageWidth = 595.0
        let exact = 0.7041512304821277 * pageWidth
        await run.expect(abs(raw.x * pageWidth - exact) < 0.2,
                         "drift was \(abs(raw.x * pageWidth - exact)) pt")

        // A v1 blob, with its fat numbers, shrinks when re-encoded.
        let fat = Data("""
        {"words":[{"t":"RÉPUBLIQUE","x":0.7041512304821277,"y":0.5081626473853749,\
        "w":0.05270614063038548,"h":0.2047530174255372}]}
        """.utf8)
        let slim = try await run.require(OCRLayout.recompacted(fat))
        // Only the numbers shrink — roughly twelve characters off each of the four
        // coordinates. The keys and the word itself cost the same, which is why a
        // one-word blob saves ~40 % and a real page of 400 words saves ~46 %.
        await run.expect(fat.count - slim.count >= 40,
                         "\(fat.count) → \(slim.count) bytes")
        await run.equal(try OCRLayout.decode(slim).words.first?.text, "RÉPUBLIQUE")
        // Already compact: nothing to gain, so nothing is rewritten.
        await run.equal(OCRLayout.recompacted(slim), nil)
    }

    /// The bug this locks down: during the OCR phase the text queue is empty, so
    /// showing `remaining` said "0 left" for as long as Vision was working.
    static func progressReportsTheRightQueue(_ run: TestRun) async throws {
        var progress = IndexCoordinator.Progress()
        progress.remaining = 0
        progress.ocrRemaining = 42

        progress.phase = .text
        await run.equal(progress.remainingInPhase, 0)
        progress.phase = .ocr
        await run.equal(progress.remainingInPhase, 42, "the OCR phase must report the OCR queue")
        progress.phase = .idle
        await run.equal(progress.remainingInPhase, 0)
        await run.expect(!progress.isRunning)

        // And pending OCR work is counted in pages, because one document can hold
        // a hundred of them.
        let directory = tempDirectory("ocr-pages-pending")
        try PDFFixtures.writeScan(to: directory.appendingPathComponent("a.pdf"))
        try PDFFixtures.writeScan(to: directory.appendingPathComponent("b.pdf"))

        let store = try makeStore()
        let coordinator = IndexCoordinator(store: store, concurrency: 1)
        await coordinator.apply(ocrSettings: OCRSettings(isEnabled: false))
        try await coordinator.addFolder(directory)
        _ = try await coordinator.runUntilIdle()

        let stats = try await store.stats()
        await run.equal(stats.ocrPending, 2, "two documents")
        await run.equal(stats.ocrPagesPending, 2, "one page each")
    }

    static func rasterizes(_ run: TestRun) async throws {
        let url = tempDirectory("raster").appendingPathComponent("page.pdf")
        try PDFFixtures.write([PDFFixtures.Page(body: "anything")], to: url)
        guard let page = await firstPage(of: url, run) else { return }

        // 612 pt at 144 dpi is twice the page's point size.
        guard let image = PageRasterizer.render(page, dpi: 144) else {
            await run.expect(false, "rendering produced no image")
            return
        }
        await run.equal(image.width, 1_224)
        await run.equal(image.height, 1_584)

        await run.equal(PageRasterizer.render(page, dpi: 36)?.width, 306)
    }

    static func recognizesScan(_ run: TestRun) async throws {
        let url = tempDirectory("ocr").appendingPathComponent("scan.pdf")
        try PDFFixtures.writeScannedText(
            headline: "Invoice Summary",
            body: "The decommissioning of the Kirkwall substation is scheduled for the third quarter.",
            to: url)

        // No text layer at all: the extractor must see an empty page.
        let extracted = try PDFTextExtractor().extract(from: url)
        await run.expect(extracted.first?.looksLikeScan == true,
                         "the fixture must have no text layer")

        guard let page = await firstPage(of: url, run) else { return }
        let result = try await OCRService().recognize(page: page)

        await run.expect(result.text.localizedCaseInsensitiveContains("Kirkwall"),
                         "OCR returned: \(result.text)")
        await run.expect(result.text.localizedCaseInsensitiveContains("substation"))
        await run.expect(result.averageConfidence > 0.5,
                         "confidence was \(result.averageConfidence)")
        await run.expect(result.title.localizedCaseInsensitiveContains("Invoice"),
                         "the biggest line should be read as a heading, got '\(result.title)'")
    }

    static func wordBoxes(_ run: TestRun) async throws {
        let url = tempDirectory("boxes").appendingPathComponent("scan.pdf")
        try PDFFixtures.writeScannedText(
            headline: "Quarterly Report",
            body: "Turbine maintenance is due in March.", to: url)

        guard let page = await firstPage(of: url, run) else { return }
        let result = try await OCRService().recognize(page: page)

        await run.expect(!result.layout.words.isEmpty, "no word boxes were produced")
        for word in result.layout.words {
            await run.expect(
                word.x >= 0 && word.x <= 1 && word.y >= 0 && word.y <= 1
                    && word.width > 0 && word.width <= 1 && word.height > 0 && word.height <= 1,
                "box out of range for '\(word.text)': \(word)")
        }

        let matches = result.layout.boxes(matching: ["turbine"])
        await run.expect(!matches.isEmpty, "the matched word should have a box")
        // The heading sits at the top of the page, the body below it.
        let headline = result.layout.boxes(matching: ["quarterly"]).first
        if let headline, let body = matches.first {
            await run.expect(headline.y > body.y,
                             "normalized boxes use a lower-left origin, so the heading sits higher")
        }
        await run.expect(result.layout.boxes(matching: ["nonexistentword"]).isEmpty)
    }

    static func layoutRoundTrip(_ run: TestRun) async throws {
        let layout = OCRLayout(words: [
            OCRWord(text: "Économique", x: 0.1, y: 0.8, width: 0.2, height: 0.03),
            OCRWord(text: "report", x: 0.32, y: 0.8, width: 0.1, height: 0.03),
        ])
        let restored = try OCRLayout.decode(try layout.encoded())
        await run.equal(restored, layout)

        // Folding applies on both sides, so an accented word matches unaccented.
        await run.equal(restored.boxes(matching: ["economique"]).count, 1)
        await run.equal(restored.boxes(matching: ["econom"]).count, 1, "a prefix should match too")
    }

    static func endToEndOCR(_ run: TestRun) async throws {
        let directory = tempDirectory("ocr-pipeline")
        try PDFFixtures.writeScannedText(
            headline: "Kirkwall Substation",
            body: "Decommissioning is scheduled for the third quarter of next year.",
            to: directory.appendingPathComponent("scan.pdf"))

        let store = try makeStore()
        let coordinator = IndexCoordinator(store: store, concurrency: 2)
        try await coordinator.addFolder(directory)
        let progress = try await coordinator.runUntilIdle()

        await run.equal(progress.ocrPages, 1, "one page should have been recognized")
        await run.equal(progress.failed, 0)
        await run.equal(progress.ocrRemaining, 0)

        let stats = try await store.stats()
        await run.equal(stats.indexed, 1, "the document should be searchable now")
        await run.equal(stats.ocrPending, 0)
        await run.equal(stats.ocrPages, 1)

        // The recognized text is in the index, with its layout.
        let engine = SearchEngine(store: store)
        let results = try await engine.search("Kirkwall decommissioning")
        await run.equal(results.documents.count, 1)
        let hit = try await run.require(results.documents.first?.bestHit)
        await run.expect(hit.fromOCR, "the hit should be flagged as coming from OCR")

        let layoutData = try await run.require(try await store.ocrLayout(pageID: hit.pageID))
        let layout = try OCRLayout.decode(layoutData)
        await run.expect(!layout.boxes(matching: hit.matchedText).isEmpty,
                         "the viewer needs a box for what it must highlight")

        // A second pass has nothing left to do.
        let again = try await coordinator.runUntilIdle()
        await run.equal(again.ocrRemaining, 0)
        await run.equal(try await store.queueDepth(), 0)
    }

    static func disabledKeepsQueue(_ run: TestRun) async throws {
        let directory = tempDirectory("ocr-off")
        try PDFFixtures.writeScan(to: directory.appendingPathComponent("blank.pdf"))

        let store = try makeStore()
        let coordinator = IndexCoordinator(store: store, concurrency: 1)
        await coordinator.apply(ocrSettings: OCRSettings(isEnabled: false))
        try await coordinator.addFolder(directory)
        _ = try await coordinator.runUntilIdle()

        // Routing: a picture-only PDF is not a failure, it is OCR's problem.
        await run.equal(try await store.queueDepth(kind: .ocr), 1,
                        "the scan must wait, not be dropped")
        await run.equal(try await store.queueDepth(kind: .text), 0)
        let waiting = try await store.stats()
        await run.equal(waiting.ocrPending, 1)
        await run.equal(waiting.failed, 0)
        await run.equal(waiting.pages, 1, "the empty page is still indexed, so it can be replaced")

        // Turning it back on picks the work up.
        await coordinator.apply(ocrSettings: OCRSettings(isEnabled: true))
        _ = try await coordinator.runUntilIdle()
        await run.equal(try await store.queueDepth(kind: .ocr), 0)
        await run.equal(try await store.stats().indexed, 1,
                        "a blank scan is still done being tried")
    }
}
