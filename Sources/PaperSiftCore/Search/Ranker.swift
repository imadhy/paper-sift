import Foundation

/// Second stage of a search: re-score the shortlist SQLite handed back.
///
/// bm25 alone answers "does this page talk about the query", not "is this the
/// page you wanted". The difference is in where the words sit — together or
/// scattered, in a heading or buried, on a fresh file or an old one — and that is
/// what this adds, one page at a time, on text we already have in memory.
public struct Ranker: Sendable {
    public var weights: RankingWeights

    public init(weights: RankingWeights = .default) {
        self.weights = weights
    }

    /// Scores candidates and groups them by document, best first.
    public func rank(
        _ candidates: [PageCandidate],
        for query: ParsedQuery,
        now: Date = Date()
    ) -> [DocumentResult] {
        let matchers = query.positiveTerms.compactMap(TermMatcher.init)
        guard !matchers.isEmpty else { return [] }
        // SQLite's `NOT` already dropped these on the FTS path, but the scan
        // fallback has no such luxury — enforce exclusions here either way.
        let forbidden = query.terms
            .filter { $0.requirement == .excluded }
            .compactMap(TermMatcher.init)

        // bm25 is negative and unbounded; normalize against the best candidate so
        // the component lands in 0…1 like every other one.
        let strongest = candidates.map { -$0.bm25 }.max() ?? 0

        var hits: [PageHit] = []
        hits.reserveCapacity(candidates.count)
        for candidate in candidates {
            if let hit = score(candidate, matchers: matchers, forbidden: forbidden,
                               strongest: strongest, now: now) {
                hits.append(hit)
            }
        }
        return group(hits, candidates: candidates)
    }

    // MARK: - One page

    private func score(
        _ candidate: PageCandidate,
        matchers: [TermMatcher],
        forbidden: [TermMatcher],
        strongest: Double,
        now: Date
    ) -> PageHit? {
        let tokens = Tokenizer.tokenize(candidate.body)
        let titleTokens = candidate.title.isEmpty ? [] : Tokenizer.tokenize(candidate.title)

        for matcher in forbidden where !matcher.matches(in: tokens).isEmpty {
            return nil
        }

        var positionsByTerm: [[Int]] = []
        var ranges: [(start: Int, length: Int)] = []
        var matchedTerms = 0
        var occurrences = 0
        var titleMatches = 0

        for matcher in matchers {
            let found = matcher.matches(in: tokens)
            if !found.isEmpty {
                matchedTerms += 1
                occurrences += found.count
                positionsByTerm.append(found.map(\.position))
                ranges.append(contentsOf: found.map { (start: $0.start, length: $0.length) })
            } else {
                positionsByTerm.append([])
            }
            if !titleTokens.isEmpty, !matcher.matches(in: titleTokens).isEmpty {
                titleMatches += 1
            }
        }

        // A page that carries none of the query's words is not a result, whatever
        // SQLite thought — this happens with pattern post-filters.
        guard matchedTerms > 0 else { return nil }
        // Mandatory terms are mandatory.
        for (index, matcher) in matchers.enumerated() where matcher.isRequired {
            guard !positionsByTerm[index].isEmpty else { return nil }
        }

        let window = Ranker.minimalWindow(positionsByTerm)
        var breakdown = ScoreBreakdown()
        breakdown.relevance = strongest > 0 ? (-candidate.bm25) / strongest : 0
        breakdown.coverage = Double(matchedTerms) / Double(matchers.count)
        breakdown.proximity = Ranker.proximityScore(
            span: window?.span, matched: matchedTerms, asked: matchers.count)
        breakdown.density = Ranker.densityScore(occurrences: occurrences, tokens: tokens.count)
        breakdown.title = titleTokens.isEmpty ? 0 : Double(titleMatches) / Double(matchers.count)
        breakdown.recency = Ranker.recencyScore(
            modifiedAt: candidate.modifiedAt, now: now, decayDays: weights.recencyDecayDays)

        let total =
            weights.relevance * breakdown.relevance
            + weights.coverage * breakdown.coverage
            + weights.proximity * breakdown.proximity
            + weights.density * breakdown.density
            + weights.title * breakdown.title
            + weights.recency * breakdown.recency

        let anchor = window?.anchor ?? ranges.map(\.start).min() ?? 0
        return PageHit(
            pageID: candidate.pageID,
            documentID: candidate.documentID,
            pageNumber: candidate.pageNumber,
            score: total,
            breakdown: breakdown,
            snippet: Snippet.make(from: candidate.body, tokens: tokens, around: anchor, highlighting: ranges),
            fromOCR: candidate.fromOCR,
            matchedText: Ranker.matchedText(in: candidate.body, ranges: ranges),
            matchedTermCount: matchedTerms,
            queryTermCount: matchers.count)
    }

    private func group(_ hits: [PageHit], candidates: [PageCandidate]) -> [DocumentResult] {
        var metadata: [Int64: PageCandidate] = [:]
        for candidate in candidates where metadata[candidate.documentID] == nil {
            metadata[candidate.documentID] = candidate
        }

        let byDocument = Dictionary(grouping: hits, by: \.documentID)
        var results: [DocumentResult] = []
        for (documentID, pages) in byDocument {
            guard let info = metadata[documentID] else { continue }
            let sorted = pages.sorted { ($0.score, -Double($0.pageNumber)) > ($1.score, -Double($1.pageNumber)) }
            results.append(DocumentResult(
                documentID: documentID,
                path: info.documentPath,
                filename: info.filename,
                modifiedAt: info.modifiedAt,
                pageCount: info.pageCount,
                size: info.size,
                score: sorted[0].score,
                hits: sorted))
        }
        // Best score wins; ties go to the file touched most recently.
        return results.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.modifiedAt > $1.modifiedAt
        }
    }

    // MARK: - Components

    /// Smallest token distance covering one occurrence of every matched term,
    /// plus where that window starts.
    static func minimalWindow(_ positionsByTerm: [[Int]]) -> (span: Int, anchor: Int)? {
        var merged: [(position: Int, term: Int)] = []
        for (term, positions) in positionsByTerm.enumerated() {
            for position in positions { merged.append((position, term)) }
        }
        guard !merged.isEmpty else { return nil }
        merged.sort { $0.position < $1.position }

        let needed = positionsByTerm.count { !$0.isEmpty }
        var counts: [Int: Int] = [:]
        var distinct = 0
        var left = 0
        var best: (span: Int, anchor: Int)?

        for right in merged.indices {
            counts[merged[right].term, default: 0] += 1
            if counts[merged[right].term] == 1 { distinct += 1 }
            while distinct == needed {
                let span = merged[right].position - merged[left].position
                if best == nil || span < best!.span {
                    best = (span, merged[left].position)
                }
                let leftTerm = merged[left].term
                counts[leftTerm]! -= 1
                if counts[leftTerm] == 0 { distinct -= 1 }
                left += 1
            }
        }
        return best
    }

    /// 1 when every word of the query sits shoulder to shoulder, decaying as they
    /// drift apart.
    ///
    /// Scaled by how much of the query the page actually carries: a page holding
    /// one word out of three has nothing to be close to, and must not collect a
    /// perfect proximity score for it — that is exactly how a page repeating a
    /// single term used to outrank a page containing all of them.
    static func proximityScore(span: Int?, matched: Int, asked: Int) -> Double {
        guard asked > 0 else { return 0 }
        let coverage = Double(matched) / Double(asked)
        guard matched > 1, let span else { return coverage }
        let slack = Double(max(0, span - (matched - 1)))
        return coverage / (1 + log(1 + slack))
    }

    /// Occurrences relative to page length: two hits on an index card beat two
    /// hits in a fifty-page appendix.
    static func densityScore(occurrences: Int, tokens: Int) -> Double {
        guard occurrences > 0 else { return 0 }
        let expected = Double(tokens) / 200 + 1
        return min(1, Double(occurrences) / expected)
    }

    static func recencyScore(modifiedAt: Date, now: Date, decayDays: Double) -> Double {
        let days = max(0, now.timeIntervalSince(modifiedAt) / 86_400)
        return exp(-days / max(1, decayDays))
    }

    /// The matched words as they are actually written on the page — the viewer
    /// needs the real spelling to find and highlight them in the PDF.
    static func matchedText(in body: String, ranges: [(start: Int, length: Int)]) -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        for range in ranges.prefix(64) {
            guard let text = body.utf16Substring(start: range.start, length: range.length) else { continue }
            guard seen.insert(Tokenizer.fold(text)).inserted else { continue }
            words.append(text)
        }
        return words
    }
}

// MARK: - Matching a single term

/// Compiled form of a query term, ready to be run against a page's tokens.
struct TermMatcher: Sendable {
    struct Match: Sendable {
        let position: Int
        let start: Int
        let length: Int
    }

    private enum Test: Sendable {
        case word(Set<String>)
        case prefix(String)
        case phrase([String])
        case regex(NSRegularExpression)
    }

    private let test: Test
    let isRequired: Bool

    init?(_ term: QueryTerm) {
        isRequired = term.requirement == .required
        switch term.kind {
        case .word(let word):
            var forms: Set<String> = [Tokenizer.fold(word)]
            if let lemma = term.lemma { forms.insert(Tokenizer.fold(lemma)) }
            test = .word(forms)
        case .prefix(let prefix):
            test = .prefix(Tokenizer.fold(prefix))
        case .phrase(let words):
            guard !words.isEmpty else { return nil }
            test = .phrase(words.map(Tokenizer.fold))
        case .pattern(let pattern):
            // `*nomic` / `eco*mic` — anchored so the star only spans one word.
            let escaped = pattern
                .components(separatedBy: "*")
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "[\\p{L}\\p{N}]*")
            guard let regex = try? NSRegularExpression(pattern: "^\(escaped)$") else { return nil }
            test = .regex(regex)
        }
    }

    func matches(in tokens: [Token]) -> [Match] {
        switch test {
        case .word(let forms):
            return tokens.filter { forms.contains($0.text) }
                .map { Match(position: $0.position, start: $0.start, length: $0.length) }

        case .prefix(let prefix):
            return tokens.filter { $0.text.hasPrefix(prefix) }
                .map { Match(position: $0.position, start: $0.start, length: $0.length) }

        case .phrase(let words):
            guard tokens.count >= words.count else { return [] }
            var matches: [Match] = []
            for start in 0...(tokens.count - words.count) {
                var isMatch = true
                for offset in words.indices where tokens[start + offset].text != words[offset] {
                    isMatch = false
                    break
                }
                guard isMatch else { continue }
                let last = tokens[start + words.count - 1]
                matches.append(Match(
                    position: tokens[start].position,
                    start: tokens[start].start,
                    length: last.end - tokens[start].start))
            }
            return matches

        case .regex(let regex):
            return tokens.filter { token in
                let range = NSRange(location: 0, length: token.text.utf16.count)
                return regex.firstMatch(in: token.text, options: [], range: range) != nil
            }
            .map { Match(position: $0.position, start: $0.start, length: $0.length) }
        }
    }
}

// MARK: - Snippets

extension Snippet {
    /// The whole text with every occurrence of `terms` marked — what the text
    /// reader shows, where there is no page to render.
    ///
    /// Matching folds like the index does, and a term also matches words it
    /// prefixes, so `econom*` lights up `economic`.
    public static func full(_ text: String, highlighting terms: [String]) -> Snippet {
        let needles = Set(terms.map(Tokenizer.fold).filter { !$0.isEmpty })
        guard !needles.isEmpty else { return Snippet(text: text, highlights: []) }
        let highlights = Tokenizer.tokenize(text)
            .filter { token in needles.contains { token.text == $0 || token.text.hasPrefix($0) } }
            .map { $0.start..<$0.end }
        return Snippet(text: text, highlights: highlights)
    }
}

extension Snippet {
    /// Cuts a readable window around the best match and marks every hit inside it.
    static func make(
        from body: String,
        tokens: [Token],
        around anchorPosition: Int,
        highlighting ranges: [(start: Int, length: Int)],
        before: Int = 12,
        after: Int = 34
    ) -> Snippet {
        guard !tokens.isEmpty, !body.isEmpty else { return .empty }
        let anchorIndex = tokens.firstIndex { $0.position >= anchorPosition } ?? 0
        let first = max(0, anchorIndex - before)
        let last = min(tokens.count - 1, anchorIndex + after)

        let windowStart = tokens[first].start
        let windowEnd = tokens[last].end
        guard let text = body.utf16Substring(start: windowStart, length: windowEnd - windowStart) else {
            return .empty
        }

        let leading = first > 0 ? "… " : ""
        let trailing = last < tokens.count - 1 ? " …" : ""
        let shift = leading.utf16.count - windowStart

        let highlights = ranges
            .filter { $0.start >= windowStart && $0.start + $0.length <= windowEnd }
            .map { ($0.start + shift)..<($0.start + $0.length + shift) }
            .sorted { $0.lowerBound < $1.lowerBound }

        return Snippet(text: leading + text + trailing, highlights: highlights)
    }
}
