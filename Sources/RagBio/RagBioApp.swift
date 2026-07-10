import SwiftUI

@main
struct RagBioApp: App {
    @StateObject private var store = SearchStore()
    @StateObject private var libraryStore = LibraryStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, libraryStore: libraryStore)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("导入 PDF 到文库…") {
                    Task { await libraryStore.choosePDFs() }
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("检索") {
                Button("开始检索") {
                    Task { await store.search() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
