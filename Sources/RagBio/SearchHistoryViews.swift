import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    static func canSubmit(query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum SearchHistoryExportSelection {
    static func candidates(
        _ summaries: [SearchHistorySummary]
    ) -> [SearchHistorySummary] {
        summaries.filter { $0.useCount > 0 }
            .sorted { $0.lastSuccessfulSearchAt > $1.lastSuccessfulSearchAt }
    }

    static func initialIDs(
        candidates: [SearchHistorySummary],
        currentHistoryID: UUID?
    ) -> Set<UUID> {
        guard let currentHistoryID,
              candidates.contains(where: { $0.id == currentHistoryID }) else { return [] }
        return [currentHistoryID]
    }
}

@MainActor
private enum SearchHistoryNativeSave {
    static func run(text: String) throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "RagBio-Use-URLs.txt"
        panel.message = "Export URLs from selected search histories"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}

struct UseURLExportSheet: View {
    @ObservedObject var store: SearchStore
    @Binding var isPresented: Bool
    @State private var selectedIDs = Set<UUID>()
    @State private var document = SearchHistoryExportDocument.empty
    @State private var documentIDs = Set<UUID>()
    @State private var activeLoadID = UUID()
    @State private var writeError: String?

    private var candidates: [SearchHistorySummary] {
        SearchHistoryExportSelection.candidates(store.historySummaries)
    }

    private var currentDocument: SearchHistoryExportDocument {
        documentIDs == selectedIDs ? document : .empty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Use URLs")
                .font(.title2.bold())

            HStack {
                Button("Select All") {
                    select(Set(candidates.map(\.id)))
                }
                Button("Clear") {
                    select([])
                }
                Spacer()
                Text("\(selectedIDs.count) selected")
                    .foregroundStyle(.secondary)
            }

            List(candidates) { summary in
                Toggle(isOn: Binding(
                    get: { selectedIDs.contains(summary.id) },
                    set: { isSelected in
                        var updated = selectedIDs
                        if isSelected {
                            updated.insert(summary.id)
                        } else {
                            updated.remove(summary.id)
                        }
                        select(updated)
                    }
                )) {
                    HStack {
                        Text(summary.displayQuery)
                            .lineLimit(1)
                        Spacer()
                        Text("\(summary.useCount) Use")
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }

            if let writeError {
                Text(writeError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button("Export \(currentDocument.urlCount) URLs…") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty || documentIDs != selectedIDs)
            }
        }
        .padding(20)
        .frame(width: 520, height: 430)
        .task {
            guard selectedIDs.isEmpty else { return }
            select(SearchHistoryExportSelection.initialIDs(
                candidates: candidates,
                currentHistoryID: store.currentHistoryID
            ))
        }
        .task(id: selectedIDs) {
            await loadDocument()
        }
    }

    private func select(_ ids: Set<UUID>) {
        selectedIDs = ids
        documentIDs = []
        writeError = nil
    }

    private func loadDocument() async {
        let requestedIDs = selectedIDs
        let loadID = UUID()
        activeLoadID = loadID
        documentIDs = []
        guard !requestedIDs.isEmpty else {
            document = .empty
            return
        }
        do {
            let loaded = try await store.loadExportRecords(ids: requestedIDs)
            try Task.checkCancellation()
            guard activeLoadID == loadID, selectedIDs == requestedIDs else { return }
            document = loaded
            documentIDs = requestedIDs
        } catch is CancellationError {
            return
        } catch {
            guard activeLoadID == loadID, selectedIDs == requestedIDs else { return }
            writeError = "The selected histories could not be loaded: \(error.localizedDescription)"
        }
    }

    private func save() {
        writeError = nil
        do {
            guard try SearchHistoryNativeSave.run(text: currentDocument.text) else { return }
            store.presentExportStatus(currentDocument)
            isPresented = false
        } catch {
            writeError = "The file could not be written: \(error.localizedDescription)"
        }
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
                    !SearchHistorySuggestions.canSubmit(query: store.query)
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
        .background(alignment: .topLeading) {
            SearchHistoryOutsideClickMonitor(isActive: focused) {
                focused = false
            }
            .frame(height: 310)
        }
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
        guard SearchHistorySuggestions.canSubmit(query: store.query) else { return }
        focused = false
        Task { await store.search() }
    }
}

private struct SearchHistoryOutsideClickMonitor: NSViewRepresentable {
    let isActive: Bool
    let onOutsideClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.isActive = isActive
        context.coordinator.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ nsView: PassthroughView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var view: NSView?
        var isActive = false
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self,
                      self.isActive,
                      let view = self.view,
                      event.window === view.window else { return event }
                let location = view.convert(event.locationInWindow, from: nil)
                guard !view.bounds.contains(location) else { return event }
                DispatchQueue.main.async { [weak self] in
                    self?.onOutsideClick?()
                }
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            removeMonitor()
        }
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
