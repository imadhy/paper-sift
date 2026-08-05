import CoreGraphics
import Foundation
import PDFKit
import Vision

/// What one page of OCR produced.
public struct OCRPageResult: Sendable, Equatable {
    /// The recognized lines, joined into readable text.
    public var text: String
    /// Lines Vision considered titles — these feed the `title` column, so a scan
    /// ranks by its headings like any other page.
    public var title: String
    public var layout: OCRLayout
    public var averageConfidence: Double

    public var isEmpty: Bool { text.isEmpty }
}

/// Reads text off rendered pages with Vision.
public struct OCRService: Sendable {
    public var settings: OCRSettings

    public init(settings: OCRSettings = .default) {
        self.settings = settings
    }

    /// Recognizes one page image.
    public func recognize(_ image: CGImage) async throws -> OCRPageResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if settings.languageIdentifiers.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = settings.languages
        }

        let observations = try await request.perform(on: image)

        // Vision's own `isTitle` needs macOS 26, and referring to it would stop
        // this file compiling against an older SDK. Line height says the same
        // thing, and it is the same heuristic the text-layer path uses: a line
        // noticeably taller than the page's typical line is a heading.
        let heights = observations.map { $0.boundingBox.cgRect.height }.sorted()
        let typicalHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
        let titleHeight = typicalHeight * 1.25

        var lines: [String] = []
        var titles: [String] = []
        var words: [OCRWord] = []
        var confidenceTotal = 0.0
        var counted = 0

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= settings.minimumConfidence
            else { continue }

            let line = candidate.string
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            lines.append(line)
            if typicalHeight > 0, observation.boundingBox.cgRect.height >= titleHeight {
                titles.append(line)
            }
            confidenceTotal += Double(candidate.confidence)
            counted += 1

            // Per-word boxes, so highlighting a match lands on the word rather
            // than washing over the whole line.
            for range in wordRanges(in: line) {
                guard let box = candidate.boundingBox(for: range) else { continue }
                let rect = box.boundingBox.cgRect
                words.append(OCRWord(
                    text: String(line[range]),
                    x: rect.origin.x, y: rect.origin.y,
                    width: rect.width, height: rect.height))
            }
        }

        return OCRPageResult(
            text: lines.joined(separator: " "),
            title: titles.joined(separator: " · "),
            layout: OCRLayout(words: words),
            averageConfidence: counted > 0 ? confidenceTotal / Double(counted) : 0)
    }

    /// Renders a page and reads it, in one step.
    public func recognize(page: PDFPage) async throws -> OCRPageResult {
        guard let image = PageRasterizer.render(page, dpi: settings.dpi) else {
            throw ExtractionError.unreadable("page \(page.label ?? "?") could not be rendered")
        }
        return try await recognize(image)
    }

    private func wordRanges(in line: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in line.indices {
            if Tokenizer.isWordScalar(line.unicodeScalars[index]) {
                if start == nil { start = index }
            } else if let began = start {
                ranges.append(began..<index)
                start = nil
            }
        }
        if let began = start { ranges.append(began..<line.endIndex) }
        return ranges
    }
}
