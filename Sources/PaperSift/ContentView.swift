import SwiftUI

struct ContentView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        NavigationSplitView {
            RootsSidebar()
        } content: {
            ResultsColumn()
        } detail: {
            DocumentDetailView()
        }
        .navigationTitle("PaperSift")
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { library.failure != nil },
                set: { if !$0 { library.dismissFailure() } })
        ) {
            Button("OK") { library.dismissFailure() }
        } message: {
            Text(library.failure ?? "")
        }
    }
}
