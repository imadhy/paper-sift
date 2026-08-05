import Foundation

/// Cuts a document with no pages of its own into page-sized pieces.
///
/// A text file or a Word document has no page 7 to jump to, but the whole app is
/// built around page-level results — so the text is split into stable chunks that
/// play the same role. Cuts land on paragraph breaks where possible, so a chunk
/// reads like something a person wrote.
public enum PageChunker {
    public static let targetLength = 3_000

    public static func chunk(_ text: String, targetLength: Int = targetLength) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > targetLength else { return [trimmed] }

        var chunks: [String] = []
        var current = ""
        // Paragraphs first: a blank line is the strongest hint of a seam.
        for paragraph in trimmed.components(separatedBy: "\n\n") {
            let piece = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }

            if current.count + piece.count + 2 <= targetLength || current.isEmpty {
                current += current.isEmpty ? piece : "\n\n" + piece
            } else {
                chunks.append(current)
                current = piece
            }

            // A single paragraph longer than a chunk still has to be cut.
            while current.count > targetLength * 2 {
                let cut = softCut(current, near: targetLength)
                chunks.append(String(current[current.startIndex..<cut])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                current = String(current[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.filter { !$0.isEmpty }
    }

    /// The nearest sentence end, then the nearest space, then wherever we must.
    private static func softCut(_ text: String, near target: Int) -> String.Index {
        let limit = text.index(text.startIndex, offsetBy: min(target, text.count))
        let window = text.index(
            text.startIndex, offsetBy: max(0, min(target, text.count) - 200))
        if let sentence = text.range(of: ". ", options: .backwards, range: window..<limit) {
            return sentence.upperBound
        }
        if let space = text.range(of: " ", options: .backwards, range: window..<limit) {
            return space.upperBound
        }
        return limit
    }
}
