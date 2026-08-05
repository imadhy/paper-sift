import Foundation
import PaperSiftCore

/// Collects FSEvents callbacks from whatever thread they arrive on.
actor PathCollector {
    private var paths: [String] = []
    func add(_ new: [String]) { paths.append(contentsOf: new) }
    var count: Int { paths.count }
}

enum IndexingChecks {
    static let cases: [(String, @Sendable (TestRun) async throws -> Void)] = [
        ("The scanner keeps indexable files and ignores the rest", scannerFilters),
        ("A folder goes from disk to searchable pages", endToEnd),
        ("Re-running skips untouched files and picks up edits", incrementalReindex),
        ("A broken file is recorded as failed and leaves the queue", brokenFile),
        ("The folder watcher reports a new file", folderWatcherFires),
    ]

    static func scannerFilters(_ run: TestRun) async throws {
        let directory = tempDirectory("scanner")
        try PDFFixtures.write([PDFFixtures.Page(body: "indexable")],
                              to: directory.appendingPathComponent("keep.pdf"))
        try PDFFixtures.write([PDFFixtures.Page(body: "nested")],
                              to: directory.appendingPathComponent("sub/deep.pdf"))
        try "ignored".write(to: directory.appendingPathComponent("notes.txt"),
                            atomically: true, encoding: .utf8)
        try Data().write(to: directory.appendingPathComponent("empty.pdf"))

        let result = DocumentScanner(extensions: ["pdf"]).scan(rootID: 1, at: directory)
        let names = Set(result.candidates.map { URL(fileURLWithPath: $0.path).lastPathComponent })

        await run.equal(names, ["keep.pdf", "deep.pdf"], "zero-byte and .txt files must be skipped")
        await run.expect(result.candidates.allSatisfy { $0.size > 0 })
        await run.expect(result.candidates.allSatisfy { $0.rootID == 1 })
    }

    static func endToEnd(_ run: TestRun) async throws {
        let directory = tempDirectory("pipeline")
        try PDFFixtures.write([
            PDFFixtures.Page(title: "Turbine Maintenance",
                             body: "Inspect the blades every six months."),
            PDFFixtures.Page(body: "Lubrication schedule for the gearbox."),
        ], to: directory.appendingPathComponent("manual.pdf"))
        try PDFFixtures.write([
            PDFFixtures.Page(body: "The children were hiking near the lake."),
        ], to: directory.appendingPathComponent("trip.pdf"))

        let store = try makeStore()
        let coordinator = IndexCoordinator(store: store, concurrency: 2)
        try await coordinator.addFolder(directory)
        let progress = try await coordinator.runUntilIdle()

        await run.equal(progress.indexed, 2)
        await run.equal(progress.failed, 0)
        await run.equal(progress.remaining, 0)

        let stats = try await store.stats()
        await run.equal(stats.documents, 2)
        await run.equal(stats.pages, 3)
        await run.equal(stats.indexed, 2)
        await run.equal(stats.queued, 0)

        // Body text is searchable…
        await run.equal(try await store.matchPages(
            expression: "blades", columnWeights: checkWeights, limit: 10).count, 1)
        // …the heading landed in its own column…
        let heading = try await store.matchPages(
            expression: "title: turbine", columnWeights: checkWeights, limit: 10)
        await run.equal(heading.count, 1, "the heading should be indexed in the title column")
        // …and lemmas make "child" find "children".
        await run.equal(try await store.matchPages(
            expression: "lemmas: child", columnWeights: checkWeights, limit: 10).count, 1)
    }

    static func incrementalReindex(_ run: TestRun) async throws {
        let directory = tempDirectory("incremental")
        let url = directory.appendingPathComponent("draft.pdf")
        try PDFFixtures.write([PDFFixtures.Page(body: "First draft mentions turbines.")], to: url)

        let store = try makeStore()
        let coordinator = IndexCoordinator(store: store, concurrency: 2)
        let root = try await coordinator.addFolder(directory)
        await run.equal(try await coordinator.runUntilIdle().indexed, 1)

        // Nothing changed on disk: no work to redo.
        try await coordinator.rescan(root)
        await run.equal(try await store.queueDepth(kind: .text), 0)
        await run.equal(try await coordinator.runUntilIdle().indexed, 1, "counters are cumulative")

        // Rewrite the file: it must be re-extracted and the old text must go.
        try PDFFixtures.write([PDFFixtures.Page(body: "Second draft mentions propellers.")], to: url)
        try await coordinator.rescan(root)
        await run.equal(try await store.queueDepth(kind: .text), 1)
        _ = try await coordinator.runUntilIdle()

        await run.expect(try await store.matchPages(
            expression: "turbines", columnWeights: checkWeights, limit: 10).isEmpty)
        await run.equal(try await store.matchPages(
            expression: "propellers", columnWeights: checkWeights, limit: 10).count, 1)
        await run.equal(try await store.stats().documents, 1)

        // Delete it: the document disappears from the index.
        try FileManager.default.removeItem(at: url)
        try await coordinator.rescan(root)
        await run.equal(try await store.stats().documents, 0)
    }

    static func brokenFile(_ run: TestRun) async throws {
        let directory = tempDirectory("broken")
        let url = directory.appendingPathComponent("corrupt.pdf")
        try Data("this is not a PDF at all".utf8).write(to: url)

        let store = try makeStore()
        let coordinator = IndexCoordinator(store: store, concurrency: 1)
        try await coordinator.addFolder(directory)
        let progress = try await coordinator.runUntilIdle()

        await run.equal(progress.failed, 1)
        await run.equal(progress.indexed, 0)
        let failures = try await store.documents(state: .failed)
        await run.equal(failures.count, 1)
        await run.expect(failures.first?.error?.isEmpty == false, "the reason must be recorded")
        await run.equal(try await store.queueDepth(), 0, "a failure must not be retried forever")
    }

    static func folderWatcherFires(_ run: TestRun) async throws {
        let directory = tempDirectory("watcher")
        let collector = PathCollector()
        let watcher = FolderWatcher(latency: 0.1) { paths in
            Task { await collector.add(paths) }
        }
        watcher.watch([directory.path])
        defer { watcher.stop() }

        // FSEvents needs a moment to arm the stream before it reports anything.
        try await Task.sleep(for: .milliseconds(400))
        try "hello".write(to: directory.appendingPathComponent("fresh.txt"),
                          atomically: true, encoding: .utf8)

        var fired = false
        for _ in 0..<40 where !fired {
            if await collector.count > 0 { fired = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        await run.expect(fired, "no FSEvents callback within 10 s")
    }
}
