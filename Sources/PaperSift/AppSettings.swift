import Foundation
import PaperSiftCore

/// User preferences, backed by `UserDefaults`.
///
/// A singleton because the index location has to be known before any view exists —
/// `Main` reads it to decide which database to open.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let ocrEnabled = "ocr.enabled"
        static let ocrLanguages = "ocr.languages"
        static let ocrDPI = "ocr.dpi"
        static let databasePath = "index.path"
        static let resultSort = "results.sort"
        static let resultSortReversed = "results.sort.reversed"
    }

    private let defaults: UserDefaults

    var ocrEnabled: Bool {
        didSet { defaults.set(ocrEnabled, forKey: Key.ocrEnabled) }
    }

    /// BCP-47 identifiers. Empty means "let Vision detect the language".
    var ocrLanguageIdentifiers: [String] {
        didSet { defaults.set(ocrLanguageIdentifiers, forKey: Key.ocrLanguages) }
    }

    var ocrDPI: Double {
        didSet { defaults.set(ocrDPI, forKey: Key.ocrDPI) }
    }

    /// How the results column is ordered — remembered between launches, because a
    /// sort you have to re-pick every morning is not a sort.
    var resultSort: ResultSort {
        didSet { defaults.set(resultSort.rawValue, forKey: Key.resultSort) }
    }

    var resultSortReversed: Bool {
        didSet { defaults.set(resultSortReversed, forKey: Key.resultSortReversed) }
    }

    /// Set when the user moved the index somewhere else.
    var customDatabasePath: String? {
        didSet {
            if let customDatabasePath {
                defaults.set(customDatabasePath, forKey: Key.databasePath)
            } else {
                defaults.removeObject(forKey: Key.databasePath)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ocrEnabled = defaults.object(forKey: Key.ocrEnabled) as? Bool ?? true
        ocrLanguageIdentifiers = defaults.stringArray(forKey: Key.ocrLanguages) ?? []
        ocrDPI = defaults.object(forKey: Key.ocrDPI) as? Double ?? 200
        customDatabasePath = defaults.string(forKey: Key.databasePath)
        resultSort = defaults.string(forKey: Key.resultSort)
            .flatMap(ResultSort.init(rawValue:)) ?? .relevance
        resultSortReversed = defaults.bool(forKey: Key.resultSortReversed)
    }

    var ocrSettings: OCRSettings {
        OCRSettings(
            isEnabled: ocrEnabled,
            languageIdentifiers: ocrLanguageIdentifiers,
            dpi: ocrDPI)
    }

    var databaseURL: URL {
        customDatabasePath.map { URL(fileURLWithPath: $0) } ?? IndexStore.defaultURL
    }
}
