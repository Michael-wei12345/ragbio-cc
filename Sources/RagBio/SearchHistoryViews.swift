import SwiftUI

enum SearchHistorySuggestions {
    static func filtered(
        _ summaries: [SearchHistorySummary],
        query: String
    ) -> [SearchHistorySummary] {
        let needle = SearchQueryIdentity.normalize(query)
        guard !needle.isEmpty else { return summaries }
        return summaries.filter {
            SearchQueryIdentity.normalize($0.displayQuery).contains(needle)
        }
    }

    static func canSubmit(query: String, isLoading: Bool) -> Bool {
        !isLoading && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct SearchHistoryField: View {
    @ObservedObject var store: SearchStore
    @FocusState private var focused: Bool
    @State private var deletion: SearchHistorySummary?

    private var filtered: [SearchHistorySummary] {
        SearchHistorySuggestions.filtered(store.historySummaries, query: store.query)
    }

    var body: some View {
        HStack(spacing: 0) {
            TextField("描述你想找什么…", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .focused($focused)
                .onSubmit(runSearch)

            Button("检索", action: runSearch)
                .buttonStyle(.borderedProminent)
                .disabled(
                    !SearchHistorySuggestions.canSubmit(
                        query: store.query,
                        isLoading: store.isLoading
                    )
                )
        }
        .padding(3)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(focused ? Color.accentColor : Color.secondary.opacity(0.25))
        }
        .overlay(alignment: .top) {
            if focused, !filtered.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { summary in
                            Button {
                                focused = false
                                Task { await store.openHistory(summary.id) }
                            } label: {
                                Text(summary.displayQuery)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .frame(height: 38)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete Search History", role: .destructive) {
                                    if summary.useCount == 0 {
                                        Task { await store.deleteHistory(summary.id) }
                                    } else {
                                        deletion = summary
                                    }
                                }
                            }

                            Divider()
                        }
                    }
                }
                .frame(height: 266)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .offset(y: 44)
                .shadow(radius: 8, y: 4)
                .zIndex(20)
            }
        }
        .zIndex(20)
        .alert(
            "Delete Search History?",
            isPresented: Binding(
                get: { deletion != nil },
                set: { if !$0 { deletion = nil } }
            ),
            presenting: deletion
        ) { summary in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await store.deleteHistory(summary.id) }
            }
        } message: { summary in
            Text(
                "This also deletes \(summary.useCount) saved Use selection(s) from this search history. This cannot be undone."
            )
        }
    }

    private func runSearch() {
        guard SearchHistorySuggestions.canSubmit(
            query: store.query,
            isLoading: store.isLoading
        ) else { return }
        focused = false
        Task { await store.search() }
    }
}
