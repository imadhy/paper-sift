import Foundation
import PaperSiftCore

/// A throwaway store in a unique temp directory.
func makeStore() throws -> IndexStore {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("papersift-check-\(UUID().uuidString)", isDirectory: true)
    return try IndexStore(url: directory.appendingPathComponent("index.sqlite"))
}

/// Default bm25 column weights, mirroring what the search engine uses.
let checkWeights = (body: 1.0, title: 3.0, lemmas: 0.8)

/// A document under a fresh root, ready to receive pages.
func makeDocument(
    in store: IndexStore, rootPath: String = "/tmp/papers", named name: String
) async throws -> (root: Root, id: Int64) {
    let root = try await store.addRoot(path: rootPath)
    let id = try await store.upsert(DocumentCandidate(
        rootID: root.id, path: "\(root.path)/\(name)", size: 10, modifiedAt: Date())).documentID
    return (root, id)
}

enum StoreChecks {
    static let cases: [(String, @Sendable (TestRun) async throws -> Void)] = [
        ("A fresh database migrates and reports an empty index", freshDatabase),
        ("Adding the same root twice returns the same row", rootsAreIdempotent),
        ("Upsert distinguishes new, unchanged and modified files", upsertOutcomes),
        ("Indexed pages are found by prefix and ranked", searchFindsPages),
        ("Diacritics are folded on both sides of the query", diacriticsAreFolded),
        ("Re-indexing replaces pages instead of piling them up", replacePagesIsIdempotent),
        ("Deleting a document clears its FTS rows too", deletingClearsFTS),
        ("Dropping a root takes its documents and pages with it", removingRootCascades),
        ("Vanished files are pruned, surviving ones are kept", prunesMissingFiles),
        ("Reset wipes pages but keeps folders and documents", resetKeepsRoots),
        ("The queue is deduplicated and FIFO per kind", queueRoundTrip),
        ("Pages with no text are offered to the OCR queue", scanPagesAreFlagged),
        ("Backup produces an openable copy", backupIsUsable),
        ("Failed documents can be given another go", retryFailures),
    ]

    /// A rescan only re-reads files that changed on disk, so without this a
    /// document that failed once — even for a reason since fixed — stays failed
    /// forever.
    static func retryFailures(_ run: TestRun) async throws {
        let store = try makeStore()
        let document = try await makeDocument(in: store, named: "broken.pdf")
        try await store.setState(.failed, id: document.id, error: "could not be opened")

        var stats = try await store.stats()
        await run.equal(stats.failed, 1)
        await run.equal(try await store.queueDepth(), 0, "a failure leaves the queue")

        let requeued = try await store.retryFailures()

        await run.equal(requeued, 1)
        stats = try await store.stats()
        await run.equal(stats.failed, 0)
        await run.equal(stats.pending, 1)
        await run.equal(try await store.queueDepth(kind: .text), 1)
        await run.equal(try await store.document(id: document.id)?.error, nil,
                        "the stale reason must be cleared")
        await run.equal(try await store.retryFailures(), 0, "nothing left to retry")
    }

    static func freshDatabase(_ run: TestRun) async throws {
        let store = try makeStore()
        let stats = try await store.stats()
        await run.expect(stats.isEmpty)
        await run.equal(stats.roots, 0)
        await run.equal(stats.pages, 0)
        await run.expect(stats.databaseBytes > 0, "the file should exist on disk")
    }

    static func rootsAreIdempotent(_ run: TestRun) async throws {
        let store = try makeStore()
        let first = try await store.addRoot(path: "/tmp/papers")
        let second = try await store.addRoot(path: "/tmp/papers/")
        await run.equal(first.id, second.id, "trailing slash should not create a second root")
        await run.equal(try await store.roots().count, 1)
        await run.equal(first.name, "papers")
    }

    static func upsertOutcomes(_ run: TestRun) async throws {
        let store = try makeStore()
        let root = try await store.addRoot(path: "/tmp/papers")
        var candidate = DocumentCandidate(
            rootID: root.id, path: "/tmp/papers/report.pdf", size: 1_024,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let created = try await store.upsert(candidate)
        await run.equal(created, .created(created.documentID))
        await run.equal(try await store.upsert(candidate).needsIndexing, false)

        candidate.size = 2_048
        let changed = try await store.upsert(candidate)
        await run.equal(changed, .changed(created.documentID))
        await run.expect(changed.needsIndexing)

        let stored = try await run.require(try await store.document(id: created.documentID))
        await run.equal(stored.filename, "report.pdf")
        await run.equal(stored.ext, "pdf")
        await run.equal(stored.state, .pending)
    }

    static func searchFindsPages(_ run: TestRun) async throws {
        let store = try makeStore()
        let document = try await makeDocument(in: store, named: "report.pdf")

        try await store.replacePages([
            PageContent(pageNumber: 1, body: "Table of contents", title: "Contents"),
            PageContent(pageNumber: 2,
                        body: "The annual economic report shows a steady recovery.",
                        title: "Annual economic report"),
            PageContent(pageNumber: 3, body: "Appendix with raw figures."),
        ], documentID: document.id, state: .indexed)

        let hits = try await store.matchPages(
            expression: "econom*", columnWeights: checkWeights, limit: 10)
        await run.equal(hits.count, 1)
        let best = try await run.require(hits.first)
        await run.equal(best.pageNumber, 2)
        // bm25 is negative, and "more negative" means "better".
        await run.expect(best.bm25 < 0, "bm25 was \(best.bm25)")
        await run.equal(best.filename, "report.pdf")

        let stats = try await store.stats()
        await run.equal(stats.pages, 3)
        await run.equal(stats.indexed, 1)
    }

    static func diacriticsAreFolded(_ run: TestRun) async throws {
        let store = try makeStore()
        let document = try await makeDocument(in: store, named: "fr.pdf")
        try await store.replacePages(
            [PageContent(pageNumber: 1, body: "Le rapport économique annuel")],
            documentID: document.id, state: .indexed)

        await run.equal(try await store.matchPages(
            expression: "economique", columnWeights: checkWeights, limit: 10).count, 1)
        await run.equal(try await store.matchPages(
            expression: "économique", columnWeights: checkWeights, limit: 10).count, 1)
    }

    static func replacePagesIsIdempotent(_ run: TestRun) async throws {
        let store = try makeStore()
        let document = try await makeDocument(in: store, named: "notes.pdf")

        try await store.replacePages(
            [PageContent(pageNumber: 1, body: "first draft about turbines")],
            documentID: document.id, state: .indexed)
        try await store.replacePages(
            [PageContent(pageNumber: 1, body: "second draft about propellers")],
            documentID: document.id, state: .indexed)

        await run.equal(try await store.stats().pages, 1)
        await run.expect(try await store.matchPages(
            expression: "turbines", columnWeights: checkWeights, limit: 10).isEmpty,
            "stale text should be gone from the FTS index")
        await run.equal(try await store.matchPages(
            expression: "propellers", columnWeights: checkWeights, limit: 10).count, 1)
    }

    static func deletingClearsFTS(_ run: TestRun) async throws {
        let store = try makeStore()
        let document = try await makeDocument(in: store, named: "gone.pdf")
        try await store.replacePages(
            [PageContent(pageNumber: 1, body: "ephemeral content")],
            documentID: document.id, state: .indexed)

        try await store.removeDocument(id: document.id)

        await run.expect(try await store.matchPages(
            expression: "ephemeral", columnWeights: checkWeights, limit: 10).isEmpty)
        let stats = try await store.stats()
        await run.equal(stats.documents, 0)
        await run.equal(stats.pages, 0)
    }

    static func removingRootCascades(_ run: TestRun) async throws {
        let store = try makeStore()
        let document = try await makeDocument(in: store, named: "a.pdf")
        try await store.replacePages(
            [PageContent(pageNumber: 1, body: "content under a root")],
            documentID: document.id, state: .indexed)

        try await store.removeRoot(id: document.root.id)

        let stats = try await store.stats()
        await run.equal(stats.roots, 0)
        await run.equal(stats.documents, 0)
        await run.equal(stats.pages, 0)
        await run.expect(try await store.matchPages(
            expression: "content", columnWeights: checkWeights, limit: 10).isEmpty)
    }

    static func prunesMissingFiles(_ run: TestRun) async throws {
        let store = try makeStore()
        let root = try await store.addRoot(path: "/tmp/papers")
        for name in ["a.pdf", "b.pdf", "c.pdf"] {
            _ = try await store.upsert(DocumentCandidate(
                rootID: root.id, path: "/tmp/papers/\(name)", size: 10, modifiedAt: Date()))
        }

        let removed = try await store.removeDocuments(
            underRoot: root.id, keeping: ["/tmp/papers/b.pdf"])

        await run.equal(removed, 2)
        await run.equal(try await store.documentPaths(underRoot: root.id), ["/tmp/papers/b.pdf"])
    }

    static func resetKeepsRoots(_ run: TestRun) async throws {
        let store = try makeStore()
        let document = try await makeDocument(in: store, named: "a.pdf")
        try await store.replacePages(
            [PageContent(pageNumber: 1, body: "to be forgotten")],
            documentID: document.id, state: .indexed)

        try await store.resetIndex()

        let stats = try await store.stats()
        await run.equal(stats.roots, 1)
        await run.equal(stats.documents, 1)
        await run.equal(stats.pages, 0)
        await run.equal(stats.pending, 1)
        await run.equal(try await store.document(id: document.id)?.indexedAt, nil)
    }

    static func queueRoundTrip(_ run: TestRun) async throws {
        let store = try makeStore()
        let root = try await store.addRoot(path: "/tmp/papers")
        let first = try await store.upsert(DocumentCandidate(
            rootID: root.id, path: "/tmp/papers/a.pdf", size: 10, modifiedAt: Date())).documentID
        let second = try await store.upsert(DocumentCandidate(
            rootID: root.id, path: "/tmp/papers/b.pdf", size: 10, modifiedAt: Date())).documentID

        try await store.enqueue(documentID: first, kind: .text)
        try await store.enqueue(documentID: second, kind: .ocr)
        try await store.enqueue(documentID: first, kind: .text)  // must not duplicate

        await run.equal(try await store.queueDepth(), 2)
        await run.equal(try await store.queueDepth(kind: .text), 1)

        let jobs = try await store.nextJobs(kind: .text, limit: 10)
        await run.equal(jobs.count, 1)
        await run.equal(jobs.first?.path, "/tmp/papers/a.pdf")

        try await store.dequeue(documentID: first)
        await run.equal(try await store.queueDepth(kind: .text), 0)
    }

    static func scanPagesAreFlagged(_ run: TestRun) async throws {
        let store = try makeStore()
        let document = try await makeDocument(in: store, named: "scan.pdf")

        try await store.replacePages([
            PageContent(pageNumber: 1, body: ""),
            PageContent(pageNumber: 2, body: "This page has a real text layer on it."),
        ], documentID: document.id, state: .ocrPending)

        let scans = try await store.scanPages(documentID: document.id)
        await run.equal(scans.map(\.pageNumber), [1])
        await run.equal(try await store.document(id: document.id)?.needsOCR, true)

        // OCR comes back with text: the page is rewritten, not duplicated.
        try await store.replacePage(
            PageContent(pageNumber: 1, body: "Recognized invoice total", fromOCR: true,
                        layout: Data([0x01, 0x02])),
            documentID: document.id)

        await run.equal(try await store.stats().pages, 2)
        await run.equal(try await store.stats().ocrPages, 1)
        await run.expect(try await store.scanPages(documentID: document.id).isEmpty)
        await run.equal(try await store.matchPages(
            expression: "invoice", columnWeights: checkWeights, limit: 10).count, 1)

        let rewritten = try await run.require(
            try await store.pages(documentID: document.id).first { $0.pageNumber == 1 })
        await run.expect(rewritten.fromOCR)
        await run.equal(try await store.ocrLayout(pageID: rewritten.id), Data([0x01, 0x02]))
    }

    static func backupIsUsable(_ run: TestRun) async throws {
        let store = try makeStore()
        let document = try await makeDocument(in: store, named: "a.pdf")
        try await store.replacePages(
            [PageContent(pageNumber: 1, body: "backed up sentence")],
            documentID: document.id, state: .indexed)

        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("papersift-backup-\(UUID().uuidString).sqlite")
        try await store.backup(to: destination)

        let restored = try IndexStore(url: destination)
        await run.equal(try await restored.matchPages(
            expression: "sentence", columnWeights: checkWeights, limit: 10).count, 1)
    }
}
