import Foundation
import PDFKit

/// Drives the whole indexing pipeline: scan a folder, extract text, write pages.
///
/// The queue lives in SQLite, so quitting mid-way and relaunching picks up where
/// it stopped. Extraction runs off the actor — `index(_:)` is `nonisolated` on
/// purpose, otherwise every document would be serialized behind this actor
/// instead of running `concurrency` at a time.
public actor IndexCoordinator {
    public struct Progress: Sendable, Equatable {
        public enum Phase: String, Sendable {
            case idle
            /// Reading text layers.
            case text
            /// Reading scans with Vision.
            case ocr
        }

        public var phase = Phase.idle
        public var indexed = 0
        public var ocrPages = 0
        public var failed = 0
        /// Valid files with nothing in them to index.
        public var skipped = 0
        /// Files in a format we cannot read. Kept apart from `skipped`, which
        /// means "readable and empty" — a different thing to report.
        public var unsupported = 0
        /// Documents waiting for text extraction.
        public var remaining = 0
        /// Documents waiting for OCR.
        public var ocrRemaining = 0
        /// The file being worked on right now — set when it *starts*, because a
        /// long scan can take minutes and silence reads as a hang.
        public var currentFilename: String?
        public var isPaused = false

        public init() {}

        public var isRunning: Bool { phase != .idle }

        /// What is left to do in the phase currently running.
        public var remainingInPhase: Int {
            switch phase {
            case .idle: 0
            case .text: remaining
            case .ocr: ocrRemaining
            }
        }
    }

    private enum Outcome: Sendable {
        case indexed(filename: String)
        case recognized(filename: String)
        /// Readable, but there was nothing to index.
        case skipped(filename: String)
        /// A format we cannot read.
        case unsupported(filename: String)
        case failed(filename: String, reason: String)
    }

    private let store: IndexStore
    private let extractors: ExtractorRegistry
    private let lemmatizer = Lemmatizer()
    private let concurrency: Int
    private let updates: AsyncStream<Progress>.Continuation
    /// Read by the OCR pass on every document, so a preference change takes
    /// effect without restarting anything.
    private var ocrSettings = OCRSettings.default

    /// Live progress for the UI. Single consumer — the Index Status view.
    public nonisolated let progress: AsyncStream<Progress>

    private var state = Progress()
    private var paused = false
    private var draining: Task<Void, Never>?

    public init(store: IndexStore, extractors: ExtractorRegistry = .default, concurrency: Int? = nil) {
        self.store = store
        self.extractors = extractors
        // Half the cores: indexing is a background chore and the machine belongs
        // to whoever is reading, not to us.
        self.concurrency = concurrency ?? max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        let (stream, continuation) = AsyncStream<Progress>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        self.progress = stream
        self.updates = continuation
    }

    // MARK: - Folders

    @discardableResult
    public func addFolder(_ url: URL) async throws -> Root {
        let root = try await store.addRoot(
            path: url.standardizedFileURL.path,
            bookmark: try? url.bookmarkData())
        try await rescan(root)
        return root
    }

    public func rescanAll() async throws {
        for root in try await store.roots() {
            try await rescan(root)
        }
    }

    /// Reconciles a folder with the index: new and modified files are queued,
    /// vanished ones are dropped.
    public func rescan(_ root: Root) async throws {
        let extensions = extractors.indexableExtensions
        let rootID = root.id
        let url = root.url
        // Off the actor: walking a deep folder can take a while and callers
        // (pause, progress) must stay responsive.
        let result = await Task.detached {
            DocumentScanner(extensions: extensions).scan(rootID: rootID, at: url)
        }.value

        for candidate in result.candidates {
            let outcome = try await store.upsert(candidate)
            if outcome.needsIndexing {
                try await store.enqueue(documentID: outcome.documentID, kind: .text)
            }
        }
        try await store.removeDocuments(
            underRoot: root.id, keeping: Set(result.candidates.map(\.path)))

        state.remaining = try await store.queueDepth(kind: .text)
        publish()
    }

    public func removeFolder(_ root: Root) async throws {
        try await store.removeRoot(id: root.id)
        state.remaining = try await store.queueDepth(kind: .text)
        publish()
    }

    // MARK: - Draining the queue

    public func apply(ocrSettings settings: OCRSettings) {
        ocrSettings = settings
    }

    /// Re-queues everything that failed, and gets to work on it.
    @discardableResult
    public func retryFailures() async throws -> Int {
        let count = try await store.retryFailures()
        try await refreshQueueDepths()
        start()
        return count
    }

    /// Works through the text queue, then the OCR queue, until both are empty (or
    /// paused). Returns the final progress snapshot — this is what `--index` and
    /// the checks use.
    @discardableResult
    public func runUntilIdle() async throws -> Progress {
        defer {
            state.phase = .idle
            state.currentFilename = nil
            publish()
        }

        state.phase = .text
        while !paused {
            let batch = try await store.nextJobs(kind: .text, limit: concurrency * 4)
            guard !batch.isEmpty else { break }
            try await refreshQueueDepths()
            await process(batch)
        }

        if ocrSettings.isEnabled {
            state.phase = .ocr
            while !paused {
                // One document at a time: Vision is already parallel inside, and
                // rasterized pages are large.
                let batch = try await store.nextJobs(kind: .ocr, limit: 1)
                guard !batch.isEmpty else { break }
                try await refreshQueueDepths()
                await process(batch)
            }
        }

        try await refreshQueueDepths()
        return state
    }

    private func refreshQueueDepths() async throws {
        state.remaining = try await store.queueDepth(kind: .text)
        state.ocrRemaining = try await store.queueDepth(kind: .ocr)
        publish()
    }

    /// Starts draining in the background, if it is not already running.
    public func start() {
        guard draining == nil, !paused else { return }
        draining = Task { [weak self] in
            guard let self else { return }
            _ = try? await self.runUntilIdle()
            await self.drainingFinished()
        }
    }

    public func pause() {
        paused = true
        state.isPaused = true
        publish()
    }

    public func resume() {
        paused = false
        state.isPaused = false
        publish()
        start()
    }

    private func drainingFinished() {
        draining = nil
    }

    private func process(_ jobs: [IndexJob]) async {
        // Settings are read here, on the actor, and handed to the workers: the
        // workers are nonisolated so they can actually run in parallel.
        let settings = ocrSettings
        await withTaskGroup(of: Outcome.self) { group in
            var pending = jobs.makeIterator()
            for _ in 0..<concurrency {
                guard let job = pending.next() else { break }
                group.addTask { await self.index(job, ocr: settings) }
            }
            while let outcome = await group.next() {
                record(outcome)
                // Stop feeding the group when paused; work already in flight
                // finishes so counters stay honest.
                if !paused, let job = pending.next() {
                    group.addTask { await self.index(job, ocr: settings) }
                }
            }
        }
    }

    private func record(_ outcome: Outcome) {
        switch outcome {
        case .indexed: state.indexed += 1
        case .recognized: break  // pages were counted one by one as they landed
        case .skipped: state.skipped += 1
        case .unsupported: state.unsupported += 1
        case .failed: state.failed += 1
        }
        publish()
    }

    /// Called by a worker as it picks a document up. Without this the UI shows a
    /// spinner and no filename for however long the first document takes.
    private func noteStarted(_ filename: String) {
        state.currentFilename = filename
        publish()
    }

    /// Called after every OCR'd page, so a fifty-page scan visibly advances
    /// instead of reporting nothing until the whole document is done.
    private func notePageRecognized() {
        state.ocrPages += 1
        publish()
    }

    private func publish() {
        updates.yield(state)
    }

    // MARK: - One document

    /// Deliberately `nonisolated`: this is the CPU-bound half of the pipeline and
    /// it must run in parallel, not queued behind the actor.
    private nonisolated func index(_ job: IndexJob, ocr settings: OCRSettings) async -> Outcome {
        switch job.kind {
        case .text: await extractText(job)
        case .ocr: await recognize(job, settings: settings)
        }
    }

    private nonisolated func extractText(_ job: IndexJob) async -> Outcome {
        let url = URL(fileURLWithPath: job.path)
        let filename = url.lastPathComponent
        await noteStarted(filename)
        do {
            var pages = try extractors.extract(from: url)
            guard !pages.isEmpty else {
                return await markSkipped(job, filename: filename, reason: "no readable page")
            }

            for index in pages.indices {
                pages[index].lemmas = lemmatizer.lemmas(of: pages[index].body)
            }

            // Only a PDF page can be rasterized and read by Vision. A short text
            // file is short, not scanned — routing one to OCR sent it to
            // `PDFDocument(url:)`, which failed, and it surfaced as "could not be
            // read" for a file that had been read perfectly well.
            let isPDF = url.pathExtension.lowercased() == "pdf"
            let needsOCR = isPDF && pages.contains { $0.looksLikeScan && !$0.fromOCR }
            let state: DocumentState = needsOCR ? .ocrPending : .indexed
            try await store.replacePages(pages, documentID: job.documentID, state: state)

            if needsOCR {
                // Same row, new kind: the document leaves the text queue and
                // joins the OCR queue.
                try await store.enqueue(documentID: job.documentID, kind: .ocr)
            } else {
                try await store.dequeue(documentID: job.documentID)
            }
            return .indexed(filename: filename)
        } catch let error as ExtractionError {
            switch error {
            case .empty:
                // A valid file with no text is not a failure — an empty
                // spreadsheet, a logo-only page. Counting those as "could not be
                // read" sends people hunting for a problem that is not there.
                return await markSkipped(job, filename: filename, reason: error.description)
            case .unsupportedFormat:
                // Nothing wrong with the file; we simply cannot read the format.
                try? await store.setState(
                    .unsupported, id: job.documentID, error: error.description)
                try? await store.dequeue(documentID: job.documentID)
                return .unsupported(filename: filename)
            case .unreadable, .encrypted:
                return await markFailed(job, filename: filename, error: error)
            }
        } catch {
            return await markFailed(job, filename: filename, error: error)
        }
    }

    /// Readable, nothing to index: recorded as done so it is not retried, but not
    /// reported as broken.
    private nonisolated func markSkipped(
        _ job: IndexJob, filename: String, reason: String
    ) async -> Outcome {
        try? await store.replacePages([], documentID: job.documentID, state: .indexed)
        try? await store.dequeue(documentID: job.documentID)
        return .skipped(filename: filename)
    }

    private nonisolated func markFailed(
        _ job: IndexJob, filename: String, error: Error
    ) async -> Outcome {
        let reason = (error as? ExtractionError)?.description ?? String(describing: error)
        try? await store.setState(.failed, id: job.documentID, error: reason)
        try? await store.dequeue(documentID: job.documentID)
        return .failed(filename: filename, reason: reason)
    }

    /// Reads the pages of a document that carry no text layer.
    private nonisolated func recognize(_ job: IndexJob, settings: OCRSettings) async -> Outcome {
        let url = URL(fileURLWithPath: job.path)
        let filename = url.lastPathComponent
        await noteStarted(filename)
        guard url.pathExtension.lowercased() == "pdf" else {
            // An index written by an older build can hold non-PDFs in this queue.
            // There is nothing to rasterize, and nothing wrong with the file.
            try? await store.markOCRComplete(id: job.documentID)
            try? await store.dequeue(documentID: job.documentID)
            return .skipped(filename: filename)
        }
        do {
            guard let document = PDFDocument(url: url) else {
                throw ExtractionError.unreadable("\(filename) could not be opened")
            }
            let service = OCRService(settings: settings)
            let scans = try await store.scanPages(documentID: job.documentID)

            for (position, scan) in scans.enumerated() {
                guard let page = document.page(at: scan.pageNumber - 1) else { continue }
                // Long documents report which page they are on, otherwise a
                // hundred-page scan looks identical to a hang.
                if scans.count > 1 {
                    await noteStarted("\(filename) — page \(position + 1) of \(scans.count)")
                }
                let result = try await service.recognize(page: page)
                guard !result.isEmpty else { continue }
                try await store.replacePage(
                    PageContent(
                        pageNumber: scan.pageNumber,
                        body: result.text,
                        title: result.title,
                        lemmas: lemmatizer.lemmas(of: result.text),
                        fromOCR: true,
                        layout: try? result.layout.encoded()),
                    documentID: job.documentID)
                await notePageRecognized()
            }

            // Even when nothing was legible: the document has had its turn.
            try await store.markOCRComplete(id: job.documentID)
            try await store.dequeue(documentID: job.documentID)
            return .recognized(filename: filename)
        } catch {
            return await markFailed(job, filename: filename, error: error)
        }
    }
}
