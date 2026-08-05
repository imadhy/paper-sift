import Foundation

/// Where a recognized word sits on the page.
///
/// Coordinates are normalized (0…1) with a lower-left origin, exactly as Vision
/// reports them, so they survive any zoom level the viewer chooses.
public struct OCRWord: Codable, Sendable, Equatable {
    /// Coordinates are quantized to four decimals on the way in.
    ///
    /// `JSONEncoder` writes a `Double` at full precision —
    /// `0.2047530174255372`, eighteen characters for a number that needs six —
    /// which made a stored layout twice the size it had to be. Four decimals of a
    /// ~600 pt page is 0.06 pt; a human hair is 0.2 pt. Quantizing here rather
    /// than at encoding time keeps the value in memory identical to the value on
    /// disk, so a round trip is exact.
    static let precision = 10_000.0

    public let text: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.x = Self.quantized(x)
        self.y = Self.quantized(y)
        self.width = Self.quantized(width)
        self.height = Self.quantized(height)
    }

    static func quantized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * precision).rounded() / precision
    }

    enum CodingKeys: String, CodingKey {
        case text = "t"
        case x, y
        case width = "w"
        case height = "h"
    }
}

/// The word boxes of one OCR'd page.
///
/// Stored as JSON with one-letter keys and quantized coordinates — a page of 400
/// words costs about 20 kB. A packed binary layout would be a quarter of that, but
/// being able to read a blob with `sqlite3` has already paid for itself once while
/// debugging highlight placement, and this table is never touched by a search.
public struct OCRLayout: Codable, Sendable, Equatable {
    public var words: [OCRWord]

    public init(words: [OCRWord]) {
        self.words = words
    }

    /// Re-encodes a stored blob compactly, for the schema migration. Returns nil
    /// when there is nothing to gain.
    public static func recompacted(_ data: Data) -> Data? {
        guard let layout = try? decode(data) else { return nil }
        // Feed the values back through `OCRWord.init`, which quantizes.
        let compact = OCRLayout(words: layout.words.map {
            OCRWord(text: $0.text, x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        })
        guard let encoded = try? compact.encoded(), encoded.count < data.count else { return nil }
        return encoded
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> OCRLayout {
        try JSONDecoder().decode(OCRLayout.self, from: data)
    }

    /// Normalized boxes of the words matching any of `terms`.
    ///
    /// Matching folds the same way the index does, and a term also matches a word
    /// it prefixes, so searching `econom*` still lights up `economic`.
    public func boxes(matching terms: [String]) -> [OCRWord] {
        let needles = Set(terms.map(Tokenizer.fold).filter { !$0.isEmpty })
        guard !needles.isEmpty else { return [] }
        return words.filter { word in
            let folded = Tokenizer.fold(word.text)
            return needles.contains { folded == $0 || folded.hasPrefix($0) }
        }
    }
}
