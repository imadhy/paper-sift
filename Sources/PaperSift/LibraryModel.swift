import AppKit
import Foundation
import PaperSiftCore
import SwiftUI

/// Everything the window needs, in one observable place.
///
/// The store and the indexer are actors; this is the only thing that talks to
/// them from the main actor, which keeps the views free of `await` and of any
/// concurrency reasoning.
@MainActor
@Observable
final class LibraryModel {
    // MARK: - Published state

    var queryText = "" {
        didSet { if queryText != oldValue { scheduleSearch() } }
    }

    private(set) var roots: [Root] = []
    private(set) var rootStats: [RootStats] = []
    private(set) var failures: [Document] = []
    private(set) var results: SearchResults?
    private(set) var isSearching = false
    private(set) var progress = IndexCoordinator.Progress()
    private(set) var stats = IndexStats()
    private(set) var failure: String?

    /// The document whose pages are on screen.
    var selectedDocumentID: Int64? {
        didSet {
            guard selectedDocumentID != oldValue else { return }
            selectedPageIndex = 0
        }
    }

    /// Which of the selected document's hits is showing, as an index into `hits`.
    var selectedPageIndex = 0

    /// True when the highlight belongs on a page row rather than on its document row.
    private var showsPageRow = false

    /// Documents whose matching pages are listed underneath them.
    private(set) var expandedDocumentIDs: Set<Int64> = []

    /// Restricts the search to one folder. `nil` searches everything.
    var scopedRootID: Int64? {
        didSet { if scopedRootID != oldValue { scheduleSearch(debounce: false) } }
    }

    /// The sidebar's selection, which is `scopedRootID` seen as a selectable value.
    var scope: SearchScope {
        get { SearchScope(rootID: scopedRootID) }
        set { scopedRootID = newValue.rootID }
    }

    var sort: ResultSort = AppSettings.shared.resultSort {
        didSet { AppSettings.shared.resultSort = sort }
    }

    var sortReversed = AppSettings.shared.resultSortReversed {
        didSet { AppSettings.shared.resultSortReversed = sortReversed }
    }

    // MARK: - Collaborators

    let store: IndexStore
    private let coordinator: IndexCoordinator
    private let engine: SearchEngine
    private var searchTask: Task<Void, Never>?
    private var watcher: FolderWatcher?

    init(store: IndexStore) {
        self.store = store
        self.coordinator = IndexCoordinator(store: store)
        self.engine = SearchEngine(store: store)
    }

    // MARK: - Derived

    var selectedDocument: DocumentResult? {
        guard let selectedDocumentID else { return nil }
        return results?.documents.first { $0.documentID == selectedDocumentID }
    }

    var selectedHit: PageHit? {
        guard let document = selectedDocument, !document.hits.isEmpty else { return nil }
        return document.hits[min(selectedPageIndex, document.hits.count - 1)]
    }

    /// The documents to draw, in the order the sort control asks for.
    var displayedDocuments: [DocumentResult] {
        guard let documents = results?.documents else { return [] }
        let ordered = sort.apply(to: documents)
        return sortReversed ? ordered.reversed() : ordered
    }

    /// Where a page sits in the overall ordering — the number on its badge.
    func rank(of hit: PageHit) -> Int? {
        results?.rank(ofPage: hit.pageID)
    }

    // MARK: - Selection

    /// The results list's selection, mapped onto the document and page the viewer
    /// is already driven by.
    var resultSelection: ResultSelection? {
        get {
            guard let selectedDocumentID else { return nil }
            guard showsPageRow, let hit = selectedHit else { return .document(selectedDocumentID) }
            return .page(document: selectedDocumentID, pageID: hit.pageID)
        }
        set {
            // A click on empty space hands back `nil`. Emptying the viewer for it
            // would be a strange way to reward missing a row.
            guard let newValue else { return }
            switch newValue {
            case .document(let id):
                select(documentID: id)
            case .page(let id, let pageID):
                select(documentID: id)
                if let index = selectedDocument?.hits.firstIndex(where: { $0.pageID == pageID }) {
                    selectedPageIndex = index
                }
                showsPageRow = true
            }
        }
    }

    /// Selects a document and opens its list of matching pages — clicking a
    /// document is also how you ask what else is in it.
    private func select(documentID: Int64) {
        selectedDocumentID = documentID
        showsPageRow = false
        expandedDocumentIDs.insert(documentID)
    }

    func isExpanded(_ documentID: Int64) -> Bool {
        expandedDocumentIDs.contains(documentID)
    }

    func toggleExpansion(_ documentID: Int64) {
        if expandedDocumentIDs.contains(documentID) {
            expandedDocumentIDs.remove(documentID)
        } else {
            expandedDocumentIDs.insert(documentID)
        }
    }

    var hasQuery: Bool { !queryText.trimmingCharacters(in: .whitespaces).isEmpty }

    var statusLine: String {
        guard let results, hasQuery else {
            return stats.documents == 0
                ? "No documents indexed yet"
                : "\(stats.documents.formatted()) documents · \(stats.pages.formatted()) pages indexed"
        }
        if results.documents.isEmpty { return "No match" }
        let milliseconds = Double(results.duration.components.attoseconds) / 1e15
            + Double(results.duration.components.seconds) * 1_000
        return String(
            format: "%d documents · %d pages · %.0f ms",
            results.documentCount, results.pageCount, milliseconds)
    }

    // MARK: - Lifecycle

    var databaseURL: URL { store.url }

    func bootstrap() async {
        await coordinator.apply(ocrSettings: AppSettings.shared.ocrSettings)
        await refreshRoots()
        await refreshStats()
        await refreshRootStats()
        observeProgress()
        warmUpLanguageModels()
        if let query = AppConfiguration.initialQuery, !query.isEmpty {
            queryText = query
        }
        await coordinator.rescanAllIgnoringErrors()
        await coordinator.start()
        startWatching()
    }

    /// The first query of a session otherwise pays a few hundred milliseconds to
    /// load Apple's language models. Do it now, while the user is still reading the
    /// window.
    ///
    /// The word is deliberately not a real one: `lemma(ofTerm:)` returns as soon as
    /// a language changes it, so warming up with "documents" would only load the
    /// first language and leave the rest for the first real query.
    private func warmUpLanguageModels() {
        Task.detached(priority: .utility) {
            _ = Lemmatizer().lemma(ofTerm: "zzqx")
        }
    }

    private func observeProgress() {
        Task { [weak self] in
            guard let self else { return }
            var lastRefresh = ContinuousClock().now
            for await update in coordinator.progress {
                self.progress = update
                // Stats used to be refreshed only when the whole run finished,
                // which left the counters frozen for the entire OCR pass — the app
                // looked stuck while it was working. Refresh as it goes, throttled
                // so a hundred documents a second do not mean a hundred queries.
                let now = ContinuousClock().now
                if !update.isRunning || lastRefresh.duration(to: now) > .seconds(2) {
                    lastRefresh = now
                    await self.refreshStats()
                    // The sidebar shows a count per folder, so those move too.
                    await self.refreshRootStats()
                }
            }
        }
    }

    private func startWatching() {
        let paths = roots.map(\.path)
        guard !paths.isEmpty else { return }
        watcher = FolderWatcher { [weak self] _ in
            Task { @MainActor [weak self] in await self?.rescan() }
        }
        watcher?.watch(paths)
    }

    // MARK: - Folders

    func addFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Index"
        panel.message = "Pick a folder — everything inside it becomes searchable."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            _ = try await coordinator.addFolder(url)
            await refreshRoots()
            await refreshRootStats()
            startWatching()
            await coordinator.start()
        } catch {
            failure = "Could not add \(url.lastPathComponent): \(error)"
        }
    }

    func removeFolder(_ root: Root) async {
        do {
            try await coordinator.removeFolder(root)
            if scopedRootID == root.id { scopedRootID = nil }
            await refreshRoots()
            await refreshStats()
            await refreshRootStats()
            await runSearch(queryText)
        } catch {
            failure = "Could not remove \(root.name): \(error)"
        }
    }

    func rescan() async {
        await coordinator.rescanAllIgnoringErrors()
        await coordinator.start()
    }

    func pauseOrResumeIndexing() async {
        if progress.isPaused {
            await coordinator.resume()
        } else {
            await coordinator.pause()
        }
    }

    private func refreshRoots() async {
        do { roots = try await store.roots() } catch { failure = "\(error)" }
    }

    private func refreshStats() async {
        do { stats = try await store.stats() } catch { failure = "\(error)" }
    }

    func refreshRootStats() async {
        do {
            rootStats = try await store.rootStats()
            failures = try await store.unreadableDocuments()
        } catch {
            failure = "\(error)"
        }
    }

    // MARK: - What the indexer is doing, in words

    /// One line describing the work in flight.
    ///
    /// The phase matters: during OCR the text queue is empty, so reporting
    /// `progress.remaining` here is what produced a permanent "Indexing · 0 left"
    /// while Vision chewed through a hundred scans.
    var activityLabel: String? {
        if progress.isPaused {
            return "Paused · \(outstandingLabel) left"
        }
        switch progress.phase {
        case .text:
            return "Reading text · \(progress.remaining.formatted()) left"
        case .ocr:
            let pages = max(stats.ocrPagesPending, 1)
            return "Recognizing scans · \(pages.formatted()) pages left"
        case .idle:
            guard stats.outstanding > 0 else { return nil }
            return "Waiting · \(outstandingLabel) left"
        }
    }

    private var outstandingLabel: String {
        stats.outstanding.formatted()
    }

    var isBusy: Bool {
        progress.isRunning || stats.outstanding > 0
    }

    /// "12 in an unsupported format" reads very differently from "12 could not be
    /// read", and only one of them is true for a folder full of Pages documents.
    var unreadableSummary: String {
        switch (stats.failed, stats.unsupported) {
        case (let failed, 0):
            "\(failed) could not be read"
        case (0, let unsupported):
            "\(unsupported) in an unsupported format"
        case (let failed, let unsupported):
            "\(failed) unreadable · \(unsupported) unsupported"
        }
    }

    // MARK: - Settings actions

    func applyOCRSettings(_ settings: OCRSettings) async {
        await coordinator.apply(ocrSettings: settings)
        // Enabling OCR should get to work, not wait for the next launch.
        if settings.isEnabled { await coordinator.start() }
    }

    /// The full text of a hit's page, with every match marked — the text reader's
    /// content for documents that have no pages to render.
    func pageSnippet(for hit: PageHit) async -> Snippet? {
        guard let body = try? await store.pageBody(pageID: hit.pageID) else { return nil }
        return Snippet.full(body, highlighting: hit.matchedText)
    }

    /// The OCR word boxes for a hit, when it came from a scan.
    func layout(for hit: PageHit) async -> OCRLayout? {
        guard hit.fromOCR else { return nil }
        guard let data = try? await store.ocrLayout(pageID: hit.pageID) else { return nil }
        return try? OCRLayout.decode(data)
    }

    /// Give the unreadable ones another go — after an update, the reason may be
    /// gone.
    func retryFailures() async {
        do {
            _ = try await coordinator.retryFailures()
            await refreshStats()
            await refreshRootStats()
        } catch {
            failure = "Could not retry: \(error)"
        }
    }

    func rebuildIndex() async {
        do {
            try await store.resetIndex()
            results = nil
            selectedDocumentID = nil
            await refreshStats()
            await rescan()
        } catch {
            failure = "Could not rebuild the index: \(error)"
        }
    }

    func backupIndex() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PaperSift-index-backup.sqlite"
        panel.message = "Where should the index copy go?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await store.backup(to: url)
        } catch {
            failure = "Backup failed: \(error)"
        }
    }

    func revealDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    /// Copies the index to a folder the user picks and remembers it.
    /// Returns whether a relaunch is now needed.
    func moveDatabase() async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Move Here"
        panel.message = "Pick the folder that should hold the index."
        guard panel.runModal() == .OK, let folder = panel.url else { return false }

        let destination = folder.appendingPathComponent("index.sqlite")
        guard destination.standardizedFileURL != store.url.standardizedFileURL else { return false }
        do {
            // VACUUM INTO writes a clean, consistent copy even while indexing.
            try await store.backup(to: destination)
            AppSettings.shared.customDatabasePath = destination.path
            return true
        } catch {
            failure = "Could not move the index: \(error)"
            return false
        }
    }

    func relaunch() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    // MARK: - Searching

    /// Typing restarts the search; the previous one is cancelled mid-flight so a
    /// fast typist never waits on stale work.
    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        let text = queryText
        searchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            await self?.runSearch(text)
        }
    }

    private func runSearch(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = nil
            selectedDocumentID = nil
            expandedDocumentIDs = []
            isSearching = false
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await engine.search(text, rootID: scopedRootID)
            guard !Task.isCancelled else { return }
            results = found
            // Documents that fell out of the results must not keep their disclosure
            // state, or a later search that brings one back opens it for no reason.
            let alive = Set(found.documents.map(\.documentID))
            expandedDocumentIDs.formIntersection(alive)
            // Keep the selection when it still matches, otherwise take the top hit.
            if let current = selectedDocumentID, alive.contains(current) {
                return
            }
            if let best = found.documents.first?.documentID {
                select(documentID: best)
            } else {
                selectedDocumentID = nil
            }
            selectedPageIndex = 0
        } catch is CancellationError {
            // Superseded by a newer keystroke.
        } catch {
            failure = "\(error)"
        }
    }

    // MARK: - Navigating hits

    /// Walking through matches moves the highlight onto the page rows, so the list
    /// and the viewer never disagree about which match is on screen.
    func showNextHit() {
        guard let document = selectedDocument else { return }
        selectedPageIndex = min(selectedPageIndex + 1, document.hits.count - 1)
        showsPageRow = true
        expandedDocumentIDs.insert(document.documentID)
    }

    func showPreviousHit() {
        guard let document = selectedDocument else { return }
        selectedPageIndex = max(selectedPageIndex - 1, 0)
        showsPageRow = true
        expandedDocumentIDs.insert(document.documentID)
    }

    func selectNextDocument() {
        move(by: 1)
    }

    func selectPreviousDocument() {
        move(by: -1)
    }

    /// Follows the order on screen, not the ranker's — otherwise "next result" jumps
    /// around as soon as the list is sorted by name.
    private func move(by offset: Int) {
        let documents = displayedDocuments
        guard !documents.isEmpty else { return }
        guard let current = selectedDocumentID,
              let index = documents.firstIndex(where: { $0.documentID == current })
        else {
            if let first = documents.first?.documentID { select(documentID: first) }
            return
        }
        let next = (index + offset + documents.count) % documents.count
        select(documentID: documents[next].documentID)
    }

    func revealInFinder() {
        guard let url = selectedDocument?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInDefaultApp() {
        guard let url = selectedDocument?.url else { return }
        NSWorkspace.shared.open(url)
    }

    func dismissFailure() {
        failure = nil
    }
}

private extension IndexCoordinator {
    /// Rescanning is best-effort: a folder that disappeared or lost permission
    /// must not stop the app from starting.
    func rescanAllIgnoringErrors() async {
        try? await rescanAll()
    }
}
