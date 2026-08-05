import Foundation

/// A folder the user asked us to watch.
public struct Root: Sendable, Identifiable, Equatable {
    public let id: Int64
    public let path: String
    public let bookmark: Data?
    public let addedAt: Date

    public init(id: Int64, path: String, bookmark: Data?, addedAt: Date) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.addedAt = addedAt
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var name: String { url.lastPathComponent }
}

public enum DocumentState: String, Sendable, CaseIterable {
    /// Discovered on disk, text not extracted yet.
    case pending
    /// Text extracted and searchable.
    case indexed
    /// Text extracted, but some pages carry no text layer and await OCR.
    case ocrPending = "ocr_pending"
    /// Extraction failed; `Document.error` says why.
    case failed
    /// A format PaperSift cannot read — modern iWork files, mostly. Kept apart
    /// from `failed` because there is nothing wrong with the file, and reporting a
    /// dozen Pages documents as "could not be read" sends people looking for a
    /// problem they do not have.
    case unsupported
}

/// What the indexer knows about a file that lives under a root.
public struct Document: Sendable, Identifiable, Equatable {
    public let id: Int64
    public let rootID: Int64
    public let path: String
    public let filename: String
    public let ext: String
    public let size: Int64
    public let modifiedAt: Date
    public let addedAt: Date
    public let pageCount: Int
    public let indexedAt: Date?
    public let state: DocumentState
    public let needsOCR: Bool
    public let error: String?

    public init(
        id: Int64, rootID: Int64, path: String, filename: String, ext: String, size: Int64,
        modifiedAt: Date, addedAt: Date, pageCount: Int, indexedAt: Date?,
        state: DocumentState, needsOCR: Bool, error: String?
    ) {
        self.id = id
        self.rootID = rootID
        self.path = path
        self.filename = filename
        self.ext = ext
        self.size = size
        self.modifiedAt = modifiedAt
        self.addedAt = addedAt
        self.pageCount = pageCount
        self.indexedAt = indexedAt
        self.state = state
        self.needsOCR = needsOCR
        self.error = error
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var isPDF: Bool { ext == "pdf" }
}

/// A file found on disk, before it has an identity in the database.
public struct DocumentCandidate: Sendable, Equatable {
    public var rootID: Int64
    public var path: String
    public var size: Int64
    public var modifiedAt: Date

    public init(rootID: Int64, path: String, size: Int64, modifiedAt: Date) {
        self.rootID = rootID
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var filename: String { url.lastPathComponent }
    public var ext: String { url.pathExtension.lowercased() }
}

/// Outcome of reconciling a candidate with what the database already holds.
public enum UpsertOutcome: Sendable, Equatable {
    /// First time we see this path.
    case created(Int64)
    /// Known path whose size or modification date moved — needs re-indexing.
    case changed(Int64)
    /// Known path, untouched since the last pass.
    case unchanged(Int64)

    public var documentID: Int64 {
        switch self {
        case .created(let id), .changed(let id), .unchanged(let id): id
        }
    }

    public var needsIndexing: Bool {
        switch self {
        case .created, .changed: true
        case .unchanged: false
        }
    }
}
