import PDFKit
import PaperSiftCore
import SwiftUI

/// A `PDFView` that opens on the matching page with the matched words marked.
///
/// Two ways in, because scans have no text to select:
///
/// * a normal page uses `highlightedSelections`, found in the page's own text.
///   Searching the whole document per term would cost more than the search itself
///   on a long PDF, so the lookup stays page-local.
/// * an OCR'd page has no text layer, so the stored word boxes become temporary
///   highlight annotations instead.
///
/// Neither path ever writes to the user's file — the annotations live on the
/// in-memory document and are removed when the selection moves on.
struct PDFViewerView: NSViewRepresentable {
    let url: URL
    let pageNumber: Int
    let terms: [String]
    let ocrLayout: OCRLayout?
    /// Multiplier on the width-fitting scale; 1 hands the sizing back to PDFKit.
    var zoom: Double = 1

    final class Coordinator {
        var loadedURL: URL?
        var highlightedKey: String?
        var appliedZoom: Double = 1
        var addedAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.loadedURL != url {
            view.document = PDFDocument(url: url)
            context.coordinator.loadedURL = url
            context.coordinator.highlightedKey = nil
        }
        guard let document = view.document else { return }
        let index = min(max(0, pageNumber - 1), max(0, document.pageCount - 1))
        guard let page = document.page(at: index) else { return }

        // Zoom is applied before the highlight guard below, or a change of scale with
        // the same page and terms would be dropped along with it.
        if context.coordinator.appliedZoom != zoom {
            context.coordinator.appliedZoom = zoom
            if zoom == 1 {
                view.autoScales = true
            } else {
                // `scaleFactorForSizeToFit` is the width-fitting scale PDFKit would
                // have picked, so the steps stay relative to the window, not to the
                // paper size.
                view.autoScales = false
                view.scaleFactor = view.scaleFactorForSizeToFit * zoom
            }
        }

        // Re-highlighting on every SwiftUI update would fight the user's scrolling.
        let key = "\(url.path)#\(index)#\(terms.joined(separator: "|"))#\(ocrLayout?.words.count ?? 0)"
        guard context.coordinator.highlightedKey != key else { return }
        context.coordinator.highlightedKey = key

        // Drop whatever we drew for the previous selection.
        for entry in context.coordinator.addedAnnotations {
            entry.page.removeAnnotation(entry.annotation)
        }
        context.coordinator.addedAnnotations = []

        if let ocrLayout {
            let boxes = ocrLayout.boxes(matching: terms)
            context.coordinator.addedAnnotations = Self.annotate(boxes, on: page)
            view.highlightedSelections = nil
            view.go(to: page)
            // Landing on page 40 of a scan and leaving the reader to hunt for the
            // yellow box is not an answer. Scroll the first one into view.
            if let first = context.coordinator.addedAnnotations.first {
                view.go(to: Self.withContext(first.annotation.bounds), on: page)
            }
        } else {
            let selections = Self.selections(for: terms, on: page)
            view.highlightedSelections = selections
            view.go(to: page)
            if let first = selections?.first {
                view.go(to: Self.withContext(first.bounds(for: page)), on: page)
            }
        }
    }

    /// A match scrolled to the very top edge of the view reads as if the page starts
    /// there. Grow the rectangle so a couple of lines above it come along.
    private static func withContext(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: 0, dy: -90)
    }

    /// Turns normalized OCR boxes into highlight annotations.
    ///
    /// Vision reports lower-left-origin normalized rects and PDF page space is
    /// also lower-left origin, so this is a straight scale — no flipping.
    private static func annotate(
        _ words: [OCRWord], on page: PDFPage
    ) -> [(page: PDFPage, annotation: PDFAnnotation)] {
        let bounds = page.bounds(for: .mediaBox)
        var added: [(page: PDFPage, annotation: PDFAnnotation)] = []
        for word in words {
            let rect = CGRect(
                x: bounds.minX + word.x * bounds.width,
                y: bounds.minY + word.y * bounds.height,
                width: word.width * bounds.width,
                height: word.height * bounds.height)
            let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            annotation.color = .systemYellow
            page.addAnnotation(annotation)
            added.append((page, annotation))
        }
        return added
    }

    private static func selections(for terms: [String], on page: PDFPage) -> [PDFSelection]? {
        guard let text = page.string as NSString? else { return nil }
        var selections: [PDFSelection] = []
        for term in terms where !term.isEmpty {
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let found = text.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange)
                guard found.location != NSNotFound else { break }
                if let selection = page.selection(for: found) {
                    selections.append(selection)
                }
                let next = found.location + max(found.length, 1)
                searchRange = NSRange(location: next, length: max(0, text.length - next))
            }
        }
        return selections.isEmpty ? nil : selections
    }
}
