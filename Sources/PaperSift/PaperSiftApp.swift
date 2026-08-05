import AppKit
import PaperSiftCore
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        // A CLI flag means "do this and quit"; anything else opens the window.
        switch CLI.handle(Array(CommandLine.arguments.dropFirst())) {
        case .handled:
            return
        case .launchApp(let database, let query):
            // `--database` wins, then the preference, then the default location.
            AppConfiguration.databaseURL = database ?? AppSettings.shared.databaseURL
            AppConfiguration.initialQuery = query
            PaperSiftApp.main()
        }
    }
}

/// Set once by `Main` before the app starts, so `--database` can point the window
/// at a scratch index and `--query` can open it on a search.
@MainActor
enum AppConfiguration {
    static var databaseURL = IndexStore.defaultURL
    static var initialQuery: String?
}

struct PaperSiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library: LibraryModel?
    @State private var startupFailure: String?
    @State private var updates = UpdateService()

    init() {
        do {
            let store = try IndexStore(url: AppConfiguration.databaseURL)
            _library = State(initialValue: LibraryModel(store: store))
        } catch {
            _startupFailure = State(initialValue: String(describing: error))
        }
    }

    var body: some Scene {
        WindowGroup("PaperSift", id: "main") {
            if let library {
                ContentView()
                    .environment(library)
                    .task { await library.bootstrap() }
            } else {
                StartupFailureView(message: startupFailure ?? "unknown error")
            }
        }
        .defaultSize(width: 1_180, height: 760)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Find") {
                    NotificationCenter.default.post(name: .focusSearchField, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Add Folder…") {
                    guard let library else { return }
                    Task { await library.addFolder() }
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Rescan Folders") {
                    guard let library else { return }
                    Task { await library.rescan() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            // Walking the results without leaving the search field is how you use a
            // search box: type, then ⌘↓ until the right page is on screen.
            CommandMenu("Results") {
                Button("Next Result") {
                    library?.selectNextDocument()
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Button("Previous Result") {
                    library?.selectPreviousDocument()
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Divider()

                Button("Next Matching Page") {
                    library?.showNextHit()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])

                Button("Previous Matching Page") {
                    library?.showPreviousHit()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            }
        }

        Settings {
            if let library {
                SettingsView()
                    .environment(library)
                    .environment(updates)
            }
        }
    }
}

/// Shown when the index cannot be opened at all — a read-only disk, a corrupted
/// file. Better than a window that silently does nothing.
struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: Metrics.tight) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)
            Text("PaperSift could not open its index")
                .font(.headline)
            Text(message)
                .captionStyle()
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text(AppConfiguration.databaseURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(Metrics.gutter * 2)
        .frame(minWidth: 460, minHeight: 260)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Required when the binary runs outside a bundle (`swift run`): without
        // it the app never comes to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
