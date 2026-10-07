import LineMapCore
import UIKit
import SwiftUI

/// The Settings tab (FR-5, FR-44): Made a wrong report? (FR-41), Time in lines
/// (FR-48), the privacy policy and support pages, the contact email, and the
/// anonymous ID, which people email to support to delete their data (FR-32).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Shows "Copied" on the Copy ID button for a moment.
    @State private var copiedID = false

    private let version = AppVersion(infoDictionary: Bundle.main.infoDictionary).label

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Made a wrong report?") {
                        RecentReportsView()
                    }
                    .accessibilityIdentifier("recent-reports-link")
                } footer: {
                    Text("Delete a report you made in the last 24 hours.")
                }

                TimeInLinesSection()

                Section("About") {
                    Link("Privacy policy", destination: AppConfig.privacyURL)
                    Link("Support", destination: AppConfig.supportURL)
                    if let mail = URL(string: "mailto:\(AppConfig.contactEmail)") {
                        Link(AppConfig.contactEmail, destination: mail)
                    }
                    LabeledContent("Version", value: version)
                }

                if let anonId = model.anonId?.uuidString {
                    Section {
                        Text(anonId)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .accessibilityLabel("Anonymous ID")
                        Button {
                            UIPasteboard.general.string = anonId
                            copiedID = true
                            UIAccessibility.post(notification: .announcement, argument: "ID copied")
                        } label: {
                            if copiedID {
                                Label("Copied", systemImage: "checkmark")
                            } else {
                                Text("Copy ID")
                            }
                        }
                        .sensoryFeedback(.success, trigger: copiedID) { _, copied in copied }
                        .task(id: copiedID) {
                            guard copiedID else { return }
                            try? await Task.sleep(for: .seconds(2))
                            copiedID = false
                        }
                        .accessibilityIdentifier("copy-id-button")
                    } header: {
                        Text("Anonymous ID")
                    } footer: {
                        Text("A random ID that isn't linked to you. Support may ask for it. To delete your data, email support with this ID.")
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .accessibilityIdentifier("settings")
    }
}

/// Time in lines (FR-48): the person's total from every timed wait that ended
/// with I'm in or Gave up, Adjust time included. It loads each time Settings
/// shows, so a wait just finished or deleted is counted right.
private struct TimeInLinesSection: View {
    @Environment(AppModel.self) private var model
    @State private var failed = false

    var body: some View {
        Section {
            content
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("wait-stats")
                .task {
                    do {
                        try await model.refreshWaitStats()
                        failed = false
                    } catch {
                        failed = true
                    }
                }
        } header: {
            Text("Time in lines")
        } footer: {
            Text("All your timed lines from the past year, from Start line timer to I'm in or Gave up.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let stats = model.waitStats {
            if stats.waits == 0 {
                Label("No lines timed yet", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "hourglass")
                        .font(.title)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stats.totalLabel)
                            .font(.title.bold())
                        Text(stats.detailLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } else if failed {
            Text("Couldn't load your time. Check your connection.")
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }
}
