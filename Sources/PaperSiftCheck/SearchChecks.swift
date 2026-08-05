import Foundation
import NaturalLanguage
import PaperSiftCore

/// A parser pinned to English, so the expected FTS expressions are the same
/// on a French laptop and on a CI runner.
let checkParser = QueryParser(lemmatizer: Lemmatizer(queryLanguages: [.english]))

/// A candidate page built by hand, so ranking can be tested one signal at a time.
func candidate(
    id: Int64,
    document: Int64 = 1,
    page: Int = 1,
    body: String,
    title: String = "",
    bm25: Double = -1,
    modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    filename: String = "doc.pdf",
    size: Int64 = 2_048
) -> PageCandidate {
    PageCandidate(
        pageID: id, documentID: document, pageNumber: page, fromOCR: false, bm25: bm25,
        body: body, title: title, documentPath: "/tmp/papers/\(filename)", filename: filename,
        modifiedAt: modifiedAt, pageCount: 10, size: size)
}

enum SearchChecks {
    static let cases: [(String, @Sendable (TestRun) async throws -> Void)] = [
        ("Plain words become an optional FTS group", parsePlainWords),
        ("Quotes, plus, minus and prefix each map to FTS syntax", parseOperators),
        ("AND and NOT are honoured, OR is the default", parseExplicitOperators),
        ("Suffix and infix wildcards fall back to a scan", parsePatterns),
        ("FTS keywords and quotes in the query cannot break it", parseHostileInput),
        ("Nothing typed means nothing searched", parseEmptyInput),
        ("A one-word lemma stays in the languages we read", lemmaStaysInLanguage),
        ("Pages carrying every term beat pages repeating one", coverageWins),
        ("Words sitting together beat words drifting apart", proximityWins),
        ("A term in a heading lifts the page", titleLifts),
        ("Fresher files win ties", recencyBreaksTies),
        ("Mandatory terms are mandatory, excluded terms are gone", requirementsEnforced),
        ("Snippets are cut around the match and mark it exactly", snippetsHighlight),
        ("A search over a real index returns ranked documents", endToEndSearch),
        ("An infix wildcard finds a word FTS5 cannot index", scanFallbackFindsInfix),
        ("Every returned page knows its place in the overall ordering", pagesCarryTheirRank),
        ("A document result carries what a row has to display", resultsCarryFileMetadata),
    ]

    // MARK: - Parsing

    static func parsePlainWords(_ run: TestRun) async throws {
        let query = checkParser.parse("annual report")
        await run.equal(query.terms.count, 2)
        await run.equal(query.terms.map(\.requirement), [.optional, .optional])
        await run.equal(query.expression, "(\"annual\" OR \"report\")")
        await run.expect(!query.needsScan)
        await run.expect(!query.hasPatterns)
    }

    static func parseOperators(_ run: TestRun) async throws {
        let parser = checkParser

        await run.equal(parser.parse("\"annual report\"").expression, "\"annual report\"")
        await run.equal(parser.parse("+turbine").expression, "\"turbine\"")
        await run.equal(parser.parse("econom*").expression, "\"econom\"*")
        await run.equal(parser.parse("+turbine -draft").expression, "\"turbine\" NOT (\"draft\")")
        await run.equal(
            parser.parse("report +turbine -draft").expression,
            "\"report\" AND \"turbine\" NOT (\"draft\")")

        // A single quoted word is a word, not a one-word phrase.
        let single = parser.parse("\"turbine\"")
        await run.equal(single.terms.count, 1)
        await run.equal(single.expression, "\"turbine\"")

        // Lemmas widen a word term.
        let plural = parser.parse("children")
        await run.equal(plural.terms.first?.lemma, "child")
        await run.equal(plural.expression, "(\"children\" OR \"child\")")
    }

    static func parseExplicitOperators(_ run: TestRun) async throws {
        let parser = checkParser
        await run.equal(parser.parse("turbine AND gearbox").expression,
                        "\"turbine\" AND \"gearbox\"")
        await run.equal(parser.parse("turbine OR gearbox").expression,
                        "(\"turbine\" OR \"gearbox\")")
        await run.equal(parser.parse("turbine NOT draft").expression,
                        "\"turbine\" NOT (\"draft\")")
        // Lowercase words are search terms, not operators.
        await run.equal(parser.parse("gears and belts").terms.count, 3)
    }

    static func parsePatterns(_ run: TestRun) async throws {
        let parser = checkParser

        let suffix = parser.parse("*nomic")
        await run.equal(suffix.expression, nil, "FTS5 cannot index a suffix wildcard")
        await run.equal(suffix.likeFragment, "nomic")
        await run.expect(suffix.needsScan)
        await run.expect(suffix.hasPatterns)

        let infix = parser.parse("eco*mic")
        await run.equal(infix.expression, nil)
        await run.expect(infix.needsScan)

        // Paired with an indexable term, the pattern rides along as a post-filter.
        let mixed = parser.parse("report *nomic")
        await run.equal(mixed.expression, "\"report\"")
        await run.expect(!mixed.needsScan)
        await run.expect(mixed.hasPatterns)
    }

    static func parseHostileInput(_ run: TestRun) async throws {
        let parser = checkParser
        // Bare FTS5 keywords, quotes and punctuation must not become syntax.
        await run.equal(parser.parse("and").expression, "\"and\"")
        await run.equal(parser.parse("near").expression, "\"near\"")
        let broken = parser.parse("report\" OR pages_fts MATCH \"x")
        await run.expect(broken.expression?.contains("MATCH") == false,
                         "got \(broken.expression ?? "nil")")
        await run.expect(broken.expression != nil)
    }

    static func parseEmptyInput(_ run: TestRun) async throws {
        let parser = checkParser
        await run.expect(parser.parse("").isEmpty)
        await run.expect(parser.parse("   ").isEmpty)
        await run.equal(parser.parse("-draft").expression, nil,
                        "only exclusions leaves nothing to search for")
    }

    static func lemmaStaysInLanguage(_ run: TestRun) async throws {
        // Left to guess from a single word, NLTagger reads "turbine" as Italian
        // and hands back "turbina". Pinning the languages is what prevents a
        // search for turbines from quietly matching Italian text.
        await run.equal(Lemmatizer(queryLanguages: [.english]).lemma(ofTerm: "turbine"), nil)
        await run.equal(Lemmatizer(queryLanguages: [.french]).lemma(ofTerm: "turbine"), nil)
        await run.equal(Lemmatizer(queryLanguages: [.english]).lemma(ofTerm: "children"), "child")

        // French inflection needs French lemma data, and that is an on-demand OS
        // asset rather than something every Mac carries — a CI runner typically has
        // English only. A machine that cannot lemmatize French is not a regression,
        // so assert the answer only where there is one.
        if let french = Lemmatizer(queryLanguages: [.french]).lemma(ofTerm: "enfants") {
            await run.equal(french, "enfant")
        } else {
            print("    · no French lemma data on this machine — skipped that half")
        }

        // The default list follows the user, and always ends with English.
        await run.expect(Lemmatizer().queryLanguages.contains(.english))
        await run.equal(Lemmatizer().lemma(ofTerm: "children"), "child")
    }

    // MARK: - Ranking

    static func coverageWins(_ run: TestRun) async throws {
        let query = checkParser.parse("turbine gearbox")
        let results = Ranker().rank([
            candidate(id: 1, document: 1,
                      body: "turbine turbine turbine turbine turbine maintenance", bm25: -2),
            candidate(id: 2, document: 2,
                      body: "the turbine drives the gearbox", bm25: -1),
        ], for: query)

        await run.equal(results.count, 2)
        await run.equal(results.first?.documentID, 2, "the page with both words must win")
        await run.equal(results.first?.bestHit.matchedTermCount, 2)
        await run.equal(results.first?.bestHit.queryTermCount, 2)
    }

    static func proximityWins(_ run: TestRun) async throws {
        let query = checkParser.parse("turbine gearbox")
        let filler = String(repeating: "maintenance ", count: 60)
        let results = Ranker().rank([
            candidate(id: 1, document: 1, body: "turbine \(filler) gearbox", bm25: -1),
            candidate(id: 2, document: 2, body: "the turbine gearbox assembly \(filler)", bm25: -1),
        ], for: query)

        await run.equal(results.first?.documentID, 2)
        let near = try await run.require(results.first?.bestHit)
        let far = try await run.require(results.last?.bestHit)
        await run.expect(near.breakdown.proximity > far.breakdown.proximity,
                         "\(near.breakdown.proximity) vs \(far.breakdown.proximity)")
    }

    static func titleLifts(_ run: TestRun) async throws {
        let query = checkParser.parse("turbine")
        let body = "Routine checks keep the turbine running."
        let results = Ranker().rank([
            candidate(id: 1, document: 1, body: body, bm25: -1),
            candidate(id: 2, document: 2, body: body, title: "Turbine Maintenance", bm25: -1),
        ], for: query)

        await run.equal(results.first?.documentID, 2)
        await run.expect((results.first?.bestHit.breakdown.title ?? 0) > 0)
        await run.equal(results.last?.bestHit.breakdown.title, 0)
    }

    static func recencyBreaksTies(_ run: TestRun) async throws {
        let query = checkParser.parse("turbine")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let results = Ranker().rank([
            candidate(id: 1, document: 1, body: "the turbine", bm25: -1,
                      modifiedAt: now.addingTimeInterval(-3 * 365 * 86_400)),
            candidate(id: 2, document: 2, body: "the turbine", bm25: -1, modifiedAt: now),
        ], for: query, now: now)

        await run.equal(results.first?.documentID, 2)
        await run.expect((results.first?.bestHit.breakdown.recency ?? 0) > 0.9)
        await run.expect((results.last?.bestHit.breakdown.recency ?? 1) < 0.1)
    }

    static func requirementsEnforced(_ run: TestRun) async throws {
        let ranker = Ranker()

        let required = ranker.rank([
            candidate(id: 1, document: 1, body: "gearbox only", bm25: -1),
            candidate(id: 2, document: 2, body: "turbine and gearbox", bm25: -1),
        ], for: checkParser.parse("+turbine gearbox"))
        await run.equal(required.count, 1, "the page without the mandatory word must go")
        await run.equal(required.first?.documentID, 2)

        let excluded = ranker.rank([
            candidate(id: 1, document: 1, body: "turbine draft notes", bm25: -1),
            candidate(id: 2, document: 2, body: "turbine final notes", bm25: -1),
        ], for: checkParser.parse("turbine -draft"))
        await run.equal(excluded.count, 1)
        await run.equal(excluded.first?.documentID, 2)
    }

    static func snippetsHighlight(_ run: TestRun) async throws {
        let body = String(repeating: "filler word ", count: 40)
            + "the économique report matters "
            + String(repeating: "trailing text ", count: 40)
        let results = Ranker().rank(
            [candidate(id: 1, body: body, bm25: -1)],
            for: checkParser.parse("économique"))

        let hit = try await run.require(results.first?.bestHit)
        await run.expect(hit.snippet.text.contains("économique"),
                         "snippet was: \(hit.snippet.text)")
        await run.expect(hit.snippet.text.hasPrefix("… "), "long pages get an ellipsis")
        await run.expect(hit.snippet.text.hasSuffix(" …"))
        await run.equal(hit.snippet.highlights.count, 1)

        // The highlight must land exactly on the word.
        let range = try await run.require(hit.snippet.highlights.first)
        let highlighted = hit.snippet.text.utf16Substring(
            start: range.lowerBound, length: range.upperBound - range.lowerBound)
        await run.equal(highlighted, "économique", "accented text must not shift the offsets")
        await run.equal(hit.matchedText, ["économique"])
    }

    // MARK: - End to end

    static func endToEndSearch(_ run: TestRun) async throws {
        let store = try makeStore()
        let root = try await store.addRoot(path: "/tmp/papers")

        func add(_ name: String, pages: [PageContent]) async throws {
            let id = try await store.upsert(DocumentCandidate(
                rootID: root.id, path: "/tmp/papers/\(name)", size: 100,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))).documentID
            try await store.replacePages(pages, documentID: id, state: .indexed)
        }

        try await add("manual.pdf", pages: [
            PageContent(pageNumber: 1, body: "Introduction to the plant.", title: "Introduction"),
            PageContent(pageNumber: 2,
                        body: "The turbine gearbox must be inspected every six months.",
                        title: "Turbine gearbox"),
        ])
        try await add("minutes.pdf", pages: [
            PageContent(pageNumber: 1,
                        body: "We discussed the gearbox at length, and the turbine briefly, "
                            + String(repeating: "among many other topics. ", count: 30)),
        ])
        try await add("unrelated.pdf", pages: [
            PageContent(pageNumber: 1, body: "Catering arrangements for the summer party."),
        ])

        let engine = SearchEngine(store: store)
        let results = try await engine.search("turbine gearbox")

        await run.equal(results.documents.count, 2, "the catering page must not match")
        await run.equal(results.documents.first?.filename, "manual.pdf",
                        "the page where both words sit together should lead")
        await run.equal(results.pageCount, 2)
        await run.expect(!results.usedScan)
        await run.expect(!results.truncated)
        await run.expect(results.duration > .zero)

        let best = try await run.require(results.documents.first?.bestHit)
        await run.equal(best.pageNumber, 2)
        await run.expect(best.snippet.text.contains("gearbox"))

        // Exclusions reach into the index too.
        let filtered = try await engine.search("gearbox -inspected")
        await run.equal(filtered.documents.count, 1)
        await run.equal(filtered.documents.first?.filename, "minutes.pdf")

        // Nothing at all is not an error.
        await run.expect(try await engine.search("xylophone").isEmpty)
        await run.expect(try await engine.search("").isEmpty)
    }

    /// The badge on a page row says how that page compares to the pages of every
    /// other document, so the numbering has to be global and gap-free.
    static func pagesCarryTheirRank(_ run: TestRun) async throws {
        let query = checkParser.parse("turbine gearbox")
        let documents = Ranker().rank([
            candidate(id: 1, document: 1, page: 1, body: "the turbine drives the gearbox", bm25: -2),
            candidate(id: 2, document: 1, page: 2, body: "turbine only", bm25: -1),
            candidate(id: 3, document: 2, page: 7, body: "gearbox and turbine together", bm25: -2),
        ], for: query)
        let ranks = SearchResults.ranks(across: documents)

        await run.equal(ranks.count, 3, "every returned page gets a number")
        await run.equal(Set(ranks.values), Set([1, 2, 3]), "no gaps, no duplicates")

        // The winning document's best page must be rank 1, and a weaker page of a
        // strong document can rank below another document's page.
        let best = try await run.require(documents.first?.bestHit)
        await run.equal(ranks[best.pageID], 1)
        let weakest = try await run.require(
            documents.flatMap(\.hits).min { $0.score < $1.score })
        await run.equal(ranks[weakest.pageID], 3)

        var results = SearchResults.empty(query: query)
        results.documents = documents
        results.pageRanks = ranks
        await run.equal(results.rank(ofPage: best.pageID), 1)
        await run.equal(results.rank(ofPage: 999), nil, "a page we never returned has no rank")
    }

    /// Rows show the file's size and date; both come along with the search rather
    /// than a second trip to the disk.
    static func resultsCarryFileMetadata(_ run: TestRun) async throws {
        let store = try makeStore()
        let root = try await store.addRoot(path: "/tmp/papers")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let id = try await store.upsert(DocumentCandidate(
            rootID: root.id, path: "/tmp/papers/report.pdf", size: 4_096,
            modifiedAt: modified)).documentID
        try await store.replacePages([
            PageContent(pageNumber: 1, body: "The turbine is fine."),
        ], documentID: id, state: .indexed)

        let results = try await SearchEngine(store: store).search("turbine")
        let document = try await run.require(results.documents.first)
        await run.equal(document.size, 4_096)
        await run.equal(document.pageCount, 1)
        await run.equal(document.modifiedAt.timeIntervalSince1970, modified.timeIntervalSince1970)
        await run.equal(results.rank(ofPage: document.bestHit.pageID), 1)
    }

    static func scanFallbackFindsInfix(_ run: TestRun) async throws {
        let store = try makeStore()
        let root = try await store.addRoot(path: "/tmp/papers")
        let id = try await store.upsert(DocumentCandidate(
            rootID: root.id, path: "/tmp/papers/report.pdf", size: 10, modifiedAt: Date())).documentID
        try await store.replacePages([
            PageContent(pageNumber: 1, body: "The economic outlook is stable."),
            PageContent(pageNumber: 2, body: "Catering arrangements only."),
        ], documentID: id, state: .indexed)

        let engine = SearchEngine(store: store)
        let results = try await engine.search("eco*mic")

        await run.expect(results.usedScan, "an infix wildcard has to scan")
        await run.equal(results.documents.count, 1)
        await run.equal(results.documents.first?.bestHit.pageNumber, 1)
        await run.equal(results.documents.first?.bestHit.matchedText, ["economic"])
    }
}
