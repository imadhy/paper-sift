import Foundation

/// Database layout and migrations.
///
/// Two things are worth knowing before touching this file:
///
/// * `pages.id` and `pages_fts.rowid` are kept **aligned** — a page's text is
///   inserted into the FTS table under the rowid the `pages` row just got. That
///   is what lets us join metadata and matches without a second lookup table.
/// * `pages_fts` stores the page text instead of using `content=''`. A
///   contentless FTS5 table cannot serve `snippet()` / `highlight()`, and the
///   text is cheap — roughly 1 MB per 500 pages.
enum Schema {
    static let latestVersion = 2

    static func migrate(_ database: SQLiteConnection) throws {
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA foreign_keys = ON")

        var version = try database.userVersion()
        if version < 1 {
            try database.transaction { try createV1(database) }
            version = 1
            try database.setUserVersion(version)
        }
        if version < 2 {
            try compactOCRLayouts(database)
            version = 2
            try database.setUserVersion(version)
        }
    }

    /// v1 wrote word boxes with full `Double` precision — eighteen characters for a
    /// coordinate that needs six — which doubled the size of every OCR'd page's
    /// layout. Rewrite them once, in batches, rather than asking people to re-run
    /// OCR across a whole library to reclaim the space.
    ///
    /// The file itself does not shrink: SQLite keeps the freed pages and reuses
    /// them. Running `VACUUM` here would return them, but it rewrites the entire
    /// database at launch, and a search index that reuses its own free space is a
    /// better trade than a slow first start.
    private static func compactOCRLayouts(_ database: SQLiteConnection) throws {
        var lastID: Int64 = 0
        while true {
            // Batched: a library of scans holds gigabytes of layouts, and loading
            // them all to save a few megabytes would be a poor exchange.
            let rows = try database.query("""
                SELECT page_id, data FROM ocr_layout
                WHERE page_id > ? ORDER BY page_id LIMIT 500
                """, [.int(lastID)], { (id: $0.int64(0), data: $0.blob(1)) })
            guard let last = rows.last else { return }
            try database.transaction {
                for row in rows {
                    guard let compact = OCRLayout.recompacted(row.data) else { continue }
                    try database.run(
                        "UPDATE ocr_layout SET data = ? WHERE page_id = ?",
                        [.blob(compact), .int(row.id)])
                }
            }
            lastID = last.id
        }
    }

    private static func createV1(_ database: SQLiteConnection) throws {
        try database.execute("""
        CREATE TABLE roots(
            id        INTEGER PRIMARY KEY,
            path      TEXT NOT NULL UNIQUE,
            bookmark  BLOB,
            added_at  REAL NOT NULL);

        CREATE TABLE documents(
            id         INTEGER PRIMARY KEY,
            root_id    INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
            path       TEXT NOT NULL UNIQUE,
            filename   TEXT NOT NULL,
            ext        TEXT NOT NULL,
            size       INTEGER NOT NULL,
            mtime      REAL NOT NULL,
            added_at   REAL NOT NULL,
            page_count INTEGER NOT NULL DEFAULT 0,
            indexed_at REAL,
            state      TEXT NOT NULL DEFAULT 'pending',
            needs_ocr  INTEGER NOT NULL DEFAULT 0,
            error      TEXT);

        CREATE INDEX documents_root_idx  ON documents(root_id);
        CREATE INDEX documents_state_idx ON documents(state);

        CREATE TABLE pages(
            id         INTEGER PRIMARY KEY,
            doc_id     INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            page_no    INTEGER NOT NULL,
            char_count INTEGER NOT NULL DEFAULT 0,
            from_ocr   INTEGER NOT NULL DEFAULT 0,
            UNIQUE(doc_id, page_no));

        CREATE INDEX pages_doc_idx ON pages(doc_id);

        CREATE VIRTUAL TABLE pages_fts USING fts5(
            body,
            title,
            lemmas,
            tokenize = 'unicode61 remove_diacritics 2',
            prefix   = '2 3 4');

        CREATE TABLE ocr_layout(
            page_id INTEGER PRIMARY KEY REFERENCES pages(id) ON DELETE CASCADE,
            data    BLOB NOT NULL);

        CREATE TABLE index_queue(
            doc_id      INTEGER PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
            kind        TEXT NOT NULL,
            enqueued_at REAL NOT NULL);
        """)
    }
}
