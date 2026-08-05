import Foundation
import NaturalLanguage

/// Reduces words to their dictionary form, so "children" finds "child" and
/// "hiking" finds "hike".
///
/// Pages are indexed with a `lemmas` column holding only the lemmas that differ
/// from the word actually written — the surface forms already live in `body`, and
/// keeping the column lean keeps the index small. Duplicates are dropped for the
/// same reason: this column exists for recall, not for term frequency.
public struct Lemmatizer: Sendable {
    /// Long pages are truncated: tagging is linear, and a page's first 40 000
    /// characters carry its vocabulary.
    private static let maxCharacters = 40_000

    /// Languages to try when lemmatizing a single query word.
    ///
    /// A page gives `NLLanguageRecognizer` plenty to work with; one word does
    /// not, and it guesses badly — on its own, "turbine" reads as Italian and
    /// comes back as "turbina". So query terms are lemmatized against an explicit
    /// list instead, defaulting to the languages this user actually reads.
    public let queryLanguages: [NLLanguage]

    public init(queryLanguages: [NLLanguage]? = nil) {
        self.queryLanguages = queryLanguages ?? Self.preferredLanguages()
    }

    static func preferredLanguages() -> [NLLanguage] {
        var languages: [NLLanguage] = []
        for identifier in Locale.preferredLanguages.prefix(3) {
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier
            else { continue }
            let language = NLLanguage(code)
            if !languages.contains(language) { languages.append(language) }
        }
        if !languages.contains(.english) { languages.append(.english) }
        return languages
    }

    public func lemmas(of text: String) -> String {
        let source = text.count > Self.maxCharacters ? String(text.prefix(Self.maxCharacters)) : text
        guard !source.isEmpty else { return "" }

        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = source
        if let language = NLLanguageRecognizer.dominantLanguage(for: source) {
            tagger.setLanguage(language, range: source.startIndex..<source.endIndex)
        }

        var seen = Set<String>()
        var lemmas: [String] = []
        tagger.enumerateTags(
            in: source.startIndex..<source.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitPunctuation, .omitWhitespace, .omitOther]
        ) { tag, range in
            guard let lemma = tag?.rawValue.lowercased(), !lemma.isEmpty else { return true }
            guard lemma != source[range].lowercased(), seen.insert(lemma).inserted else { return true }
            lemmas.append(lemma)
            return true
        }
        return lemmas.joined(separator: " ")
    }

    /// The lemma of a single query term, or `nil` when it would add nothing.
    /// Used to widen a search: `children` also looks for `child`.
    ///
    /// Each language in `queryLanguages` gets a turn, and the first one that
    /// actually changes the word wins. Guessing the language from the word alone
    /// is what produces nonsense, so we never let it.
    public func lemma(ofTerm term: String) -> String? {
        let word = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.count > 2, !word.contains(" ") else { return nil }

        for language in queryLanguages {
            let tagger = NLTagger(tagSchemes: [.lemma])
            tagger.string = word
            tagger.setLanguage(language, range: word.startIndex..<word.endIndex)
            let (tag, _) = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma)
            guard let lemma = tag?.rawValue.lowercased(), !lemma.isEmpty,
                  lemma != word.lowercased() else { continue }
            return lemma
        }
        return nil
    }
}
