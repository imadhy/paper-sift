import SwiftUI

/// The shared visual language: spacing, radii and the few semantic colors the
/// app reuses. Anything that appears in more than one view belongs here.
enum Metrics {
    static let gutter: CGFloat = 16
    static let tight: CGFloat = 8
    static let hairline: CGFloat = 4
    static let rowSpacing: CGFloat = 6
    static let cornerRadius: CGFloat = 10
    /// Rows and cards that carry content, rather than chrome.
    static let cardRadius: CGFloat = 14
    static let thumbnailWidth: CGFloat = 52
    static let thumbnailHeight: CGFloat = 68
    static let sidebarMinWidth: CGFloat = 216
    static let resultsMinWidth: CGFloat = 380
    static let resultsIdealWidth: CGFloat = 440
}

extension Color {
    /// Background of a search snippet's matched term.
    ///
    /// Tied to the accent color rather than a fixed yellow: at 22% it reads as a
    /// highlight in both appearances, and it stops the results column from looking
    /// like a highlighter pen exploded on it.
    static let matchHighlight = Color.accentColor.opacity(0.22)
    /// Surface used for cards and rows that need to lift off the window.
    static let surface = Color(nsColor: .controlBackgroundColor)
}

/// The glass recipe itself, outside any `@ViewBuilder`, which has no room for the
/// three statements it takes to build one.
@available(macOS 26.0, *)
private func liquidGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// Small and dimmed — metadata, captions and status lines.
    func captionStyle() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Liquid Glass where the OS has it, a vibrancy material where it does not.
    ///
    /// One helper rather than `#available` scattered through the views: macOS 26
    /// gets the real thing — refraction, the specular edge, the way it picks up
    /// what is behind it — and macOS 15 keeps a flat material that at least has
    /// the same shape and padding, so nothing shifts between the two.
    @ViewBuilder
    func glassPanel(
        in shape: some Shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous),
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(liquidGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }

    /// Groups nearby glass shapes so they merge instead of stacking their edges.
    /// A no-op before macOS 26, where there is nothing to merge.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = Metrics.tight) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// The system's glass button on macOS 26, a bordered one before it.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }

    /// Hides the opaque background a `List` or `Form` paints, so the window's
    /// material shows through it.
    func clearScrollBackground() -> some View {
        scrollContentBackground(.hidden)
    }

    /// A cluster of icon buttons sitting in a bar: one glass capsule around them all,
    /// full-contrast glyphs, and a hit area worth aiming at.
    func barControlStyle() -> some View {
        buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .imageScale(.medium)
            .font(.body)
            .padding(.horizontal, Metrics.tight)
            .padding(.vertical, 5)
            .glassPanel(in: Capsule())
    }
}

/// A small pill — page rank, "OCR", "scanned". Reads as a label, not a button.
struct Chip: View {
    enum Emphasis {
        /// Filled with the accent color: the one number the eye should find.
        case primary
        /// Quiet, for provenance and warnings.
        case secondary
    }

    let text: String
    var symbol: String?
    var emphasis: Emphasis = .secondary

    var body: some View {
        Label {
            Text(text).monospacedDigit()
        } icon: {
            if let symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(emphasis == .primary ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            // A fill, not a tint on the text: rank 1 has to be findable at a glance
            // even for someone who cannot tell the accent color from the row.
            Capsule().fill(emphasis == .primary
                           ? AnyShapeStyle(Color.accentColor.gradient)
                           : AnyShapeStyle(.quaternary))
        }
        // A chip is a label, and a label folded onto two lines inside a capsule reads
        // as a bug. In a narrow column whatever sits next to it yields instead.
        .fixedSize()
    }
}

/// A label above its value, the way file inspectors show metadata.
struct MetadataItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        // Two stacked labels read as "Modified, 28/01/2025" rather than as two
        // unrelated fragments.
        .accessibilityElement(children: .combine)
    }
}

extension Date {
    /// "28/01/2025, 10:58" — short, unambiguous, and the same width every time.
    var resultRowFormat: String {
        formatted(date: .numeric, time: .shortened)
    }
}

extension Int64 {
    var fileSizeFormat: String {
        formatted(.byteCount(style: .file))
    }
}
