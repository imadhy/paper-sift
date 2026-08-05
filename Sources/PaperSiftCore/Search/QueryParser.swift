import Foundation

/// How much a term matters to the result set.
public enum Requirement: Sendable, Equatable {
    /// Contributes to the score; a page without it can still rank.
    case optional
    /// `+term` — every result must contain it.
    case required
    /// `-term` — no result may contain it.
    case excluded
}

public struct QueryTerm: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case word(String)
        /// `econom*`
        case prefix(String)
        /// `"annual report"`, already split into words.
        case phrase([String])
        /// `*nomic` or `eco*mic` — FTS5 cannot index these, so they are matched
        /// against candidate pages with a regular expression.
        case pattern(String)
    }

    public var kind: Kind
    public var requirement: Requirement
    /// Dictionary form of a word term, when it differs from what was typed.
    public var lemma: String?

    public var isPositive: Bool { requirement != .excluded }

    /// What to show the user when we echo the query back.
    public var display: String {
        switch kind {
        case .word(let word): word
        case .prefix(let prefix): "\(prefix)*"
        case .phrase(let words): "\"\(words.joined(separator: " "))\""
        case .pattern(let pattern): pattern
        }
    }
}

/// A user query, translated into something SQLite and the ranker can both use.
public struct ParsedQuery: Sendable, Equatable {
    public var raw: String
    public var terms: [QueryTerm]
    /// FTS5 `MATCH` expression, or `nil` when nothing positive can be expressed
    /// (a query made only of exclusions, or only of unindexable patterns).
    public var expression: String?
    /// Longest literal fragment of a pattern-only query, for the `LIKE` fallback.
    public var likeFragment: String?

    public var isEmpty: Bool { terms.isEmpty }
    public var positiveTerms: [QueryTerm] { terms.filter(\.isPositive) }
    /// True when the query had to fall back to scanning page bodies.
    public var needsScan: Bool { expression == nil && likeFragment != nil }
    /// True when a suffix or infix wildcard forced a post-filter.
    public var hasPatterns: Bool { terms.contains { if case .pattern = $0.kind { true } else { false } } }
}

/// Turns what the user typed into a `ParsedQuery`.
///
/// Supported, mirroring what PDF Search documents:
///
///     annual report        both words count, pages with both rank higher
///     "annual report"      that exact phrase
///     +turbine             mandatory
///     -draft               excluded
///     econom*              prefix
///     *nomic  eco*mic      suffix / infix — matched by scan, see `needsScan`
///     AND OR NOT           explicit operators, uppercase only
///
/// Every term reaches SQLite as a quoted FTS5 string literal, so words that
/// collide with FTS5 keywords, or carry punctuation, cannot break the query.
public struct QueryParser: Sendable {
    private let lemmatizer: Lemmatizer

    public init(lemmatizer: Lemmatizer = Lemmatizer()) {
        self.lemmatizer = lemmatizer
    }

    public func parse(_ input: String) -> ParsedQuery {
        var terms = lex(input)
        for index in terms.indices {
            if case .word(let word) = terms[index].kind {
                terms[index].lemma = lemmatizer.lemma(ofTerm: word)
            }
        }
        return ParsedQuery(
            raw: input,
            terms: terms,
            expression: expression(for: terms),
            likeFragment: likeFragment(for: terms))
    }

    // MARK: - Lexing

    private func lex(_ input: String) -> [QueryTerm] {
        var terms: [QueryTerm] = []
        let characters = Array(input)
        var index = 0
        // Applies to the next term produced, set by `+`, `-` or `NOT`.
        var pendingRequirement: Requirement?
        // `a AND b` marks both sides required.
        var previousWasAnd = false

        func append(_ kind: QueryTerm.Kind) {
            var requirement = pendingRequirement ?? .optional
            if previousWasAnd {
                requirement = requirement == .excluded ? .excluded : .required
                if var last = terms.popLast() {
                    if last.requirement == .optional { last.requirement = .required }
                    terms.append(last)
                }
            }
            terms.append(QueryTerm(kind: kind, requirement: requirement, lemma: nil))
            pendingRequirement = nil
            previousWasAnd = false
        }

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                index += 1
                continue
            }

            if character == "+" || character == "-" {
                // Only a prefix marker, never part of a word.
                pendingRequirement = character == "+" ? .required : .excluded
                index += 1
                continue
            }

            if character == "\"" {
                index += 1
                var phrase = ""
                while index < characters.count, characters[index] != "\"" {
                    phrase.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 }  // closing quote
                let words = Tokenizer.tokenize(phrase).map(\.text)
                if words.count == 1 {
                    append(.word(words[0]))
                } else if !words.isEmpty {
                    append(.phrase(words))
                }
                continue
            }

            var word = ""
            while index < characters.count,
                  !characters[index].isWhitespace,
                  characters[index] != "\"" {
                word.append(characters[index])
                index += 1
            }

            switch word {
            case "AND":
                previousWasAnd = true
            case "OR":
                break  // the default already scores optional terms together
            case "NOT":
                pendingRequirement = .excluded
            default:
                if let kind = classify(word) { append(kind) }
            }
        }

        return terms
    }

    /// Decides what a bare word is: a plain word, a prefix, or a pattern.
    private func classify(_ word: String) -> QueryTerm.Kind? {
        let stars = word.filter { $0 == "*" }.count
        let stripped = Tokenizer.fold(word.replacingOccurrences(of: "*", with: " "))
            .trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return nil }

        guard stars > 0 else {
            let words = Tokenizer.tokenize(word).map(\.text)
            guard let first = words.first else { return nil }
            return words.count == 1 ? .word(first) : .phrase(words)
        }
        // A single trailing star is the one wildcard FTS5 indexes natively.
        if stars == 1, word.hasSuffix("*") {
            let prefix = Tokenizer.tokenize(String(word.dropLast())).map(\.text).joined()
            return prefix.isEmpty ? nil : .prefix(prefix)
        }
        return .pattern(Tokenizer.fold(word))
    }

    // MARK: - FTS5 expression

    private func expression(for terms: [QueryTerm]) -> String? {
        let required = terms.filter { $0.requirement == .required }.compactMap(ftsFragment)
        let optional = terms.filter { $0.requirement == .optional }.compactMap(ftsFragment)
        let excluded = terms.filter { $0.requirement == .excluded }.compactMap(ftsFragment)

        var clauses: [String] = []
        if !optional.isEmpty {
            clauses.append(optional.count == 1 ? optional[0] : "(\(optional.joined(separator: " OR ")))")
        }
        clauses.append(contentsOf: required)
        guard !clauses.isEmpty else { return nil }

        var expression = clauses.joined(separator: " AND ")
        if !excluded.isEmpty {
            expression += " NOT (" + excluded.joined(separator: " OR ") + ")"
        }
        return expression
    }

    /// One term as FTS5 syntax. Patterns have no representation and return nil.
    private func ftsFragment(_ term: QueryTerm) -> String? {
        switch term.kind {
        case .word(let word):
            let surface = Self.literal(word)
            // Widen to the dictionary form so "children" also finds "child".
            guard let lemma = term.lemma else { return surface }
            return "(\(surface) OR \(Self.literal(lemma)))"
        case .prefix(let prefix):
            return "\(Self.literal(prefix))*"
        case .phrase(let words):
            return Self.literal(words.joined(separator: " "))
        case .pattern:
            return nil
        }
    }

    /// FTS5 string literal: double quotes, inner quotes doubled.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Scan fallback

    /// When the only positive terms are patterns, the recall stage has to scan.
    /// The longest literal chunk between the stars narrows that scan down.
    private func likeFragment(for terms: [QueryTerm]) -> String? {
        guard expression(for: terms) == nil else { return nil }
        let chunks = terms
            .filter(\.isPositive)
            .compactMap { term -> [String]? in
                guard case .pattern(let pattern) = term.kind else { return nil }
                return pattern.components(separatedBy: "*")
            }
            .flatMap { $0 }
            .filter { $0.count >= 2 }
        return chunks.max(by: { $0.count < $1.count })
    }
}
