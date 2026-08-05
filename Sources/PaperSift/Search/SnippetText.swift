import PaperSiftCore
import SwiftUI

/// Renders a snippet with its matched words marked.
///
/// The highlight ranges are UTF-16 offsets, so the string is rebuilt run by run
/// rather than converted to `AttributedString` indices — same approach as the CLI,
/// and it cannot drift on accented text.
struct SnippetText: View {
    let snippet: Snippet
    var font: Font = .callout
    /// Off inside list rows: a selectable `Text` swallows the click that was meant
    /// to select the row it sits in.
    var selectable = true

    var body: some View {
        // `.enabled` and `.disabled` are different types, so this is an if, not a
        // ternary.
        if selectable {
            text.textSelection(.enabled)
        } else {
            text.textSelection(.disabled)
        }
    }

    private var text: Text {
        Text(attributed).font(font)
    }

    private var attributed: AttributedString {
        let text = snippet.text
        var result = AttributedString()
        var cursor = 0

        for range in snippet.highlights where range.lowerBound >= cursor {
            if let plain = text.utf16Substring(start: cursor, length: range.lowerBound - cursor) {
                result += AttributedString(plain)
            }
            if let match = text.utf16Substring(
                start: range.lowerBound, length: range.upperBound - range.lowerBound) {
                var run = AttributedString(match)
                run.backgroundColor = .matchHighlight
                run.inlinePresentationIntent = .stronglyEmphasized
                result += run
            }
            cursor = range.upperBound
        }
        if let tail = text.utf16Substring(start: cursor, length: text.utf16.count - cursor) {
            result += AttributedString(tail)
        }
        return result
    }
}
