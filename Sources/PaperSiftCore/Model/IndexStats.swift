import Foundation

/// Snapshot of what the index holds — what the Index Status window shows.
public struct IndexStats: Sendable, Equatable {
    public var roots: Int
    public var documents: Int
    public var indexed: Int
    public var pending: Int
    public var ocrPending: Int
    public var failed: Int
    /// Files in a format we cannot read. Not errors.
    public var unsupported: Int
    public var pages: Int
    public var ocrPages: Int
    /// Pages still waiting to be recognized — the honest measure of how long OCR
    /// has left, since one document can hold a hundred of them.
    public var ocrPagesPending: Int
    /// Readable files with nothing in them: an empty spreadsheet, a logo-only
    /// page. Not failures.
    public var empty: Int
    public var queued: Int
    public var databaseBytes: Int64

    public init(
        roots: Int = 0, documents: Int = 0, indexed: Int = 0, pending: Int = 0,
        ocrPending: Int = 0, failed: Int = 0, unsupported: Int = 0,
        pages: Int = 0, ocrPages: Int = 0,
        ocrPagesPending: Int = 0, empty: Int = 0,
        queued: Int = 0, databaseBytes: Int64 = 0
    ) {
        self.roots = roots
        self.documents = documents
        self.indexed = indexed
        self.pending = pending
        self.ocrPending = ocrPending
        self.failed = failed
        self.unsupported = unsupported
        self.pages = pages
        self.ocrPages = ocrPages
        self.ocrPagesPending = ocrPagesPending
        self.empty = empty
        self.queued = queued
        self.databaseBytes = databaseBytes
    }

    public var isEmpty: Bool { documents == 0 }

    /// Documents still to do, whatever the reason.
    public var outstanding: Int { pending + ocrPending }

    /// Everything we could not turn into searchable pages, for either reason.
    public var unreadable: Int { failed + unsupported }

    /// Share of documents already searchable, 0…1. Useful for a progress bar.
    public var progress: Double {
        guard documents > 0 else { return 1 }
        return Double(indexed) / Double(documents)
    }
}

/// Per-folder breakdown, for the Index Status popover.
public struct RootStats: Sendable, Identifiable, Equatable {
    public var id: Int64 { rootID }

    public let rootID: Int64
    public let path: String
    public let documents: Int
    public let indexed: Int
    public let pages: Int

    public init(rootID: Int64, path: String, documents: Int, indexed: Int, pages: Int) {
        self.rootID = rootID
        self.path = path
        self.documents = documents
        self.indexed = indexed
        self.pages = pages
    }

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    public var progress: Double {
        guard documents > 0 else { return 1 }
        return Double(indexed) / Double(documents)
    }
}
