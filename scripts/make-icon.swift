// Draws Resources/AppIcon.icns with no Xcode and no design tool:
//   swift scripts/make-icon.swift
// Renders the 1024 px master (gradient squircle + document-and-lens glyph);
// build-iconset.sh then derives the sizes with sips and packs them with iconutil.
import AppKit

let canvas: CGFloat = 1024
let masterURL = URL(fileURLWithPath: "build/icon/icon_1024.png")
try FileManager.default.createDirectory(at: masterURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let copy = image.copy() as! NSImage
    copy.lockFocus()
    color.set()
    NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
    copy.unlockFocus()
    return copy
}

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Squircle at macOS icon proportions (~80 % of the canvas).
let inset: CGFloat = 100
let squircle = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset),
    xRadius: 185, yRadius: 185
)
NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.35, alpha: 1),
    NSColor(calibratedRed: 0.29, green: 0.55, blue: 0.95, alpha: 1),
])!.draw(in: squircle, angle: 90)

// A page with a lens over it: the whole app in one glyph.
let configuration = NSImage.SymbolConfiguration(pointSize: 430, weight: .regular)
if let glyph = NSImage(systemSymbolName: "doc.text.magnifyingglass",
                       accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration) {
    let white = tinted(glyph, .white)
    let scale = 520 / max(white.size.width, white.size.height)
    let size = NSSize(width: white.size.width * scale, height: white.size.height * scale)
    let origin = NSPoint(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()

    white.draw(in: NSRect(origin: origin, size: size))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let representation = NSBitmapImageRep(data: tiff),
      let png = representation.representation(using: .png, properties: [:]) else {
    fatalError("PNG rendering failed")
}
try png.write(to: masterURL)
print("✅ master: \(masterURL.path)")
