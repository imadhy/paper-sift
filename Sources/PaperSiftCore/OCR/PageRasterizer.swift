import CoreGraphics
import Foundation
import PDFKit

/// Renders a PDF page into a bitmap for Vision to read.
public enum PageRasterizer {
    /// Nothing good comes of handing Vision a 200-megapixel image; a poster-sized
    /// page is downscaled to fit this instead.
    static let maximumPixels = 40_000_000

    /// Grayscale on purpose: a third of the memory of RGB, and OCR does not care
    /// about colour.
    public static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        var scale = max(0.1, dpi / 72)
        let pixels = (bounds.width * scale) * (bounds.height * scale)
        if pixels > Double(maximumPixels) {
            scale *= (Double(maximumPixels) / pixels).squareRoot()
        }

        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }

        // Scans are ink on paper: start from white, or dark PDFs come out inverted.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)

        return context.makeImage()
    }
}
