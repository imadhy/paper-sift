import PaperSiftCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            OCRSettingsTab()
                .tabItem { Label("OCR", systemImage: "text.viewfinder") }
            IndexSettingsTab()
                .tabItem { Label("Index", systemImage: "internaldrive") }
            UpdatesSettingsTab()
                .tabItem { Label("Updates", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct UpdatesSettingsTab: View {
    @Environment(UpdateService.self) private var updates

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PaperSift \(UpdateService.currentVersion)")
                        Text(status).captionStyle()
                    }
                    Spacer()
                    action
                }
                if !UpdateService.isBundled {
                    Text("Running outside an .app bundle, so there is nothing to replace. Build with scripts/bundle.sh to try the updater.")
                        .captionStyle()
                }
                if case .homebrew(let command) = UpdateService.ownership {
                    BrewUpgradeHint(command: command)
                }
            }

            if case .available(let release) = updates.phase, !release.notes.isEmpty {
                Section("What's new in \(release.version)") {
                    ScrollView {
                        Text(release.notes)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }

            Section {
                Link("Releases on GitHub", destination: UpdateService.releasesPage)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .task { updates.checkIfStale() }
    }

    private var status: String {
        switch updates.phase {
        case .idle: "Checked daily, in the background."
        case .checking: "Checking…"
        case .upToDate: "Up to date."
        case .available(let release): "Version \(release.version) is available."
        case .installing(let release): "Installing \(release.version)…"
        case .failed(let message, _): message
        }
    }

    @ViewBuilder
    private var action: some View {
        switch updates.phase {
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .available where !UpdateService.isHomebrewManaged:
            Button("Install and Relaunch") {
                Task { await updates.install() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!UpdateService.isBundled)
        default:
            Button("Check Now") {
                Task { await updates.check() }
            }
        }
    }
}

/// Shown when Homebrew owns the copy on disk: the command to run, ready to paste.
private struct BrewUpgradeHint: View {
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            Text("Installed by Homebrew, so it updates with brew rather than replacing itself:")
                .captionStyle()
            HStack {
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc",
                       action: copy)
                    .labelStyle(.titleOnly)
                    .controlSize(.small)
            }
            .padding(.horizontal, Metrics.tight)
            .padding(.vertical, Metrics.rowSpacing)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
    }
}

private struct OCRSettingsTab: View {
    @Environment(LibraryModel.self) private var library
    private let settings = AppSettings.shared
    @State private var supported: [Locale.Language] = []

    var body: some View {
        Form {
            Section {
                Toggle("Read scanned pages with OCR", isOn: Binding(
                    get: { settings.ocrEnabled },
                    set: { settings.ocrEnabled = $0; push() }))
                Text("Pages with no text layer are rendered and read by Vision, on this Mac. Turning this off leaves them queued — nothing is lost.")
                    .captionStyle()
            }

            Section("Resolution") {
                Picker("Render at", selection: Binding(
                    get: { settings.ocrDPI },
                    set: { settings.ocrDPI = $0; push() })
                ) {
                    Text("150 dpi — fastest").tag(150.0)
                    Text("200 dpi — recommended").tag(200.0)
                    Text("300 dpi — small print").tag(300.0)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Languages") {
                Toggle("Detect automatically", isOn: Binding(
                    get: { settings.ocrLanguageIdentifiers.isEmpty },
                    set: { automatic in
                        settings.ocrLanguageIdentifiers = automatic
                            ? []
                            : [Locale.current.identifier(.bcp47)]
                        push()
                    }))

                if !settings.ocrLanguageIdentifiers.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(supported.map(\.minimalIdentifier), id: \.self) { identifier in
                                Toggle(displayName(identifier), isOn: Binding(
                                    get: { settings.ocrLanguageIdentifiers.contains(identifier) },
                                    set: { isOn in
                                        var languages = Set(settings.ocrLanguageIdentifiers)
                                        if isOn { languages.insert(identifier) } else { languages.remove(identifier) }
                                        settings.ocrLanguageIdentifiers = languages.sorted()
                                        push()
                                    }))
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            supported = OCRSettings.supportedLanguages()
        }
    }

    private func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private func push() {
        Task { await library.applyOCRSettings(settings.ocrSettings) }
    }
}

private struct IndexSettingsTab: View {
    @Environment(LibraryModel.self) private var library
    private let settings = AppSettings.shared
    @State private var confirmingReset = false
    @State private var needsRelaunch = false

    var body: some View {
        Form {
            Section("Location") {
                Text(library.databaseURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack {
                    Text(library.stats.databaseBytes.formatted(.byteCount(style: .file)))
                        .captionStyle()
                    Spacer()
                    Button("Reveal") { library.revealDatabase() }
                    Button("Move…") {
                        Task { needsRelaunch = await library.moveDatabase() }
                    }
                }
            }

            Section("Maintenance") {
                HStack {
                    Button("Back Up Index…") {
                        Task { await library.backupIndex() }
                    }
                    Spacer()
                    Button("Rebuild Index", role: .destructive) {
                        confirmingReset = true
                    }
                }
                Text("Rebuilding keeps your folders and reads every document again. It is the fix if search results ever look stale.")
                    .captionStyle()
            }

            Section("Contents") {
                ForEach(library.rootStats) { root in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(root.name)
                            Spacer()
                            Text("\(root.documents.formatted()) documents · \(root.pages.formatted()) pages")
                                .captionStyle()
                        }
                        if root.progress < 1 {
                            ProgressView(value: root.progress)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await library.refreshRootStats() }
        .alert("Rebuild the index?", isPresented: $confirmingReset) {
            Button("Rebuild", role: .destructive) {
                Task { await library.rebuildIndex() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your folders stay. Every document is read again, which can take a while on a big library.")
        }
        .alert("Relaunch to use the new location", isPresented: $needsRelaunch) {
            Button("Relaunch") { library.relaunch() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("The index was copied to its new home. PaperSift needs to restart to open it.")
        }
    }
}
