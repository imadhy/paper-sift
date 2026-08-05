import AppKit
import PaperSiftCore
import QuickLookThumbnailing
import SwiftUI

/// Page-one previews for result rows.
///
/// QuickLook rather than PDFKit on purpose: it covers every format we index — PDF,
/// Word, spreadsheets, code, plain text — and the system already keeps a disk cache
/// of them, so scrolling a folder you have searched before costs nothing. All this
/// adds is the in-memory half, and the guarantee that a file being asked for twice
/// while the list settles only renders once.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    /// Size and date are part of the key: an edited file must not keep showing the
    /// preview of what it used to say.
    private struct Key: Hashable {
        let path: String
        let modifiedAt: Double
        let size: Int64
    }

    private var cache: [Key: Image] = [:]
    private var insertionOrder: [Key] = []
    private var running: [Key: Task<Image?, Never>] = [:]

    /// Roughly two screens of rows. Past that the oldest go, since the system cache
    /// makes a second render cheap and holding a thousand bitmaps does not.
    private let capacity = 240

    func thumbnail(for document: DocumentResult, size: CGSize) async -> Image? {
        let key = Key(
            path: document.path,
            modifiedAt: document.modifiedAt.timeIntervalSince1970,
            size: document.size)
        if let cached = cache[key] { return cached }
        if let inFlight = running[key] { return await inFlight.value }

        let url = document.url
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let task = Task { await Self.render(url: url, size: size, scale: scale) }
        running[key] = task
        let image = await task.value
        running[key] = nil
        if let image { remember(image, for: key) }
        return image
    }

    private func remember(_ image: Image, for key: Key) {
        if cache.updateValue(image, forKey: key) == nil {
            insertionOrder.append(key)
        }
        guard insertionOrder.count > capacity else { return }
        for key in insertionOrder.prefix(insertionOrder.count - capacity) {
            cache[key] = nil
        }
        insertionOrder.removeFirst(insertionOrder.count - capacity)
    }

    /// Off the main actor, and PNG data on the way back: `QLThumbnailRepresentation`
    /// is a reference type the compiler will not let cross an isolation boundary,
    /// and encoding a 100-point bitmap costs less than arguing about it.
    private nonisolated static func render(url: URL, size: CGSize, scale: CGFloat) async -> Image? {
        let data: Data? = await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: size, scale: scale, representationTypes: .all)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let cgImage = representation?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                continuation.resume(returning: bitmap.representation(using: .png, properties: [:]))
            }
        }
        guard let data, let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
    }
}

/// A document's first page, or the icon of its kind while there is nothing to show.
struct DocumentThumbnail: View {
    let document: DocumentResult
    var width: CGFloat = Metrics.thumbnailWidth
    var height: CGFloat = Metrics.thumbnailHeight

    @State private var image: Image?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
    }

    var body: some View {
        shape
            .fill(.background.secondary)
            .overlay {
                if let image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(shape)
                        .transition(.opacity)
                } else {
                    Image(systemName: document.isPDF ? "doc.richtext" : "doc.text")
                        .font(.title3)
                        .fontWeight(.light)
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
            .animation(.easeOut(duration: 0.18), value: image == nil)
            // The filename is right next to it; VoiceOver does not need the picture.
            .accessibilityHidden(true)
            .task(id: document.documentID) {
                image = await ThumbnailLoader.shared.thumbnail(
                    for: document, size: CGSize(width: width, height: height))
            }
    }
}
