#!/usr/bin/env swift
// Builds a synthetic document set for screenshots and demos.
//
// The README cannot show anyone's real files, and a screenshot of an empty window
// sells nothing — so this draws a plausible corpus with CoreText: a folder of
// multi-page engineering reports with a text layer, one page that is a *picture* of
// text (the OCR path, which is the feature that needs proving), and a few non-PDF
// files for the text reader.
//
// Deterministic on purpose: a fixed seed means re-running it produces the same
// corpus, so a screenshot can be retaken later and still match its caption.
//
// Usage: swift scripts/demo-corpus.swift [destination]
//        (default: /tmp/PaperSift Demo)

import AppKit
import CoreText
import Foundation

// MARK: - Deterministic randomness

/// A tiny linear congruential generator. `SystemRandomNumberGenerator` would make
/// every run a different corpus, and then the captions would drift from the images.
struct Seeded: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

var rng = Seeded(seed: 20_260_805)

// MARK: - Vocabulary

/// Words a maintenance report would actually carry, so the highlighted matches in a
/// screenshot look like something and not like lorem ipsum.
let vocabulary = [
    "turbine", "gearbox", "calibration", "flange", "bearing", "vibration", "torque",
    "inspection", "tolerance", "maintenance", "clearance", "alignment", "coupling",
    "lubrication", "housing", "impeller", "seal", "gasket", "shaft", "compressor",
    "threshold", "baseline", "quarterly", "schedule", "reading", "deviation",
    "assembly", "fatigue", "corrosion", "overhaul", "spare", "vendor",
]

let connectives = [
    "the", "a", "and", "of", "for", "with", "after", "before", "during", "per",
    "within", "against", "under", "above", "between",
]

func sentence(words: Int) -> String {
    var parts: [String] = []
    for index in 0..<words {
        // Roughly one connective in three keeps it readable without a grammar.
        let pool = index % 3 == 1 ? connectives : vocabulary
        parts.append(pool.randomElement(using: &rng)!)
    }
    var text = parts.joined(separator: " ")
    text = text.prefix(1).uppercased() + text.dropFirst()
    return text + "."
}

func paragraph(sentences: Int) -> String {
    (0..<sentences).map { _ in sentence(words: Int.random(in: 9...18, using: &rng)) }
        .joined(separator: " ")
}

// MARK: - Drawing

func draw(_ text: String, font: NSFont, in rect: CGRect, context: CGContext) {
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: NSColor.black,
    ])
    let setter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(rect: rect, transform: nil)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, context)
}

struct Page {
    var title: String
    var body: String
}

func pdfContext(at url: URL) throws -> (CGContext, CGRect) {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let consumer = CGDataConsumer(url: url as CFURL) else {
        throw Failure("cannot write \(url.path)")
    }
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
        throw Failure("cannot open a PDF context at \(url.path)")
    }
    return (context, box)
}

/// A report with a real text layer: title large, body small, so the ranker's heading
/// heuristic has something to find.
func writeReport(_ pages: [Page], to url: URL) throws {
    let (context, _) = try pdfContext(at: url)
    for page in pages {
        context.beginPDFPage(nil)
        draw(page.title,
             font: NSFont(name: "Helvetica-Bold", size: 26) ?? .boldSystemFont(ofSize: 26),
             in: CGRect(x: 54, y: 692, width: 504, height: 44),
             context: context)
        draw(page.body,
             font: NSFont(name: "Helvetica", size: 11) ?? .systemFont(ofSize: 11),
             in: CGRect(x: 54, y: 80, width: 504, height: 590),
             context: context)
        context.endPDFPage()
    }
    context.closePDF()
}

/// A page that is an *image* of text: no text layer at all, so Vision is the only
/// way in. Rendered at ~150 dpi, which is what a real scanner produces.
func writeScan(headline: String, pages: [String], to url: URL) throws {
    let (pdf, box) = try pdfContext(at: url)
    let width = 1_240
    let height = 1_754

    for (index, body) in pages.enumerated() {
        guard let bitmap = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw Failure("cannot allocate the scan bitmap") }

        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(index == 0 ? headline : "\(headline) (continued)",
             font: NSFont(name: "Helvetica-Bold", size: 64) ?? .boldSystemFont(ofSize: 64),
             in: CGRect(x: 110, y: 1_430, width: 1_020, height: 190),
             context: bitmap)
        draw(body,
             font: NSFont(name: "Helvetica", size: 40) ?? .systemFont(ofSize: 40),
             in: CGRect(x: 110, y: 420, width: 1_020, height: 970),
             context: bitmap)
        // A faint scanner artefact along one edge, so it reads as a scan.
        bitmap.setFillColor(gray: 0.82, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: 26, height: height))

        guard let image = bitmap.makeImage() else { throw Failure("cannot rasterize the scan") }
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
    }
    pdf.closePDF()
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - The corpus

let destination = URL(
    fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/PaperSift Demo",
    isDirectory: true)

try? FileManager.default.removeItem(at: destination)

// Twenty-four reports of three to six pages: enough that a common word matches
// dozens of pages across a dozen files, which is the case the results list exists
// for.
for number in 101...124 {
    let pageCount = Int.random(in: 3...6, using: &rng)
    let pages = (1...pageCount).map { page in
        Page(
            title: "Engineering Review \(number) — Section \(page)",
            body: (0..<4).map { _ in paragraph(sentences: Int.random(in: 4...7, using: &rng)) }
                .joined(separator: "\n\n"))
    }
    try writeReport(
        pages, to: destination.appendingPathComponent("Engineering/engineering-\(number).pdf"))
}

// A handful of shorter maintenance logs, to vary the sizes in the list.
for number in 1...6 {
    let pages = (1...2).map { page in
        Page(title: "Maintenance Log \(number).\(page)", body: paragraph(sentences: 8))
    }
    try writeReport(
        pages, to: destination.appendingPathComponent("Maintenance/maintenance-\(number).pdf"))
}

// The scan: no text layer, three pages, deliberately using the same vocabulary so
// it competes with the text documents in the ranking.
try writeScan(
    headline: "Turbine Gearbox Inspection",
    pages: (0..<3).map { _ in paragraph(sentences: 6) },
    to: destination.appendingPathComponent("Scans/gearbox-inspection-scan.pdf"))

// Non-PDF files, for the reader that handles documents with no pages of their own.
try write("""
# Calibration notes

The quarterly **calibration** of the turbine gearbox follows the same three steps
every time, and the third is the one everybody forgets.

1. Record the vibration baseline before touching anything.
2. Torque the flange bolts in a star pattern, never around the circle.
3. Re-read the baseline an hour later, once the housing has settled.

\(paragraph(sentences: 6))

## Tolerances

\(paragraph(sentences: 5))
""", to: destination.appendingPathComponent("Notes/calibration-notes.md"))

try write("""
import Foundation

/// Reads a vibration log and reports the readings that drifted past tolerance.
///
/// The calibration baseline is deliberately passed in rather than measured here:
/// the gearbox housing needs an hour to settle and this runs immediately.
struct VibrationMonitor {
    let baseline: Double
    let tolerance: Double

    func deviations(in readings: [Double]) -> [Int] {
        readings.indices.filter { abs(readings[$0] - baseline) > tolerance }
    }
}
""", to: destination.appendingPathComponent("Notes/VibrationMonitor.swift"))

// Proof that pruning works: this must never appear in a result.
try write(
    "module.exports = { turbine: 'this should never be indexed' };",
    to: destination.appendingPathComponent("Notes/node_modules/left-pad/index.js"))

let files = try FileManager.default
    .subpathsOfDirectory(atPath: destination.path)
    .filter { !$0.hasSuffix(".DS_Store") }
print("✅ \(files.count) files in \(destination.path)")
