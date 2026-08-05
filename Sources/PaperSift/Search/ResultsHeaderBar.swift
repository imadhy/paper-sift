import PaperSiftCore
import SwiftUI

/// How many results there were, how long they took, and how they are ordered.
struct ResultsHeaderBar: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        HStack(spacing: Metrics.rowSpacing) {
            Text(library.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if library.results?.usedScan == true {
                Chip(text: "scanned", symbol: "tortoise")
                    .help("A suffix or infix wildcard cannot use the index, so pages were scanned. Prefix wildcards (econom*) are instant.")
            }
            if library.results?.truncated == true {
                Chip(text: "more exist", symbol: "ellipsis.circle")
                    .help("The shortlist was full — narrow the query to see the rest.")
            }

            Spacer()
            sortMenu
        }
        .padding(.horizontal, 14)
        .padding(.bottom, Metrics.rowSpacing)
    }

    private var sortMenu: some View {
        @Bindable var library = library
        return Menu {
            Picker("Order", selection: $library.sort) {
                ForEach(ResultSort.allCases) { sort in
                    Label(sort.label, systemImage: sort.symbol).tag(sort)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Reverse order", isOn: $library.sortReversed)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: library.sort.symbol)
                Text(library.sort.label)
                Image(systemName: library.sortReversed ? "arrow.up" : "arrow.down")
                    .font(.caption2.bold())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Sort results")
        .accessibilityValue(library.sort.label)
        .help("Sorted by \(library.sort.label.lowercased())")
    }
}
