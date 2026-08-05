import Foundation
import PaperSiftCore

/// The headless harness: `--stats`, and later `--index` / `--search` / `--ocr`.
///
/// Same idea as juice-flow's `--dump`: a feedback loop that needs no window, and
/// something CI can run to prove the pipeline still works.
enum CLI {
    static let usage = """
    PaperSift — search inside your documents.

    USAGE
      PaperSift                     launch the app
      PaperSift --query <text>      launch the app with the search field filled
      PaperSift --index <folder>    add a folder and index everything under it
      PaperSift --search <query>    search the index and print ranked pages
      PaperSift --stats             print what the index holds
      PaperSift --failures          list the files that could not be read, and why
      PaperSift --diagnose <file>   try to extract one file and say what happened
      PaperSift --retry-failures    queue the unreadable ones again and re-read them
      PaperSift --check-update      ask GitHub for the latest release
      PaperSift --install-update    download it and replace this bundle
      PaperSift --version           print the version
      PaperSift --help              print this

    OPTIONS
      --database <path>             use another index file, instead of
                                    ~/Library/Application Support/PaperSift/index.sqlite
      --limit <n>                   how many documents --search prints (default 10)
      --repeat <n>                  run the search n times and time each pass, to
                                    separate warm-up from steady-state latency

    QUERY SYNTAX
      annual report                 both words count; pages with both rank higher
      "annual report"               that exact phrase
      +turbine                      mandatory
      -draft                        excluded
      econom*                       prefix
      *nomic   eco*mic              suffix / infix — matched by scanning, slower
    """

    enum Disposition {
        /// A command ran; the process is done.
        case handled
        /// Open the window. `database` is nil unless `--database` said otherwise,
        /// so the app can fall back to the user's preference.
        case launchApp(database: URL?, query: String?)
    }

    @MainActor
    static func handle(_ arguments: [String]) -> Disposition {
        let databaseArgument = value(of: "--database", in: arguments)
        let explicitDatabase = databaseArgument.map { URL(fileURLWithPath: $0).standardizedFileURL }
        // Commands work on the same index the window would open.
        let database = explicitDatabase ?? AppSettings.shared.databaseURL
        let queryArgument = value(of: "--query", in: arguments)
        guard !arguments.isEmpty else { return .launchApp(database: nil, query: nil) }

        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return .handled
        }
        if arguments.contains("--version") {
            print(version)
            return .handled
        }
        if arguments.contains("--stats") {
            blocking { await printStats(database: database) }
            return .handled
        }
        if arguments.contains("--failures") {
            blocking { await printFailures(database: database) }
            return .handled
        }
        if let path = value(of: "--diagnose", in: arguments) {
            diagnose(path: path)
            return .handled
        }
        if arguments.contains("--retry-failures") {
            blocking { await retryFailures(database: database) }
            return .handled
        }
        if let folder = value(of: "--index", in: arguments) {
            blocking { await index(folder: folder, database: database) }
            return .handled
        }
        if arguments.contains("--check-update") || arguments.contains("--install-update") {
            let install = arguments.contains("--install-update")
            blocking { await updateCLI(install: install) }
            return .handled
        }
        if let query = value(of: "--search", in: arguments) {
            let limit = value(of: "--limit", in: arguments).flatMap(Int.init) ?? 10
            let passes = value(of: "--repeat", in: arguments).flatMap(Int.init) ?? 1
            blocking { await search(query: query, database: database, limit: limit, passes: passes) }
            return .handled
        }
        // `--database` and `--query` on their own open the window instead of
        // running a command — a scratch index and a pre-filled field are how the
        // UI gets exercised. Compare against the arguments as typed: standardizing
        // a path turns /private/tmp into /tmp.
        let launchFlags: Set<String?> = ["--database", "--query", databaseArgument, queryArgument]
        if arguments.allSatisfy({ launchFlags.contains($0) }) {
            return .launchApp(database: explicitDatabase, query: queryArgument)
        }

        FileHandle.standardError.write(
            Data("Unknown arguments: \(arguments.joined(separator: " "))\n\n".utf8))
        print(usage)
        exit(2)
    }

    private static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0 (unbundled)"
    }

    // MARK: - Commands

    private static func printStats(database: URL) async {
        do {
            let store = try IndexStore(url: database)
            let stats = try await store.stats()
            print("""
            Index      \(database.path)
            Size       \(stats.databaseBytes.formatted(.byteCount(style: .file)))
            Folders    \(stats.roots)
            Documents  \(stats.documents)  (\(stats.indexed) indexed, \(stats.pending) pending, \
            \(stats.ocrPending) awaiting OCR, \(stats.failed) failed, \
            \(stats.unsupported) unsupported)
            Pages      \(stats.pages)  (\(stats.ocrPages) from OCR)
            To OCR     \(stats.ocrPagesPending) pages in \(stats.ocrPending) documents
            No text     \(stats.empty) documents were readable but hold nothing
            Queue      \(stats.queued)
            """)
        } catch {
            fail(error)
        }
    }

    private static func printFailures(database: URL) async {
        do {
            let store = try IndexStore(url: database)
            let failures = try await store.unreadableDocuments()
            guard !failures.isEmpty else {
                print("Nothing failed.")
                return
            }
            print("\(failures.count) documents produced no searchable pages:\n")
            for document in failures {
                print("  \(document.filename)")
                print("    \(document.error ?? "unknown reason")")
                print("    \(document.url.deletingLastPathComponent().path)")
            }
        } catch {
            fail(error)
        }
    }

    private static func retryFailures(database: URL) async {
        do {
            let store = try IndexStore(url: database)
            let coordinator = IndexCoordinator(store: store)
            let requeued = try await store.retryFailures()
            guard requeued > 0 else {
                print("Nothing was marked as failed.")
                return
            }
            print("Re-reading \(requeued) documents…")
            let result = try await coordinator.runUntilIdle()
            print("""
            Indexed \(result.indexed)\
            \(result.skipped > 0 ? ", \(result.skipped) had no text" : "")\
            \(result.unsupported > 0 ? ", \(result.unsupported) in an unsupported format" : "")\
            \(result.failed > 0 ? ", \(result.failed) still cannot be read" : "")
            """)
            for document in try await store.unreadableDocuments(limit: 20) {
                print("  ✗ \(document.filename): \(document.error ?? "unknown reason")")
            }
        } catch {
            fail(error)
        }
    }

    /// Runs one file through extraction and reports what came back.
    ///
    /// This exists because "could not be read" in the UI is a dead end otherwise —
    /// with this you can point at the file and see exactly which extractor claimed
    /// it and what it said. Page text is summarized, never printed.
    private static func diagnose(path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        print("File       \(url.path)")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        print("Size       \(size.formatted(.byteCount(style: .file)))")
        print("Extension  .\(url.pathExtension.lowercased())")

        let registry = ExtractorRegistry.default
        guard let extractor = registry.extractor(for: url) else {
            print("Extractor  none — PaperSift does not read this format")
            exit(1)
        }
        print("Extractor  \(type(of: extractor))")

        do {
            let pages = try extractor.extract(from: url)
            let characters = pages.reduce(0) { $0 + $1.body.count }
            // Only PDFs can go to OCR, so only mention it for them.
            let scans = url.pathExtension.lowercased() == "pdf"
                ? pages.filter(\.looksLikeScan).count : 0
            print("Result     \(pages.count) pages, \(characters) characters"
                + (scans > 0 ? ", \(scans) with no text layer (OCR will read those)" : ""))
            if let first = pages.first(where: { !$0.title.isEmpty }) {
                print("Heading    \(first.title.prefix(70))")
            }
        } catch let error as ExtractionError {
            print("Result     \(error.isFailure ? "failed" : "nothing to index")")
            print("Reason     \(error)")
            exit(error.isFailure ? 1 : 0)
        } catch {
            print("Result     failed")
            print("Reason     \(error)")
            exit(1)
        }
    }

    private static func index(folder: String, database: URL) async {
        let url = URL(fileURLWithPath: folder).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("No such folder: \(url.path)\n".utf8))
            exit(1)
        }
        do {
            let store = try IndexStore(url: database)
            let coordinator = IndexCoordinator(store: store)
            let clock = ContinuousClock()
            let start = clock.now
            try await coordinator.addFolder(url)
            let result = try await coordinator.runUntilIdle()
            let elapsed = start.duration(to: clock.now)

            let stats = try await store.stats()
            print("""
            Indexed \(result.indexed) documents in \(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))\
            \(result.failed > 0 ? " — \(result.failed) failed" : "")\
            \(result.skipped > 0 ? " — \(result.skipped) had no text" : "")\
            \(result.unsupported > 0 ? " — \(result.unsupported) in an unsupported format" : "")
            Pages   \(stats.pages)  (\(result.ocrPages) recognized by OCR)
            OCR     \(stats.ocrPagesPending) pages still queued
            """)
            for document in try await store.documents(state: .failed, limit: 10) {
                print("  ✗ \(document.filename): \(document.error ?? "unknown error")")
            }
        } catch {
            fail(error)
        }
    }

    private static func search(query: String, database: URL, limit: Int, passes: Int) async {
        do {
            let store = try IndexStore(url: database)
            let engine = SearchEngine(store: store)

            var results = try await engine.search(query, documentLimit: limit)
            var timings = [milliseconds(results.duration)]
            for _ in 1..<max(1, passes) {
                results = try await engine.search(query, documentLimit: limit)
                timings.append(milliseconds(results.duration))
            }

            let timing = timings.count == 1
                ? String(format: "%.1f ms", timings[0])
                : String(format: "%.1f ms first pass, then %@",
                         timings[0],
                         timings.dropFirst().map { String(format: "%.1f", $0) }
                            .joined(separator: " / ") + " ms")
            print(String(
                format: "%d of %d documents, %d matching pages in %@%@%@",
                results.documents.count, results.documentCount, results.pageCount, timing,
                results.usedScan ? "  [scanned: FTS5 cannot index that wildcard]" : "",
                results.truncated ? "  [shortlist full: there may be more]" : ""))

            for (rank, document) in results.documents.enumerated() {
                let hit = document.bestHit
                print(String(
                    format: "\n%2d. %@  ·  page %d/%d  ·  score %.2f%@",
                    rank + 1, document.filename, hit.pageNumber, document.pageCount,
                    document.score, hit.fromOCR ? "  (OCR)" : ""))
                print("    \(document.folder)")
                print("    \(highlighted(hit.snippet))")
                if document.hits.count > 1 {
                    let others = document.hits.dropFirst().prefix(6).map { "\($0.pageNumber)" }
                    print("    also on pages \(others.joined(separator: ", "))")
                }
            }
        } catch {
            fail(error)
        }
    }

    /// `--check-update` asks GitHub what the latest release is; `--install-update`
    /// performs the same swap the app does, without relaunching.
    private static func updateCLI(install: Bool) async {
        print("Installed version: \(UpdateService.currentVersion)")
        do {
            let release = try await UpdateService.fetchLatest(from: UpdateService.feedURL)
            guard UpdateService.isNewer(release.version, than: UpdateService.currentVersion) else {
                print("Up to date — latest release is \(release.version).")
                return
            }
            print("New version: \(release.version) (\(release.zipURL?.absoluteString ?? "no .zip asset"))")
            guard install else { return }
            // Homebrew keeps its own receipt of what is installed; swapping the
            // bundle here would make it wrong. Hand the job over.
            if case .homebrew(let command) = UpdateService.ownership {
                print("This copy is managed by Homebrew. Run:\n\n    \(command)\n")
                return
            }
            guard UpdateService.isBundled else {
                FileHandle.standardError.write(Data(
                    "Not running from an .app bundle — build with scripts/bundle.sh first.\n".utf8))
                exit(1)
            }
            print("Installing into \(Bundle.main.bundleURL.path)…")
            try await UpdateService.downloadAndInstall(release, replacing: Bundle.main.bundleURL)
            print("✅ \(release.version) installed — the old version is in the Trash.")
        } catch {
            fail(error)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
    }

    /// Marks the matched words — reverse video on a terminal, «guillemets» when
    /// the output is piped, so CI can grep for them.
    private static func highlighted(_ snippet: Snippet) -> String {
        let (open, close) = isatty(1) != 0 ? ("\u{1B}[7m", "\u{1B}[0m") : ("«", "»")
        var output = ""
        var cursor = 0
        for range in snippet.highlights {
            guard range.lowerBound >= cursor,
                  let before = snippet.text.utf16Substring(
                    start: cursor, length: range.lowerBound - cursor),
                  let match = snippet.text.utf16Substring(
                    start: range.lowerBound, length: range.upperBound - range.lowerBound)
            else { continue }
            output += before + open + match + close
            cursor = range.upperBound
        }
        let tail = snippet.text.utf16Substring(
            start: cursor, length: snippet.text.utf16.count - cursor) ?? ""
        return output + tail
    }

    // MARK: - Helpers

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func fail(_ error: Error) -> Never {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }

    /// Runs an async command to completion from `main`, before the app's run loop
    /// exists. Blocking the calling thread is fine here — there is nothing else
    /// on it yet.
    private static func blocking(_ body: @escaping @Sendable () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await body()
            semaphore.signal()
        }
        semaphore.wait()
    }
}
