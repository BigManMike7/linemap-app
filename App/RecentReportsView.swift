import LineMapCore
import SwiftUI

/// Made a wrong report? (FR-41): the person's own reports and finished timed
/// waits from the last 24 hours, each with Delete. Opened from Settings.
struct RecentReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState = .loading
    @State private var pendingDelete: MyReport?
    @State private var deleting: MyReport.Target?
    @State private var errorMessage: String?

    private enum LoadState {
        case loading
        case failed
        case loaded([MyReport])
    }

    var body: some View {
        content
            .navigationTitle("Recent reports")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .refreshable { await load() }
            .confirmationDialog("Delete this report?", isPresented: isConfirming, titleVisibility: .visible,
                                presenting: pendingDelete) { item in
                Button("Delete", role: .destructive) {
                    Task { await delete(item) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This can't be undone.")
            }
            .alert("Couldn't delete", isPresented: hasError) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
            .accessibilityIdentifier("recent-reports")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Couldn't load your reports", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        case .loaded(let items) where items.isEmpty:
            ContentUnavailableView("No recent reports", systemImage: "tray",
                                   description: Text("Reports you make show here for 24 hours."))
        case .loaded(let items):
            List {
                Section {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
        }
    }

    private func row(_ item: MyReport) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.bar(item.barId)?.name ?? "A bar")
                    .font(.headline)
                Text(item.summary)
                    .font(.subheadline)
                Text(item.at, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if deleting == item.target {
                ProgressView()
            } else {
                Button("Delete", role: .destructive) {
                    pendingDelete = item
                }
                .buttonStyle(.bordered)
                .disabled(deleting != nil)
                .accessibilityLabel("Delete report at \(model.bar(item.barId)?.name ?? "this bar")")
                .accessibilityIdentifier("delete-report-button")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var hasError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func load() async {
        do {
            state = .loaded(try await model.recentReports())
        } catch {
            if case .loaded = state { return } // keep showing the last list
            state = .failed
        }
    }

    private func delete(_ item: MyReport) async {
        deleting = item.target
        defer { deleting = nil }
        do {
            switch try await model.deleteReport(item) {
            case .deleted, .notFound:
                if case .loaded(let items) = state {
                    state = .loaded(items.filter { $0.target != item.target })
                }
            case .sessionOpen:
                errorMessage = "That timer is still running. Stop it from the timer card."
            }
        } catch {
            errorMessage = "Check your connection and try again."
        }
    }
}
