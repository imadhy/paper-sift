import Foundation
import PaperSiftCore

enum TokenizerChecks {
    static let cases: [(String, @Sendable (TestRun) async throws -> Void)] = [
        ("Words split on punctuation and keep their offsets", splitsAndOffsets),
        ("Case and diacritics fold, the way the index folds them", folding),
        ("Decomposed text stays one word", decomposedText),
        ("Emoji and non-breaking spaces separate words", unusualSeparators),
    ]

    static func splitsAndOffsets(_ run: TestRun) async throws {
        let text = "The turbine's gearbox — inspected, twice."
        let tokens = Tokenizer.tokenize(text)

        await run.equal(tokens.map(\.text), ["the", "turbine", "s", "gearbox", "inspected", "twice"])
        await run.equal(tokens.map(\.position), Array(0..<6))

        // Every offset must point back at the original spelling.
        for token in tokens {
            let original = text.utf16Substring(start: token.start, length: token.length)
            await run.equal(original?.lowercased(), token.text, "offset drift on '\(token.text)'")
        }
        await run.expect(Tokenizer.tokenize("").isEmpty)
        await run.expect(Tokenizer.tokenize("...,;!").isEmpty)
    }

    static func folding(_ run: TestRun) async throws {
        await run.equal(Tokenizer.fold("ÉCONOMIQUE"), "economique")
        await run.equal(Tokenizer.fold("Straße"), "straße", "ß is not a diacritic")
        await run.equal(Tokenizer.tokenize("Le rapport Économique").map(\.text),
                        ["le", "rapport", "economique"])
    }

    static func decomposedText(_ run: TestRun) async throws {
        // The same word, composed and decomposed — PDF text arrives both ways.
        let composed = "économique"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        await run.expect(composed.unicodeScalars.count != decomposed.unicodeScalars.count,
                         "the fixture must actually be decomposed")

        let tokens = Tokenizer.tokenize(decomposed)
        await run.equal(tokens.count, 1, "a combining accent must not split the word")
        await run.equal(tokens.first?.text, "economique")
        await run.equal(Tokenizer.tokenize(composed).first?.text, "economique",
                        "both spellings must reach the same token")

        // Offsets still address the original text.
        let token = try await run.require(tokens.first)
        await run.equal(decomposed.utf16Substring(start: token.start, length: token.length),
                        decomposed)
    }

    static func unusualSeparators(_ run: TestRun) async throws {
        await run.equal(Tokenizer.tokenize("prix\u{00A0}total").map(\.text), ["prix", "total"],
                        "a non-breaking space is a space")
        await run.equal(Tokenizer.tokenize("«économique»").map(\.text), ["economique"],
                        "French quotation marks are punctuation")
        await run.equal(Tokenizer.tokenize("hello🙂world").map(\.text), ["hello", "world"])
        await run.equal(Tokenizer.tokenize("2026-08-05").map(\.text), ["2026", "08", "05"])
    }
}
