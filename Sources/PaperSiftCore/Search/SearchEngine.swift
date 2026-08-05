import Foundation

/// Runs a query: parse, recall from SQLite, re-rank in Swift, group by document.
///
/// Two stages on purpose. SQLite is very good at "which pages contain these
/// words" over hundreds of thousands of rows; it knows nothing about how close
/// the words sit or whether they landed in a heading. So the index picks a
/// shortlist and `Ranker` decides the order.
public struct SearchEngine: Sendable {
    private let store: IndexStore
    private let parser: QueryParser
    public var weights: RankingWeights

    public init(store: IndexStore, weights: RankingWeights = .default) {
        self.store = store
        self.parser = QueryParser()
        self.weights = weights
    }

    /// Everything a search returns, including why it might be incomplete.
    ///
    /// Cancellation-aware: the UI runs this on every keystroke and drops the
    /// previous task, so each stage checks in before doing more work.
    public func search(
        _ text: String,
        rootID: Int64? = nil,
        documentLimit: Int = 60
    ) async throws -> SearchResults {
        let clock = ContinuousClock()
        let started = clock.now

        let query = parser.parse(text)
        guard !query.isEmpty, !query.positiveTerms.isEmpty else { return .empty(query: query) }

        let candidates = try await recall(for: query, rootID: rootID)
        try Task.checkCancellation()

        let ranker = Ranker(weights: weights)
        let ranked = ranker.rank(candidates, for: query)
        // Counts describe everything that matched; `documents` is only what the
        // caller asked to see.
        let pageCount = ranked.reduce(0) { $0 + $1.hits.count }
        let shown = Array(ranked.prefix(documentLimit))

        return SearchResults(
            query: query,
            documents: shown,
            // Ranks span the documents we return, not the ones we dropped: a badge
            // reading "rank 4" has to mean the fourth row you can actually reach.
            pageRanks: SearchResults.ranks(across: shown),
            documentCount: ranked.count,
            pageCount: pageCount,
            usedScan: query.needsScan,
            truncated: candidates.count >= weights.shortlistSize,
            duration: started.duration(to: clock.now))
    }

    /// Stage one. Normally an FTS5 `MATCH`; a `LIKE` scan only when the query is
    /// nothing but suffix or infix wildcards, which FTS5 cannot index.
    private func recall(for query: ParsedQuery, rootID: Int64?) async throws -> [PageCandidate] {
        if let expression = query.expression {
            return try await store.matchPages(
                expression: expression,
                columnWeights: weights.columnWeights,
                limit: weights.shortlistSize,
                rootID: rootID)
        }
        guard let fragment = query.likeFragment else { return [] }
        // Wider limit: the ranker throws away everything the pattern rejects.
        return try await store.scanPages(
            containing: fragment, limit: weights.shortlistSize * 3, rootID: rootID)
    }
}
