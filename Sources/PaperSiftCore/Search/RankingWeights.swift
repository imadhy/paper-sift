import Foundation

/// Every knob the ranking uses, in one place.
///
/// The components are each normalized to 0…1 before being weighted, so these
/// numbers can be read as "how much this matters relative to the others". They
/// are deliberately data, not code: tuning them is a matter of editing values and
/// re-running the ranking checks.
public struct RankingWeights: Sendable, Equatable {
    /// SQLite's bm25 — term frequency against document frequency and page length.
    public var relevance = 1.0
    /// Share of the query's terms the page actually carries. The strongest
    /// signal: a page with every word beats a page that repeats one of them.
    public var coverage = 1.8
    /// How close the terms sit to each other on the page.
    public var proximity = 0.9
    /// How often they occur, relative to the page's length.
    public var density = 0.3
    /// Whether they appear in what looked like a heading.
    public var title = 0.6
    /// Newer files first, all else being equal.
    public var recency = 0.25

    /// bm25 per-column multipliers, in the order the FTS table declares them:
    /// body, title, lemmas. Lemmas score low — they exist to widen recall.
    public var bodyColumn = 1.0
    public var titleColumn = 3.0
    public var lemmaColumn = 0.6

    /// Age at which the recency bonus has decayed to about a third.
    public var recencyDecayDays = 365.0

    /// How many pages the recall stage hands to the ranker.
    public var shortlistSize = 300

    public init() {}

    public static let `default` = RankingWeights()

    var columnWeights: (body: Double, title: Double, lemmas: Double) {
        (bodyColumn, titleColumn, lemmaColumn)
    }
}
