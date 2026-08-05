import Foundation

/// One word of a page, folded for comparison but remembering where it came from.
///
/// `start` and `length` are UTF-16 offsets into the original text: that is what
/// lets us cut a snippet and highlight the exact characters that matched.
public struct Token: Sendable, Equatable {
    public let text: String
    public let start: Int
    public let length: Int
    public let position: Int

    public var end: Int { start + length }
}

/// Splits text the way the index does.
///
/// It has to agree with FTS5's `unicode61 remove_diacritics 2` tokenizer,
/// otherwise the ranker would score words SQLite never matched: split on
/// anything that is not a letter or a digit, lowercase, drop diacritics.
public enum Tokenizer {
    /// Lowercase and strip diacritics.
    ///
    /// `folding(options:.diacriticInsensitive)` goes through ICU and dominates the
    /// cost of ranking a shortlist — a broad query re-scores hundreds of pages,
    /// which is hundreds of thousands of tokens. Almost all of them are plain
    /// ASCII and cannot carry a diacritic, so they take the cheap path.
    public static func fold(_ text: String) -> String {
        var isASCII = true
        for scalar in text.unicodeScalars where !scalar.isASCII {
            isASCII = false
            break
        }
        let lowered = text.lowercased()
        return isASCII ? lowered : lowered.folding(options: [.diacriticInsensitive], locale: nil)
    }

    /// Is this scalar part of a word?
    ///
    /// Combining marks count, and that is not a detail: PDF text is often
    /// decomposed, so "é" arrives as "e" followed by U+0301. Treating the mark as
    /// a separator would cut "économique" into "e" and "conomique" — folding then
    /// removes the mark anyway, exactly as FTS5's `remove_diacritics 2` does.
    @inline(__always)
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 {
            return (value >= 0x61 && value <= 0x7A)
                || (value >= 0x41 && value <= 0x5A)
                || (value >= 0x30 && value <= 0x39)
        }
        let properties = scalar.properties
        if properties.isAlphabetic || properties.numericType != nil { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Scalars, not characters: iterating `String` yields grapheme clusters, and
    /// that segmentation is the single most expensive thing about tokenizing a
    /// page. Ranking a shortlist does this hundreds of times per keystroke.
    public static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        tokens.reserveCapacity(text.utf16.count / 6)
        var current = ""
        var currentStart = 0
        var offset = 0

        for scalar in text.unicodeScalars {
            if isWordScalar(scalar) {
                if current.isEmpty { currentStart = offset }
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(Token(
                    text: fold(current), start: currentStart,
                    length: offset - currentStart, position: tokens.count))
                current.removeAll(keepingCapacity: true)
            }
            offset += UTF16.width(scalar)
        }
        if !current.isEmpty {
            tokens.append(Token(
                text: fold(current), start: currentStart,
                length: offset - currentStart, position: tokens.count))
        }
        return tokens
    }
}
