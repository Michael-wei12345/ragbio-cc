import SwiftUI

@main
struct RagBioApp: App {
    @StateObject private var store = SearchStore()
    @StateObject private var reviewJobs = ReviewJobCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, reviewJobs: reviewJobs)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("检索") {
                Button("开始检索") {
                    Task { await store.search() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    !SearchHistorySuggestions.canSubmit(query: store.query)
                )
            }
        }

        Settings {
            SettingsView()
        }
    }
}
