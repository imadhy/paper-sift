import Foundation
import Vision

/// How the OCR pass should behave. Owned by the app's preferences, read by the
/// indexer.
public struct OCRSettings: Sendable, Equatable {
    /// When off, scans stay in the queue instead of being dropped — turning OCR
    /// back on picks up where it left off.
    public var isEnabled: Bool
    /// BCP-47 identifiers. Empty means "let Vision work it out", which is right
    /// for mixed libraries and slightly slower.
    public var languageIdentifiers: [String]
    /// Rendering resolution. 200 dpi is the sweet spot for Vision on scans; 300
    /// costs twice the memory for marginal gains.
    public var dpi: Double
    /// Lines Vision is less sure about than this are dropped.
    public var minimumConfidence: Float

    public init(
        isEnabled: Bool = true,
        languageIdentifiers: [String] = [],
        dpi: Double = 200,
        minimumConfidence: Float = 0.3
    ) {
        self.isEnabled = isEnabled
        self.languageIdentifiers = languageIdentifiers
        self.dpi = dpi
        self.minimumConfidence = minimumConfidence
    }

    public static let `default` = OCRSettings()

    var languages: [Locale.Language] {
        languageIdentifiers.map { Locale.Language(identifier: $0) }
    }

    /// What this machine's Vision can actually read, for the settings picker.
    public static func supportedLanguages() -> [Locale.Language] {
        RecognizeTextRequest().supportedRecognitionLanguages
    }
}
