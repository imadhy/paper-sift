import AppKit
import CoreText
import Foundation

/// Builds real PDFs at runtime instead of committing binary fixtures to git.
///
/// The generated files carry a genuine text layer, so they exercise
/// `PDFTextExtractor` for real — including the heading heuristic, which needs a
/// page whose title is visibly larger than its body.
enum PDFFixtures {
    struct Page {
        var title: String
        var body: String

        init(title: String = "", body: String) {
            self.title = title
            self.body = body
        }
    }

    static func write(_ pages: [Page], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw FixtureError.cannotWrite(url.path)
        }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw FixtureError.cannotWrite(url.path)
        }

        for page in pages {
            context.beginPDFPage(nil)
            if !page.title.isEmpty {
                draw(page.title,
                     font: NSFont(name: "Helvetica-Bold", size: 28) ?? .boldSystemFont(ofSize: 28),
                     in: CGRect(x: 54, y: 660, width: 504, height: 90),
                     context: context)
            }
            draw(page.body,
                 font: NSFont(name: "Helvetica", size: 11) ?? .systemFont(ofSize: 11),
                 in: CGRect(x: 54, y: 90, width: 504, height: 560),
                 context: context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// A page with ink but no text — what a scanned document looks like to us.
    static func writeScan(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw FixtureError.cannotWrite(url.path)
        }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw FixtureError.cannotWrite(url.path)
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.lightGray.cgColor)
        context.fill(CGRect(x: 80, y: 300, width: 452, height: 200))
        context.endPDFPage()
        context.closePDF()
    }

    /// A PDF whose page is a picture of text — a stand-in for a real scan.
    ///
    /// The text is rendered to a bitmap first, so the PDF carries no text layer at
    /// all and OCR is the only way to read it.
    static func writeScannedText(headline: String, body: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 1 240 × 1 754 is roughly A4 at 150 dpi — a realistic scan resolution.
        let width = 1_240
        let height = 1_754
        guard let bitmap = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw FixtureError.cannotWrite(url.path) }

        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(headline,
             font: NSFont(name: "Helvetica-Bold", size: 76) ?? .boldSystemFont(ofSize: 76),
             in: CGRect(x: 110, y: 1_420, width: 1_020, height: 200),
             context: bitmap)
        draw(body,
             font: NSFont(name: "Helvetica", size: 44) ?? .systemFont(ofSize: 44),
             in: CGRect(x: 110, y: 500, width: 1_020, height: 880),
             context: bitmap)

        guard let image = bitmap.makeImage() else { throw FixtureError.cannotWrite(url.path) }

        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw FixtureError.cannotWrite(url.path)
        }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw FixtureError.cannotWrite(url.path)
        }
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
    }

    private static func draw(_ text: String, font: NSFont, in rect: CGRect, context: CGContext) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
        ])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case cannotWrite(String)
        var description: String {
            switch self {
            case .cannotWrite(let path): "cannot write fixture at \(path)"
            }
        }
    }
}

/// A unique scratch directory, removed by the OS eventually.
func tempDirectory(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("papersift-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
