import Foundation

/// A page that matched an FTS query, with everything the ranker needs to score
/// it without going back to the database.
public struct PageCandidate: Sendable, Equatable {
    public let pageID: Int64
    public let documentID: Int64
    public let pageNumber: Int
    public let fromOCR: Bool
    /// Raw FTS5 bm25 output: negative, and the more negative the better.
    public let bm25: Double
    public let body: String
    public let title: String
    public let documentPath: String
    public let filename: String
    public let modifiedAt: Date
    public let pageCount: Int
    /// The file's size on disk — result rows show it, ranking ignores it.
    public let size: Int64

    public init(
        pageID: Int64, documentID: Int64, pageNumber: Int, fromOCR: Bool, bm25: Double,
        body: String, title: String, documentPath: String, filename: String,
        modifiedAt: Date, pageCount: Int, size: Int64 = 0
    ) {
        self.pageID = pageID
        self.documentID = documentID
        self.pageNumber = pageNumber
        self.fromOCR = fromOCR
        self.bm25 = bm25
        self.body = body
        self.title = title
        self.documentPath = documentPath
        self.filename = filename
        self.modifiedAt = modifiedAt
        self.pageCount = pageCount
        self.size = size
    }
}

/// What kind of work a queued document is waiting for.
public enum IndexJobKind: String, Sendable {
    case text
    case ocr
}

public struct IndexJob: Sendable, Equatable {
    public let documentID: Int64
    public let kind: IndexJobKind
    public let path: String
    public let enqueuedAt: Date
}

/// The single owner of the SQLite connection.
///
/// An actor rather than a plain class: the UI reads from the main actor while the
/// indexer writes from background tasks, and SQLite wants one writer at a time.
/// Serializing every access here is both correct and fast enough — searches take
/// single-digit milliseconds.
public actor IndexStore {
    private let connection: SQLiteConnection
    /// Where the database lives. `nonisolated` so the UI can show the path and
    /// reveal it in the Finder without awaiting the indexer.
    public nonisolated let url: URL

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        self.connection = try SQLiteConnection(path: url.path)
        try Schema.migrate(connection)
    }

    /// `~/Library/Application Support/PaperSift/index.sqlite`
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperSift", isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }

    // MARK: - Roots

    public func addRoot(path: String, bookmark: Data? = nil) throws -> Root {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let existing = try root(atPath: standardized) { return existing }
        let now = Date()
        let id = try connection.run(
            "INSERT INTO roots(path, bookmark, added_at) VALUES (?,?,?)",
            [.text(standardized), .optionalBlob(bookmark), .date(now)])
        return Root(id: id, path: standardized, bookmark: bookmark, addedAt: now)
    }

    public func roots() throws -> [Root] {
        try connection.query("SELECT id, path, bookmark, added_at FROM roots ORDER BY path") {
            Root(id: $0.int64(0), path: $0.text(1), bookmark: $0.optionalBlob(2), addedAt: $0.date(3))
        }
    }

    public func root(atPath path: String) throws -> Root? {
        try connection.first(
            "SELECT id, path, bookmark, added_at FROM roots WHERE path = ?", [.text(path)]
        ) {
            Root(id: $0.int64(0), path: $0.text(1), bookmark: $0.optionalBlob(2), addedAt: $0.date(3))
        }
    }

    /// Drops a root and everything indexed under it.
    public func removeRoot(id: Int64) throws {
        try connection.transaction {
            // FTS5 rows are not reached by foreign-key cascades, so clear them first.
            try connection.run("""
                DELETE FROM pages_fts WHERE rowid IN (
                    SELECT p.id FROM pages p
                    JOIN documents d ON d.id = p.doc_id
                    WHERE d.root_id = ?)
                """, [.int(id)])
            try connection.run("DELETE FROM roots WHERE id = ?", [.int(id)])
        }
    }

    // MARK: - Documents

    /// Reconciles a file found on disk with what we already stored.
    public func upsert(_ candidate: DocumentCandidate) throws -> UpsertOutcome {
        let existing = try connection.first(
            "SELECT id, size, mtime FROM documents WHERE path = ?", [.text(candidate.path)]
        ) { (id: $0.int64(0), size: $0.int64(1), mtime: $0.double(2)) }

        guard let existing else {
            let id = try connection.run("""
                INSERT INTO documents(root_id, path, filename, ext, size, mtime, added_at, state)
                VALUES (?,?,?,?,?,?,?,?)
                """, [
                    .int(candidate.rootID), .text(candidate.path), .text(candidate.filename),
                    .text(candidate.ext), .int(candidate.size), .date(candidate.modifiedAt),
                    .date(Date()), .text(DocumentState.pending.rawValue),
                ])
            return .created(id)
        }

        let sameSize = existing.size == candidate.size
        // One second of tolerance: file-system timestamps round-trip through
        // several representations and we do not want spurious re-indexing.
        let sameDate = abs(existing.mtime - candidate.modifiedAt.timeIntervalSince1970) < 1
        if sameSize, sameDate { return .unchanged(existing.id) }

        try connection.run("""
            UPDATE documents SET size = ?, mtime = ?, state = ?, needs_ocr = 0, error = NULL
            WHERE id = ?
            """, [
                .int(candidate.size), .date(candidate.modifiedAt),
                .text(DocumentState.pending.rawValue), .int(existing.id),
            ])
        return .changed(existing.id)
    }

    public func document(id: Int64) throws -> Document? {
        try connection.first(Self.documentColumns + " WHERE id = ?", [.int(id)], Self.decodeDocument)
    }

    public func document(atPath path: String) throws -> Document? {
        try connection.first(Self.documentColumns + " WHERE path = ?", [.text(path)], Self.decodeDocument)
    }

    public func documents(state: DocumentState, limit: Int = 200) throws -> [Document] {
        try connection.query(
            Self.documentColumns + " WHERE state = ? ORDER BY id LIMIT ?",
            [.text(state.rawValue), .count(limit)], Self.decodeDocument)
    }

    public func documentPaths(underRoot rootID: Int64) throws -> Set<String> {
        let paths = try connection.query(
            "SELECT path FROM documents WHERE root_id = ?", [.int(rootID)]) { $0.text(0) }
        return Set(paths)
    }

    /// Called when the OCR pass has been through every scan of a document —
    /// including when it found nothing, so a blank scan is not retried forever.
    public func markOCRComplete(id: Int64) throws {
        try connection.run("""
            UPDATE documents SET state = ?, needs_ocr = 0, error = NULL WHERE id = ?
            """, [.text(DocumentState.indexed.rawValue), .int(id)])
    }

    public func setState(_ state: DocumentState, id: Int64, error: String? = nil) throws {
        try connection.run(
            "UPDATE documents SET state = ?, error = ? WHERE id = ?",
            [.text(state.rawValue), .optionalText(error), .int(id)])
    }

    /// Replaces every page of a document, in one transaction.
    ///
    /// `pages` may be empty — an unreadable or picture-only file still gets its
    /// state updated so it is not retried forever.
    public func replacePages(_ pages: [PageContent], documentID: Int64, state: DocumentState) throws {
        try connection.transaction {
            try deletePages(documentID: documentID)
            for page in pages {
                let pageID = try connection.run("""
                    INSERT INTO pages(doc_id, page_no, char_count, from_ocr) VALUES (?,?,?,?)
                    """, [
                        .int(documentID), .count(page.pageNumber),
                        .count(page.body.count), .bool(page.fromOCR),
                    ])
                // Keep pages.id and pages_fts.rowid in lockstep.
                try connection.run("""
                    INSERT INTO pages_fts(rowid, body, title, lemmas) VALUES (?,?,?,?)
                    """, [.int(pageID), .text(page.body), .text(page.title), .text(page.lemmas)])
                if let layout = page.layout {
                    try connection.run(
                        "INSERT OR REPLACE INTO ocr_layout(page_id, data) VALUES (?,?)",
                        [.int(pageID), .blob(layout)])
                }
            }
            // The caller decided whether OCR applies — it knows the file type, and
            // only PDF pages can be rendered for Vision. Deriving it here from the
            // page text alone flagged short text files as scans.
            try connection.run("""
                UPDATE documents
                SET page_count = ?, indexed_at = ?, state = ?, needs_ocr = ?, error = NULL
                WHERE id = ?
                """, [
                    .count(pages.count), .date(Date()), .text(state.rawValue),
                    .bool(state == .ocrPending), .int(documentID),
                ])
        }
    }

    /// Rewrites a single page — what the OCR pass does once it has read a scan.
    public func replacePage(_ page: PageContent, documentID: Int64) throws {
        try connection.transaction {
            if let existing = try connection.first(
                "SELECT id FROM pages WHERE doc_id = ? AND page_no = ?",
                [.int(documentID), .count(page.pageNumber)], { $0.int64(0) }) {
                try connection.run("DELETE FROM pages_fts WHERE rowid = ?", [.int(existing)])
                try connection.run("DELETE FROM pages WHERE id = ?", [.int(existing)])
            }
            let pageID = try connection.run("""
                INSERT INTO pages(doc_id, page_no, char_count, from_ocr) VALUES (?,?,?,?)
                """, [
                    .int(documentID), .count(page.pageNumber),
                    .count(page.body.count), .bool(page.fromOCR),
                ])
            try connection.run("""
                INSERT INTO pages_fts(rowid, body, title, lemmas) VALUES (?,?,?,?)
                """, [.int(pageID), .text(page.body), .text(page.title), .text(page.lemmas)])
            if let layout = page.layout {
                try connection.run(
                    "INSERT OR REPLACE INTO ocr_layout(page_id, data) VALUES (?,?)",
                    [.int(pageID), .blob(layout)])
            }
        }
    }

    public func removeDocument(id: Int64) throws {
        try connection.transaction {
            try deletePages(documentID: id)
            try connection.run("DELETE FROM documents WHERE id = ?", [.int(id)])
        }
    }

    /// Removes everything under a root whose path is no longer on disk.
    @discardableResult
    public func removeDocuments(underRoot rootID: Int64, keeping paths: Set<String>) throws -> Int {
        let stored = try connection.query(
            "SELECT id, path FROM documents WHERE root_id = ?", [.int(rootID)]
        ) { (id: $0.int64(0), path: $0.text(1)) }
        let gone = stored.filter { !paths.contains($0.path) }
        for document in gone { try removeDocument(id: document.id) }
        return gone.count
    }

    private func deletePages(documentID: Int64) throws {
        try connection.run(
            "DELETE FROM pages_fts WHERE rowid IN (SELECT id FROM pages WHERE doc_id = ?)",
            [.int(documentID)])
        try connection.run("DELETE FROM pages WHERE doc_id = ?", [.int(documentID)])
    }

    // MARK: - Pages

    public func pages(documentID: Int64) throws -> [PageRef] {
        try connection.query("""
            SELECT id, doc_id, page_no, char_count, from_ocr FROM pages
            WHERE doc_id = ? ORDER BY page_no
            """, [.int(documentID)]
        ) {
            PageRef(id: $0.int64(0), documentID: $0.int64(1), pageNumber: $0.int(2),
                    charCount: $0.int(3), fromOCR: $0.bool(4))
        }
    }

    public func pageBody(pageID: Int64) throws -> String? {
        try connection.first("SELECT body FROM pages_fts WHERE rowid = ?", [.int(pageID)]) { $0.text(0) }
    }

    public func ocrLayout(pageID: Int64) throws -> Data? {
        try connection.first("SELECT data FROM ocr_layout WHERE page_id = ?", [.int(pageID)]) { $0.blob(0) }
    }

    /// Pages of a document that hold no usable text — the OCR queue's input.
    public func scanPages(documentID: Int64) throws -> [PageRef] {
        try connection.query("""
            SELECT id, doc_id, page_no, char_count, from_ocr FROM pages
            WHERE doc_id = ? AND from_ocr = 0 AND char_count < 30 ORDER BY page_no
            """, [.int(documentID)]
        ) {
            PageRef(id: $0.int64(0), documentID: $0.int64(1), pageNumber: $0.int(2),
                    charCount: $0.int(3), fromOCR: $0.bool(4))
        }
    }

    // MARK: - Recall

    /// Stage one of a search: hand SQLite the FTS expression and take the best
    /// `limit` pages by bm25. The ranker re-scores this shortlist in Swift.
    ///
    /// `weights` are the per-column bm25 multipliers (body, title, lemmas). They
    /// are interpolated rather than bound because FTS5 wants them constant, and
    /// they never come from user input.
    public func matchPages(
        expression: String,
        columnWeights: (body: Double, title: Double, lemmas: Double),
        limit: Int,
        rootID: Int64? = nil
    ) throws -> [PageCandidate] {
        let scoring = String(
            format: "bm25(pages_fts, %.4f, %.4f, %.4f)",
            columnWeights.body, columnWeights.title, columnWeights.lemmas)
        var sql = """
        SELECT p.id, p.doc_id, p.page_no, p.from_ocr, \(scoring),
               pages_fts.body, pages_fts.title,
               d.path, d.filename, d.mtime, d.page_count, d.size
        FROM pages_fts
        JOIN pages p ON p.id = pages_fts.rowid
        JOIN documents d ON d.id = p.doc_id
        WHERE pages_fts MATCH ?
        """
        var bindings: [SQLValue] = [.text(expression)]
        if let rootID {
            sql += " AND d.root_id = ?"
            bindings.append(.int(rootID))
        }
        sql += " ORDER BY \(scoring) LIMIT ?"
        bindings.append(.count(limit))

        return try connection.query(sql, bindings) {
            PageCandidate(
                pageID: $0.int64(0), documentID: $0.int64(1), pageNumber: $0.int(2),
                fromOCR: $0.bool(3), bm25: $0.double(4), body: $0.text(5), title: $0.text(6),
                documentPath: $0.text(7), filename: $0.text(8), modifiedAt: $0.date(9),
                pageCount: $0.int(10), size: $0.int64(11))
        }
    }

    /// Fallback path for queries FTS5 cannot express (suffix and infix
    /// wildcards): scan page bodies and let the caller filter.
    public func scanPages(containing needle: String, limit: Int, rootID: Int64? = nil) throws -> [PageCandidate] {
        var sql = """
        SELECT p.id, p.doc_id, p.page_no, p.from_ocr, 0.0,
               pages_fts.body, pages_fts.title,
               d.path, d.filename, d.mtime, d.page_count, d.size
        FROM pages_fts
        JOIN pages p ON p.id = pages_fts.rowid
        JOIN documents d ON d.id = p.doc_id
        WHERE pages_fts.body LIKE ?
        """
        var bindings: [SQLValue] = [.text("%\(needle)%")]
        if let rootID {
            sql += " AND d.root_id = ?"
            bindings.append(.int(rootID))
        }
        sql += " LIMIT ?"
        bindings.append(.count(limit))

        return try connection.query(sql, bindings) {
            PageCandidate(
                pageID: $0.int64(0), documentID: $0.int64(1), pageNumber: $0.int(2),
                fromOCR: $0.bool(3), bm25: $0.double(4), body: $0.text(5), title: $0.text(6),
                documentPath: $0.text(7), filename: $0.text(8), modifiedAt: $0.date(9),
                pageCount: $0.int(10), size: $0.int64(11))
        }
    }

    // MARK: - Queue

    public func enqueue(documentID: Int64, kind: IndexJobKind) throws {
        try connection.run("""
            INSERT INTO index_queue(doc_id, kind, enqueued_at) VALUES (?,?,?)
            ON CONFLICT(doc_id) DO UPDATE SET kind = excluded.kind
            """, [.int(documentID), .text(kind.rawValue), .date(Date())])
    }

    public func nextJobs(kind: IndexJobKind, limit: Int) throws -> [IndexJob] {
        try connection.query("""
            SELECT q.doc_id, q.kind, d.path, q.enqueued_at
            FROM index_queue q JOIN documents d ON d.id = q.doc_id
            WHERE q.kind = ? ORDER BY q.enqueued_at LIMIT ?
            """, [.text(kind.rawValue), .count(limit)]
        ) {
            IndexJob(documentID: $0.int64(0),
                     kind: IndexJobKind(rawValue: $0.text(1)) ?? .text,
                     path: $0.text(2),
                     enqueuedAt: $0.date(3))
        }
    }

    public func dequeue(documentID: Int64) throws {
        try connection.run("DELETE FROM index_queue WHERE doc_id = ?", [.int(documentID)])
    }

    public func queueDepth(kind: IndexJobKind? = nil) throws -> Int {
        guard let kind else { return try connection.count("SELECT COUNT(*) FROM index_queue") }
        return try connection.count(
            "SELECT COUNT(*) FROM index_queue WHERE kind = ?", [.text(kind.rawValue)])
    }

    // MARK: - Stats & maintenance

    public func stats() throws -> IndexStats {
        var stats = IndexStats()
        stats.roots = try connection.count("SELECT COUNT(*) FROM roots")
        stats.documents = try connection.count("SELECT COUNT(*) FROM documents")
        // Closures passed inside the parentheses on purpose: a trailing closure
        // in a `for ... in` or `if let` condition is ambiguous with the body.
        let byState = try connection.query(
            "SELECT state, COUNT(*) FROM documents GROUP BY state", [],
            { (state: $0.text(0), count: $0.int(1)) })
        for row in byState {
            switch DocumentState(rawValue: row.state) {
            case .indexed: stats.indexed = row.count
            case .pending: stats.pending = row.count
            case .ocrPending: stats.ocrPending = row.count
            case .failed: stats.failed = row.count
            case .unsupported: stats.unsupported = row.count
            case nil: break
            }
        }
        if let pageRow = try connection.first(
            "SELECT COUNT(*), COALESCE(SUM(from_ocr), 0) FROM pages", [],
            { (all: $0.int(0), ocr: $0.int(1)) }) {
            stats.pages = pageRow.all
            stats.ocrPages = pageRow.ocr
        }
        stats.queued = try connection.count("SELECT COUNT(*) FROM index_queue")
        // How many *pages* OCR still owes, not how many documents: one scanned
        // binder is a single document and a hundred pages of work.
        stats.ocrPagesPending = try connection.count("""
            SELECT COUNT(*) FROM pages p
            JOIN index_queue q ON q.doc_id = p.doc_id
            WHERE q.kind = 'ocr' AND p.from_ocr = 0 AND p.char_count < 30
            """)
        stats.empty = try connection.count(
            "SELECT COUNT(*) FROM documents WHERE state = 'indexed' AND page_count = 0")
        stats.databaseBytes = Self.fileSize(of: url)
        return stats
    }

    /// Documents that produced no pages, with the reason — so a count in the UI
    /// can be opened up instead of just worrying people. Covers both real failures
    /// and unsupported formats; the reason text tells them apart.
    public func unreadableDocuments(limit: Int = 200) throws -> [Document] {
        try connection.query(
            Self.documentColumns + " WHERE state IN (?, ?) ORDER BY state, filename LIMIT ?",
            [.text(DocumentState.failed.rawValue), .text(DocumentState.unsupported.rawValue),
             .count(limit)], Self.decodeDocument)
    }

    /// One row per watched folder, for the Index Status popover.
    public func rootStats() throws -> [RootStats] {
        try connection.query("""
            SELECT r.id, r.path,
                   COUNT(d.id),
                   COALESCE(SUM(d.state = 'indexed'), 0),
                   COALESCE(SUM(d.page_count), 0)
            FROM roots r
            LEFT JOIN documents d ON d.root_id = r.id
            GROUP BY r.id, r.path
            ORDER BY r.path
            """, []
        ) {
            RootStats(rootID: $0.int64(0), path: $0.text(1), documents: $0.int(2),
                      indexed: $0.int(3), pages: $0.int(4))
        }
    }

    /// Puts every unreadable document back in the queue — failures and
    /// unsupported formats alike, since a new version is exactly when either might
    /// start working.
    ///
    /// A rescan only re-reads files whose size or date moved, so a document that
    /// failed once stays failed — including when the reason was a bug that has
    /// since been fixed. This is the way back, without rebuilding the whole index.
    @discardableResult
    public func retryFailures() throws -> Int {
        try connection.transaction {
            let ids = try connection.query(
                "SELECT id FROM documents WHERE state IN (?, ?)",
                [.text(DocumentState.failed.rawValue),
                 .text(DocumentState.unsupported.rawValue)], { $0.int64(0) })
            for id in ids {
                try connection.run("""
                    INSERT INTO index_queue(doc_id, kind, enqueued_at) VALUES (?,?,?)
                    ON CONFLICT(doc_id) DO UPDATE SET kind = excluded.kind
                    """, [.int(id), .text(IndexJobKind.text.rawValue), .date(Date())])
            }
            try connection.run(
                "UPDATE documents SET state = ?, error = NULL WHERE state IN (?, ?)",
                [.text(DocumentState.pending.rawValue), .text(DocumentState.failed.rawValue),
                 .text(DocumentState.unsupported.rawValue)])
            return ids.count
        }
    }

    /// Wipes the index but keeps the roots, so the next pass rebuilds everything.
    public func resetIndex() throws {
        try connection.transaction {
            try connection.run("DELETE FROM pages_fts")
            try connection.run("DELETE FROM pages")
            try connection.run("DELETE FROM index_queue")
            try connection.run("""
                UPDATE documents SET state = ?, page_count = 0, indexed_at = NULL,
                                     needs_ocr = 0, error = NULL
                """, [.text(DocumentState.pending.rawValue)])
        }
        try connection.execute("VACUUM")
    }

    /// Online backup — safe to call while the app is indexing.
    public func backup(to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try connection.run("VACUUM INTO ?", [.text(destination.path)])
    }

    // MARK: - Helpers

    private static let documentColumns = """
    SELECT id, root_id, path, filename, ext, size, mtime, added_at, page_count,
           indexed_at, state, needs_ocr, error
    FROM documents
    """

    private static func decodeDocument(_ row: SQLRow) -> Document {
        Document(
            id: row.int64(0), rootID: row.int64(1), path: row.text(2), filename: row.text(3),
            ext: row.text(4), size: row.int64(5), modifiedAt: row.date(6), addedAt: row.date(7),
            pageCount: row.int(8), indexedAt: row.optionalDate(9),
            state: DocumentState(rawValue: row.text(10)) ?? .pending,
            needsOCR: row.bool(11), error: row.optionalText(12))
    }

    private static func fileSize(of url: URL) -> Int64 {
        let paths = [url.path, url.path + "-wal", url.path + "-shm"]
        return paths.reduce(into: Int64(0)) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            total += (attributes?[.size] as? Int64) ?? 0
        }
    }
}
